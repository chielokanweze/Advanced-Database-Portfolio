
from __future__ import annotations

import threading
import time
from pathlib import Path

import psycopg
from psycopg import errors

from gclib import Report, pg_connect

HERE = Path(__file__).resolve().parent
out = Report(HERE / "results" / "concurrency_demo_output.txt")

DEMO_HOSPITAL_NO = "GC99990001"
DEMO_WARD = "P3 Demo Ward"
_t0 = time.perf_counter()
_print_lock = threading.Lock()


def log(session: str, text: str) -> None:
    with _print_lock:
        out(f"  +{(time.perf_counter() - _t0) * 1000:7.0f} ms  [{session:<7}] {text}")


def restart_clock() -> None:
    global _t0
    _t0 = time.perf_counter()


def session(name: str, isolation: str = "READ COMMITTED") -> psycopg.Connection:
    return pg_connect(isolation=isolation, app_name=f"P3-{name}")


def admin() -> psycopg.Connection:
    return pg_connect(autocommit=True, app_name="P3-admin")


def scalar(conn, sql: str, params=None):
    return conn.execute(sql, params).fetchone()[0]


def report_waits(monitor, label: str = "monitor") -> None:
    """Print every P3 session that is currently waiting for a lock, and who blocks it."""
    rows = monitor.execute("""
        SELECT w.application_name, w.wait_event_type || ':' || w.wait_event,
               (SELECT string_agg(b.application_name, ',') FROM pg_stat_activity b
                 WHERE b.pid = ANY (pg_blocking_pids(w.pid)))
        FROM pg_stat_activity w
        WHERE w.application_name LIKE 'P3-%' AND w.wait_event_type = 'Lock'""").fetchall()
    if not rows:
        log(label, "pg_stat_activity: no session is waiting for a lock")
    for app, wait, blockers in rows:
        log(label, f"pg_stat_activity: {app[3:]} is WAITING ({wait}), blocked by {blockers[3:] if blockers else '?'}")


# =====================================================================================
# set-up / tear-down of demo fixtures
# =====================================================================================
def setup() -> dict:
    a = admin()
    a.execute((HERE / "procedures.sql").read_text(encoding="utf-8").replace("\\set ON_ERROR_STOP on", ""))
    teardown(quiet=True)
    fx = {}
    fx["stock"] = dict(a.execute("SELECT name, stock_qty FROM drugs").fetchall())
    fx["paracetamol"] = scalar(a, "SELECT drug_id FROM drugs WHERE name = 'Paracetamol 500mg'")
    fx["ceftriaxone"] = scalar(a, "SELECT drug_id FROM drugs WHERE name = 'Ceftriaxone 1g'")
    fx["amoxicillin"] = scalar(a, "SELECT drug_id FROM drugs WHERE name = 'Amoxicillin 500mg'")
    fx["doctor_gop"] = scalar(a, "SELECT min(doctor_id) FROM doctors d JOIN departments USING (dept_id) "
                                 "WHERE name = 'General Outpatient'")
    # demo patient + a completed visit on a Saturday (no clinics run, so the slot is free)
    fx["patient"] = scalar(a, """
        INSERT INTO patients (hospital_no, first_name, last_name, sex, date_of_birth, phone)
        VALUES (%s, 'Demo', 'Portfolio-Three', 'F', '1988-04-12', '+2348030000001')
        RETURNING patient_id""", (DEMO_HOSPITAL_NO,))
    fx["visit"] = scalar(a, """
        INSERT INTO appointments (patient_id, doctor_id, start_at, end_at, status, reason)
        VALUES (%s, %s, '2026-11-14 09:00+01', '2026-11-14 09:30+01', 'COMPLETED', 'P3 demo visit')
        RETURNING appointment_id""", (fx["patient"], fx["doctor_gop"]))
    # ICU on-call roster: exactly two doctors on call
    icu = [r[0] for r in a.execute("SELECT doctor_id FROM doctors d JOIN departments USING (dept_id) "
                                   "WHERE name = 'Intensive Care' ORDER BY doctor_id LIMIT 2").fetchall()]
    fx["icu"] = icu
    a.execute("DELETE FROM icu_oncall")
    a.execute("INSERT INTO icu_oncall VALUES (%s, true), (%s, true)", icu)
    # demo ward with 5 empty beds
    ward = scalar(a, "INSERT INTO wards (dept_id, name) SELECT dept_id, %s FROM departments "
                     "WHERE name = 'Intensive Care' RETURNING ward_id", (DEMO_WARD,))
    a.execute("INSERT INTO beds (ward_id, bed_label) SELECT %s, 'DEMO-' || k FROM generate_series(1, 5) k", (ward,))
    a.close()
    return fx


