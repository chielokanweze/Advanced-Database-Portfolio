-- =====================================================================================
-- Portfolio 1 - GraceCare Specialist Hospital, Port Harcourt (simulated organisation)
-- Relational schema, PostgreSQL 16
--
-- Run:  psql -U gc -d gracecare -f 01_schema.sql
-- Design notes are in README.md and NORMALISATION.md (same folder).
-- =====================================================================================
\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS gc CASCADE;
CREATE SCHEMA gc;

-- btree_gist : lets an EXCLUDE constraint combine "=" on an integer with "&&" (overlap) on a range
-- pg_trgm    : trigram matching, used in Part 2 for fast "contains" name searches
-- pg_stat_statements : query statistics, used in Part 2
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;

ALTER DATABASE gracecare SET search_path = gc, public;
SET search_path = gc, public;

-- -------------------------------------------------------------------------------------
-- Reference / master data
-- -------------------------------------------------------------------------------------
CREATE TABLE departments (
    dept_id    smallint    GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       varchar(60) NOT NULL UNIQUE,
    dept_type  varchar(12) NOT NULL
               CHECK (dept_type IN ('EMERGENCY', 'OUTPATIENT', 'INPATIENT', 'THEATRE'))
);

CREATE TABLE doctors (
    doctor_id        int          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    staff_no         varchar(10)  NOT NULL UNIQUE CHECK (staff_no ~ '^DR[0-9]{4}$'),
    first_name       varchar(40)  NOT NULL,
    last_name        varchar(40)  NOT NULL,
    sex              char(1)      NOT NULL CHECK (sex IN ('M', 'F')),
    specialty        varchar(60)  NOT NULL,
    dept_id          smallint     NOT NULL REFERENCES departments (dept_id) ON DELETE RESTRICT,
    mdcn_licence_no  varchar(20)  NOT NULL UNIQUE,            -- Medical & Dental Council of Nigeria
    email            varchar(120) NOT NULL UNIQUE CHECK (email ~* '^[^@\s]+@[^@\s]+\.[a-z]{2,}$'),
    is_active        boolean      NOT NULL DEFAULT true
);

CREATE TABLE patients (
    patient_id     int          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    hospital_no    char(10)     NOT NULL UNIQUE CHECK (hospital_no ~ '^GC[0-9]{8}$'),
    first_name     varchar(40)  NOT NULL,
    last_name      varchar(40)  NOT NULL,
    sex            char(1)      NOT NULL CHECK (sex IN ('M', 'F')),
    date_of_birth  date         NOT NULL CHECK (date_of_birth >= DATE '1900-01-01'),
    phone          varchar(14)  CHECK (phone ~ '^\+234[789][01][0-9]{8}$'),  -- Nigerian mobile, E.164
    blood_group    varchar(3)   CHECK (blood_group IN ('A+','A-','B+','B-','AB+','AB-','O+','O-')),
    genotype       varchar(2)   CHECK (genotype IN ('AA','AS','AC','SS','SC')), -- sickle-cell status
    registered_at  timestamptz  NOT NULL DEFAULT now()
);

-- ICD-10 diagnosis codes live in their own table: description depends on the code,
-- so storing it in diagnoses would be a transitive dependency (3NF violation).
CREATE TABLE icd10_codes (
    code             varchar(7)   PRIMARY KEY CHECK (code ~ '^[A-Z][0-9]{2}(\.[0-9A-Z]{1,4})?$'),
    description      varchar(120) NOT NULL,
    chapter          varchar(60)  NOT NULL,
    sex_restriction  char(1)      CHECK (sex_restriction IN ('M', 'F'))  -- NULL = applies to both
);

CREATE TABLE drugs (
    drug_id        int           GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name           varchar(80)   NOT NULL UNIQUE,
    form           varchar(10)   NOT NULL
                   CHECK (form IN ('TABLET','CAPSULE','INJECTION','SYRUP','SACHET','INHALER','PEN')),
    unit_price     numeric(10,2) NOT NULL CHECK (unit_price > 0),       -- Naira
    stock_qty      int           NOT NULL CHECK (stock_qty >= 0),       -- current on-hand balance
    reorder_level  int           NOT NULL DEFAULT 0 CHECK (reorder_level >= 0)
);

