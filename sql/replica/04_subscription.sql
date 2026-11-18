-- =============================================================================
-- 04_subscription.sql  (replica only)
-- Requirement 7 (subscriber side): subscribe to the publisher's T1.
--
-- At this point common/01-02 have created the same partitioned ops.operations with
-- partitions covering the publisher's data range (R-03), so the initial copy does not
-- land in DEFAULT.
-- The replica runs no business jobs and has no GUID registry / MV (D-14): it only
-- applies changes that were already validated on the publisher. Its only job is the
-- partition maintenance from common/02 (which also heals DEFAULT if needed).
--
-- psql variables (passed by the init runner): :primary_host, :primary_db, :replicator_password
-- CREATE SUBSCRIPTION can't run inside a transaction block; psql -f runs in autocommit.
-- =============================================================================

SELECT format(
    'CREATE SUBSCRIPTION ops_sub CONNECTION %L PUBLICATION ops_pub WITH (copy_data = true, create_slot = true, slot_name = %L)',
    format('host=%s port=5432 dbname=%s user=replicator password=%s application_name=ops_sub',
           :'primary_host', :'primary_db', :'replicator_password'),
    'ops_sub')
WHERE NOT EXISTS (SELECT 1 FROM pg_subscription WHERE subname = 'ops_sub') \gexec

COMMENT ON SUBSCRIPTION ops_sub IS 'Requirement 7: logical replica of pg-primary ops.operations (publication ops_pub).';