def teardown(fx: dict | None = None, quiet: bool = False) -> None:
    a = admin()
    if fx and "stock" in fx:                         # put every stock level back exactly as it was
        for name, qty in fx["stock"].items():
            a.execute("UPDATE drugs SET stock_qty = %s WHERE name = %s AND stock_qty <> %s", (qty, name, qty))
    a.execute("DELETE FROM admissions WHERE bed_id IN (SELECT bed_id FROM beds JOIN wards USING (ward_id) WHERE wards.name = %s)", (DEMO_WARD,))
    a.execute("DELETE FROM beds WHERE ward_id IN (SELECT ward_id FROM wards WHERE name = %s)", (DEMO_WARD,))
    a.execute("DELETE FROM wards WHERE name = %s", (DEMO_WARD,))
    a.execute("DELETE FROM appointments WHERE reason LIKE 'P3 demo%%' AND NOT EXISTS (SELECT 1 FROM patients p "
              "WHERE p.patient_id = appointments.patient_id AND p.hospital_no = %s)", (DEMO_HOSPITAL_NO,))
    for table in ("lab_orders", "prescriptions", "diagnoses"):
        a.execute(f"DELETE FROM {table} WHERE appointment_id IN (SELECT appointment_id FROM appointments a "
                  f"JOIN patients p USING (patient_id) WHERE p.hospital_no = %s)", (DEMO_HOSPITAL_NO,))
    a.execute("DELETE FROM appointments WHERE patient_id IN (SELECT patient_id FROM patients WHERE hospital_no = %s)", (DEMO_HOSPITAL_NO,))
    a.execute("DELETE FROM patients WHERE hospital_no = %s", (DEMO_HOSPITAL_NO,))
    a.execute("DELETE FROM icu_oncall")
    a.close()
    if not quiet:
        out("\nDemo data removed; drug stock restored to its original values.")


def set_stock(drug_id: int, qty: int) -> None:
    with admin() as a:
        a.execute("UPDATE drugs SET stock_qty = %s WHERE drug_id = %s", (qty, drug_id))


def stock(drug_id: int) -> int:
    with admin() as a:
        return scalar(a, "SELECT stock_qty FROM drugs WHERE drug_id = %s", (drug_id,))


