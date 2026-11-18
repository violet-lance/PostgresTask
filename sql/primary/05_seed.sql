-- =============================================================================
-- 05_seed.sql  (primary only)
-- Requirement 2: initial data — 100 000 operations over the last 4 months.
--
-- Runs right after the generator and BEFORE the materialized view is created, so the
-- view is built from the seeded data. Seeding inserts rows (status 0/1); the MV refresh
-- trigger reacts to UPDATEs only.
-- =============================================================================

CALL ops.generate_operations(
    p_rows  => 100000,
    p_from  => now() - interval '4 months',
    p_to    => now(),
    p_batch => 10000
);

-- Autovacuum never ANALYZEs a partitioned parent; do it explicitly after a bulk load.
ANALYZE ops.operations;
ANALYZE ops.operation_guid_registry;
