# Review — Stage 4 (insert job every 5 s)

Date: 2026-11-18
Reviewed: commit `5c4a9d1` — `sql/primary/06_job_functions.sql`, `sql/primary/08_jobs.sql`, `verify/04_insert_job.sql`, Stage 4 section of the [implementation log](../04-implementation-log.md).

## Method

1. Re-reading the function, schedules and verification checks.
2. **Measuring how pg_cron actually schedules interval jobs** over the full run history (127 runs, ~10.5 min), because Stage 5 depends on the exact *second* at which a job runs.
3. Checking scheduler-related settings (worker pools, time zone, job owner).

## Key measurement: how pg_cron times interval jobs

| Observation | Value |
|-------------|-------|
| Runs vs. elapsed time | 127 runs from 19:05:05 to 19:15:35 = exactly 126 × 5 s → **no skipped or doubled runs** |
| Wall-clock alignment | `epoch mod 5 = 0` for **all** runs → runs land on :00, :05, :10, … |
| Offset inside the second | Drifts slowly (~0.7 ms per second of runtime) from 0 to 997 ms, then wraps to 0. The start **never leaves the scheduled second** |
| `now()` inside the job vs. `start_time` | +1 … +12 ms |
| Run duration | 7–42 ms |

**Consequence for Stage 5 (S4-01, Info → design input).** When the intra-second offset is close to 1000 ms, `now()` in the job's transaction can already be in the **next** second. For the 3-second job, the "seconds parity" seen by the function then differs from the scheduled second's parity. In other words, parity alternates on most runs, but not *always*. My estimate: a ~1% chance per run (a 1–12 ms window out of 1000 ms). Stage 5 design:
- Parity is taken from `now()`: the moment the confirming transaction actually runs is the honest reading of "the number of seconds".
- The audit log stores the second actually used.
- Verification checks **parity correctness per run** (confirmed ids ↔ logged second). Strict alternation is only reported as a statistic, not required.

## Findings

| ID | Sev. | Finding | Resolution |
|----|------|---------|------------|
| S4-01 | Info | pg_cron timing behaviour (above): aligned to the wall clock, intra-second drift, `now()` can cross into the next second | Carried into the Stage 5 design |
| S4-02 | Minor | Misleading comment: "returns the new id (visible in `cron.job_run_details.return_message` …)". pg_cron records only `1 row`, not the returned value | **Fixed** the comment |
| S4-03 | Info | Verify check 5 attributes rows to runs by time window (`op_date` between run start and end). Any other insert in that window (manual, a concurrent generator call) would be counted too. An exact attribution would need a marker in the row, which isn't worth changing the message contract for | **Accepted, documented.** The check is precise on an otherwise idle system (the 3-s job only updates) |
| S4-04 | Info | Check 4 (gaps within 4.5–5.5 s) could fail under heavy load if pg_cron is delayed | Accepted. Measured gaps are exactly 5.00 s; a delay of > 0.5 s *is* worth flagging |
| S4-05 | Info | Jobs run as the superuser `postgres` | Production note: schedule them as a dedicated low-privilege role (pg_cron runs a job as its `username`). Not applied: single-superuser assignment |
| S4-06 | Info | `cron.max_running_jobs = 5`: at most 5 jobs run at once (3 jobs exist) | Enough. `max_worker_processes = 32` also leaves room for 8 parallel workers + 4 logical-replication workers (Stage 7) |
| S4-07 | Info | Runs missed while the server is down are not backfilled | Correct for this requirement ("every 5 s" while running) |

Also confirmed: `cron.timezone = GMT`, so the daily jobs (`partition-maintenance` 00:15, `cron-history-cleanup` 00:30) run in UTC, consistent with UTC partition bounds.

## Verdict

Stage 4 is **accepted**. One comment fixed. The main output of this review is the pg_cron timing measurement, which changes how Stage 5 is verified.