# =====================================================================================
# A. Atomicity
# =====================================================================================
def demo_a(fx: dict) -> None:
    out.heading("A. ATOMICITY - commit, rollback and savepoint")
    out("A visit has two prescriptions: Paracetamol x18 and Ceftriaxone x3. dispense_prescriptions()\n"
        "updates stock and prescription status for BOTH inside one transaction.")
    with admin() as a:
        a.execute("INSERT INTO prescriptions (appointment_id, drug_id, dosage, quantity) VALUES "
                  "(%s, %s, '1g eight-hourly x 3 days', 18), (%s, %s, '1g daily IV x 3 days', 3)",
                  (fx["visit"], fx["paracetamol"], fx["visit"], fx["ceftriaxone"]))
    set_stock(fx["paracetamol"], 1000)
    set_stock(fx["ceftriaxone"], 2)                      # not enough Ceftriaxone in the pharmacy
    restart_clock()

    out("\nA1 - Ceftriaxone stock is only 2, so the second drug fails:")
    conn = session("pharm1")
    try:
        conn.execute("SELECT * FROM dispense_prescriptions(%s)", (fx["visit"],)).fetchall()
        conn.commit()
        log("pharm1", "COMMIT (unexpected)")
    except errors.RaiseException as e:
        conn.rollback()
        log("pharm1", f"ERROR: {e.diag.message_primary} -> ROLLBACK")
    with admin() as a:
        statuses = a.execute("SELECT string_agg(status, ', ') FROM prescriptions WHERE appointment_id = %s",
                             (fx["visit"],)).fetchone()[0]
    log("check", f"Paracetamol stock = {stock(fx['paracetamol'])} (unchanged although it was updated first)")
    log("check", f"prescription statuses = {statuses} -> nothing half-done (atomicity)")

    out("\nA2 - stock refilled to 45, same call:")
    set_stock(fx["ceftriaxone"], 45)
    rows = conn.execute("SELECT * FROM dispense_prescriptions(%s)", (fx["visit"],)).fetchall()
    conn.commit()
    for drug, qty, after in rows:
        log("pharm1", f"dispensed {drug} x{qty} -> stock now {after}")
    log("pharm1", "COMMIT - both changes are now durable")
    with admin() as a:
        n = scalar(a, "SELECT count(*) FROM audit_log WHERE table_name IN ('drugs','prescriptions') "
                      "AND changed_at > now() - interval '1 minute'")
    log("check", f"{n} audit_log rows written by the triggers for these changes")

    out("\nA3 - SAVEPOINT: a doctor orders 3 lab tests; the 2nd uses an unknown test id.")
    out("     Only that step is undone (ROLLBACK TO SAVEPOINT); the other two orders are kept.")
    for code in ("MPD", None, "HB"):
        conn.execute("SAVEPOINT before_order")
        try:
            if code:
                conn.execute("INSERT INTO lab_orders (appointment_id, test_id) "
                             "SELECT %s, test_id FROM lab_tests WHERE code = %s", (fx["visit"], code))
                log("doctor", f"ordered {code}")
            else:
                conn.execute("INSERT INTO lab_orders (appointment_id, test_id) VALUES (%s, 999)", (fx["visit"],))
            conn.execute("RELEASE SAVEPOINT before_order")
        except errors.ForeignKeyViolation:
            conn.execute("ROLLBACK TO SAVEPOINT before_order")
            log("doctor", "test_id 999 does not exist -> ROLLBACK TO SAVEPOINT (transaction continues)")
    conn.commit()
    with admin() as a:
        tests = a.execute("SELECT string_agg(t.code, ', ' ORDER BY l.order_id) FROM lab_orders l "
                          "JOIN lab_tests t USING (test_id) WHERE appointment_id = %s", (fx["visit"],)).fetchone()[0]
    log("check", f"lab orders stored after COMMIT: {tests}")
    conn.close()


# =====================================================================================
# B. Lost update
# =====================================================================================
def _pharmacist(name, qty, mode, barrier, results, drug_id):
    iso = "REPEATABLE READ" if mode == "repeatable_read" else "READ COMMITTED"
    conn = session(name, iso)
    for attempt in range(1, 4):
        try:
            if mode == "atomic":
                barrier.wait()
                log(name, f"UPDATE drugs SET stock_qty = stock_qty - {qty}")
                conn.execute("UPDATE drugs SET stock_qty = stock_qty - %s WHERE drug_id = %s", (qty, drug_id))
            else:
                lock = " FOR UPDATE" if mode == "for_update" else ""
                if mode == "for_update" and name == "pharm2":
                    time.sleep(0.05)                    # let pharm1 take the lock first
                log(name, f"SELECT stock_qty ...{lock}")
                s = scalar(conn, f"SELECT stock_qty FROM drugs WHERE drug_id = %s{lock}", (drug_id,))
                log(name, f"read stock = {s}")
                if mode != "for_update":
                    barrier.wait()                      # both have read before either writes
                time.sleep(0.3)                         # pharmacist counts tablets ...
                log(name, f"UPDATE drugs SET stock_qty = {s} - {qty} = {s - qty}")
                conn.execute("UPDATE drugs SET stock_qty = %s WHERE drug_id = %s", (s - qty, drug_id))
            conn.commit()
            log(name, "COMMIT")
            break
        except errors.SerializationFailure:
            conn.rollback()
            log(name, f"ERROR 40001 could not serialize access due to concurrent update -> ROLLBACK, retry #{attempt}")
            barrier = threading.Barrier(1)
    conn.close()


