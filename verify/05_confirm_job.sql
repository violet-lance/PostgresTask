-- =============================================================================
-- verify/05_confirm_job.sql — Requirement 5: every 3 seconds pending operations are
-- confirmed (0 -> 1) for ids with the parity of the current second.
-- Primary only. Needs >= 1 minute of runtime. Non-destructive (rolled back).
-- =============================================================================
\set ON_ERROR_STOP 1
\pset footer off
BEGIN;

CREATE TEMP TABLE vr (n serial, check_name text, passed boolean, details text) ON COMMIT DROP;

-- 1. Job definition
INSERT INTO vr (check_name, passed, details)
SELECT 'pg_cron job "confirm-operations": active, every 3 seconds, calls ops.confirm_operations_by_parity()',
       count(*) = 1 AND bool_and(active AND schedule = '3 seconds' AND command ILIKE '%ops.confirm_operations_by_parity(%'),
       coalesce(string_agg(format('[%s] %s -> %s, active=%s', jobid, schedule, command, active), '; '), 'job not found')
FROM cron.job WHERE jobname = 'confirm-operations';

CREATE TEMP VIEW runs AS
SELECT d.*
FROM cron.job_run_details d JOIN cron.job j USING (jobid)
WHERE j.jobname = 'confirm-operations' AND d.start_time > now() - interval '2 minutes';

-- 2. Runs happen, succeed, ~3 s apart
INSERT INTO vr (check_name, passed, details)
SELECT 'Runs in the last 2 minutes all succeeded, every 3 s (gaps within 2.5..3.5 s)',
       count(*) >= 20 AND count(*) FILTER (WHERE status <> 'succeeded') = 0
         AND min(gap) >= 2.5 AND max(gap) <= 3.5,
       format('%s runs, %s failed; gaps min %s / avg %s / max %s s', count(*), count(*) FILTER (WHERE status <> 'succeeded'),
              round(min(gap), 2), round(avg(gap), 2), round(max(gap), 2))
FROM (SELECT status, extract(epoch FROM start_time - lag(start_time) OVER (ORDER BY start_time)) AS gap FROM runs) g;

-- 3. Every succeeded run wrote exactly one audit row
INSERT INTO vr (check_name, passed, details)
SELECT 'Every succeeded run wrote exactly one confirm_job_log row',
       count(*) >= 20 AND count(*) FILTER (WHERE log_rows <> 1) = 0,
       format('%s runs checked, %s without exactly one log row', count(*), count(*) FILTER (WHERE log_rows <> 1))
FROM (SELECT (SELECT count(*) FROM ops.confirm_job_log l WHERE l.run_at BETWEEN r.start_time AND r.end_time) AS log_rows
      FROM runs r WHERE r.status = 'succeeded') x;

-- 4. THE RULE: in every logged run, parity = parity of the second, and every confirmed id has that parity
INSERT INTO vr (check_name, passed, details)
SELECT 'Rule holds for every logged run: even second -> only even ids, odd second -> only odd ids',
       count(*) > 0
         AND count(*) FILTER (WHERE parity <> floor(extract(epoch FROM run_at))::bigint % 2) = 0
         AND count(*) FILTER (WHERE run_second % 2 <> parity) = 0
         AND count(*) FILTER (WHERE EXISTS (SELECT 1 FROM unnest(confirmed_ids) i WHERE i % 2 <> parity)) = 0
         AND count(*) FILTER (WHERE cardinality(confirmed_ids) <> rows_confirmed) = 0,
       format('%s runs (%s even / %s odd), %s ids confirmed, %s violating run(s)',
              count(*), count(*) FILTER (WHERE parity = 0), count(*) FILTER (WHERE parity = 1), sum(rows_confirmed),
              count(*) FILTER (WHERE parity <> floor(extract(epoch FROM run_at))::bigint % 2
                                  OR run_second % 2 <> parity
                                  OR EXISTS (SELECT 1 FROM unnest(confirmed_ids) i WHERE i % 2 <> parity)))
FROM ops.confirm_job_log;

-- 5. Confirmed ids really are status 1 now (the log tells the truth)
INSERT INTO vr (check_name, passed, details)
SELECT 'Every id in the audit log is confirmed (status = 1) in T1',
       count(*) FILTER (WHERE o.status IS DISTINCT FROM 1) = 0,
       format('%s logged ids, %s not confirmed / missing', count(*), count(*) FILTER (WHERE o.status IS DISTINCT FROM 1))