CREATE TABLE lab_tests (
    test_id        smallint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code           varchar(10)   NOT NULL UNIQUE,
    name           varchar(80)   NOT NULL UNIQUE,
    unit           varchar(20)   NOT NULL,
    ref_low        numeric(12,2) NOT NULL,
    ref_high       numeric(12,2) NOT NULL,
    critical_low   numeric(12,2),            -- NULL = no low critical limit
    critical_high  numeric(12,2),            -- NULL = no high critical limit
    price          numeric(10,2) NOT NULL CHECK (price >= 0),
    CHECK (ref_low <= ref_high),
    CHECK (critical_low  IS NULL OR critical_low  <  ref_low),
    CHECK (critical_high IS NULL OR critical_high >  ref_high)
);

-- -------------------------------------------------------------------------------------
-- Outpatient encounters
-- -------------------------------------------------------------------------------------
CREATE TABLE appointments (
    appointment_id  bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id      int          NOT NULL REFERENCES patients (patient_id) ON DELETE RESTRICT,
    doctor_id       int          NOT NULL REFERENCES doctors  (doctor_id)  ON DELETE RESTRICT,
    start_at        timestamptz  NOT NULL,
    end_at          timestamptz  NOT NULL,
    status          varchar(10)  NOT NULL DEFAULT 'BOOKED'
                    CHECK (status IN ('BOOKED','CHECKED_IN','COMPLETED','CANCELLED','NO_SHOW')),
    reason          varchar(200),
    booked_at       timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT appt_time_valid CHECK (end_at > start_at AND end_at - start_at <= interval '4 hours'),
    -- No double booking: a doctor cannot hold two overlapping, non-cancelled appointments.
    -- Unlike a UNIQUE(doctor_id, start_at) this also catches 09:00-09:30 vs 09:15-09:45.
    CONSTRAINT appt_no_doctor_overlap
        EXCLUDE USING gist (doctor_id WITH =, tstzrange(start_at, end_at) WITH &&)
        WHERE (status <> 'CANCELLED'),
    -- ...and a patient cannot be in two places at once.
    CONSTRAINT appt_no_patient_overlap
        EXCLUDE USING gist (patient_id WITH =, tstzrange(start_at, end_at) WITH &&)
        WHERE (status <> 'CANCELLED')
);

CREATE TABLE diagnoses (
    diagnosis_id    bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id  bigint       NOT NULL REFERENCES appointments (appointment_id) ON DELETE RESTRICT,
    icd10_code      varchar(7)   NOT NULL REFERENCES icd10_codes (code),
    is_primary      boolean      NOT NULL DEFAULT false,
    notes           text,
    recorded_at     timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT diagnosis_once_per_visit UNIQUE (appointment_id, icd10_code)
);
-- exactly one PRIMARY diagnosis per visit (partial unique index)
CREATE UNIQUE INDEX uq_one_primary_diagnosis ON diagnoses (appointment_id) WHERE is_primary;

CREATE TABLE prescriptions (
    prescription_id  bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id   bigint       NOT NULL REFERENCES appointments (appointment_id) ON DELETE RESTRICT,
    drug_id          int          NOT NULL REFERENCES drugs (drug_id),
    dosage           varchar(60)  NOT NULL,
    quantity         int          NOT NULL CHECK (quantity BETWEEN 1 AND 500),
    status           varchar(10)  NOT NULL DEFAULT 'PRESCRIBED'
                     CHECK (status IN ('PRESCRIBED','DISPENSED','CANCELLED')),
    prescribed_at    timestamptz  NOT NULL DEFAULT now(),
    dispensed_at     timestamptz,
    CONSTRAINT prescription_once_per_visit UNIQUE (appointment_id, drug_id),
    CONSTRAINT dispensed_has_timestamp CHECK ((status = 'DISPENSED') = (dispensed_at IS NOT NULL))
);

CREATE TABLE lab_orders (
    order_id        bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id  bigint        NOT NULL REFERENCES appointments (appointment_id) ON DELETE RESTRICT,
    test_id         smallint      NOT NULL REFERENCES lab_tests (test_id),
    ordered_at      timestamptz   NOT NULL DEFAULT now(),
    status          varchar(10)   NOT NULL DEFAULT 'ORDERED'
                    CHECK (status IN ('ORDERED','RESULTED','REVIEWED')),
    result_value    numeric(12,2),
    result_flag     varchar(8)    CHECK (result_flag IN ('NORMAL','LOW','HIGH','CRITICAL')),
    resulted_at     timestamptz,
    reviewed_at     timestamptz,
    reviewed_by     int           REFERENCES doctors (doctor_id),
    CONSTRAINT result_present_when_resulted
        CHECK ((status = 'ORDERED') = (result_value IS NULL)
               AND (result_value IS NULL) = (resulted_at IS NULL)),
    CONSTRAINT review_complete
        CHECK ((status = 'REVIEWED') = (reviewed_at IS NOT NULL AND reviewed_by IS NOT NULL))
);

