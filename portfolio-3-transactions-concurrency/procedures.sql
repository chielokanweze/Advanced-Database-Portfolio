-- =====================================================================================
-- Portfolio 3 - Transactional procedures and demo objects
-- Run once before concurrency_demos.py (the script also runs it automatically):
--     psql -U gc -d gracecare -f procedures.sql
-- =====================================================================================
\set ON_ERROR_STOP on
SET search_path = gc, public;

-- -------------------------------------------------------------------------------------
-- 1. dispense_prescriptions: pharmacy dispenses every open prescription of one visit.
--    All-or-nothing: if ANY drug is short, nothing is dispensed and no stock changes.
--    Deadlock prevention: drug rows are always locked in ascending drug_id order, so two
--    pharmacists can never hold locks in opposite orders.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dispense_prescriptions(p_appointment_id bigint)
RETURNS TABLE (o_drug text, o_quantity int, o_stock_after int)
LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    -- lock all drugs needed by this visit, in a fixed global order
    PERFORM 1
    FROM drugs
    WHERE drug_id IN (SELECT drug_id FROM prescriptions
                      WHERE appointment_id = p_appointment_id AND status = 'PRESCRIBED')
    ORDER BY drug_id
    FOR UPDATE;

    FOR r IN
        SELECT p.prescription_id, p.drug_id, p.quantity, d.name, d.stock_qty
        FROM prescriptions p JOIN drugs d USING (drug_id)
        WHERE p.appointment_id = p_appointment_id AND p.status = 'PRESCRIBED'
        ORDER BY p.drug_id
        FOR UPDATE OF p
    LOOP
        IF r.stock_qty < r.quantity THEN
            RAISE EXCEPTION 'insufficient stock for %: need %, have %', r.name, r.quantity, r.stock_qty
                  USING ERRCODE = 'P0001', HINT = 'nothing was dispensed - the whole transaction is rolled back';
        END IF;

        UPDATE drugs SET stock_qty = stock_qty - r.quantity
        WHERE drug_id = r.drug_id
        RETURNING stock_qty INTO o_stock_after;

        UPDATE prescriptions SET status = 'DISPENSED', dispensed_at = now()
        WHERE prescription_id = r.prescription_id;

        o_drug := r.name;
        o_quantity := r.quantity;
        RETURN NEXT;
    END LOOP;
END $$;

-- -------------------------------------------------------------------------------------
-- 2. allocate_bed: give the patient the first free bed on a ward.
--    FOR UPDATE SKIP LOCKED: if another admission clerk is in the middle of taking bed 1,
--    this call does not wait - it takes the next free bed instead (queue pattern).
--    Returns the bed_id, or NULL when the ward is full.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION allocate_bed(p_patient_id int, p_ward text, p_doctor_id int, p_reason text)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
    v_bed int;
BEGIN
    SELECT b.bed_id INTO v_bed
    FROM beds b JOIN wards w USING (ward_id)
    WHERE w.name = p_ward
      AND b.is_active
      AND NOT EXISTS (SELECT 1 FROM admissions a WHERE a.bed_id = b.bed_id AND a.discharged_at IS NULL)
    ORDER BY b.bed_id
    LIMIT 1
    FOR UPDATE OF b SKIP LOCKED;

    IF v_bed IS NULL THEN
        RETURN NULL;
    END IF;

    INSERT INTO admissions (patient_id, bed_id, admitting_doctor_id, admitted_at, admission_reason)
    VALUES (p_patient_id, v_bed, p_doctor_id, now(), p_reason);
    RETURN v_bed;
END $$;

-- -------------------------------------------------------------------------------------
-- 3. ICU on-call roster, used for the write-skew demo.
--    Hospital rule: at least one ICU doctor must be on call at all times.
--    This rule spans several rows, so no single-row CHECK constraint can enforce it.
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS icu_oncall (
    doctor_id  int     PRIMARY KEY REFERENCES doctors (doctor_id),
    on_call    boolean NOT NULL
);

GRANT EXECUTE ON FUNCTION dispense_prescriptions(bigint) TO gc_pharmacist;
GRANT EXECUTE ON FUNCTION allocate_bed(int, text, int, text) TO gc_clinician;
