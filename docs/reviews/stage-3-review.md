# Review — Stage 3 (data generator)

Date: 2026-11-18
Reviewed: commit `97f4e09` — `sql/primary/04_generator.sql`, `sql/primary/05_seed.sql`, `verify/02_generator.sql`, Stage 3 section of the [implementation log](../04-implementation-log.md).

## Method

1. Close what Stage 3 left open: `p_seed` was explicitly marked as untested.
2. Call the generator with **parameters other than the seed's** (a historical range) and watch the side effects, not only the inserted rows.
3. Boundary review of the helper functions (input domains).
4. **Negative run of every check** in `verify/02_generator.sql`. For each check, a targeted mutation is applied inside a rolled-back transaction, and the check must report `FAIL`. Stage 3 introduced this rule after finding a check that could never fail.

## Findings

| ID | Sev. | Finding | Resolution |
|----|------|---------|------------|
| S3-01 | Minor | **The generator created dozens of empty partitions for a historical range.** It called `ensure_monthly_partitions(p_from, 2)`, which fills *every* month from `p_from` up to now + 2. A test call with `p_from = 2020-01-01` created **66 empty partitions** (2020-01 … 2026-06). Found while testing `p_seed`. | **Fixed.** The generator creates exactly the months of `[p_from, p_to)` via `create_month_partition()`. Re-test: a call over 2020-01..2020-03 creates only `operations_y2020m01`, `operations_y2020m02`. |
| S3-02 | Minor | **Silent collisions in `ops.client_account()`.** `lpad(x, n)` *truncates* strings longer than `n`, so a `client_id` with more than 10 digits (or an account number above 99 999) would map to another client's IBAN without any error. That breaks D-13 ("an account always belongs to one client"). Unreachable with the default pool of 1000, but the function is generic. | **Fixed.** The documented domain (`client_id` 1…9 999 999 999, `account_no` 1…99 999) is enforced: outside it the function returns `NULL`, and the message `CHECK` on T1 then rejects the row. Verified: `client_account(10^10, 1)` and `client_account(1, 100000)` → `NULL`. |
| S3-03 | Minor | **A check that errors instead of failing.** Negative run of check 1: after `DROP PROCEDURE`, the cast `'ops.generate_operations'::regproc` raised an error and the whole script aborted, so there was no `FAIL` row and the other checks were never reported. | **Fixed.** The lookup now goes through `pg_proc`/`pg_namespace`; a missing procedure gives `FAIL … not found`. |
| S3-04 | Info | `p_seed` reproducibility was untested. **My first test was itself wrong:** run 1 was copied out *and also stayed in T1*, so comparing against T1 matched run 1 with itself and "proved" nothing (in both directions). Noticed from the numbers, which made no sense (1000 "identical" rows for a *different* seed). | **Re-done correctly** by isolating each run by its id range: seed 0.42 vs 0.42 → 0 differing rows in both directions; seed 0.42 vs 0.43 → 0 identical rows; GUIDs differ in every run (`gen_random_uuid()` doesn't depend on `setseed`). Closed. |
| S3-05 | Info | A failure halfway through the seed (or any init script) leaves an **initialised** data volume. The official entrypoint then skips `/docker-entrypoint-initdb.d` on the next start, so the database stays half-built without any error. | Documented; goes into README troubleshooting in Stage 8: "if init failed, `docker compose down -v`". Inherent to the official image. |
| S3-06 | Info | Rows inserted with `status = 1` **after** the MV exists (e.g. a later `CALL ops.generate_operations`) won't appear in the MV until the next 0→1 refresh: the requirement ties refreshes to status *updates*. | **Carried to Stage 6:** decide whether the generator should refresh the MV at the end when it exists. |

## Negative runs of `verify/02_generator.sql`

Every mutation runs inside `BEGIN … ROLLBACK` together with the verification script. Afterwards the data was confirmed unchanged (100 000 rows, 69 895 online).

| # | Check | Mutation | Result |
|---|-------|----------|--------|
| 1 | Generator is a PROCEDURE | `DROP PROCEDURE` | FAIL ✔ (after S3-03 fix) |
| 2 | ≥ 100 000 rows | delete 1 row | FAIL ✔ |
| 3 | Spans ≥ 3 months | delete rows older than 2 months | FAIL ✔ |
| 4 | No empty day | delete one day | FAIL ✔ |
| 5 | DEFAULT empty | insert a 2030 row | FAIL ✔ |
| 6 | No old pending row | set one old row to 0 | FAIL ✔ |
| 7 | Account ↔ one client | reuse client 1's account for client 2 | FAIL ✔ |
| 8 | Valid IBANs | insert a wrong-checksum account | FAIL ✔ |
| 9 | Realistic pool/types | make everything offline | FAIL ✔ |
| 10 | Amount range | insert 60 000.00 | FAIL ✔ |
| 11 | Ids grow with op_date | insert a back-dated row | FAIL ✔ |
| 12 | Registry 1:1 | delete a T1 row (registry row stays) | FAIL ✔ |

## Re-verification after fixes

`docker compose down -v && up`: seed of 100 000 rows in 10.2 s. `01_table` 10/10, `02_generator` 12/12, `03_guid_uniqueness` 12/12 PASS. The test data from the S3-01/S3-04 experiments was removed afterwards (rows, registry rows, partitions).

## Verdict

Stage 3 is **accepted**. 3 minor fixes, `p_seed` verified, all 12 checks proven able to fail, 1 item carried to Stage 6 (S3-06).
