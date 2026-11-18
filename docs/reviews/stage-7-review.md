# Review — Stage 7 (logical replication)

Date: 2026-11-18
Reviewed: commit `9b2f4a2` — `sql/primary/09_publication.sql`, `sql/replica/04_subscription.sql`, `verify/07_replication*`, Stage 7 section of the [implementation log](../04-implementation-log.md).

## Method

1. Going through the classic failure modes of logical replication: writes on the subscriber, WAL retention by slots, sequences, DDL, TRUNCATE, credentials.
2. Reproducing the most dangerous one (local writes on the replica) on the running pair.
3. Re-testing everything after the fixes, including partition self-healing on the now-guarded replica, plus negative runs.

## Findings

| ID | Sev. | Finding | Resolution |
|----|------|---------|------------|
| S7-01 | **Major** | **Local writes on the replica silently diverge from the primary.** Stage 7 already showed this for an `UPDATE` (fingerprint FAIL). In this review I expected a local `INSERT` with an id the primary would issue later to *stall* replication with a duplicate key. **It didn't, which is worse:** the PK is `(id, op_date)`, so the replicated row (same id, different `op_date`) didn't conflict, and the replica just had **one row more** than the primary, with 0 apply errors. | **Fixed (decision confirmed by me, D-22):** `replica/03_read_only_guard.sql` adds row-level `BEFORE INSERT OR UPDATE OR DELETE` triggers (cloned to every partition, so direct partition writes are caught too) and a `BEFORE TRUNCATE` trigger. They raise `read_only_sql_transaction`. The apply and table-sync workers run with `session_replication_role = replica`, where ordinary triggers don't fire, so replication is unaffected: the initial sync of 100k rows and live changes went through. Intentional local writes (partition self-healing, verification scripts) use a transaction-local flag `ops.allow_replica_writes`. `create_month_partition()` sets it only around the row move and restores it afterwards. |
| S7-02 | Major | **Unbounded WAL retention.** While the replica is away, slot `ops_sub` pins all WAL on the primary, so the primary's disk can fill up and take the primary down. | **Fixed (D-23):** `max_slot_wal_keep_size = 1GB` on the primary. Beyond that, the slot is invalidated and the replica must be re-synced: a replica problem instead of a primary outage. The publisher check verifies the setting and that the slot is within it (`wal_status=reserved`, `safe_wal_size≈1040 MB`). |
| S7-03 | Info | **Sequences are not replicated.** The replica's identity sequence for `ops.operations.id` stays at its start value. | Documented: if the replica is ever promoted to take writes, first `setval` the sequence to `max(id)`. Not needed for a read replica. |
| S7-04 | Info | **DDL is not replicated.** | Already documented (plan, known limitations). Partitions are independent on each side thanks to `publish_via_partition_root`. Schema changes must be applied to both, subscriber first for added columns. |
| S7-05 | Info | **TRUNCATE is published.** `TRUNCATE ops.operations` on the primary empties the replica too. | Intended: the replica mirrors T1. The verification's TRUNCATE test (`verify/06` #11) runs in a rolled-back transaction, so nothing is published. On the replica itself, a local TRUNCATE is now rejected by S7-01. |
| S7-06 | Info | **Credentials:** the subscription's connection string (with the replicator password) is stored in `pg_subscription.subconninfo`, which only superusers can read. `pg_hba` accepts the replicator from any host. | Production notes: a `passfile` / `.pgpass` instead of an inline password; restrict `pg_hba` to the replica's network and require `hostssl`. Not applied for the demo. |
| S7-07 | Info | The guard is a protection against accidents, not a security boundary: a superuser can set the flag or `session_replication_role`. | Documented in the guard's header. |

## Mistakes in my own testing during this review

- I **predicted the wrong failure** for the local-INSERT scenario (a stall). The reproduction showed silent divergence instead, which changed how severe I rate S7-01 and what the fix has to cover (UPDATE/DELETE as well, not just INSERT).
- The first version of guard check #8 tested a direct write with `DELETE FROM ops.operations_default`. DEFAULT is empty, so a row-level trigger had no row to fire on, and the check reported a false "ALLOWED". It now updates a row in a **populated** partition (5/5 rejected).

## Re-verification

Fresh `docker compose down -v && up`:
- `verify/07_replication.sh` — **16/16 PASS** (6 publisher, 8 subscriber, 2 live).
- Primary `01`–`06` — 60/60 PASS; replica `01_table` — 10/10 PASS.
- **Self-healing on the guarded replica** without setting the flag by hand: a replicated row in DEFAULT was moved to `operations_y2027m06`. Afterwards the flag was not `on` any more, and a local write was blocked again. Test data cleaned up on both sides.
- **Negative run:** guard trigger dropped → #8 FAIL (`1 of 5 rejected`); guard restored.

## Verdict

Stage 7 is **accepted**. Two major operational risks (silent divergence through local writes on the subscriber, unbounded WAL retention on the publisher) are fixed and verified. Remaining replication limitations are documented.
