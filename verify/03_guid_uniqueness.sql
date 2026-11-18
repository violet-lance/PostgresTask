-- =============================================================================
-- verify/03_guid_uniqueness.sql — Requirement 3: operation_guid is globally unique
-- Primary only. Non-destructive: runs in a transaction that is rolled back.
-- Note: check 6 uses ALTER TABLE ... DISABLE TRIGGER, which takes an ACCESS EXCLUSIVE
-- lock on ops.operations until rollback — running jobs wait for a moment.
-- =============================================================================
\set ON_ERROR_STOP 1
\pset footer off
BEGIN;

CREATE TEMP TABLE vr (n serial, check_name text, passed boolean, details text) ON COMMIT DROP;

-- 1. Existing data: no duplicate GUIDs, every T1 row is registered
INSERT INTO vr (check_name, passed, details)
SELECT 'Existing data: no duplicate operation_guid across all partitions',
       count(*) = 0, format('%s duplicated guid(s)', count(*))
FROM (SELECT operation_guid FROM ops.operations GROUP BY 1 HAVING count(*) > 1) d;

INSERT INTO vr (check_name, passed, details)
SELECT 'Existing data: every T1 row has a matching registry row',
       count(*) = 0, format('%s unregistered row(s)', count(*))
FROM ops.operations o
WHERE NOT EXISTS (SELECT 1 FROM ops.operation_guid_registry r
                  WHERE r.operation_guid = o.operation_guid AND r.op_date = o.op_date);

-- 2. Schema: registry PK on guid alone, composite FK from T1
INSERT INTO vr (check_name, passed, details)
SELECT 'Registry has PRIMARY KEY (operation_guid)', count(*) = 1, string_agg(pg_get_constraintdef(oid), '; ')
FROM pg_constraint
WHERE conrelid = 'ops.operation_guid_registry'::regclass AND contype = 'p'
  AND pg_get_constraintdef(oid) = 'PRIMARY KEY (operation_guid)';

INSERT INTO vr (check_name, passed, details)
SELECT 'T1 has composite FK (operation_guid, op_date) -> registry', count(*) = 1, string_agg(pg_get_constraintdef(oid), '; ')
FROM pg_constraint
WHERE conrelid = 'ops.operations'::regclass AND contype = 'f'
  AND confrelid = 'ops.operation_guid_registry'::regclass
  AND pg_get_constraintdef(oid) LIKE 'FOREIGN KEY (operation_guid, op_date) REFERENCES ops.operation_guid_registry(operation_guid, op_date)%';

-- 3..7: behaviour
DO $$
DECLARE
    g      uuid  := gen_random_uuid();
    msg    jsonb := '{"account_number":"UA000000000000000000000000003","client_id":3,"operation_type":"online"}';
    d_this timestamptz := now();
    d_prev timestamptz := now() - interval '1 month';   -- a different partition
    v_err  text;
    v_ok   boolean;
    v_id   bigint;
BEGIN
    -- 3. Insert registers the GUID
    INSERT INTO ops.operations (op_date, amount, operation_guid, message) VALUES (d_this, 1, g, msg) RETURNING id INTO v_id;
    SELECT EXISTS (SELECT 1 FROM ops.operation_guid_registry WHERE operation_guid = g AND op_date = d_this) INTO v_ok;
    INSERT INTO vr (check_name, passed, details) VALUES ('Insert registers (guid, op_date) in the registry', v_ok, g::text);

    -- 4. Same GUID, different op_date / partition  -> rejected (the case UNIQUE(guid, op_date) alone would miss)
    v_err := NULL;
    BEGIN
        INSERT INTO ops.operations (op_date, amount, operation_guid, message) VALUES (d_prev, 1, g, msg);
    EXCEPTION WHEN unique_violation THEN v_err := SQLERRM;
    END;
    INSERT INTO vr (check_name, passed, details)
    VALUES ('Same guid in ANOTHER partition is rejected', v_err IS NOT NULL, coalesce(v_err, 'accepted!'));

    -- 5. Same GUID, same op_date -> rejected
    v_err := NULL;
    BEGIN
        INSERT INTO ops.operations (op_date, amount, operation_guid, message) VALUES (d_this, 1, g, msg);
    EXCEPTION WHEN unique_violation THEN v_err := SQLERRM;
    END;
    INSERT INTO vr (check_name, passed, details)
    VALUES ('Same guid with the SAME op_date is rejected', v_err IS NOT NULL, coalesce(v_err, 'accepted!'));

    -- 6. Registry trigger disabled -> still rejected, by the composite FK (R-02)
    v_err := NULL;
    ALTER TABLE ops.operations DISABLE TRIGGER operations_register_guid_trg;
    BEGIN
        INSERT INTO ops.operations (op_date, amount, operation_guid, message) VALUES (d_prev, 1, g, msg);
    EXCEPTION WHEN foreign_key_violation THEN v_err := SQLERRM;
    END;
    ALTER TABLE ops.operations ENABLE TRIGGER operations_register_guid_trg;
    INSERT INTO vr (check_name, passed, details)
    VALUES ('Trigger DISABLED: duplicate guid still rejected by composite FK', v_err IS NOT NULL, coalesce(v_err, 'accepted!'));

    -- 7. Changing the GUID of an existing operation is rejected (immutability via FK)
    v_err := NULL;
    BEGIN
        UPDATE ops.operations SET operation_guid = gen_random_uuid() WHERE id = v_id AND op_date = d_this;
    EXCEPTION WHEN foreign_key_violation THEN v_err := SQLERRM;
    END;
    INSERT INTO vr (check_name, passed, details)
    VALUES ('operation_guid of an existing operation cannot be changed', v_err IS NOT NULL, coalesce(v_err, 'changed!'));

    -- 8. A status update is not affected
    UPDATE ops.operations SET status = 1 WHERE id = v_id AND op_date = d_this;
    INSERT INTO vr (check_name, passed, details)
    VALUES ('Status update (FK columns untouched) works', FOUND, 'status 0 -> 1');
END $$;

SELECT n AS "#", CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result, check_name, details FROM vr ORDER BY n;
ROLLBACK;
