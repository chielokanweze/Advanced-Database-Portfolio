-- =====================================================================================
-- Portfolio 5 - Distributed (sharded) GraceCare schema on Citus 12 (PostgreSQL 16)
-- Coordinator: citus-coord.  Workers: citus-w1, citus-w2.
--
-- Distribution key = patient_id. Patients and their appointments are CO-LOCATED: shard N of
-- appointments lives on the same worker as shard N of patients, so "a patient's history" and
-- patient-appointment joins run on ONE worker with no network shuffle.
-- Small, rarely-changing tables (departments, doctors) are REFERENCE tables: copied to every worker.
-- =====================================================================================
\set ON_ERROR_STOP on
SET citus.shard_count = 8;                 -- 8 shards -> 4 per worker (default would be 32)

DROP TABLE IF EXISTS appointments, patients, doctors, departments CASCADE;

CREATE TABLE departments (
    dept_id  smallint PRIMARY KEY,
    name     varchar(60) NOT NULL UNIQUE
);
CREATE TABLE doctors (
    doctor_id  int PRIMARY KEY,
    last_name  varchar(40) NOT NULL,
    dept_id    smallint NOT NULL REFERENCES departments (dept_id)
);
CREATE TABLE patients (
    patient_id     int PRIMARY KEY,
    hospital_no    char(10) NOT NULL,
    sex            char(1) NOT NULL CHECK (sex IN ('M','F')),
    date_of_birth  date NOT NULL
);
CREATE TABLE appointments (
    appointment_id bigint NOT NULL,
    patient_id     int NOT NULL,
    doctor_id      int NOT NULL,
    start_at       timestamptz NOT NULL,
    status         varchar(10) NOT NULL,
    -- in a distributed table, PRIMARY KEY / UNIQUE must include the distribution column
    PRIMARY KEY (patient_id, appointment_id)
);

SELECT create_reference_table('departments');
SELECT create_reference_table('doctors');
SELECT create_distributed_table('patients', 'patient_id');
SELECT create_distributed_table('appointments', 'patient_id', colocate_with => 'patients');

-- foreign keys work between co-located tables and from distributed to reference tables
ALTER TABLE appointments ADD CONSTRAINT appt_patient_fk FOREIGN KEY (patient_id) REFERENCES patients (patient_id);
ALTER TABLE appointments ADD CONSTRAINT appt_doctor_fk  FOREIGN KEY (doctor_id)  REFERENCES doctors (doctor_id);
CREATE INDEX ON appointments (doctor_id, start_at);