def demo_b(fx: dict) -> None:
    out.heading("B. LOST UPDATE - two pharmacists dispense Paracetamol at the same moment")
    out("Start stock 1000. Pharmacist 1 dispenses 18, pharmacist 2 dispenses 24. Correct result: 958.")
    drug = fx["paracetamol"]
    cases = [
        ("naive", "B1 read-modify-write in the application, READ COMMITTED (the bug)"),
        ("for_update", "B2 fix 1: pessimistic lock - SELECT ... FOR UPDATE"),
        ("atomic", "B3 fix 2: let the database do the arithmetic - UPDATE ... SET stock_qty = stock_qty - n"),
        ("repeatable_read", "B4 fix 3: optimistic - REPEATABLE READ, the loser gets error 40001 and retries"),
    ]
    summary = []
    for mode, title in cases:
        set_stock(drug, 1000)
        out(f"\n{title}")
        restart_clock()
        barrier = threading.Barrier(2)
        threads = [threading.Thread(target=_pharmacist, args=(n, q, mode, barrier, None, drug))
                   for n, q in (("pharm1", 18), ("pharm2", 24))]
        for t in threads:
            t.start()
        if mode == "for_update":
            time.sleep(0.2)
            with admin() as mon:
                report_waits(mon)
        for t in threads:
            t.join()
        final = stock(drug)
        verdict = "CORRECT" if final == 958 else f"WRONG - {1000 - final} tablets recorded instead of 42 (lost update)"
        log("check", f"final stock = {final} -> {verdict}")
        summary.append((title.split(" ")[0], final, verdict))
    out("\nSummary B:")
    for case, final, verdict in summary:
        out(f"  {case}: final stock {final:5}  {verdict}")


# =====================================================================================
# C. Non-repeatable read
# =====================================================================================
def demo_c(fx: dict) -> None:
    out.heading("C. NON-REPEATABLE READ - stock report while a delivery is booked in")
    drug = fx["amoxicillin"]
    for iso in ("READ COMMITTED", "REPEATABLE READ"):
        set_stock(drug, 5200)
        restart_clock()
        out(f"\nReport transaction runs at {iso}:")
        rep, store = session("report", iso), session("store")
        first = scalar(rep, "SELECT stock_qty FROM drugs WHERE drug_id = %s", (drug,))
        log("report", f"1st read of Amoxicillin stock = {first}")
        store.execute("UPDATE drugs SET stock_qty = stock_qty + 2000 WHERE drug_id = %s", (drug,))
        store.commit()
        log("store", "delivery of 2000 capsules booked in -> COMMIT")
        second = scalar(rep, "SELECT stock_qty FROM drugs WHERE drug_id = %s", (drug,))
        log("report", f"2nd read in the SAME transaction = {second}")
        rep.commit()
        log("check", "value changed inside one transaction (non-repeatable read)" if first != second
            else "same value both times - the transaction works on one snapshot")
        rep.close(); store.close()


# =====================================================================================
# D. Write skew
# =====================================================================================
def _go_off_call(name, doctor_id, iso, barrier, results):
    conn = session(name, iso)
    try:
        on_call = scalar(conn, "SELECT count(*) FROM icu_oncall WHERE on_call")
        log(name, f"checks rule: {on_call} doctors on call -> OK for me to leave")
        barrier.wait()
        conn.execute("UPDATE icu_oncall SET on_call = false WHERE doctor_id = %s", (doctor_id,))
        log(name, "UPDATE own row: on_call = false")
        conn.commit()
        log(name, "COMMIT")
        results[name] = "committed"
    except errors.SerializationFailure as e:
        conn.rollback()
        log(name, f"ERROR 40001 {e.diag.message_primary} -> ROLLBACK")
        results[name] = "rolled back"
    conn.close()


