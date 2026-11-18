-- =============================================================================
-- 06_job_functions.sql  (primary only)
-- Functions called by the scheduled jobs (requirements 4 and 5).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Requirement 4: add one operation with status 0. Called every 5 seconds by pg_cron.
-- Reuses the generator's random_amount()/random_message(), so a job-inserted row
-- looks exactly like generated data, and goes through the same GUID registry path.
-- Returns the new id (visible in cron.job_run_details.return_message as "1 row").
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ops.insert_random_operation(p_clients int DEFAULT 1000)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SET search_path = ops, pg_catalog
AS $$
DECLARE
    v_id bigint;
BEGIN
    INSERT INTO ops.operations (op_date, amount, status, message)
    VALUES (now(), ops.random_amount(), 0, ops.random_message(p_clients))
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION ops.insert_random_operation(int) IS
    'Requirement 4: inserts one random operation with status = 0 (pending). Scheduled every 5 seconds.';