FROM (SELECT unnest(confirmed_ids) AS id FROM ops.confirm_job_log WHERE run_at > now() - interval '10 minutes') l
LEFT JOIN ops.operations o ON o.id = l.id;

-- 6. Liveness: both parities get processed -> nothing stays pending for long
INSERT INTO vr (check_name, passed, details)
SELECT 'No operation stays pending longer than 10 s (both parities are processed)',
       count(*) FILTER (WHERE op_date < now() - interval '10 seconds') = 0,
       format('pending now: %s, of which older than 10 s: %s', count(*), count(*) FILTER (WHERE op_date < now() - interval '10 seconds'))
FROM ops.operations WHERE status = 0;

-- 7. Direct behaviour test: two fresh pending rows (consecutive ids -> one even, one odd)
SELECT ops.insert_random_operation() AS id_a \gset
SELECT ops.insert_random_operation() AS id_b \gset
SELECT ops.confirm_operations_by_parity() AS confirmed \gset
INSERT INTO vr (check_name, passed, details)
SELECT 'Direct call confirms exactly the id whose parity matches the current second',
       bool_and(status = CASE WHEN id % 2 = floor(extract(epoch FROM now()))::bigint % 2 THEN 1 ELSE 0 END),
       format('second parity=%s; %s', floor(extract(epoch FROM now()))::bigint % 2,
              string_agg(format('id %s -> status %s', id, status), ', ' ORDER BY id))
FROM ops.operations WHERE id IN (:id_a, :id_b);

-- 8. Efficiency: the UPDATE uses the partial index, no sequential scan of partitions
CREATE TEMP TABLE plan_lines (line text) ON COMMIT DROP;
DO $$
DECLARE r record;
BEGIN
    -- the candidate query of ops.confirm_operations_by_parity()
    FOR r IN EXECUTE 'EXPLAIN (COSTS OFF) SELECT id, op_date FROM ops.operations WHERE status = 0 AND id % 2 = 0 FOR UPDATE SKIP LOCKED' LOOP
        INSERT INTO plan_lines VALUES (r."QUERY PLAN");
    END LOOP;
END $$;
-- A Seq Scan is fine (and chosen by the planner) on EMPTY partitions (relpages = 0:
-- future months, DEFAULT); it must not appear on partitions that hold data.
INSERT INTO vr (check_name, passed, details)
SELECT 'Confirm candidate query uses the partial index on every non-empty partition',
       count(*) FILTER (WHERE s.seq_rel IS NOT NULL AND c.relpages > 0) = 0
         AND (SELECT count(*) FROM plan_lines WHERE line ILIKE '%Index Scan using %_id_idx%') > 0,
       format('%s index scan node(s) on *_id_idx; seq scans: %s',
              (SELECT count(*) FROM plan_lines WHERE line ILIKE '%Index Scan using %_id_idx%'),
              coalesce(string_agg(format('%s (relpages=%s)', s.seq_rel, c.relpages), ', ') FILTER (WHERE s.seq_rel IS NOT NULL), 'none'))
FROM (SELECT substring(line FROM 'Seq Scan on (\S+)') AS seq_rel FROM plan_lines) s
LEFT JOIN pg_class c ON c.relname = s.seq_rel AND c.relnamespace = 'ops'::regnamespace;

-- 9. Statistic (not a requirement): how often consecutive job runs alternate parity.
-- A pair does not alternate when pg_cron starts at ~x.99 s and now() inside the job is
-- already in the next second (stage-4 review S4-01); the rule is still applied correctly.
-- run_at <> now() excludes the direct call made by check 7 inside this transaction.
INSERT INTO vr (check_name, passed, details)
SELECT 'Consecutive job runs alternate parity in >= 90% of cases (statistic, see stage-4 review)',
       count(*) > 0 AND avg((parity <> prev)::int) >= 0.9,
       format('%s of %s consecutive pairs alternate (%s%%); non-alternating: %s', sum((parity <> prev)::int), count(*),
              round(100 * avg((parity <> prev)::int), 1),
              coalesce(string_agg(format('%s -> %s', to_char(prev_at, 'HH24:MI:SS.MS'), to_char(run_at, 'HH24:MI:SS.MS')), ', ')
                       FILTER (WHERE parity = prev), 'none'))
FROM (SELECT parity, run_at, lag(parity) OVER (ORDER BY run_at) AS prev, lag(run_at) OVER (ORDER BY run_at) AS prev_at
      FROM ops.confirm_job_log WHERE run_at <> now()) s
WHERE prev IS NOT NULL;

SELECT n AS "#", CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result, check_name, details FROM vr ORDER BY n;
ROLLBACK;
