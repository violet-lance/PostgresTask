# PostgresTask

PostgreSQL 17 test assignment, implemented entirely in the database:

- a partitioned operations table;
- a batched data generator;
- globally unique operation GUIDs on a partitioned table;
- second-level `pg_cron` jobs;
- a materialized view refreshed on status changes;
- logical replication to a second instance.

Everything runs with one command and is checked by **86 automated checks**.

```
                     pg-primary  (localhost:5433)                              pg-replica  (localhost:5434)
 ┌──────────────────────────────────────────────────────────────┐    ┌──────────────────────────────────────────────┐
 │ pg_cron ── every 5 s ─► ops.insert_random_operation()        │    │                                              │
 │         ── every 3 s ─► ops.confirm_operations_by_parity()   │    │                                              │
 │                                │                             │    │                                              │
 │                                ▼                             │    │                                              │
 │  ops.operations (T1)  RANGE(op_date), monthly + DEFAULT      │    │  ops.operations (T1)  same partitioning,     │
 │   ├─ BEFORE INSERT ─► ops.operation_guid_registry (PK guid)  │    │   read-only for local sessions               │
 │   │   + composite FK (guid, op_date)  → global GUID unique   │    │                                              │
 │   └─ AFTER stmt triggers ─► REFRESH MATERIALIZED VIEW        │    │                                              │
 │                              CONCURRENTLY                    │    │                                              │
 │                              ops.client_type_totals          │    │                                              │
 │                                                              │    │                                              │
 │  PUBLICATION ops_pub (publish_via_partition_root) ───────────┼───►│  SUBSCRIPTION ops_sub                        │
 └──────────────────────────────────────────────────────────────┘    └──────────────────────────────────────────────┘
```

## Quick start

Requirements: Docker with Compose v2; bash (Linux/macOS, or Git Bash/WSL on Windows) for the verification runner.

```bash
docker compose up -d --wait     # builds the image, initialises both instances, seeds 100k rows (~15 s)
bash verify/run.sh              # waits for ~90 s of job history on first run, then runs all checks
                                # Windows: powershell -File verify\run.ps1
docker compose down -v          # stop and wipe (init scripts re-run on the next start)
```

Expected summary:

```
Req 1  partitioned T1           (pg-primary)          10 PASS    0 FAIL
Req 1  partitioned T1           (pg-replica)          10 PASS    0 FAIL
Req 2  data generator           (pg-primary)          12 PASS    0 FAIL
Req 3  GUID uniqueness          (pg-primary)          12 PASS    0 FAIL
Req 4  insert job every 5 s     (pg-primary)           6 PASS    0 FAIL
Req 5  confirm job every 3 s    (pg-primary)           9 PASS    0 FAIL
Req 6  materialized view        (pg-primary)          11 PASS    0 FAIL
Req 7  logical replication      (both)                16 PASS    0 FAIL
TOTAL                                                 86 PASS    0 FAIL
```

Connect: `docker exec -it pg-primary psql -U postgres -d opsdb` (or `localhost:5433`, `postgres`/`postgres`; replica on `5434`). Credentials are demo defaults, overridable via `.env` (see `.env.example`).

## Requirement → implementation

The task says names are not to be taken literally, so meaningful names are used. `COMMENT ON` on every column maps it back to the task's terms.

