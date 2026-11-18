# Decision Log

One line per decision. Details, alternatives and reasoning are in the linked session files.

| ID | Topic | Decision | Source |
|----|-------|----------|--------|
| D-01 | Environment | Docker Compose, two PostgreSQL 17 containers (publisher + subscriber) | [Session 1 · Q1.1](01-grilling-session-1.md#q11--environment-how-do-we-run-two-postgresql-instances-primary--replica) |
| D-02 | Docs language | All `.md` docs and logs in English | [Session 1 · Q1.1](01-grilling-session-1.md) |
| D-03 | General-purpose language | .NET + EF Core, only if needed | [Session 1 · Q1.1](01-grilling-session-1.md) |
| D-04 | Scheduler | `pg_cron` with second-level interval schedules | [Session 1 · Q1.2](01-grilling-session-1.md) |
| D-05 | Replication | Logical replication, `publish_via_partition_root = true` | [Session 1 · Q1.3](01-grilling-session-1.md) |
| D-06 | Partitioning | RANGE by `op_date`, monthly, + `DEFAULT` partition + scheduled pre-creation of future partitions | [Session 1 · Q1.4](01-grilling-session-1.md) |
| D-07 | GUID uniqueness | Non-partitioned GUID registry table (PK on guid) filled by BEFORE INSERT trigger + **composite** FK `(operation_guid, op_date)` from T1 — uniqueness is enforced by constraints alone *(amended in review R-02)* | [Session 2 · Q2.1](01-grilling-session-2.md), [Review R-02](03-plan-review.md#r-02--major--guid-uniqueness-silently-depended-on-the-trigger--fixed-confirmed-by-spike) |
| D-08 | Aggregation | Real `MATERIALIZED VIEW`, refreshed `CONCURRENTLY` by a statement-level trigger only when rows went 0→1 | [Session 2 · Q2.2](01-grilling-session-2.md) |
| D-09 | Aggregate semantics | Sum of confirmed (`status = 1`) operations only | [Session 2 · Q2.3](01-grilling-session-2.md) |
| D-10 | Tooling | No .NET; SQL scripts + Docker Compose + verification scripts | [Session 2 · Q2.4](01-grilling-session-2.md) |
| D-11 | Historical statuses | Older than 24 h → 1; last 24 h → mostly 0 | [Session 3 · Q3.1](01-grilling-session-3.md) |
| D-12 | Generator | Procedure, set-based batches with `COMMIT` per batch | [Session 3 · Q3.2](01-grilling-session-3.md) |
| D-13 | Message domain | Deterministic client/account pool + `CHECK` constraints on jsonb | [Session 3 · Q3.3](01-grilling-session-3.md) |
| D-14 | Subscriber shape | Same partitioned layout + own partition-maintenance job; no business jobs, no registry | [Session 3 · Q3.4](01-grilling-session-3.md) |
| D-15 | Naming | Schema `ops`, table `ops.operations`, meaningful columns, mapping in docs + `COMMENT ON` | [Session 4 · Q4.1](01-grilling-session-4.md) |
| D-16 | MV refresh failure | Abort the whole UPDATE (strong consistency, retried by next run) | [Session 4 · Q4.2](01-grilling-session-4.md) |
| D-17 | Git | One commit per stage, no push | [Session 4 · Q4.3](01-grilling-session-4.md) |
| D-18 | DEFAULT partition | Pre-create partitions ahead on both sides (subscriber: before subscribing); maintenance function moves rows out of `DEFAULT` and attaches the new partition in one transaction; `DEFAULT` must be empty in verification | [Review R-03](03-plan-review.md) |
| D-19 | Confirm-job audit | `ops.confirm_job_log` — run time, second, parity, rows confirmed — per run (primary only) | [Review R-06](03-plan-review.md) |
| D-20 | Coding rule | All objects schema-qualified; every function has `SET search_path = ops, pg_catalog` (PG 17 restricted search_path for MV maintenance). **Exception:** procedures that `COMMIT` (PostgreSQL forbids transaction control with a `SET` clause) rely on schema-qualification only | [Review R-04](03-plan-review.md), Stage 3 |
| D-21 | MV refresh scope | Statement-level triggers on INSERT/UPDATE/DELETE/TRUNCATE refresh the MV whenever the **confirmed set** changes (0→1 as required, plus 1→0, amount/message change of confirmed rows, insert/delete of confirmed rows); statements that do not touch confirmed rows never refresh | Stage 6 (asked before implementation) |
| D-22 | Replica write protection | T1 on the replica is read-only for local sessions (row-level BEFORE triggers cloned to partitions + TRUNCATE trigger); logical replication bypasses them (replica role); intentional maintenance uses the transaction-local flag `ops.allow_replica_writes` | [Stage 7 review S7-01](reviews/stage-7-review.md) |
| D-23 | Slot WAL retention | `max_slot_wal_keep_size = 1GB` on the primary: a long-absent replica gets its slot invalidated (re-sync needed) instead of filling the primary's disk | [Stage 7 review S7-02](reviews/stage-7-review.md) |