def demo_d(fx: dict) -> None:
    out.heading("D. WRITE SKEW - rule: at least one ICU doctor must stay on call")
    out("Two on-call doctors each check the rule and then sign off. They update DIFFERENT rows,\n"
        "so row locks never conflict - only SERIALIZABLE (SSI) detects the dangerous pattern.")
    for iso in ("REPEATABLE READ", "SERIALIZABLE"):
        with admin() as a:
            a.execute("UPDATE icu_oncall SET on_call = true")
        out(f"\nBoth transactions at {iso}:")
        restart_clock()
        barrier, results = threading.Barrier(2), {}
        threads = [threading.Thread(target=_go_off_call, args=(f"dr{i + 1}", d, iso, barrier, results))
                   for i, d in enumerate(fx["icu"])]
        for t in threads: t.start()
        for t in threads: t.join()
        with admin() as a:
            left = scalar(a, "SELECT count(*) FROM icu_oncall WHERE on_call")
        log("check", f"doctors still on call = {left} -> " +
            ("RULE VIOLATED (write skew)" if left == 0 else "rule holds"))


# =====================================================================================
# E. Double booking
# =====================================================================================
def _book(name, patient_id, doctor_id, start, end, barrier, results):
    conn = session(name)
    try:
        barrier.wait()
        if name == "desk2":
            time.sleep(0.1)
        log(name, f"INSERT appointment {start[11:16]}-{end[11:16]} for doctor {doctor_id}")
        conn.execute("INSERT INTO appointments (patient_id, doctor_id, start_at, end_at, reason) "
                     "VALUES (%s, %s, %s, %s, 'P3 demo booking')", (patient_id, doctor_id, start, end))
        log(name, "insert accepted, holding transaction open (talking to patient) ...")
        time.sleep(0.8)
        conn.commit()
        log(name, "COMMIT")
        results[name] = "booked"
    except errors.ExclusionViolation as e:
        conn.rollback()
        log(name, f"ERROR 23P01 {e.diag.message_primary} -> ROLLBACK")
        results[name] = "rejected"
    conn.close()


def demo_e(fx: dict) -> None:
    out.heading("E. DOUBLE BOOKING - two receptionists book the same doctor at overlapping times")
    with admin() as a:
        patients = [r[0] for r in a.execute(
            "SELECT patient_id FROM patients WHERE hospital_no IN ('GC00000101','GC00000102') ORDER BY 1").fetchall()]
    doctor = fx["doctor_gop"]
    restart_clock()
    barrier, results = threading.Barrier(2), {}
    t1 = threading.Thread(target=_book, args=("desk1", patients[0], doctor, "2026-11-22 10:00+01",
                                              "2026-11-22 10:30+01", barrier, results))
    t2 = threading.Thread(target=_book, args=("desk2", patients[1], doctor, "2026-11-22 10:15+01",
                                              "2026-11-22 10:45+01", barrier, results))
    t1.start(); t2.start()
    time.sleep(0.4)
    with admin() as mon:
        report_waits(mon)
    t1.join(); t2.join()
    with admin() as a:
        n = scalar(a, "SELECT count(*) FROM appointments WHERE doctor_id = %s AND reason = 'P3 demo booking'", (doctor,))
    log("check", f"bookings stored for that doctor/time = {n}. desk2 had to WAIT for desk1's transaction "
                 "to finish before PostgreSQL could decide (no race window).")


# =====================================================================================
# F. Deadlock
# =====================================================================================
def _two_drug_dispense(name, first, second, barrier, results):
    conn = session(name)
    try:
        conn.execute("SET lock_timeout = '5s'")
        conn.execute("UPDATE drugs SET stock_qty = stock_qty - 1 WHERE drug_id = %s", (first,))
        log(name, f"locked drug {first}")
        barrier.wait()
        log(name, f"now needs drug {second} ...")
        conn.execute("UPDATE drugs SET stock_qty = stock_qty - 1 WHERE drug_id = %s", (second,))
        log(name, f"locked drug {second}")
        conn.commit()
        log(name, "COMMIT")
        results[name] = "committed"
    except errors.DeadlockDetected as e:
        conn.rollback()
        log(name, f"ERROR 40P01 deadlock detected -> PostgreSQL chose this transaction as the victim, ROLLBACK")
        results[name] = "aborted"
    conn.close()


