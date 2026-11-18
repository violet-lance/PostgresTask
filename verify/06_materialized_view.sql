-- =============================================================================
-- verify/06_materialized_view.sql — Requirement 6: totals per client and operation
-- type in a materialized view, refreshed on every status update 0 -> 1.
-- Primary only. Needs >= 1 minute of runtime. Non-destructive (rolled back).
-- Note: check 9 drops the MV's unique index inside the transaction; the confirm job
-- waits on that lock until the rollback (a moment).
-- =============================================================================
\set ON_ERROR_STOP 1
\pset footer off
BEGIN;

CREATE TEMP TABLE vr (n serial, check_name text, passed boolean, details text) ON COMMIT DROP;

-- Live aggregate with the same definition as the MV, for comparisons
CREATE TEMP VIEW live_totals AS
SELECT (o.message ->> 'client_id')::bigint AS client_id, (o.message ->> 'operation_type') AS operation_type,
       sum(o.amount) AS total_amount, count(*) AS operations_count
FROM ops.operations o WHERE o.status = 1 GROUP BY 1, 2;

-- mv_diff(): number of (client, type) groups where MV and live data differ (one statement = one snapshot)
CREATE FUNCTION pg_temp.mv_diff() RETURNS bigint LANGUAGE sql AS $$
    SELECT count(*) FROM ops.client_type_totals m FULL JOIN live_totals l USING (client_id, operation_type)
    WHERE m.total_amount IS DISTINCT FROM l.total_amount OR m.operations_count IS DISTINCT FROM l.operations_count
$$;

-- 1. It is a real, populated MATERIALIZED VIEW with a unique index
INSERT INTO vr (check_name, passed, details)
SELECT 'ops.client_type_totals is a populated MATERIALIZED VIEW with a unique index (needed for CONCURRENTLY)',
       count(*) = 1 AND bool_and(m.ispopulated)
         AND EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = 'ops.client_type_totals'::regclass AND i.indisunique),
       coalesce(string_agg(format('%s.%s populated=%s', m.schemaname, m.matviewname, m.ispopulated), ''), 'not found')
FROM pg_matviews m WHERE m.schemaname = 'ops' AND m.matviewname = 'client_type_totals';

-- 2. Current content equals the live aggregate (exactly, every group)
INSERT INTO vr (check_name, passed, details)
SELECT 'MV equals the live aggregate of confirmed operations (all groups)',
       pg_temp.mv_diff() = 0,
       format('%s differing group(s); MV: %s groups, total %s', pg_temp.mv_diff(),
              (SELECT count(*) FROM ops.client_type_totals), (SELECT sum(total_amount) FROM ops.client_type_totals));

-- 3. Statement-level triggers for INSERT, UPDATE, DELETE, TRUNCATE
INSERT INTO vr (check_name, passed, details)
SELECT 'Statement-level refresh triggers on INSERT, UPDATE, DELETE, TRUNCATE',
       count(*) = 4,
       string_agg(tgname, ', ' ORDER BY tgname)
FROM pg_trigger
WHERE tgrelid = 'ops.operations'::regclass AND NOT tgisinternal
  AND tgfoid = 'ops.refresh_client_type_totals'::regproc
  AND (tgtype & 1) = 0;   -- bit 0 = ROW; 0 means FOR EACH STATEMENT

-- 4. THE REQUIREMENT on live data: every confirm run that flipped rows 0 -> 1 refreshed the MV
--    in the same transaction; runs that confirmed nothing did not refresh.
INSERT INTO vr (check_name, passed, details)
SELECT 'Every confirm run with rows 0 -> 1 refreshed the MV in the same transaction (and only those)',
       count(*) >= 10
         AND count(*) FILTER (WHERE c.rows_confirmed > 0 AND (r.refresh_id IS NULL OR r.rows_flipped_0_to_1 <> c.rows_confirmed)) = 0
         AND count(*) FILTER (WHERE c.rows_confirmed = 0 AND r.refresh_id IS NOT NULL) = 0,
       format('%s runs: %s with confirmations -> %s refreshed; %s without -> %s refreshed',
              count(*), count(*) FILTER (WHERE c.rows_confirmed > 0),
              count(*) FILTER (WHERE c.rows_confirmed > 0 AND r.refresh_id IS NOT NULL),
              count(*) FILTER (WHERE c.rows_confirmed = 0),
              count(*) FILTER (WHERE c.rows_confirmed = 0 AND r.refresh_id IS NOT NULL))