-- -------------------------------------------------------------------------------------
-- Inpatient care
-- -------------------------------------------------------------------------------------
CREATE TABLE wards (
    ward_id   smallint    GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dept_id   smallint    NOT NULL REFERENCES departments (dept_id),
    name      varchar(60) NOT NULL UNIQUE
);

CREATE TABLE beds (
    bed_id     int         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ward_id    smallint    NOT NULL REFERENCES wards (ward_id),
    bed_label  varchar(10) NOT NULL,
    is_active  boolean     NOT NULL DEFAULT true,
    UNIQUE (ward_id, bed_label)
);

CREATE TABLE admissions (
    admission_id         bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id           int          NOT NULL REFERENCES patients (patient_id) ON DELETE RESTRICT,
    bed_id               int          NOT NULL REFERENCES beds (bed_id),
    admitting_doctor_id  int          NOT NULL REFERENCES doctors (doctor_id),
    admitted_at          timestamptz  NOT NULL,
    discharged_at        timestamptz,                              -- NULL = still on the ward
    admission_reason     varchar(200) NOT NULL,
    CHECK (discharged_at IS NULL OR discharged_at > admitted_at),
    -- tstzrange(x, NULL) is open-ended, so a current admission blocks the bed "until further notice"
    CONSTRAINT bed_not_double_occupied
        EXCLUDE USING gist (bed_id WITH =, tstzrange(admitted_at, discharged_at) WITH &&),
    CONSTRAINT patient_one_bed_at_a_time
        EXCLUDE USING gist (patient_id WITH =, tstzrange(admitted_at, discharged_at) WITH &&)
);

-- -------------------------------------------------------------------------------------
-- Audit trail (NDPA 2023 accountability): every UPDATE / DELETE on clinical tables is logged
-- -------------------------------------------------------------------------------------
CREATE TABLE audit_log (
    audit_id    bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name  text         NOT NULL,
    row_pk      bigint       NOT NULL,
    action      char(1)      NOT NULL CHECK (action IN ('U', 'D')),
    old_values  jsonb,                     -- only the columns that changed
    new_values  jsonb,
    app_user    text,                      -- set by the application: SET gc.app_user = 'nurse.ada'
    db_user     text         NOT NULL DEFAULT current_user,
    changed_at  timestamptz  NOT NULL DEFAULT clock_timestamp()
);

-- =====================================================================================
-- Business-rule triggers (rules a CHECK constraint cannot express)
-- =====================================================================================

