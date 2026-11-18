-- =============================================================================
-- 03_read_only_guard.sql  (replica only)
-- Stage-7 review S7-01: T1 on the replica is read-only for local sessions.
--
-- A logical-replication subscriber is writable, and local writes silently diverge from
-- the publisher. Reproduced: a local INSERT with an id the primary issued later did NOT
-- conflict, because the PK is (id, op_date). The replica then simply had an extra row,
-- with 0 apply errors.
--
-- The apply and table-sync workers run with session_replication_role = replica, and
-- ordinary (ENABLE ORIGIN) triggers do not fire in that mode, so replication is not
-- affected by this guard.
--
-- Escape hatch for intentional local writes (partition self-healing, verification scripts):
--   SELECT set_config('ops.allow_replica_writes', 'on', true);   -- transaction-local
-- It's a guard against accidents, not a security boundary (a superuser can bypass anything).
-- =============================================================================

CREATE OR REPLACE FUNCTION ops.replica_read_only_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ops, pg_catalog
AS $$
BEGIN
    IF coalesce(current_setting('ops.allow_replica_writes', true), '') = 'on' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;   -- NULL for statement-level TRUNCATE is fine
    END IF;

    RAISE EXCEPTION 'ops.operations is read-only on the replica (% on %): changes arrive by logical replication from pg-primary',
                    TG_OP, TG_TABLE_NAME
        USING ERRCODE = 'read_only_sql_transaction',
              HINT    = 'Write to pg-primary. Intentional maintenance: SELECT set_config(''ops.allow_replica_writes'', ''on'', true);';
END;
$$;

COMMENT ON FUNCTION ops.replica_read_only_guard() IS
    'Replica only: rejects local writes to ops.operations (logical replication bypasses it).';

-- Row-level triggers on the partitioned parent are cloned to every partition, so direct
-- writes into a partition are caught too (statement-level triggers would not be).
DROP TRIGGER IF EXISTS operations_read_only_trg ON ops.operations;
CREATE TRIGGER operations_read_only_trg
    BEFORE INSERT OR UPDATE OR DELETE ON ops.operations
    FOR EACH ROW EXECUTE FUNCTION ops.replica_read_only_guard();

-- TRUNCATE has no row-level form: guarded on the parent only.
DROP TRIGGER IF EXISTS operations_read_only_trunc_trg ON ops.operations;
CREATE TRIGGER operations_read_only_trunc_trg
    BEFORE TRUNCATE ON ops.operations
    FOR EACH STATEMENT EXECUTE FUNCTION ops.replica_read_only_guard();
