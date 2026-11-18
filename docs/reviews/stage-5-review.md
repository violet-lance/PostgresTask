# Review — Stage 5 (confirm job by seconds parity)

Date: 2026-11-18
Reviewed: commit `8652da8` — `sql/primary/06_job_functions.sql`, `sql/primary/08_jobs.sql`, `verify/05_confirm_job.sql`, Stage 5 section of the [implementation log](../04-implementation-log.md).

## Method

1. Re-reading the function with the question "what can stop confirmations?" — locks, concurrency, interaction with the scheduler.
2. **Fault injection on the running system:** a pending row was held under `SELECT … FOR UPDATE` for 12 s by another session, before and after the fix.
3. Measuring confirmation latency from the audit log (`op_date` → `run_at` of the confirming run).

## Findings

| ID | Sev. | Finding | Resolution |
|----|------|---------|------------|
| S5-01 | **Major** | **One locked row stalled all confirmations.** The `UPDATE … WHERE status = 0 AND id % 2 = p` waits on any matching row locked by another transaction. Measured: a run blocked for **10.4 s**; pg_cron skipped the runs at :40, :43, :46 (a job never overlaps itself); 3 other operations waited > 5 s. | **Fixed (decision confirmed by me):** candidates are taken with `SELECT … FOR UPDATE SKIP LOCKED` and the `UPDATE` joins them on the full PK. Re-test with the same 12-s lock: **max run duration 0.013 s, 0 failed runs**. The locked row was confirmed by the first run with its parity after the lock was released (lock released ~:13, confirmed :14). |
| S5-02 | Info | **Structural confirmation latency up to ~6 s.** Inserts happen on multiples of 5 s, confirmations on multiples of 3 s, and only half of the runs match a given id's parity. Measured on normal operation: typically 2–5.5 s (e.g. inserted `:00.1`, odd id; run `:02` is even → confirmed by run `:05`, 5.5 s). | Inherent to the requirement. The verification liveness threshold (no pending row older than 10 s) is consistent with it. My first ad-hoc query used 5 s and flagged normal rows; that threshold was wrong, not the system. |
| S5-03 | Info | After a long run, pg_cron starts the next run **immediately** when the previous one ends, and the schedule phase shifts (observed `:37.209` → `:47.577` → `:50.580`). | Documented. The cadence check (gaps 2.5–3.5 s) flags such an event, which is the desired behaviour. With S5-01 fixed, row locks no longer cause it. |
| S5-04 | Info | **SKIP LOCKED trade-off:** a row that stays locked is never confirmed while it is locked. | Correct by definition (a row someone else holds can't be updated). It is still visible: check 6 (no pending row older than 10 s) fails while it lasts. |
| S5-05 | Info | After downtime, the first run confirms *all* pending rows of one parity, and `confirmed_ids` holds all of them in one array. | Bounded by the backlog, which is acceptable. The seed backlog of ~400 ids was handled in 2 runs. |
| S5-06 | Info | Concurrent manual call + job: with SKIP LOCKED the two callers **split** the candidates instead of waiting, and never double-process a row. | Positive side effect, noted. |
| S5-07 | Info | Stage 6 will add the MV refresh to this `UPDATE` statement. The refresh runs inside the confirm transaction, so run duration will grow. | **Carried to Stage 6:** measure the confirm run duration with the MV refresh. |

## Verification after the fix

- The function was replaced in place, the lock test repeated (above), then a **fresh `down -v && up`**. Results: `05_confirm_job` 9/9 PASS (29 runs, 414 ids, 0 violations, 100% alternation in that window). Changed check 8 (now explains the candidate query) was negative-tested: with the partial index dropped → `FAIL`, seq scans on populated partitions.
- Full suite: `01` 10/10, `02` 12/12, `03` 12/12, `04` 6/6, `05` 9/9.

Not covered by the automated verification: the lock scenario needs two concurrent sessions, which a single psql script can't create without installing `dblink`. It is documented here as a manual test with measured results.

## Verdict

Stage 5 is **accepted**. One major robustness fix (row-lock stall), latency characterised, one item carried to Stage 6 (S5-07).
