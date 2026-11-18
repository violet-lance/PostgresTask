-- =============================================================================
-- 09_publication.sql  (primary only)
-- Requirement 7 (publisher side): logical replication of T1 (D-05).
--
-- psql variables (passed by the init runner): :replicator_password
-- psql variables are not substituted inside $$-quoted bodies, hence \gexec.
-- =============================================================================

-- Dedicated least-privilege role for the subscriber: may open a replication connection and
-- read T1 (needed for the initial table copy); nothing else. pg_hba.conf needs no change:
-- the official image allows "host all all all scram-sha-256", and logical-replication
-- connections match ordinary database lines (plan review R-07).
SELECT format('CREATE ROLE replicator WITH LOGIN REPLICATION PASSWORD %L', :'replicator_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') \gexec

GRANT USAGE  ON SCHEMA ops       TO replicator;
GRANT SELECT ON ops.operations   TO replicator;

-- publish_via_partition_root = true: changes of every partition (present and future) are
-- published as changes of ops.operations itself, so
--   * partitions created later on the publisher need no publication/subscription changes;
--   * the subscriber routes rows through ITS OWN partitioning (D-14) — layouts may differ.
-- Published operations: insert, update, delete, truncate (default).
-- The GUID registry, the MV and the audit logs are intentionally NOT published.
DROP PUBLICATION IF EXISTS ops_pub;
CREATE PUBLICATION ops_pub
    FOR TABLE ops.operations
    WITH (publish_via_partition_root = true);

COMMENT ON PUBLICATION ops_pub IS 'Requirement 7: logical replication of T1 (ops.operations) to pg-replica.';
