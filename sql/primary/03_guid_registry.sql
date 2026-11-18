-- =============================================================================
-- 03_guid_registry.sql  (primary only)
-- Requirement 3: global uniqueness of operation_guid on the partitioned T1.
--
-- Problem: a UNIQUE constraint on a partitioned table must include the partition
-- key, so UNIQUE (operation_guid, op_date) alone accepts the same GUID with a
-- different op_date (= in another partition).
--
-- Solution (D-07, amended by plan review R-02): a non-partitioned registry where
-- operation_guid is the PRIMARY KEY, and a *composite* FK from T1:
--
--   registry:  PRIMARY KEY (operation_guid), UNIQUE (operation_guid, op_date)
--   T1:        UNIQUE (operation_guid, op_date),
--              FOREIGN KEY (operation_guid, op_date) -> registry (operation_guid, op_date)
--
-- If T1 had (g, d1) and (g, d2):
--   d1 <> d2 -> both (g, d1) and (g, d2) must exist in the registry -> registry PK on g forbids it;
--   d1  = d2 -> T1's UNIQUE (operation_guid, op_date) forbids it.
-- So uniqueness is enforced by constraints; the trigger below only *fills* the registry.
-- =============================================================================

CREATE TABLE IF NOT EXISTS ops.operation_guid_registry (
    operation_guid uuid        NOT NULL,
    op_date        timestamptz NOT NULL,
    registered_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT operation_guid_registry_pk      PRIMARY KEY (operation_guid),
    -- Needed as the FK target: a FK must reference columns covered by a unique index.
    CONSTRAINT operation_guid_registry_guid_date_uq UNIQUE (operation_guid, op_date)
);

COMMENT ON TABLE ops.operation_guid_registry IS
    'Every operation_guid ever issued for ops.operations (requirement 3). The PK makes GUIDs globally unique across partitions. '
    'Rows are not removed when T1 rows are deleted: the GUID stays bound to its op_date and cannot be reused for another '
    'operation date (re-inserting the identical (guid, op_date) is allowed). Retention must prune it explicitly '
    '(after the referencing partition is dropped). Not replicated.';


-- BEFORE INSERT row trigger: registers the GUID in the same transaction.
--
-- Three cases (stage-2 review S2-01):
--   * new GUID                         -> registered, insert proceeds;
--   * GUID registered with ANOTHER date -> unique_violation raised here (a duplicate in
--                                         another partition, the case requirement 3 is about);
--   * GUID registered with the SAME date -> nothing to do here; T1's own
--                                         UNIQUE (operation_guid, op_date) decides: it raises
--                                         unique_violation, or skips the row silently under
--                                         INSERT ... ON CONFLICT DO NOTHING (idempotent retries).
--   Without this distinction a BEFORE trigger fires *before* T1's conflict check and an
--   idempotent retry would fail on the registry instead of being skipped.
--
-- * No EXCEPTION block on purpose: it would open a subtransaction per row, and a
--   10k-row generator batch would create 10k subtransactions (subxid cache overflow,
--   pg_subtrans lookups). ON CONFLICT DO NOTHING + a lookup needs no subtransaction.
-- * Concurrency: a concurrent insert of the same GUID waits on the registry PK
--   (speculative insertion) until the other transaction ends; the follow-up SELECT
--   is a new statement and sees the committed row (READ COMMITTED).
-- * Defined on the partitioned parent -> cloned to every partition, including ones
--   created later or attached by the self-healing maintenance.
CREATE OR REPLACE FUNCTION ops.register_operation_guid()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ops, pg_catalog
AS $$
DECLARE
    v_registered_date timestamptz;
BEGIN
    INSERT INTO ops.operation_guid_registry (operation_guid, op_date)
    VALUES (NEW.operation_guid, NEW.op_date)
    ON CONFLICT (operation_guid) DO NOTHING;

    IF NOT FOUND THEN
        SELECT r.op_date INTO v_registered_date
        FROM ops.operation_guid_registry r
        WHERE r.operation_guid = NEW.operation_guid;

        IF v_registered_date IS DISTINCT FROM NEW.op_date THEN
            RAISE EXCEPTION 'operation_guid % is already used by an operation dated %',
                            NEW.operation_guid, v_registered_date
                USING ERRCODE    = 'unique_violation',
                      SCHEMA     = 'ops',
                      TABLE      = 'operation_guid_registry',
                      CONSTRAINT = 'operation_guid_registry_pk';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION ops.register_operation_guid() IS
    'BEFORE INSERT trigger on ops.operations: registers operation_guid in ops.operation_guid_registry.';

DROP TRIGGER IF EXISTS operations_register_guid_trg ON ops.operations;
CREATE TRIGGER operations_register_guid_trg
    BEFORE INSERT ON ops.operations
    FOR EACH ROW EXECUTE FUNCTION ops.register_operation_guid();

-- Composite FK. Side effects (intended):
-- * operation_guid and op_date of an existing operation become effectively immutable
--   (the new pair would not exist in the registry);
-- * UPDATEs that don't touch these columns (e.g. status 0 -> 1) skip the FK check entirely.
ALTER TABLE ops.operations
    DROP CONSTRAINT IF EXISTS operations_guid_registry_fk;
ALTER TABLE ops.operations
    ADD CONSTRAINT operations_guid_registry_fk
    FOREIGN KEY (operation_guid, op_date)
    REFERENCES ops.operation_guid_registry (operation_guid, op_date);
