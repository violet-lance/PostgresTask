-- =============================================================================
-- 04_generator.sql  (primary only)
-- Requirement 2: stored procedure that generates test data for T1.
--
-- Decisions: D-11 (statuses: older than 24 h -> 1, last 24 h -> mostly 0),
--            D-12 (procedure, set-based batches, COMMIT per batch),
--            D-13 (deterministic client/account pool).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- ops.client_account(client_id, n) -> UA IBAN (29 chars) of the client's n-th account
--
-- Deterministic: the same (client_id, n) always gives the same account, so an
-- account always belongs to the same client (D-13). Layout of a UA IBAN:
--   'UA' + 2 check digits + 6-digit bank code (MFO) + 19-digit account number.
-- The check digits are real ISO 13616 mod-97 digits, so the numbers pass IBAN validation.
-- Domain: client_id 1..9 999 999 999 (10 digits), account_no 1..99 999 (5 digits).
-- Outside it the function returns NULL (lpad would silently TRUNCATE longer values and
-- produce colliding accounts — stage-3 review S3-02); a NULL account_number is then
-- rejected by the message CHECK constraint on ops.operations.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ops.client_account(p_client_id bigint, p_account_no int)
RETURNS text
LANGUAGE sql
IMMUTABLE STRICT PARALLEL SAFE
SET search_path = ops, pg_catalog
BEGIN ATOMIC
    WITH b AS (
        SELECT (ARRAY['305299', '322001', '300711', '320649', '380805'])[1 + (p_client_id % 5)::int]   -- bank (MFO)
               || '0000'
               || lpad(p_client_id::text, 10, '0')
               || lpad(p_account_no::text, 5, '0') AS bban                                         -- 6 + 19 digits
    )
    -- IBAN check digits: 98 - (BBAN || 'UA' as digits (U=30, A=10) || '00') mod 97
    SELECT 'UA' || lpad((98 - ((b.bban || '301000')::numeric % 97))::text, 2, '0') || b.bban
    FROM b
    WHERE p_client_id BETWEEN 1 AND 9999999999
      AND p_account_no BETWEEN 1 AND 99999;
END;

COMMENT ON FUNCTION ops.client_account(bigint, int) IS
    'Deterministic UA IBAN (valid mod-97 check digits) of the n-th account of a client.';

-- Number of accounts a client owns: 1..3, deterministic.
CREATE OR REPLACE FUNCTION ops.client_account_count(p_client_id bigint)
RETURNS int
LANGUAGE sql
IMMUTABLE STRICT PARALLEL SAFE
SET search_path = ops, pg_catalog
RETURN 1 + (p_client_id % 3)::int;

-- -----------------------------------------------------------------------------
-- ops.random_message(clients) -> jsonb message for a random client of the pool
-- Used by the generator and by the 5-second insert job (one source of truth).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ops.random_message(p_clients int DEFAULT 1000)
RETURNS jsonb
LANGUAGE sql
VOLATILE PARALLEL RESTRICTED
SET search_path = ops, pg_catalog
BEGIN ATOMIC
    WITH c AS (SELECT 1 + floor(random() * p_clients)::bigint AS client_id)
    SELECT jsonb_build_object(
               'account_number', ops.client_account(c.client_id,
                                                    1 + floor(random() * ops.client_account_count(c.client_id))::int),
               'client_id',      c.client_id,
               'operation_type', CASE WHEN random() < 0.7 THEN 'online' ELSE 'offline' END)
    FROM c;
END;

COMMENT ON FUNCTION ops.random_message(int) IS
    'Random but consistent jsonb message: {account_number, client_id, operation_type}. ~70% online.';

-- Random amount: log-uniform between 1.00 and 50 000.00 (many small, few large operations).
CREATE OR REPLACE FUNCTION ops.random_amount()
RETURNS numeric
LANGUAGE sql
VOLATILE PARALLEL RESTRICTED
SET search_path = ops, pg_catalog
RETURN round(exp(random() * ln(50000))::numeric, 2);


