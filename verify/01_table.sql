-- =============================================================================
-- verify/01_table.sql — Requirement 1: partitioned T1 (ops.operations)
-- Non-destructive: everything runs inside a transaction that is rolled back.
-- Output: one row per check with PASS/FAIL.
-- =============================================================================
\set ON_ERROR_STOP 1
\pset footer off
BEGIN;

CREATE TEMP TABLE vr (n serial, check_name text, passed boolean, details text) ON COMMIT DROP;

-- 0. DEFAULT partition is empty (checked first, before this script inserts anything) — D-18
INSERT INTO vr (check_name, passed, details)
SELECT 'DEFAULT partition is empty', count(*) = 0, format('%s row(s) in ops.operations_default', count(*))
FROM ops.operations_default;

-- 1. Table is partitioned by RANGE on op_date
INSERT INTO vr (check_name, passed, details)
SELECT 'T1 is RANGE-partitioned by op_date',
       pt.partstrat = 'r' AND pg_get_partkeydef(c.oid) = 'RANGE (op_date)',
       pg_get_partkeydef(c.oid)
FROM pg_partitioned_table pt JOIN pg_class c ON c.oid = pt.partrelid
WHERE c.oid = 'ops.operations'::regclass;

-- 2. Required columns and types
INSERT INTO vr (check_name, passed, details)
SELECT 'Columns: op_date, id, amount, status, operation_guid, message(jsonb)',
       string_agg(attname || ':' || format_type(atttypid, atttypmod), ', ' ORDER BY attnum)
         = 'id:bigint, op_date:timestamp with time zone, amount:numeric(14,2), status:smallint, operation_guid:uuid, message:jsonb',
       string_agg(attname || ':' || format_type(atttypid, atttypmod), ', ' ORDER BY attnum)
FROM pg_attribute
WHERE attrelid = 'ops.operations'::regclass AND attnum > 0 AND NOT attisdropped;

-- 3. Monthly partitions cover [now - 4 months, now + 2 months] and DEFAULT exists
INSERT INTO vr (check_name, passed, details)
SELECT 'Monthly partitions cover generator range + 2 months ahead, DEFAULT exists',
       bool_and(to_regclass(format('ops.operations_y%sm%s', to_char(m, 'YYYY'), to_char(m, 'MM'))) IS NOT NULL)
         AND to_regclass('ops.operations_default') IS NOT NULL,
       (SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
        FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'ops.operations'::regclass)
FROM generate_series(date_trunc('month', now() - interval '4 months'),
                     date_trunc('month', now()) + interval '2 months', interval '1 month') m;

-- 4. Routing: a row lands in the partition of its month
WITH ins AS (
    INSERT INTO ops.operations (op_date, amount, message)
    VALUES (now(), 10.00, '{"account_number":"UA000000000000000000000000001","client_id":1,"operation_type":"online"}')
    RETURNING tableoid::regclass AS part
)
INSERT INTO vr (check_name, passed, details)
SELECT 'Row with op_date = now() is routed to the current month partition',
       part::text = format('ops.operations_y%s', to_char(now(), 'YYYY"m"MM')),
       part::text
FROM ins;

-- 5. jsonb message contract is enforced
DO $$
DECLARE
    bad jsonb[] := ARRAY[
        '[]',                                                                                    -- not an object
        '{"client_id":1,"operation_type":"online"}',                                             -- no account
        '{"account_number":"UA123","client_id":1,"operation_type":"online"}',                    -- bad account format
        '{"account_number":"UA000000000000000000000000001","client_id":"1","operation_type":"online"}', -- client_id not a number
        '{"account_number":"UA000000000000000000000000001","client_id":1.5,"operation_type":"online"}', -- client_id not integer
        '{"account_number":"UA000000000000000000000000001","client_id":1,"operation_type":"atm"}'       -- unknown type
    ]::jsonb[];
    m jsonb;
    rejected int := 0;
BEGIN
    FOREACH m IN ARRAY bad LOOP
        BEGIN
            INSERT INTO ops.operations (amount, message) VALUES (1, m);
        EXCEPTION WHEN check_violation THEN
            rejected := rejected + 1;
        END;
    END LOOP;
    INSERT INTO vr (check_name, passed, details)
    VALUES ('Invalid jsonb messages are rejected by CHECK constraints',
            rejected = array_length(bad, 1), format('%s of %s rejected', rejected, array_length(bad, 1)));
END $$;

-- 6. amount > 0 and status in (0,1)
DO $$
DECLARE rejected int := 0;
        ok_msg jsonb := '{"account_number":"UA000000000000000000000000001","client_id":1,"operation_type":"offline"}';
BEGIN
    BEGIN INSERT INTO ops.operations (amount, message) VALUES (0, ok_msg);
    EXCEPTION WHEN check_violation THEN rejected := rejected + 1; END;
    BEGIN INSERT INTO ops.operations (amount, status, message) VALUES (1, 2, ok_msg);
    EXCEPTION WHEN check_violation THEN rejected := rejected + 1; END;
    INSERT INTO vr (check_name, passed, details)
    VALUES ('amount <= 0 and status not in (0,1) are rejected', rejected = 2, format('%s of 2 rejected', rejected));
END $$;

-- 7. Self-healing maintenance (D-18): a row in DEFAULT is moved into a newly created partition
DO $$
DECLARE
    v_month date := (date_trunc('month', now()) + interval '6 months')::date;   -- beyond pre-created range
    v_part  text := format('ops.operations_y%s', to_char(v_month, 'YYYY"m"MM'));
    v_landed text; v_after text; v_created int; v_default_left bigint;
BEGIN
    INSERT INTO ops.operations (op_date, amount, message)
    VALUES (v_month + interval '10 days', 5,
            '{"account_number":"UA000000000000000000000000002","client_id":2,"operation_type":"offline"}')
    RETURNING tableoid::regclass::text INTO v_landed;

    v_created := ops.ensure_monthly_partitions();

    SELECT tableoid::regclass::text INTO v_after
    FROM ops.operations WHERE op_date = v_month + interval '10 days';
    SELECT count(*) INTO v_default_left FROM ops.operations_default;

    INSERT INTO vr (check_name, passed, details)
    VALUES ('Self-healing: row in DEFAULT is moved to a newly created month partition',
            v_landed = 'ops.operations_default' AND v_after = v_part AND v_default_left = 0
              AND to_regclass('ops.operations_default') IS NOT NULL,
            format('landed in %s -> after maintenance in %s; DEFAULT rows left: %s; partitions created: %s',
                   v_landed, v_after, v_default_left, v_created));
END $$;

-- 8. Maintenance is idempotent
INSERT INTO vr (check_name, passed, details)
SELECT 'ensure_monthly_partitions() is idempotent (second call creates nothing)', c = 0, format('created on re-run: %s', c)
FROM (SELECT ops.ensure_monthly_partitions((now() - interval '4 months')::date, 2) AS c) s;

-- 9. Partition-maintenance job is scheduled
INSERT INTO vr (check_name, passed, details)
SELECT 'pg_cron job "partition-maintenance" is scheduled and active',
       count(*) = 1 AND bool_and(active), string_agg(schedule || ' -> ' || command, '; ')
FROM cron.job WHERE jobname = 'partition-maintenance';

SELECT n AS "#", CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result, check_name, details FROM vr ORDER BY n;
ROLLBACK;