FROM ops.confirm_job_log c
LEFT JOIN ops.mv_refresh_log r ON r.refreshed_at = c.run_at AND r.trigger_op = 'UPDATE'
WHERE c.run_at > now() - interval '5 minutes';

-- 5..8: behaviour, on a fresh client id that has no data (so effects are isolated)
SELECT coalesce(max((message->>'client_id')::bigint), 0) + 1000000 AS cid FROM ops.operations \gset
SELECT count(*) AS refreshes_before FROM ops.mv_refresh_log \gset

-- 5. 0 -> 1 refreshes and the total moves by exactly the amount
INSERT INTO ops.operations (amount, status, message)
VALUES (123.45, 0, jsonb_build_object('account_number', ops.client_account(:cid, 1), 'client_id', :cid, 'operation_type', 'online'));
SELECT count(*) AS r1 FROM ops.mv_refresh_log \gset
UPDATE ops.operations SET status = 1 WHERE (message->>'client_id')::bigint = :cid AND status = 0;
INSERT INTO vr (check_name, passed, details)
SELECT 'Status 0 -> 1 refreshes the MV: client total appears with exactly the amount',
       :r1 = :refreshes_before                              -- inserting a PENDING row did not refresh
         AND (SELECT count(*) FROM ops.mv_refresh_log) = :r1 + 1
         AND (SELECT total_amount FROM ops.client_type_totals WHERE client_id = :cid AND operation_type = 'online') = 123.45
         AND pg_temp.mv_diff() = 0,
       format('pending insert: +%s refresh; 0->1: +%s refresh; MV total for test client = %s',
              :r1 - :refreshes_before, (SELECT count(*) FROM ops.mv_refresh_log) - :r1,
              (SELECT total_amount FROM ops.client_type_totals WHERE client_id = :cid AND operation_type = 'online'));

-- 6. A no-op update (nothing in the confirmed set changes) does not refresh
SELECT count(*) AS r2 FROM ops.mv_refresh_log \gset
UPDATE ops.operations SET status = 1 WHERE (message->>'client_id')::bigint = :cid AND status = 0;   -- 0 rows
UPDATE ops.operations SET amount = amount WHERE (message->>'client_id')::bigint = :cid;             -- 1 row, no change
INSERT INTO vr (check_name, passed, details)
SELECT 'Updates that do not change the confirmed set do not refresh',
       (SELECT count(*) FROM ops.mv_refresh_log) = :r2,
       format('+%s refresh(es)', (SELECT count(*) FROM ops.mv_refresh_log) - :r2);

-- 7. Other changes of the confirmed set also refresh (stage-6 decision): amount change, insert with status 1, 1 -> 0, delete
SELECT count(*) AS r3 FROM ops.mv_refresh_log \gset
UPDATE ops.operations SET amount = 200.00 WHERE (message->>'client_id')::bigint = :cid;
INSERT INTO ops.operations (amount, status, message)
VALUES (50.00, 1, jsonb_build_object('account_number', ops.client_account(:cid, 1), 'client_id', :cid, 'operation_type', 'offline'));
-- coalesce to '': psql \gset leaves a variable UNSET for a NULL value
SELECT coalesce((SELECT total_amount FROM ops.client_type_totals WHERE client_id = :cid AND operation_type = 'online')::text, '') AS t_online,
       coalesce((SELECT total_amount FROM ops.client_type_totals WHERE client_id = :cid AND operation_type = 'offline')::text, '') AS t_offline \gset
UPDATE ops.operations SET status = 0 WHERE (message->>'client_id')::bigint = :cid AND message->>'operation_type' = 'online';
DELETE FROM ops.operations WHERE (message->>'client_id')::bigint = :cid AND message->>'operation_type' = 'offline';
INSERT INTO vr (check_name, passed, details)
SELECT 'Amount change, insert with status 1, 1 -> 0 and delete of confirmed rows also refresh',
       (SELECT count(*) FROM ops.mv_refresh_log) = :r3 + 4
         AND nullif(:'t_online', '')::numeric = 200.00 AND nullif(:'t_offline', '')::numeric = 50.00
         AND NOT EXISTS (SELECT 1 FROM ops.client_type_totals WHERE client_id = :cid)
         AND pg_temp.mv_diff() = 0,
       format('+%s refreshes (expected 4); totals after amount change/insert: online %s, offline %s; after 1->0 and delete: %s group(s) left',
              (SELECT count(*) FROM ops.mv_refresh_log) - :r3, coalesce(nullif(:'t_online', ''), 'none'), coalesce(nullif(:'t_offline', ''), 'none'),
              (SELECT count(*) FROM ops.client_type_totals WHERE client_id = :cid));