-- CHECK constraints must be immutable, so "date of birth is not in the future" (depends on
-- today's date) is enforced by a trigger instead.
CREATE FUNCTION trg_patient_validate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.date_of_birth > current_date THEN
        RAISE EXCEPTION 'date_of_birth % is in the future', NEW.date_of_birth
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER patient_validate BEFORE INSERT OR UPDATE OF date_of_birth ON patients
    FOR EACH ROW EXECUTE FUNCTION trg_patient_validate();

-- A diagnosis is only valid for a visit that actually took place, and the code's sex
-- restriction must match the patient (e.g. Z34.9 "supervision of normal pregnancy" is female-only).
CREATE FUNCTION trg_diagnosis_validate() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_status  text;
    v_sex     char(1);
    v_rule    char(1);
BEGIN
    SELECT a.status, p.sex INTO v_status, v_sex
    FROM appointments a JOIN patients p USING (patient_id)
    WHERE a.appointment_id = NEW.appointment_id;

    IF v_status NOT IN ('CHECKED_IN', 'COMPLETED') THEN
        RAISE EXCEPTION 'cannot record a diagnosis on a % appointment', v_status
              USING ERRCODE = 'check_violation';
    END IF;

    SELECT sex_restriction INTO v_rule FROM icd10_codes WHERE code = NEW.icd10_code;
    IF v_rule IS NOT NULL AND v_rule <> v_sex THEN
        RAISE EXCEPTION 'ICD-10 % is restricted to sex %, patient is %', NEW.icd10_code, v_rule, v_sex
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER diagnosis_validate BEFORE INSERT OR UPDATE ON diagnoses
    FOR EACH ROW EXECUTE FUNCTION trg_diagnosis_validate();

-- result_flag is derived from result_value and the test's reference ranges. It is stored
-- (controlled denormalisation) so that "unreviewed CRITICAL results" can be indexed; the trigger
-- guarantees it can never disagree with the value.
CREATE FUNCTION trg_lab_flag() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE t lab_tests%ROWTYPE;
BEGIN
    IF NEW.result_value IS NULL THEN
        NEW.result_flag := NULL;
        RETURN NEW;
    END IF;
    SELECT * INTO t FROM lab_tests WHERE test_id = NEW.test_id;
    NEW.result_flag := CASE
        WHEN t.critical_low  IS NOT NULL AND NEW.result_value < t.critical_low  THEN 'CRITICAL'
        WHEN t.critical_high IS NOT NULL AND NEW.result_value > t.critical_high THEN 'CRITICAL'
        WHEN NEW.result_value < t.ref_low  THEN 'LOW'
        WHEN NEW.result_value > t.ref_high THEN 'HIGH'
        ELSE 'NORMAL'
    END;
    RETURN NEW;
END $$;
CREATE TRIGGER lab_flag BEFORE INSERT OR UPDATE OF result_value, test_id ON lab_orders
    FOR EACH ROW EXECUTE FUNCTION trg_lab_flag();

-- Generic audit trigger. TG_ARGV[0] = name of the primary-key column.
-- SECURITY DEFINER: staff roles can trigger an audit row without having any privilege on
-- audit_log themselves (so nobody can edit or delete the trail).
CREATE FUNCTION trg_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gc, public AS $$
DECLARE
    v_old jsonb := to_jsonb(OLD);
    v_new jsonb := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(NEW) END;
    v_old_changed jsonb;
    v_new_changed jsonb;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        SELECT jsonb_object_agg(o.key, o.value), jsonb_object_agg(o.key, v_new -> o.key)
          INTO v_old_changed, v_new_changed
        FROM jsonb_each(v_old) o
        WHERE v_new -> o.key IS DISTINCT FROM o.value;
        IF v_old_changed IS NULL THEN RETURN NULL; END IF;     -- no-op update: nothing to log
    ELSE
        v_old_changed := v_old;
    END IF;

    INSERT INTO audit_log (table_name, row_pk, action, old_values, new_values, app_user)
    VALUES (TG_TABLE_NAME, (v_old ->> TG_ARGV[0])::bigint, left(TG_OP, 1),
            v_old_changed, v_new_changed, current_setting('gc.app_user', true));
    RETURN NULL;
END $$;

CREATE TRIGGER audit_appointments  AFTER UPDATE OR DELETE ON appointments
    FOR EACH ROW EXECUTE FUNCTION trg_audit('appointment_id');
CREATE TRIGGER audit_diagnoses     AFTER UPDATE OR DELETE ON diagnoses
    FOR EACH ROW EXECUTE FUNCTION trg_audit('diagnosis_id');
CREATE TRIGGER audit_prescriptions AFTER UPDATE OR DELETE ON prescriptions
    FOR EACH ROW EXECUTE FUNCTION trg_audit('prescription_id');
CREATE TRIGGER audit_lab_orders    AFTER UPDATE OR DELETE ON lab_orders
    FOR EACH ROW EXECUTE FUNCTION trg_audit('order_id');
CREATE TRIGGER audit_admissions    AFTER UPDATE OR DELETE ON admissions
    FOR EACH ROW EXECUTE FUNCTION trg_audit('admission_id');
CREATE TRIGGER audit_drugs         AFTER UPDATE OR DELETE ON drugs
    FOR EACH ROW EXECUTE FUNCTION trg_audit('drug_id');

-- =====================================================================================
-- Convenience views
-- =====================================================================================
-- Age is derived, never stored (it changes every day and would go stale).
CREATE VIEW v_patients AS
SELECT p.*, date_part('year', age(current_date, p.date_of_birth))::int AS age_years
FROM patients p;

-- De-identified view for management reporting (no names, phone numbers or hospital numbers).
CREATE VIEW v_visits_deidentified AS
SELECT a.appointment_id,
       a.start_at::date                                        AS visit_date,
       dep.name                                                AS department,
       p.sex,
       width_bucket(date_part('year', age(a.start_at::date, p.date_of_birth)), 0, 100, 10) AS age_band,
       a.status,
       d.icd10_code                                            AS primary_icd10
FROM appointments a
JOIN patients    p   USING (patient_id)
JOIN doctors     doc USING (doctor_id)
JOIN departments dep ON dep.dept_id = doc.dept_id
LEFT JOIN diagnoses d ON d.appointment_id = a.appointment_id AND d.is_primary;
