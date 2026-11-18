# Review — Stage 6 (materialized view)

Date: 2026-11-18
Reviewed: commit `e3fd8c2` — `sql/primary/07_materialized_view.sql`, `verify/06_materialized_view.sql`, Stage 6 section of the [implementation log](../04-implementation-log.md).

## Method

1. Re-reading the trigger with the question "what happens when **two transactions** change the confirmed set at the same time?". The Stage 6 verification only covered sequential behaviour.
2. **Reproduction on the running primary with the jobs paused**, so the timing is deterministic: two concurrent sessions for the snapshot race; a multi-statement transaction vs. the confirm path for the deadlock.
3. Repeating each reproduction after the fix, plus a lock-timeout test.
4. Measuring refresh cost at 100k and 300k confirmed rows.

## Findings

| ID | Sev. | Finding | Resolution |
|----|------|---------|------------|
| S6-01 | **Major** | **Concurrent refreshes could silently lose committed changes.** In READ COMMITTED a statement takes its snapshot when it *starts*. `REFRESH … CONCURRENTLY` waits for the MV's `ExclusiveLock` **after** that. So if transaction A refreshed and was still open, transaction B's REFRESH waited, and after A committed, B recomputed the view from a snapshot taken *before* A's commit and wrote it, undoing A. **Reproduced:** A added +1000.00 to client 10, B touched client 20; afterwards the MV showed `274265.33` vs live `275265.33`. The MV stayed wrong until the next refresh. | **Fixed.** The trigger takes a transaction-level **advisory lock in a separate statement before** `REFRESH`, so the REFRESH statement (and its snapshot) starts only after the previous refresher has committed. `LOCK TABLE` would be the natural tool, but it is **not supported for materialized views** (`This operation is not supported for materialized views`, verified), hence the advisory lock. Key: `ops.mv_refresh_lock_key()`. **Re-test: 0 differing groups.** |
| S6-02 | **Major** | **Deadlock between a multi-statement transaction and the confirm path.** M changes a confirmed row (its refresh holds the MV lock), then updates pending row P. J confirms P (holding P's row lock) and its refresh waits for the MV lock. Cycle. **Reproduced:** `deadlock detected … waits for ExclusiveLock on relation … blocked by process …`. | **Fixed for the job:** `confirm_operations_by_parity()` takes the same advisory lock **first**, before touching any row, with `SET lock_timeout = '2s'`. The job then never waits for the lock while holding row locks (and never waits for rows: SKIP LOCKED). **Re-test with the real function, timed server-side so that J runs in P's parity second:** J waited 1–2 s for M, M committed, P was confirmed, no deadlock (2/2 attempts). If M holds the lock > 2 s, the run fails with `canceling statement due to lock timeout` (visible in `cron.job_run_details`) and the next run retries; this was tested too. **Remaining risk (documented):** two *ad-hoc* multi-statement transactions can still deadlock with each other. PostgreSQL detects it and aborts one; keep transactions that change confirmed rows short. |
| S6-03 | Minor | A bare `REFRESH MATERIALIZED VIEW` by an operator bypasses the advisory lock and can hit the S6-01 race. | **Fixed:** `ops.refresh_totals()` takes the lock first and logs the refresh as `MANUAL` (allowed in the log's `CHECK`). Tested: 51 ms, logged as `MANUAL`. |
| S6-04 | Info | **Privileges:** `REFRESH` needs ownership of the MV (or the PG 17 `MAINTAIN` privilege). An application role updating T1 would therefore fail every confirming update (refresh error → abort, D-16). | Production note: `GRANT MAINTAIN ON ops.client_type_totals TO app_role`, or make the trigger function `SECURITY DEFINER`. Not applied (single superuser). |
| S6-05 | Info | **Scalability, measured** (3 runs each): 100k confirmed rows → **44–45 ms**; 300k → **55–60 ms**. The aggregate runs as a parallel hash aggregate (2 workers), so cost grows sub-linearly here; the fixed part is the concurrent diff of ~2000 groups. | The plan's "full recomputation" limitation stands, but at the current growth (~17k rows/day from the 5-s job) it stays far below the 3-s budget for a long time. The incremental summary table (D-08) remains the upgrade path. |
| S6-06 | Info | **S3-06 (carried) verified closed:** a later `CALL ops.generate_operations(200000, …)` caused exactly 10 refreshes (one per batch, via the INSERT trigger), and the MV matched live data afterwards. | Closed. |

Also checked: `ops.housekeeping(interval '0 seconds')` prunes `cron.job_run_details`, `confirm_job_log` and `mv_refresh_log` (46 / 29 / 17 rows in a rolled-back test).

## Mistakes in my own testing during this review (recorded for honesty)

- The first deadlock re-test after the fix was **inconclusive**: J started in a second of the wrong parity, so it never wanted P and no deadlock was possible. My second attempt timed J from the Windows host clock, which drifted from the Docker VM clock, and missed again. The final test does the waiting **inside the database** (`pg_sleep` up to the next second of P's parity), then calls the function in a new transaction. That test is conclusive.
- A first check of `ops.refresh_totals()` reported its log row as `UPDATE`. The cause was the same visibility trap as in Stage 4: a sub-select in the same statement as the function call can't see the row the function inserted. Re-checked in separate statements: `MANUAL`.
- One test printed an "amount bumped" column that was meaningless (`… OR true`). The no-deadlock conclusion rests on M committing without an error, not on that column.

## Re-verification

After a fresh `down -v && up` with all fixes: full suite **60/60 PASS** (`01` 10, `02` 12, `03` 12, `04` 6, `05` 9, `06` 11). The concurrency scenarios need two sessions and aren't part of the single-session verification scripts; they're documented here with measured results.

## Verdict

Stage 6 is **accepted**. Two major concurrency defects (lost update via the snapshot race, deadlock with the confirm path) were found by reproduction and fixed, a safe manual-refresh path was added, and scalability is now backed by measurements.