-- 8. Refresh log records the requirement's case separately (job-caused refreshes only:
--    refreshed_at <> now() excludes the refreshes made by this script's own tests)
INSERT INTO vr (check_name, passed, details)
SELECT 'Refresh log of the confirm job records the 0 -> 1 flips',
       count(*) FILTER (WHERE trigger_op = 'UPDATE' AND rows_flipped_0_to_1 > 0) > 0
         AND count(*) FILTER (WHERE rows_flipped_0_to_1 > rows_changed_confirmed) = 0,
       coalesce(string_agg(DISTINCT trigger_op, ', '), 'no refreshes') || format('; refreshes with 0->1 flips: %s',
              count(*) FILTER (WHERE rows_flipped_0_to_1 > 0))
FROM ops.mv_refresh_log WHERE refreshed_at <> now();

-- 9. D-16: if the refresh fails, the status update is rolled back with it
INSERT INTO ops.operations (amount, status, message)
VALUES (77.00, 0, jsonb_build_object('account_number', ops.client_account(:cid, 2), 'client_id', :cid, 'operation_type', 'online'))
RETURNING id AS fail_id \gset
SELECT set_config('vr.fail_id', :'fail_id', true) AS ignored \gset
DO $$
DECLARE v_err text; v_status smallint; v_status_inside smallint;
BEGIN
    -- The inner block ALWAYS ends with an exception, so DROP INDEX is always undone, even
    -- if (wrongly) the UPDATE succeeds; the status seen inside is captured before that.
    BEGIN
        DROP INDEX ops.client_type_totals_uq;              -- REFRESH ... CONCURRENTLY now fails
        UPDATE ops.operations SET status = 1 WHERE id = current_setting('vr.fail_id')::bigint;
        SELECT status INTO v_status_inside FROM ops.operations WHERE id = current_setting('vr.fail_id')::bigint;
        RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = 'update succeeded';
    EXCEPTION
        WHEN SQLSTATE 'P0099' THEN v_err := NULL;
        WHEN OTHERS THEN v_err := SQLERRM;
    END;
    SELECT status INTO v_status FROM ops.operations WHERE id = current_setting('vr.fail_id')::bigint;
    INSERT INTO vr (check_name, passed, details)
    VALUES ('Failed refresh aborts the status update (D-16)', v_err IS NOT NULL AND v_status = 0,
            format('error: %s; status after: %s%s', coalesce(v_err, 'none'), v_status,
                   coalesce(' (inside the failed-to-fail block: ' || v_status_inside || ')', '')));
END $$;

-- 10. Refresh cost (stage-5 review S5-07): duration of refreshes caused by the confirm job
INSERT INTO vr (check_name, passed, details)
SELECT 'Refresh duration acceptable for a 3-second job (p95 < 500 ms)',
       count(*) > 0 AND percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms) < 500,
       format('%s refreshes: avg %s ms, p95 %s ms, max %s ms', count(*), round(avg(duration_ms), 1),
              round(percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms)::numeric, 1), max(duration_ms))
FROM ops.mv_refresh_log WHERE refreshed_at > now() - interval '10 minutes' AND refreshed_at <> now();

-- 11. TRUNCATE refreshes too (last: it locks ops.operations until the rollback)
SELECT count(*) AS r4 FROM ops.mv_refresh_log \gset
TRUNCATE ops.operations;
INSERT INTO vr (check_name, passed, details)
SELECT 'TRUNCATE of T1 refreshes the MV (empty afterwards)',
       (SELECT count(*) FROM ops.mv_refresh_log WHERE trigger_op = 'TRUNCATE') >= 1
         AND (SELECT count(*) FROM ops.mv_refresh_log) = :r4 + 1
         AND NOT EXISTS (SELECT 1 FROM ops.client_type_totals),
       format('+%s refresh, MV groups after: %s', (SELECT count(*) FROM ops.mv_refresh_log) - :r4,
              (SELECT count(*) FROM ops.client_type_totals));

SELECT n AS "#", CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result, check_name, details FROM vr ORDER BY n;
ROLLBACK;
