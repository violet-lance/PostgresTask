# 01. Grilling Session 3 — Data Generation & Replica Shape

Date: 2026-11-18

---

## Q3.1 — Status of generated historical rows (3–4 months)

| Option | Pros | Cons |
|--------|------|------|
| **Older rows `status = 1`, part of the most recent day `status = 0`** | Realistic: old operations are long confirmed, fresh ones are still pending. Right after start-up the 3-second job has visible work and the MV totals visibly change | Slightly more generator logic |
| Random ~90/10 mix across the whole period | Simple | Unrealistic (months-old operations still pending); first job run confirms ~5k old rows at once |
| All `status = 0` | Stress-tests the MV refresh | Unrealistic; the backlog is drained in two runs and then nothing interesting happens |

**Decision:** rows older than the last 24 h are `status = 1`; rows within the last 24 h are `status = 0` with a probability that grows towards "now" (the newest are mostly pending).

**Reasoning:** the demo should look like a live system at the moment it starts, so every requirement (jobs, MV refresh, replication) is observable immediately.

---

## Q3.2 — Data generator implementation

| Option | Pros | Cons |
|--------|------|------|
| **Procedure with batches + `COMMIT`** — `CALL generate_operations(p_rows => 100000, p_from => now() - interval '4 months', p_to => now(), p_batch => 10000)`; inside a batch: a set-based `INSERT … SELECT … FROM generate_series` | Set-based speed within a batch; bounded transaction size (WAL, locks, replication of one huge transaction); scales to millions; uses procedure transaction control, which is exactly what procedures exist for | Must not be called inside an explicit transaction block (the `COMMIT` would fail) |
| Function with one `INSERT … SELECT` | Simplest, fast for 100k | One giant transaction; doesn't scale |
| Loop calling the single-row insert function (same one the 5-second job uses) | Single point of insert logic | Row-by-row → orders of magnitude slower |

**Decision:** procedure with batched, set-based inserts and `COMMIT` per batch.

**Reasoning:** combines set-based performance with bounded transactions. It is also friendlier to logical replication — the subscriber receives several medium transactions rather than one 100k-row transaction.

**Note:** the registry trigger (Q2.1) also fires for generated rows, so the generator benefits from the same uniqueness guarantee — no bypass path.

---

## Q3.3 — Domain of the jsonb message (account number, client id, operation type)

| Option | Pros | Cons |
|--------|------|------|
| **Consistent pool + `CHECK` constraints** — ~1000 clients, each owning 1–3 stable accounts (UA IBAN-like numbers derived deterministically from `client_id`); `CHECK` that required keys exist and `operation_type ∈ {online, offline}` | Data are internally consistent (an account always belongs to the same client) → per-client aggregates in the MV are meaningful; constraints document and enforce the message contract | Slightly more generator code |
| Random values per row, no `CHECK` | Simplest | One account may "belong" to many clients; no contract on the message |
| Separate `clients` / `accounts` tables | Most realistic | Out of scope — the task says this data lives in the jsonb message |

**Decision:** consistent deterministic pool + `CHECK` constraints on the jsonb structure.

**Message contract:**
```json
{
  "account_number": "UA…(29 chars)",
  "client_id": 123,
  "operation_type": "online" | "offline"
}
```

**Reasoning:** jsonb gives schema flexibility, but the required fields are a contract — `CHECK` constraints make it explicit while keeping jsonb for anything extra.

---

## Q3.4 — Shape of T1 on the subscriber (replica)

| Option | Pros | Cons |
|--------|------|------|
| **Same partitioned layout** (monthly partitions + `DEFAULT`) with its own `pg_cron` partition-maintenance job; no insert/update jobs, no GUID registry | Symmetric schema; the replica is usable for reporting with the same partition pruning; demonstrates that `publish_via_partition_root` decouples the publisher and subscriber layouts (changes are routed by the subscriber's own partitioning) | Partition maintenance must exist on both sides |
| Plain (non-partitioned) table | Simplest; shows layout flexibility | Replica loses partition pruning / per-month maintenance |
| Partitioned + its own MV maintained via `ENABLE ALWAYS TRIGGER` | Full reporting replica | Extra complexity beyond the requirement |

**Decision:** same partitioned layout on the subscriber, with its own partition-maintenance job.

**Reasoning:** a replica is typically used for reads/reporting, where partitioning matters as much as on the primary. Business jobs (insert/confirm) run only on the publisher — the replica receives their effects via replication.