-- -----------------------------------------------------------------------------
-- ops.generate_operations(...) — the generator (requirement 2)
--
-- * Set-based INSERT ... SELECT generate_series per batch, COMMIT after each batch:
--   bounded transactions (WAL, locks, and medium-sized transactions for logical replication).
-- * Batches walk the period chronologically and each batch is inserted ORDER BY op_date,
--   so identity ids grow with op_date like in a real system, and each batch touches only
--   1-2 partitions.
-- * Status (D-11): rows older than (p_to - 24 h) -> 1; within the last 24 h the
--   probability of status 0 grows linearly from 0 to 1 towards p_to.
-- * Goes through the normal insert path (GUID registry trigger + FK), so generated data
--   gets the same uniqueness guarantee as everything else.
--
-- NOTE: no "SET search_path" clause here, unlike every other function (D-20):
-- PostgreSQL forbids COMMIT/ROLLBACK in a procedure that has a SET clause. All names
-- are schema-qualified instead. Must be CALLed outside an explicit transaction block.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ops.generate_operations(
    p_rows    int              DEFAULT 100000,
    p_from    timestamptz      DEFAULT now() - interval '4 months',
    p_to      timestamptz      DEFAULT now(),
    p_batch   int              DEFAULT 10000,
    p_clients int              DEFAULT 1000,
    p_seed    double precision DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_span        interval := p_to - p_from;
    v_pending_lo  timestamptz := p_to - interval '24 hours';
    v_done        int := 0;
    v_n           int;
    v_slice_from  timestamptz;
    v_slice_to    timestamptz;
    v_started     timestamptz := clock_timestamp();
    v_batch_start timestamptz;
BEGIN
    IF p_rows IS NULL OR p_rows <= 0 THEN RAISE EXCEPTION 'p_rows must be > 0'; END IF;
    IF p_batch IS NULL OR p_batch <= 0 THEN RAISE EXCEPTION 'p_batch must be > 0'; END IF;
    IF p_clients IS NULL OR p_clients <= 0 THEN RAISE EXCEPTION 'p_clients must be > 0'; END IF;
    IF p_from IS NULL OR p_to IS NULL OR p_from >= p_to THEN RAISE EXCEPTION 'p_from must be < p_to'; END IF;

    IF p_seed IS NOT NULL THEN
        PERFORM pg_catalog.setseed(p_seed);   -- reproducible dates/amounts/clients (GUIDs stay random)
    END IF;

    -- Partitions for exactly the months of [p_from, p_to) first, so nothing lands in DEFAULT.
    -- (Not ensure_monthly_partitions(p_from, ...): that fills every month from p_from up to
    -- now + 2, i.e. dozens of empty partitions for a historical range — stage-3 review S3-01.)
    PERFORM ops.create_month_partition(m::date)
    FROM pg_catalog.generate_series(date_trunc('month', p_from AT TIME ZONE 'UTC'),
                                    date_trunc('month', (p_to - interval '1 microsecond') AT TIME ZONE 'UTC'),
                                    interval '1 month') AS m;
    COMMIT;

    WHILE v_done < p_rows LOOP
        v_batch_start := clock_timestamp();
        v_n          := least(p_batch, p_rows - v_done);
        -- Time slice proportional to the batch's share of rows -> uniform density over the period.
        v_slice_from := p_from + v_span * (v_done::double precision / p_rows);
        v_slice_to   := p_from + v_span * ((v_done + v_n)::double precision / p_rows);

        INSERT INTO ops.operations (op_date, amount, status, message)
        SELECT d.op_date,
               ops.random_amount(),
               CASE
                   WHEN d.op_date < v_pending_lo THEN 1
                   WHEN random() < extract(epoch FROM d.op_date - v_pending_lo) / 86400.0 THEN 0
                   ELSE 1
               END,
               ops.random_message(p_clients)
        FROM (
            SELECT v_slice_from + (v_slice_to - v_slice_from) * random() AS op_date
            FROM generate_series(1, v_n)
        ) d
        ORDER BY d.op_date;

        v_done := v_done + v_n;
        COMMIT;

        RAISE NOTICE 'ops.generate_operations: % / % rows (batch % rows in % ms)',
            v_done, p_rows, v_n,
            round(extract(epoch FROM clock_timestamp() - v_batch_start) * 1000);
    END LOOP;

    RAISE NOTICE 'ops.generate_operations: done, % rows in % s',
        p_rows, round(extract(epoch FROM clock_timestamp() - v_started)::numeric, 1);
END;
$$;

COMMENT ON PROCEDURE ops.generate_operations(int, timestamptz, timestamptz, int, int, double precision) IS
    'Requirement 2: generates p_rows operations over [p_from, p_to) in chronological set-based batches with COMMIT per batch.';
