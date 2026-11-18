-- =============================================================================
-- verify/07_replication_subscriber.sql — Requirement 7, subscriber side (pg-replica).
-- Read-only. Expects psql variables from verify/07_replication.sh:
--   :cutoff  — timestamp; rows with op_date < cutoff are stable (statuses settled)
--   :pub_fp / :rep_fp — fingerprints (count|sum|confirmed|md5 of every row) of those rows,
--             computed by the runner with ONE query text on both instances
-- =============================================================================
\set ON_ERROR_STOP 1
\pset footer off
BEGIN;

CREATE TEMP TABLE vr (n serial, check_name text, passed boolean, details text) ON COMMIT DROP;

INSERT INTO vr (check_name, passed, details)
SELECT 'Subscription ops_sub is enabled and subscribed to ops_pub',
       count(*) = 1 AND bool_and(s.subenabled AND s.subpublications = ARRAY['ops_pub']),
       coalesce(string_agg(format('enabled=%s publications=%s slot=%s', s.subenabled, s.subpublications, s.subslotname), ''), 'not found')
FROM pg_subscription s WHERE s.subname = 'ops_sub';

INSERT INTO vr (check_name, passed, details)
SELECT 'Apply worker is running and received a message in the last 30 s',
       count(*) >= 1 AND bool_and(st.pid IS NOT NULL) AND max(st.last_msg_receipt_time) > now() - interval '30 seconds',
       coalesce(format('pid=%s, last message %s s ago', max(st.pid), round(extract(epoch FROM now() - max(st.last_msg_receipt_time))::numeric, 1)), 'no worker')
FROM pg_stat_subscription st WHERE st.subname = 'ops_sub' AND st.relid IS NULL;

INSERT INTO vr (check_name, passed, details)
SELECT 'Initial table sync finished (all subscribed relations in state ready)',
       count(*) >= 1 AND bool_and(sr.srsubstate = 'r'),
       coalesce(string_agg(format('%s=%s', sr.srrelid::regclass, sr.srsubstate), ', '), 'no relations')
FROM pg_subscription_rel sr JOIN pg_subscription s ON s.oid = sr.srsubid WHERE s.subname = 'ops_sub';

INSERT INTO vr (check_name, passed, details)
SELECT 'No apply or sync errors',
       count(*) = 1 AND bool_and(apply_error_count = 0 AND sync_error_count = 0),
       coalesce(string_agg(format('apply_errors=%s sync_errors=%s', apply_error_count, sync_error_count), ''), 'no stats')
FROM pg_stat_subscription_stats WHERE subname = 'ops_sub';

-- The data: identical fingerprint for all rows older than the cutoff
INSERT INTO vr (check_name, passed, details)
SELECT 'Data identical to the publisher for all rows older than the cutoff (count, sums, md5 of every row)',
       :'rep_fp' = :'pub_fp' AND :'pub_fp' NOT LIKE '0|%',
       format('cutoff %s; replica %s; publisher %s', :'cutoff', :'rep_fp', :'pub_fp');

-- Routed by the replica's own partitioning; nothing in DEFAULT
INSERT INTO vr (check_name, passed, details)
SELECT 'Replica routes rows into its own monthly partitions, DEFAULT empty',
       bool_and(part <> 'ops.operations_default'::regclass) AND count(*) >= 4,
       string_agg(format('%s=%s', part, cnt), ', ' ORDER BY part::text)
FROM (SELECT tableoid::regclass AS part, count(*) AS cnt FROM ops.operations GROUP BY 1) p;

-- Shape of the replica (D-14): no registry, no MV, no business jobs
INSERT INTO vr (check_name, passed, details)
SELECT 'Replica shape: no GUID registry, no MV, only the partition-maintenance job',
       to_regclass('ops.operation_guid_registry') IS NULL AND to_regclass('ops.client_type_totals') IS NULL
         AND (SELECT array_agg(jobname ORDER BY jobname) FROM cron.job) = ARRAY['partition-maintenance']::text[],
       format('registry=%s, mv=%s, jobs=%s', coalesce(to_regclass('ops.operation_guid_registry')::text, 'none'),
              coalesce(to_regclass('ops.client_type_totals')::text, 'none'),
              (SELECT string_agg(jobname, ',') FROM cron.job));

SELECT n AS "#", CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result, check_name, details FROM vr ORDER BY n;
ROLLBACK;
