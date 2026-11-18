-- =============================================================================
-- verify/04_insert_job.sql — Requirement 4: a scheduled job inserts a row with
-- status 0 every 5 seconds. Primary only. Needs the system running for >= 1 minute.
-- Non-destructive (rolled back).
-- =============================================================================
\set ON_ERROR_STOP 1
\pset footer off
BEGIN;

CREATE TEMP TABLE vr (n serial, check_name text, passed boolean, details text) ON COMMIT DROP;

-- 1. Job definition
INSERT INTO vr (check_name, passed, details)
SELECT 'pg_cron job "insert-operation": active, every 5 seconds, calls ops.insert_random_operation()',
       count(*) = 1 AND bool_and(active AND schedule = '5 seconds' AND command ILIKE '%ops.insert_random_operation(%'),
       coalesce(string_agg(format('[%s] %s -> %s, active=%s', jobid, schedule, command, active), '; '), 'job not found')
FROM cron.job WHERE jobname = 'insert-operation';

-- 2. The function inserts exactly one row with status 0 (called directly, rolled back).
-- Two separate statements on purpose: a row inserted by a function called inside a
-- statement is not visible to that same statement's snapshot.
SELECT ops.insert_random_operation() AS new_id \gset
INSERT INTO vr (check_name, passed, details)
SELECT 'ops.insert_random_operation() inserts one row with status = 0 and op_date = now()',
       count(*) = 1 AND bool_and(o.status = 0 AND o.op_date = now()),
       coalesce(string_agg(format('id=%s status=%s op_date=%s', o.id, o.status, o.op_date), '; '), 'row not found')
FROM ops.operations o WHERE o.id = :new_id;

-- Recent runs of the job (last 2 minutes)
CREATE TEMP VIEW runs AS
SELECT d.*
FROM cron.job_run_details d JOIN cron.job j USING (jobid)
WHERE j.jobname = 'insert-operation' AND d.start_time > now() - interval '2 minutes';

-- 3. Runs happen and succeed
INSERT INTO vr (check_name, passed, details)
SELECT 'Job runs in the last 2 minutes all succeeded (>= 10 runs expected)',
       count(*) >= 10 AND count(*) FILTER (WHERE status <> 'succeeded') = 0,
       format('%s runs, %s failed%s', count(*), count(*) FILTER (WHERE status <> 'succeeded'),
              coalesce(' — last error: ' || max(return_message) FILTER (WHERE status <> 'succeeded'), ''))
FROM runs;

-- 4. Cadence: consecutive runs start ~5 s apart
INSERT INTO vr (check_name, passed, details)
SELECT 'Consecutive runs start every 5 s (each gap within 4.5..5.5 s)',
       count(*) >= 5 AND min(gap) >= 4.5 AND max(gap) <= 5.5,
       format('%s gaps: min %s s, avg %s s, max %s s', count(*), round(min(gap), 2), round(avg(gap), 2), round(max(gap), 2))
FROM (SELECT extract(epoch FROM start_time - lag(start_time) OVER (ORDER BY start_time)) AS gap FROM runs) g
WHERE gap IS NOT NULL;

-- 5. Each succeeded run produced one row: rows whose op_date matches a run's start
INSERT INTO vr (check_name, passed, details)
SELECT 'Each succeeded run inserted exactly one operation',
       count(*) >= 10 AND count(*) FILTER (WHERE rows_in_run <> 1) = 0,
       format('%s runs checked, %s without exactly one row', count(*), count(*) FILTER (WHERE rows_in_run <> 1))
FROM (
    SELECT r.runid,
           (SELECT count(*) FROM ops.operations o
            WHERE o.op_date BETWEEN r.start_time - interval '1 second' AND r.end_time) AS rows_in_run
    FROM runs r
    WHERE r.status = 'succeeded' AND r.end_time < now() - interval '1 second'
) x;

-- 6. Housekeeping job exists (prunes cron history and audit logs)
INSERT INTO vr (check_name, passed, details)
SELECT 'Housekeeping job "housekeeping" is scheduled (calls ops.housekeeping())',
       count(*) = 1 AND bool_and(active AND command ILIKE '%ops.housekeeping(%'),
       coalesce(string_agg(schedule || ' -> ' || command, '; '), 'job not found')
FROM cron.job WHERE jobname = 'housekeeping';

SELECT n AS "#", CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result, check_name, details FROM vr ORDER BY n;
ROLLBACK;
