-- =============================================================================
-- 07_materialized_view.sql  (primary only)
-- Requirement 6: current total amount per client and operation type, stored in a
-- MATERIALIZED VIEW, refreshed on every status update 0 -> 1.
--
-- Decisions: D-08 (real MV, REFRESH CONCURRENTLY from statement-level triggers),
--            D-09 (only confirmed operations, status = 1), D-16 (refresh failure aborts
--            the update), D-20 (everything schema-qualified: PG 17 builds/refreshes MVs
--            with search_path = pg_catalog, pg_temp), stage-6 decision: refresh on ANY
--            change of the confirmed set, not only 0 -> 1 (see docs).
--
-- Runs after 05_seed.sql, so the view is built from the seeded data and the seed
-- itself does not trigger refreshes.
-- =============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS ops.client_type_totals AS
SELECT (o.message ->> 'client_id')::bigint AS client_id,
       (o.message ->> 'operation_type')    AS operation_type,
       sum(o.amount)                        AS total_amount,
       count(*)                             AS operations_count
FROM ops.operations o
WHERE o.status = 1
GROUP BY 1, 2
WITH DATA;

-- Required by REFRESH ... CONCURRENTLY (and the natural key of the aggregate).
CREATE UNIQUE INDEX IF NOT EXISTS client_type_totals_uq
    ON ops.client_type_totals (client_id, operation_type);

COMMENT ON MATERIALIZED VIEW ops.client_type_totals IS
    'Requirement 6: total amount and count of CONFIRMED (status = 1) operations per client and operation type. '
    'Refreshed CONCURRENTLY in the same transaction as every statement that changes the confirmed set.';


-- Refresh log: one row per refresh. refreshed_at = now() of the refreshing transaction,
-- i.e. equal to confirm_job_log.run_at when the refresh was caused by the confirm job.
CREATE TABLE IF NOT EXISTS ops.mv_refresh_log (
    refresh_id             bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    refreshed_at           timestamptz   NOT NULL,
    trigger_op             text          NOT NULL CHECK (trigger_op IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'MANUAL')),
    rows_flipped_0_to_1    bigint        NOT NULL,   -- the requirement's case
    rows_changed_confirmed bigint        NOT NULL,   -- all rows that changed the confirmed set (incl. 0 -> 1)
    duration_ms            numeric(10,3) NOT NULL
);
CREATE INDEX IF NOT EXISTS mv_refresh_log_refreshed_at_ix ON ops.mv_refresh_log (refreshed_at);

COMMENT ON TABLE ops.mv_refresh_log IS
    'One row per refresh of ops.client_type_totals. Primary only, not replicated. Pruned by ops.housekeeping().';


