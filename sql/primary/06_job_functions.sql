-- =============================================================================
-- 06_job_functions.sql  (primary only)
-- Functions called by the scheduled jobs (requirements 4 and 5).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Requirement 4: add one operation with status 0. Called every 5 seconds by pg_cron.
-- Reuses the generator's random_amount()/random_message(), so a job-inserted row
-- looks exactly like generated data, and goes through the same GUID registry path.
-- Returns the new id (useful when called by hand; pg_cron itself only records
-- "1 row" in cron.job_run_details.return_message, not the returned value).
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


-- -----------------------------------------------------------------------------
-- Key of the transaction-level advisory lock that serialises refreshes of the
-- materialized view ops.client_type_totals (stage-6 review S6-01/S6-02).
-- LOCK TABLE is not supported for materialized views, hence an advisory lock.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ops.mv_refresh_lock_key()
RETURNS bigint
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = ops, pg_catalog
RETURN 7400001;   -- arbitrary constant, unique within this database

COMMENT ON FUNCTION ops.mv_refresh_lock_key() IS
    'Advisory lock key serialising refreshes of ops.client_type_totals (see 07_materialized_view.sql).';


-- =============================================================================
-- Requirement 5: every 3 seconds confirm (0 -> 1) pending operations whose id has the
-- same parity as the current second.
-- =============================================================================

-- Audit log, one row per run (D-19), so that the parity rule can be checked exactly.
CREATE TABLE IF NOT EXISTS ops.confirm_job_log (
    run_id         bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_at         timestamptz NOT NULL,           -- now() of the run: the moment whose seconds decide
    run_second     smallint    NOT NULL CHECK (run_second BETWEEN 0 AND 59),
    parity         smallint    NOT NULL CHECK (parity IN (0, 1)),   -- 0 = even, 1 = odd
    rows_confirmed int         NOT NULL,
    confirmed_ids  bigint[]    NOT NULL,           -- exact evidence: which ids this run confirmed
    duration_ms    numeric(10,3) NOT NULL
);
CREATE INDEX IF NOT EXISTS confirm_job_log_run_at_ix ON ops.confirm_job_log (run_at);

COMMENT ON TABLE ops.confirm_job_log IS
    'Audit of ops.confirm_operations_by_parity() runs (requirement 5, D-19). Primary only, not replicated. Pruned by ops.housekeeping().';

-- -----------------------------------------------------------------------------
-- Parity source: now() = start of the confirming transaction, i.e. the moment the
-- job actually runs. floor() is essential: extract(second ...) returns a fraction
-- (e.g. 20.613) and a plain ::int cast ROUNDS it (-> 21, wrong parity). The epoch is
-- used because it doesn't depend on the session time zone; since 60 is even,
-- epoch-second parity == second-of-minute parity.
-- (Stage-4 review: pg_cron starts inside the scheduled second, but now() lags the
-- start by 1-12 ms and can occasionally fall into the next second. The rule is applied
-- to the second actually observed, and that second is logged.)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ops.confirm_operations_by_parity()
RETURNS int
LANGUAGE plpgsql
VOLATILE
SET search_path = ops, pg_catalog
SET lock_timeout = '2s'
AS $$
DECLARE
    v_run_at  timestamptz := now();
    v_epoch_s bigint      := floor(extract(epoch FROM v_run_at))::bigint;
    v_parity  int         := (v_epoch_s % 2)::int;
    v_started timestamptz := clock_timestamp();
    v_rows    int;
    v_ids     bigint[];
BEGIN
    -- Take the MV-refresh lock BEFORE locking any row (stage-6 review S6-02): the refresh
    -- trigger fired by the UPDATE below needs it, and waiting for it while already holding
    -- row locks can deadlock with a transaction that holds it and wants one of those rows.
    -- In this order the job never waits for the lock while holding row locks (rows are
    -- taken with SKIP LOCKED, so it never waits for rows either). If another transaction
    -- holds the lock for more than lock_timeout (2 s), this run fails visibly in
    -- cron.job_run_details and the next run retries.
    PERFORM pg_advisory_xact_lock(ops.mv_refresh_lock_key());

    -- Candidates come from the partial index operations_pending_id_ix (id) WHERE status = 0.
    -- FOR UPDATE SKIP LOCKED (stage-5 review S5-01): a pending row locked by someone else
    -- (long transaction, SELECT ... FOR UPDATE) is skipped instead of blocking the whole run;
    -- a later run with the same parity confirms it. Without it, one locked row stalled the
    -- job for 10.4 s in a test (3 runs lost, other operations waiting).
    WITH candidates AS (
        SELECT o.id, o.op_date
        FROM   ops.operations o
        WHERE  o.status = 0
          AND  o.id % 2 = v_parity
        FOR UPDATE SKIP LOCKED
    ),
    confirmed AS (
        UPDATE ops.operations o
        SET    status = 1
        FROM   candidates c
        WHERE  o.id = c.id AND o.op_date = c.op_date     -- full PK: one index probe per row
        RETURNING o.id
    )
    SELECT count(*), coalesce(array_agg(id ORDER BY id), '{}')
    INTO   v_rows, v_ids
    FROM   confirmed;

    INSERT INTO ops.confirm_job_log (run_at, run_second, parity, rows_confirmed, confirmed_ids, duration_ms)
    VALUES (v_run_at,
            floor(extract(second FROM v_run_at AT TIME ZONE 'UTC'))::smallint,
            v_parity, v_rows, v_ids,
            extract(epoch FROM clock_timestamp() - v_started) * 1000);

    RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION ops.confirm_operations_by_parity() IS
    'Requirement 5: sets status 0 -> 1 for ids with the parity of the current second (even second -> even ids). Scheduled every 3 seconds.';


-- -----------------------------------------------------------------------------
-- Housekeeping: second-level jobs produce ~46k cron.job_run_details rows/day and
-- ~29k confirm_job_log rows/day. Keep p_keep of history. Tables created by later
-- scripts (e.g. the MV refresh log) are pruned if they exist.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ops.housekeeping(p_keep interval DEFAULT interval '3 days')
RETURNS text
LANGUAGE plpgsql
SET search_path = ops, pg_catalog
AS $$
DECLARE
    v_cron bigint; v_confirm bigint; v_refresh bigint := 0;
BEGIN
    DELETE FROM cron.job_run_details WHERE end_time < now() - p_keep;
    GET DIAGNOSTICS v_cron = ROW_COUNT;

    DELETE FROM ops.confirm_job_log WHERE run_at < now() - p_keep;
    GET DIAGNOSTICS v_confirm = ROW_COUNT;

    IF to_regclass('ops.mv_refresh_log') IS NOT NULL THEN
        EXECUTE 'DELETE FROM ops.mv_refresh_log WHERE refreshed_at < now() - $1' USING p_keep;
        GET DIAGNOSTICS v_refresh = ROW_COUNT;
    END IF;

    RETURN format('deleted: cron.job_run_details=%s, confirm_job_log=%s, mv_refresh_log=%s', v_cron, v_confirm, v_refresh);
END;
$$;

COMMENT ON FUNCTION ops.housekeeping(interval) IS
    'Prunes job history and audit logs older than p_keep. Scheduled daily.';
