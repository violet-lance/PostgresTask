-- =============================================================================
-- verify/07_replication_publisher.sql — Requirement 7, publisher side (pg-primary).
-- Read-only. Run by verify/07_replication.sh, which also runs the subscriber side and
-- compares data fingerprints.
-- =============================================================================
\set ON_ERROR_STOP 1
\pset footer off
BEGIN;

CREATE TEMP TABLE vr (n serial, check_name text, passed boolean, details text) ON COMMIT DROP;

INSERT INTO vr (check_name, passed, details)
SELECT 'wal_level = logical', current_setting('wal_level') = 'logical', current_setting('wal_level');

INSERT INTO vr (check_name, passed, details)
SELECT 'Publication ops_pub: only ops.operations, via partition root, insert/update/delete/truncate',
       count(*) = 1 AND bool_and(p.pubviaroot AND p.pubinsert AND p.pubupdate AND p.pubdelete AND p.pubtruncate AND NOT p.puballtables)
         AND (SELECT array_agg(format('%I.%I', schemaname, tablename)) FROM pg_publication_tables WHERE pubname = 'ops_pub') = ARRAY['ops.operations'],
       coalesce(string_agg(format('viaroot=%s ins=%s upd=%s del=%s trunc=%s tables=%s', p.pubviaroot, p.pubinsert, p.pubupdate,
                                  p.pubdelete, p.pubtruncate,
                                  (SELECT string_agg(schemaname || '.' || tablename, ',') FROM pg_publication_tables WHERE pubname = 'ops_pub')), ''), 'not found')
FROM pg_publication p WHERE p.pubname = 'ops_pub';

INSERT INTO vr (check_name, passed, details)
SELECT 'Role replicator: LOGIN + REPLICATION, not superuser, read-only on T1',
       count(*) = 1 AND bool_and(r.rolcanlogin AND r.rolreplication AND NOT r.rolsuper)
         AND has_table_privilege('replicator', 'ops.operations', 'SELECT')
         AND NOT has_table_privilege('replicator', 'ops.operations', 'INSERT, UPDATE, DELETE, TRUNCATE')
         AND NOT has_table_privilege('replicator', 'ops.operation_guid_registry', 'SELECT'),
       coalesce(string_agg(format('login=%s replication=%s super=%s select_T1=%s write_T1=%s select_registry=%s',
                r.rolcanlogin, r.rolreplication, r.rolsuper,
                has_table_privilege('replicator', 'ops.operations', 'SELECT'),
                has_table_privilege('replicator', 'ops.operations', 'INSERT, UPDATE, DELETE, TRUNCATE'),
                has_table_privilege('replicator', 'ops.operation_guid_registry', 'SELECT')), ''), 'not found')
FROM pg_roles r WHERE r.rolname = 'replicator';

INSERT INTO vr (check_name, passed, details)
SELECT 'Logical slot ops_sub (pgoutput) exists and is active',
       count(*) = 1 AND bool_and(s.active AND s.slot_type = 'logical' AND s.plugin = 'pgoutput'),
       coalesce(string_agg(format('type=%s plugin=%s active=%s wal_status=%s', s.slot_type, s.plugin, s.active, s.wal_status), ''), 'not found')
FROM pg_replication_slots s WHERE s.slot_name = 'ops_sub';

INSERT INTO vr (check_name, passed, details)
SELECT 'Walsender for ops_sub is streaming, replay lag < 1 MB',
       count(*) = 1 AND bool_and(r.state = 'streaming' AND pg_wal_lsn_diff(pg_current_wal_lsn(), r.replay_lsn) < 1024 * 1024),
       coalesce(string_agg(format('state=%s, replay lag %s bytes, replay_lag %s', r.state,
                pg_wal_lsn_diff(pg_current_wal_lsn(), r.replay_lsn), coalesce(r.replay_lag::text, 'n/a')), ''), 'no walsender')
FROM pg_stat_replication r WHERE r.application_name = 'ops_sub';

INSERT INTO vr (check_name, passed, details)
SELECT 'WAL retained for slots is capped (max_slot_wal_keep_size = 1GB) and the slot is within it',
       current_setting('max_slot_wal_keep_size') = '1GB'
         AND coalesce((SELECT bool_and(wal_status IN ('reserved', 'extended')) FROM pg_replication_slots WHERE slot_name = 'ops_sub'), false),
       format('max_slot_wal_keep_size=%s; slot wal_status=%s, safe_wal_size=%s', current_setting('max_slot_wal_keep_size'),
              (SELECT wal_status FROM pg_replication_slots WHERE slot_name = 'ops_sub'),
              (SELECT pg_size_pretty(safe_wal_size) FROM pg_replication_slots WHERE slot_name = 'ops_sub'));

SELECT n AS "#", CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result, check_name, details FROM vr ORDER BY n;
ROLLBACK;