-- -----------------------------------------------------------------------------
-- Trigger function shared by the statement-level triggers below.
-- Decides from the transition tables whether the confirmed set changed:
--   INSERT   : new rows with status 1
--   DELETE   : deleted rows with status 1
--   UPDATE   : rows confirmed before or after, whose status / amount / client / type changed
--              (0 -> 1 is counted separately: it's the case named by the requirement)
--   TRUNCATE : always (no transition tables for TRUNCATE)
-- Statements that don't touch confirmed rows (e.g. the 5-s job inserting status 0,
-- or a confirm run that found nothing) do not refresh.
-- Errors are NOT caught (D-16): a failed refresh aborts the statement that caused it.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ops.refresh_client_type_totals()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ops, pg_catalog
AS $$
DECLARE
    v_started timestamptz := clock_timestamp();
    v_flipped bigint := 0;
    v_changed bigint := 0;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT count(*) INTO v_changed FROM new_rows WHERE status = 1;

    ELSIF TG_OP = 'DELETE' THEN
        SELECT count(*) INTO v_changed FROM old_rows WHERE status = 1;

    ELSIF TG_OP = 'UPDATE' THEN
        SELECT count(*) FILTER (WHERE o.status = 0 AND n.status = 1),
               count(*) FILTER (WHERE (o.status = 1 OR n.status = 1)
                                  AND (o.status, o.amount, o.message ->> 'client_id', o.message ->> 'operation_type')
                                      IS DISTINCT FROM
                                      (n.status, n.amount, n.message ->> 'client_id', n.message ->> 'operation_type'))
        INTO v_flipped, v_changed
        FROM old_rows o
        JOIN new_rows n ON n.id = o.id AND n.op_date = o.op_date;

    ELSIF TG_OP = 'TRUNCATE' THEN
        v_changed := -1;   -- unknown number of rows; always refresh
    END IF;

    IF v_changed <> 0 THEN
        -- Serialise refreshes and, crucially, take the lock in a SEPARATE statement BEFORE
        -- the REFRESH (stage-6 review S6-01). In READ COMMITTED a statement's snapshot is
        -- taken when the statement starts; REFRESH's own ExclusiveLock wait happens after
        -- that, so a REFRESH that waited for another one would recompute from a snapshot
        -- taken BEFORE the other transaction committed and silently undo its changes
        -- (reproduced: MV lost a +1000.00 change). Waiting here instead means the REFRESH
        -- statement below starts after the other transaction has committed and sees it.
        -- (LOCK TABLE is not supported for materialized views, hence an advisory lock.)
        PERFORM pg_advisory_xact_lock(ops.mv_refresh_lock_key());

        REFRESH MATERIALIZED VIEW CONCURRENTLY ops.client_type_totals;

        INSERT INTO ops.mv_refresh_log (refreshed_at, trigger_op, rows_flipped_0_to_1, rows_changed_confirmed, duration_ms)
        VALUES (now(), TG_OP, v_flipped, v_changed, extract(epoch FROM clock_timestamp() - v_started) * 1000);
    END IF;

    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION ops.refresh_client_type_totals() IS
    'Statement-level trigger: refreshes ops.client_type_totals when the set of confirmed operations changed.';

-- A trigger with transition tables may have only one event, hence one trigger per event.
-- No column list on the UPDATE trigger: not allowed together with transition tables (plan review R-01).
DROP TRIGGER IF EXISTS operations_totals_ins_trg ON ops.operations;
CREATE TRIGGER operations_totals_ins_trg
    AFTER INSERT ON ops.operations
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION ops.refresh_client_type_totals();

DROP TRIGGER IF EXISTS operations_totals_upd_trg ON ops.operations;
CREATE TRIGGER operations_totals_upd_trg
    AFTER UPDATE ON ops.operations
    REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION ops.refresh_client_type_totals();

DROP TRIGGER IF EXISTS operations_totals_del_trg ON ops.operations;
CREATE TRIGGER operations_totals_del_trg
    AFTER DELETE ON ops.operations
    REFERENCING OLD TABLE AS old_rows
    FOR EACH STATEMENT EXECUTE FUNCTION ops.refresh_client_type_totals();

DROP TRIGGER IF EXISTS operations_totals_trunc_trg ON ops.operations;
CREATE TRIGGER operations_totals_trunc_trg
    AFTER TRUNCATE ON ops.operations
    FOR EACH STATEMENT EXECUTE FUNCTION ops.refresh_client_type_totals();


-- -----------------------------------------------------------------------------
-- Manual refresh entry point (stage-6 review S6-03). A bare
-- "REFRESH MATERIALIZED VIEW ops.client_type_totals" bypasses the advisory lock and can
-- hit the snapshot race described above when it overlaps with a trigger refresh.
-- Use SELECT ops.refresh_totals(); instead.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ops.refresh_totals()
RETURNS numeric
LANGUAGE plpgsql
SET search_path = ops, pg_catalog
AS $$
DECLARE
    v_started timestamptz := clock_timestamp();
    v_ms      numeric;
BEGIN
    PERFORM pg_advisory_xact_lock(ops.mv_refresh_lock_key());   -- separate statement, before REFRESH
    REFRESH MATERIALIZED VIEW CONCURRENTLY ops.client_type_totals;
    v_ms := extract(epoch FROM clock_timestamp() - v_started) * 1000;
    INSERT INTO ops.mv_refresh_log (refreshed_at, trigger_op, rows_flipped_0_to_1, rows_changed_confirmed, duration_ms)
    VALUES (now(), 'MANUAL', 0, 0, v_ms);
    RETURN v_ms;
END;
$$;

COMMENT ON FUNCTION ops.refresh_totals() IS
    'Safe manual refresh of ops.client_type_totals (takes the refresh advisory lock first). Returns duration in ms.';