| # | Requirement | Objects | SQL | Verification |
|---|-------------|---------|-----|--------------|
| 1 | Partitioned T1: date, id, amount, status, operation guid, jsonb message (account, client id, online/offline) | `ops.operations` — `op_date`, `id`, `amount`, `status`, `operation_guid`, `message`; RANGE by month + DEFAULT; jsonb `CHECK`s; `ops.ensure_monthly_partitions()` (self-healing); daily `partition-maintenance` job | `sql/common/02_operations.sql` | `verify/01_table.sql` |
| 2 | Generate ≥ 100k rows over 3–4 months with a procedure/function | `CALL ops.generate_operations(…)`: set-based chronological batches, `COMMIT` per batch; valid UA IBANs from a consistent client/account pool | `sql/primary/04_generator.sql`, `05_seed.sql` | `verify/02_generator.sql` |
| 3 | Uniqueness by operation guid | `ops.operation_guid_registry` (PK on guid) + BEFORE INSERT trigger + composite FK `(operation_guid, op_date)`. Uniqueness is enforced by constraints across all partitions | `sql/primary/03_guid_registry.sql` | `verify/03_guid_uniqueness.sql` |
| 4 | Job adding a row with status 0 every 5 s | pg_cron `insert-operation` → `ops.insert_random_operation()` | `06_job_functions.sql`, `08_jobs.sql` | `verify/04_insert_job.sql` |
| 5 | Job every 3 s: status 0→1 for even ids on even seconds, odd on odd | pg_cron `confirm-operations` → `ops.confirm_operations_by_parity()` (`FOR UPDATE SKIP LOCKED`); audit `ops.confirm_job_log` | `06_job_functions.sql`, `08_jobs.sql` | `verify/05_confirm_job.sql` |
| 6 | Totals per client and operation type in a materialized view, refreshed on every 0→1 | `MATERIALIZED VIEW ops.client_type_totals` (confirmed operations); statement-level triggers → `REFRESH … CONCURRENTLY` in the same transaction, serialised by an advisory lock; `ops.mv_refresh_log` | `sql/primary/07_materialized_view.sql` | `verify/06_materialized_view.sql` |
| 7 | Replicate T1 to another instance | `PUBLICATION ops_pub` (via partition root), role `replicator`; `SUBSCRIPTION ops_sub`; replica T1 read-only for local sessions | `sql/primary/09_publication.sql`, `sql/replica/03_read_only_guard.sql`, `04_subscription.sql` | `verify/07_replication.sh` |

## Watching it work

```sql
-- On pg-primary ---------------------------------------------------------------
-- jobs and their latest runs
SELECT jobname, schedule, active FROM cron.job ORDER BY jobid;
SELECT j.jobname, d.start_time, d.status, d.return_message
FROM cron.job_run_details d JOIN cron.job j USING (jobid) ORDER BY d.runid DESC LIMIT 10;

-- requirement 5: which second, which parity, which ids were confirmed
SELECT run_at, run_second, parity, rows_confirmed, confirmed_ids FROM ops.confirm_job_log ORDER BY run_id DESC LIMIT 10;

-- requirement 6: the view, and the refreshes caused by each confirm run (same transaction => same timestamp)
SELECT * FROM ops.client_type_totals ORDER BY total_amount DESC LIMIT 10;
SELECT c.run_at, c.rows_confirmed, r.rows_flipped_0_to_1, r.duration_ms
FROM ops.confirm_job_log c LEFT JOIN ops.mv_refresh_log r ON r.refreshed_at = c.run_at ORDER BY c.run_id DESC LIMIT 10;

-- requirement 7: replication from the publisher's side
SELECT application_name, state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes FROM pg_stat_replication;

-- On pg-replica ---------------------------------------------------------------
SELECT subname, pid, last_msg_receipt_time FROM pg_stat_subscription;
SELECT count(*), max(id) FROM ops.operations;               -- compare with the primary
```

Useful entry points: `CALL ops.generate_operations(p_rows => …, p_from => …, p_to => …)` for more data; `SELECT ops.refresh_totals();` for a safe manual refresh; `SELECT ops.housekeeping();` prunes job history and audit logs (also scheduled daily).

## Design highlights

Full reasoning is in [the decision log](docs/decisions.md) and the [reviews](docs/reviews/).