def demo_f(fx: dict) -> None:
    out.heading("F. DEADLOCK - two pharmacists each need Paracetamol AND Amoxicillin")
    p, am = fx["paracetamol"], fx["amoxicillin"]
    lo, hi = min(p, am), max(p, am)

    out("\nF1 opposite lock order (the bug): pharm1 locks Paracetamol then Amoxicillin, pharm2 the reverse")
    restart_clock()
    barrier, results = threading.Barrier(2), {}
    threads = [threading.Thread(target=_two_drug_dispense, args=("pharm1", p, am, barrier, results)),
               threading.Thread(target=_two_drug_dispense, args=("pharm2", am, p, barrier, results))]
    for t in threads: t.start()
    for t in threads: t.join()
    log("check", f"outcome: {results}")

    out("\nF2 fix: both lock in ascending drug_id order (exactly what dispense_prescriptions() does)")
    restart_clock()
    barrier, results = threading.Barrier(1), {}     # no rendezvous: pharm2 simply queues behind pharm1
    threads = [threading.Thread(target=_two_drug_dispense, args=("pharm1", lo, hi, barrier, results)),
               threading.Thread(target=_two_drug_dispense, args=("pharm2", lo, hi, barrier, results))]
    threads[0].start(); time.sleep(0.05); threads[1].start()
    for t in threads: t.join()
    log("check", f"outcome: {results} - pharm2 waited briefly, nobody was aborted")


# =====================================================================================
# G. SKIP LOCKED
# =====================================================================================
def _admit(name, patient_id, doctor_id, barrier, results):
    conn = session(name)
    barrier.wait()
    t = time.perf_counter()
    bed = scalar(conn, "SELECT allocate_bed(%s, %s, %s, 'P3 demo admission')", (patient_id, DEMO_WARD, doctor_id))
    waited = (time.perf_counter() - t) * 1000
    label = None
    if bed is None:
        log(name, f"ward full -> no bed (answered in {waited:.0f} ms, did not wait)")
    else:
        with admin() as a:
            label = scalar(a, "SELECT bed_label FROM beds WHERE bed_id = %s", (bed,))
        log(name, f"got bed {label} in {waited:.0f} ms; filling in admission form ...")
    time.sleep(0.5)
    conn.commit()
    results[name] = label
    conn.close()


def demo_g(fx: dict) -> None:
    out.heading("G. BED QUEUE - 8 simultaneous ICU admissions, 5 free beds, FOR UPDATE SKIP LOCKED")
    with admin() as a:
        patients = [r[0] for r in a.execute("""
            SELECT patient_id FROM patients p WHERE hospital_no LIKE 'GC000002%%'
              AND NOT EXISTS (SELECT 1 FROM admissions x WHERE x.patient_id = p.patient_id AND x.discharged_at IS NULL)
            ORDER BY patient_id LIMIT 8""").fetchall()]
    restart_clock()
    barrier, results = threading.Barrier(8), {}
    threads = [threading.Thread(target=_admit, args=(f"clerk{i + 1}", pid, fx["icu"][0], barrier, results))
               for i, pid in enumerate(patients)]
    for t in threads: t.start()
    for t in threads: t.join()
    beds = sorted(v for v in results.values() if v)
    log("check", f"{len(beds)} admissions, beds {beds}, all different = {len(beds) == len(set(beds))}; "
                 f"{8 - len(beds)} clerks told 'ward full' immediately")


def main() -> None:
    out("GraceCare - Portfolio 3 concurrency demonstrations")
    with admin() as a:
        out(scalar(a, "SELECT version()").split(",")[0] + f"; default isolation = "
            + scalar(a, "SHOW default_transaction_isolation"))
    fx = setup()
    try:
        demo_a(fx); demo_b(fx); demo_c(fx); demo_d(fx); demo_e(fx); demo_f(fx); demo_g(fx)
    finally:
        teardown(fx)
        out.save()


if __name__ == "__main__":
    main()
