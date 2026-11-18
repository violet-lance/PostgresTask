# Review — Stage 1 (partitioned table T1)

Date: 2026-11-18
Reviewed: commit `79756fa` — `sql/common/01_schema.sql`, `sql/common/02_operations.sql`, `verify/01_table.sql`, Stage 1 section of the [implementation log](../04-implementation-log.md).

## Method

1. Line-by-line re-reading of the SQL with the question "under what conditions does this break?": concurrency, session settings, schema evolution, interaction with later stages (GUID registry FK, triggers, logical replication).
2. Suspicious behaviour was **measured on the running instance**, not assumed: lock modes taken by the self-healing path (`pg_locks`), and how the "current month" depends on the session `TimeZone`.
3. Review of the verification script itself: does it check what the plan says must be checked?
4. Consistency of the docs with what was actually built.

## Findings

Severity: **Major** — wrong result or hole under realistic conditions · **Minor** — robustness/hygiene · **Info** — accepted trade-off, documented.

| ID | Sev. | Finding | Resolution |
|----|------|---------|------------|
| S1-01 | Minor | `ops.create_month_partition()` is a public function, but only `ensure_monthly_partitions()` took the advisory lock. Two direct concurrent calls could race on "exists? → create". | **Fixed.** The same advisory lock is taken in `create_month_partition()` as well. Advisory xact locks are re-entrant, so the nested call from `ensure_…` doesn't self-deadlock. |
| S1-02 | Minor | "Current month" was computed with `date_trunc('month', now())`, i.e. in the **session** `TimeZone`, while partition bounds are UTC. Measured: for `2026-11-30 12:00 UTC` a `UTC+14` session gets `2026-12-01`, UTC gets `2026-11-01`. Harmless today (server TZ is UTC, and there's a 2-month buffer), but it is an inconsistency. | **Fixed.** All month arithmetic uses `now() AT TIME ZONE 'UTC'` / `timestamp` values. Verified: in a `Pacific/Kiritimati` (UTC+14) session the maintenance creates 0 extra partitions. |
| S1-03 | Minor | The self-healing move used `INSERT … SELECT *`. That relies on `operations_default` (created as `PARTITION OF`) and the new table (created with `LIKE`) having the same physical column order. A future `ALTER TABLE … DROP/ADD COLUMN` on the parent could break this. | **Fixed.** Explicit column list built from `pg_attribute` of the parent. |
| S1-04 | Minor | The plan's verification for D-18 says "`DEFAULT` must be empty on both instances", but `verify/01_table.sql` didn't check it. | **Fixed.** New check #1 (run before the script inserts anything). Now 10 checks. |
| S1-05 | Minor | Docs drift: the plan placed the partition-maintenance job in `primary/08_jobs.sql` and `replica/03_partitions_and_jobs.sql`; it was implemented once in `common/02_operations.sql`. | **Fixed.** Plan layout and Stage 7 text updated. One definition for both instances is simpler, and it also guarantees the replica has partitions before it subscribes. |
| S1-06 | Info | **Measured:** the self-healing path holds `AccessExclusiveLock` on `ops.operations` (from `DETACH PARTITION`) until commit, so reads of T1 (including the MV refresh) wait while rows are moved out of `DEFAULT`. | **Accepted.** `DEFAULT` is a safety net that is normally empty (partitions are pre-created 2 months ahead), so the path is rare and moves few rows. `DETACH … CONCURRENTLY` can't be used: it isn't allowed inside a transaction block, and atomicity of the move is the whole point. |
| S1-07 | Info | No index on `op_date` alone. | **Accepted (YAGNI).** No workload in the task filters by a date range inside a month. Partition pruning covers month-level filtering. If needed later, a BRIN index on `op_date` would be the cheap choice for append-mostly time-series data. |
| S1-08 | Info | The verification scripts insert rows inside a rolled-back transaction. Identity sequences are non-transactional, so every run "burns" a few ids. | **Accepted.** Harmless: ids are surrogate keys, and gaps are normal (requirement 5 only cares about parity of existing ids). |
| S1-09 | Info | The claim that the self-healing path is **replication-safe** (no DML published while tables are detached) is reasoned, not yet tested. | **Tracked** → explicit test in Stage 7 with live logical replication. |

## Things checked and found correct

- **Lock ordering / deadlock risk** of self-healing vs. a concurrent insert: the function holds only `AccessShareLock` on `operations_default` when it requests `AccessExclusiveLock` on the parent. A concurrent insert holds `RowExclusiveLock` on the parent and requests `RowExclusiveLock` on the partition, which is compatible with `AccessShareLock`. So the insert completes and releases its locks, then maintenance proceeds. No cycle.
- **Interaction with later stages:** row-level triggers (GUID registry) and FKs on the parent are cloned to partitions on `ATTACH`. Statement-level triggers (MV refresh) stay on the parent. Rows moved into a standalone table don't fire the registry trigger, which is correct because they are already registered.
- **`client_id` regex** `^[1-9][0-9]{0,17}$` on `message->>'client_id'`: jsonb normalises numbers (`1e3` → `1000`), non-integers (`1.5`, `1.0`) and negatives are rejected, and 18 digits always fit `bigint`, so the expression-index cast can't overflow.
- **Index/constraint parity** of self-healed partitions (4 indexes, 6 `CHECK`s), already verified in Stage 1.

## Re-verification after fixes

`docker compose down -v && docker compose up -d --wait`, then `verify/01_table.sql` on both instances: **10/10 PASS on pg-primary and pg-replica**. Extra: UTC+14 session → 0 partitions created; direct `create_month_partition('2026-11-15')` on an existing month → `false`.

## Verdict

Stage 1 is **accepted**. 5 minor issues fixed, 3 trade-offs documented, 1 item carried to Stage 7 (S1-09).
