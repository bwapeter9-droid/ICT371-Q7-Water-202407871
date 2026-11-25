-- =====================================================================
-- ICT371 Advanced Database | Student No: 202407871
-- QUESTION 7: Water Meter Readings and Billing  (50 marks)
-- Run with:  psql -d yourdb -f ICT371_202407871_Q7_Water.sql
-- Objects live in schema q7_water; the script can be re-run safely.
-- =====================================================================
DROP SCHEMA IF EXISTS q7_water CASCADE;
CREATE SCHEMA q7_water;
SET search_path TO q7_water, public;

-- ---------------------------------------------------------------------
-- (a) DATABASE AND SEED DATA [6]
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id  SERIAL       PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id        SERIAL        PRIMARY KEY,
    customer_id       INTEGER       NOT NULL REFERENCES customers(customer_id),
    reading_month     DATE          NOT NULL,
    previous_reading  NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading   NUMERIC(12,2) NOT NULL CHECK (current_reading  >= 0),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month),
    CONSTRAINT chk_reading_month_start CHECK (EXTRACT(DAY FROM reading_month) = 1)
);

CREATE TABLE bills (
    bill_id      SERIAL        PRIMARY KEY,
    reading_id   INTEGER       NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge       NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid  NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on       DATE          NOT NULL,
    CONSTRAINT chk_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date  DATE          PRIMARY KEY,
    total_due      NUMERIC(14,2) NOT NULL
);

INSERT INTO customers (full_name) VALUES ('Agness Kapambwe'), ('Brian Mutale'), ('Catherine Sinkala');

-- ---------------------------------------------------------------------
-- (b) FUNCTION fn_water_charge [6]
-- First 10 units K5 each; units above 10 cost K8 each. 0 units = K0.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
BEGIN
    IF p_units IS NULL THEN
        RAISE EXCEPTION 'Consumption must not be NULL';
    END IF;
    IF p_units < 0 THEN
        RAISE EXCEPTION 'Consumption must not be negative: %', p_units;
    END IF;

    RETURN ROUND( LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8, 2 );
END;
$$;

-- ---------------------------------------------------------------------
-- (c) PROCEDURE pr_generate_bill [8]
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_prev  NUMERIC(12,2);
    v_curr  NUMERIC(12,2);
    v_charge NUMERIC(12,2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date must not be NULL';
    END IF;

    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM   readings
    WHERE  reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_charge := fn_water_charge(v_curr - v_prev);        -- consumption = current - previous

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

-- ---------------------------------------------------------------------
-- (d) TRIGGER BEFORE INSERT OR UPDATE on readings [8]
-- Raising an exception cancels the statement, so a bad reading is never stored.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_check_reading()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_reading();

-- Six readings (zero, exactly 10, and above 10 units), loaded after the trigger
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE, 100.00, 100.00),  -- 1: 0 units
    (2, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE,  50.00,  60.00),  -- 2: 10 units
    (3, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE,  20.00,  35.00),  -- 3: 15 units
    (1, date_trunc('month', CURRENT_DATE)::DATE,                        100.00, 108.00),  -- 4: 8 units
    (2, date_trunc('month', CURRENT_DATE)::DATE,                         60.00,  75.00),  -- 5: 15 units
    (3, date_trunc('month', CURRENT_DATE)::DATE,                         35.00,  45.00);  -- 6: 10 units

-- Bills for readings 1-4 through the procedure (5 and 6 stay unbilled for testing)
CALL pr_generate_bill(1, CURRENT_DATE - 20);     -- charge  0.00  (zero consumption)
CALL pr_generate_bill(2, CURRENT_DATE - 10);     -- charge 50.00
CALL pr_generate_bill(3, CURRENT_DATE - 5);      -- charge 90.00  (10*5 + 5*8)
CALL pr_generate_bill(4, CURRENT_DATE + 15);     -- charge 40.00, not yet due