- **Global GUID uniqueness on a partitioned table.** PostgreSQL requires unique constraints to include the partition key. A registry with `PK (guid)`, plus a composite FK from T1 and T1's `UNIQUE (guid, op_date)`, makes duplicates impossible *by constraints*. This was proven with the trigger disabled and under concurrent inserts. Idempotent `INSERT … ON CONFLICT DO NOTHING` retries keep working.
- **Parity uses `floor()` of epoch seconds.** The plan's `extract(second …)::int` would *round*, giving the wrong parity about half the time. pg_cron timing was measured. Parity is applied to the second the confirm transaction actually observes, and every run is audited.
- **Concurrency-safe MV refresh.** A REFRESH that waited for another one would have recomputed from a stale snapshot and silently undone the other transaction's change (reproduced). Refreshes are serialised by an advisory lock taken *before* the REFRESH statement. The confirm job takes that lock before any row lock, so it can't deadlock.
- **Replication-safe partition self-healing.** Rows that land in DEFAULT are moved into a new partition while DEFAULT is detached, so nothing is published. The naive DELETE+INSERT variant was shown to silently desync the replica.
- **Operational guards:** `SKIP LOCKED` (a single locked row once stalled the confirm job for 10 s); a read-only guard on the replica (local writes silently diverged); `max_slot_wal_keep_size` on the primary; daily housekeeping of high-frequency logs.

## Known limitations

- The MV is recomputed in full on each refresh: ~45 ms at 100k confirmed rows, ~56 ms at 300k (parallel aggregate). The upgrade path for large volumes is an incrementally maintained summary table.
- Logical replication doesn't replicate DDL or sequences. Apply schema changes to both sides; if the replica is ever promoted, `setval` the id sequence first.
- `session_replication_role = replica` (superuser only) disables triggers *and* FK enforcement, so the GUID registry can be bypassed that way. Only a global unique index could prevent that, and PostgreSQL has none for partitioned tables.
- A pending operation is confirmed within ~6 s (5-s insert grid vs. 3-s parity grid). Strict even/odd alternation of consecutive runs holds ~98% of the time, because pg_cron's start can fall into the next second. The rule itself is always applied correctly.
- Demo security: superuser jobs, inline replication password, open `pg_hba`. Production notes are in the reviews.

## Troubleshooting

- **Init failed halfway** (`docker logs pg-primary`): the data volume is already initialised, so init scripts won't re-run. Use `docker compose down -v && docker compose up -d --wait`.
- **Ports 5433/5434 in use:** set `PRIMARY_PORT` / `REPLICA_PORT` in `.env`.
- **Job checks fail right after start:** the runner waits for 90 s of job history automatically. When running single scripts by hand, give the jobs a minute first.
- **Harmless log lines during init:** `database "opsdb" does not exist` (pg_cron starts before the DB exists in the temporary init server) and `logical replication launcher … exited with exit code 1` (the temporary init server shutting down).

## Repository layout

```
docker-compose.yml, docker/postgres/   two PostgreSQL 17.12 + pg_cron instances, init runner
sql/common/      schema, T1, partition maintenance                       (both instances)
sql/primary/     registry, generator, seed, jobs, MV, publication        (pg-primary)
sql/replica/     read-only guard, subscription                           (pg-replica)
verify/          one check script per requirement + run.sh / run.ps1
docs/            how the solution was designed (below)
```

## How it was designed

The process is documented step by step:

1. [Task statement & breakdown](docs/00-task.md)
2. Grilling sessions (each decision with alternatives and reasoning): [1 — architecture](docs/01-grilling-session-1.md) · [2 — integrity & aggregation](docs/01-grilling-session-2.md) · [3 — data & replica](docs/01-grilling-session-3.md) · [4 — conventions](docs/01-grilling-session-4.md)
3. [Implementation plan](docs/02-plan.md)
4. [Plan review](docs/03-plan-review.md), with a [feasibility spike](docs/spikes/plan-review-spike.sql) run before writing code
5. [Implementation log](docs/04-implementation-log.md): what was built per stage, problems hit, deviations from the plan
6. Stage reviews (each stage reviewed after its commit; defects reproduced, fixed, re-verified): [1](docs/reviews/stage-1-review.md) · [2](docs/reviews/stage-2-review.md) · [3](docs/reviews/stage-3-review.md) · [4](docs/reviews/stage-4-review.md) · [5](docs/reviews/stage-5-review.md) · [6](docs/reviews/stage-6-review.md) · [7](docs/reviews/stage-7-review.md)
7. [Decision log](docs/decisions.md): D-01 … D-23

The git history follows the same path: one commit per planning step, stage and review.