-- Record payments: bill 2 partly paid, bill 3 fully paid
UPDATE bills SET amount_paid = 20.00 WHERE bill_id = 2;
UPDATE bills SET amount_paid = 90.00 WHERE bill_id = 3;

-- ---------------------------------------------------------------------
-- (e) VIEW v_overdue_bills [5]
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM   bills b
JOIN   readings r  ON r.reading_id  = b.reading_id
JOIN   customers c ON c.customer_id = r.customer_id
WHERE  b.due_on < CURRENT_DATE
  AND  b.amount_paid < b.charge;

-- ---------------------------------------------------------------------
-- (f) INDEX [5]
-- Partial index on due_on that contains only UNPAID bills. Overdue
-- searches ("unpaid and due before today") read just that small index;
-- paid bills, which are the majority over time, are never in it.
-- ---------------------------------------------------------------------
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;

-- ---------------------------------------------------------------------
-- (g) SCHEDULED JOB [6]
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM   bills
    WHERE  amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
        SET total_due = EXCLUDED.total_due;            -- replaces, not adds
END;
$$;


-- Safe scheduling: runs only if pg_cron is available on this server.
-- If it is not installed you will just see a NOTICE and the rest of the script still works.
DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule('q7_refresh_receivables', '30 0 * * *', $cmd$CALL q7_water.pr_refresh_receivables()$cmd$);
        RAISE NOTICE 'Job q7_refresh_receivables scheduled: 30 0 * * *';
    ELSE
        RAISE NOTICE 'pg_cron is not installed on this server - job NOT scheduled. Schedule used: 30 0 * * *';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not schedule job (q7_refresh_receivables): %', SQLERRM;
END
$do$;

-- Inspect job / history (uncomment where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q7_refresh_receivables';
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;

-- =====================================================================
-- TESTS / EVIDENCE
-- =====================================================================
SELECT '--- (a) Data ---' AS section;
SELECT r.reading_id, r.customer_id, r.reading_month, r.previous_reading, r.current_reading,
       r.current_reading - r.previous_reading AS units
FROM readings r ORDER BY r.reading_id;
SELECT * FROM bills ORDER BY bill_id;

SELECT '--- (b) Function ---' AS section;
SELECT fn_water_charge(0) AS c0, fn_water_charge(10) AS c10, fn_water_charge(15) AS c15,
       fn_water_charge(12.5) AS c12_5;                    -- 0.00, 50.00, 90.00, 70.00
DO $$ BEGIN PERFORM fn_water_charge(NULL);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (NULL): %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(-1);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (negative): %', SQLERRM; END $$;

SELECT '--- (c) Procedure ---' AS section;
CALL pr_generate_bill(5, CURRENT_DATE + 20);              -- valid: 15 units -> 90.00
DO $$ BEGIN CALL pr_generate_bill(5, CURRENT_DATE + 20);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (already billed): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(999, CURRENT_DATE);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (unknown reading): %', SQLERRM; END $$;
SELECT * FROM bills ORDER BY bill_id;

SELECT '--- (d) Trigger: bad reading rejected and not stored ---' AS section;
DO $$ BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
            VALUES (1, (date_trunc('month', CURRENT_DATE) + INTERVAL '1 month')::DATE, 200, 150);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (insert): %', SQLERRM; END $$;
DO $$ BEGIN UPDATE readings SET current_reading = 1 WHERE reading_id = 6;   -- 35 > 1
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (update): %', SQLERRM; END $$;
SELECT COUNT(*) AS readings_still_6 FROM readings;

SELECT '--- (e) View: only bill 2 (30.00 outstanding) is overdue and unpaid ---' AS section;
SELECT * FROM v_overdue_bills;

SELECT '--- (f) EXPLAIN ---' AS section;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM bills WHERE due_on < CURRENT_DATE AND amount_paid < charge;
RESET enable_seqscan;

SELECT '--- (g) Run twice: same date replaced ---' AS section;
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot;                         -- 30 + 40 + 90 = 160.00
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot;                         -- identical, one row
