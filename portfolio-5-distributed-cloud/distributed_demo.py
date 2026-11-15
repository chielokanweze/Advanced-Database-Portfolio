"""Portfolio 5 - Distributed GraceCare: replication, sharding, failover and CAP trade-offs.

This script runs on the HOST (it needs to stop/start containers), using only the Python
standard library and the `docker` command. It talks to the databases with `docker exec`.

  Part A  Sharding with Citus: placement, router vs multi-shard queries, co-located joins,
          the unique-constraint rule, a cross-shard (2PC) transaction
  Part B  MongoDB replica set: majority writes, secondary reads, automatic failover,
          and what happens when a majority is lost (consistency over availability)
  Part C  PostgreSQL streaming replication: lag, read-only replica, stale reads,
          synchronous vs asynchronous commit, behaviour when the sync standby is down,
          and manual failover (promotion) - then the lab is rebuilt to its original state

Run from the repository root (Docker Desktop running, Parts 1 data loaded):
    python portfolio-5-distributed-cloud/distributed_demo.py            # everything
    python portfolio-5-distributed-cloud/distributed_demo.py sharding   # one part only
"""
from __future__ import annotations

import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
RESULTS = HERE / "results"
RESULTS.mkdir(exist_ok=True)


class Log:
    def __init__(self, name: str):
        self.path = RESULTS / name
        self.lines: list[str] = []

    def __call__(self, text: str = "") -> None:
        print(text, flush=True)
        self.lines.append(text)

    def heading(self, text: str) -> None:
        self("")
        self("=" * 88)
        self(text)
        self("=" * 88)

    def block(self, text: str, indent: str = "    ") -> None:
        for line in text.rstrip().splitlines():
            self(indent + line)

    def save(self) -> None:
        self.path.write_text("\n".join(self.lines) + "\n", encoding="utf-8")
        print(f"[saved] {self.path}")


# ------------------------------------------------------------------------------------- helpers
def sh(args: list[str], check: bool = True, timeout: int = 300, stdin=None) -> subprocess.CompletedProcess:
    res = subprocess.run(args, capture_output=True, text=True, timeout=timeout, cwd=ROOT, stdin=stdin)
    if check and res.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(args)}\n{res.stdout}\n{res.stderr}")
    return res


def compose(*args: str, timeout: int = 600) -> None:
    sh(["docker", "compose", *args], timeout=timeout)


def psql(container: str, sql: str, check: bool = True, flags: str = "-AtX", timeout: int = 120) -> str:
    res = sh(["docker", "exec", "-i", container, "psql", "-U", "gc", "-d", "gracecare", flags, "-v", "ON_ERROR_STOP=1",
              "-c", sql], check=check, timeout=timeout)
    return (res.stdout + (res.stderr if not check else "")).strip("\n").rstrip()


def alter_system(container: str, statement: str) -> None:
    """ALTER SYSTEM cannot run inside a transaction block, so it gets its own -c (own transaction)."""
    sh(["docker", "exec", container, "psql", "-U", "gc", "-d", "gracecare", "-X", "-q",
        "-c", statement, "-c", "SELECT pg_reload_conf()"])


def psql_table(container: str, sql: str) -> str:
    return psql(container, sql, flags="-X")


def mongosh(container: str, js: str, check: bool = True, timeout: int = 60) -> str:
    res = sh(["docker", "exec", container, "mongosh", "--quiet", "--eval", js], check=check, timeout=timeout)
    return (res.stdout + res.stderr).strip()


def wait_until(fn, timeout: float = 60, interval: float = 0.25):
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < timeout:
        try:
            v = fn()
            if v:
                return v, time.perf_counter() - t0
        except Exception:
            pass
        time.sleep(interval)
    raise TimeoutError("condition not reached")


# ===================================================================================== A. Citus
def part_sharding() -> None:
    log = Log("sharding_citus_output.txt")
    log.heading("A. SHARDING WITH CITUS - coordinator + 2 workers, distribution key patient_id")
    compose("--profile", "sharding", "up", "-d", "--wait", "citus-coord", "citus-w1", "citus-w2")
    c = "gc-citus-coord"
    psql(c, "CREATE EXTENSION IF NOT EXISTS citus")
    if psql(c, "SELECT count(*) FROM pg_dist_node WHERE noderole = 'primary' AND nodename LIKE 'citus-w%'") != "2":
        psql(c, "SELECT citus_set_coordinator_host('citus-coord', 5432)")
        psql(c, "SELECT citus_add_node('citus-w1', 5432)")
        psql(c, "SELECT citus_add_node('citus-w2', 5432)")
    log("cluster nodes:")
    log.block(psql_table(c, "SELECT nodeid, nodename, nodeport, noderole FROM pg_dist_node ORDER BY nodeid"))

    sh(["docker", "exec", c, "psql", "-U", "gc", "-d", "gracecare", "-q", "-X", "-f",
        "/portfolio/portfolio-5-distributed-cloud/citus_schema.sql"])
    log("schema created: departments, doctors = REFERENCE tables; patients, appointments = DISTRIBUTED "
        "by patient_id (8 shards, co-located)")

    # ---- load the same synthetic data from the main PostgreSQL server (COPY pipe, no files)
    t0 = time.perf_counter()
    for src_sql, table in (
        ("SELECT dept_id, name FROM gc.departments", "departments"),
        ("SELECT doctor_id, last_name, dept_id FROM gc.doctors", "doctors"),
        ("SELECT patient_id, hospital_no, sex, date_of_birth FROM gc.patients", "patients"),
        ("SELECT appointment_id, patient_id, doctor_id, start_at, status FROM gc.appointments", "appointments"),
    ):
        out = subprocess.Popen(["docker", "exec", "gc-pg-primary", "psql", "-U", "gc", "-d", "gracecare", "-X",
                                "-c", f"\\copy ({src_sql}) TO STDOUT"], stdout=subprocess.PIPE)
        sh(["docker", "exec", "-i", c, "psql", "-U", "gc", "-d", "gracecare", "-X", "-q",
            "-c", f"\\copy {table} FROM STDIN"], stdin=out.stdout)
        out.wait()
    psql(c, "ANALYZE")
    log(f"loaded data from gc-pg-primary in {time.perf_counter() - t0:.1f} s")

    log.heading("A1  Where did the data go? (shard placement)")
    log.block(psql_table(c, """
        SELECT nodename AS worker, table_name, count(*) AS shards, pg_size_pretty(sum(shard_size)) AS size
        FROM citus_shards
        WHERE table_name::text IN ('patients', 'appointments', 'doctors', 'departments')
        GROUP BY nodename, table_name ORDER BY table_name, nodename"""))
    log.block(psql_table(c, """
        SELECT 'patients' AS table_name, count(*) FROM patients UNION ALL
        SELECT 'appointments', count(*) FROM appointments"""))
    log.block(psql_table(c, """
        SELECT get_shard_id_for_distribution_column('patients', 12345) AS shard_of_patient_12345,
               (SELECT nodename FROM citus_shards WHERE shardid =
                  get_shard_id_for_distribution_column('patients', 12345)) AS stored_on"""))

    log.heading("A2  Router query: filter on the distribution key -> exactly ONE shard on ONE worker")
    log("SELECT a.start_at, a.status FROM appointments a WHERE a.patient_id = 12345")
    log.block(psql_table(c, "EXPLAIN (COSTS OFF) SELECT a.start_at, a.status FROM appointments a WHERE a.patient_id = 12345"))

    log.heading("A3  Multi-shard query: no distribution key -> fan out to ALL shards, merge on coordinator")
    log("SELECT count(*) FROM appointments WHERE doctor_id = 12 AND start_at >= '2026-11-01'")
    log.block(psql_table(c, "EXPLAIN (COSTS OFF) SELECT count(*) FROM appointments "
                            "WHERE doctor_id = 12 AND start_at >= '2026-11-01'"))

    log.heading("A4  Co-located join + reference-table join: pushed down to the workers, no data shuffle")
    q = ("SELECT dep.name, count(*) FROM patients p JOIN appointments a ON a.patient_id = p.patient_id "
         "JOIN doctors d ON d.doctor_id = a.doctor_id JOIN departments dep ON dep.dept_id = d.dept_id "
         "WHERE p.sex = 'F' AND a.status = 'COMPLETED' GROUP BY dep.name ORDER BY 2 DESC")
    log(q)
    log.block(psql_table(c, q))
    plan = psql_table(c, "EXPLAIN (COSTS OFF) " + q)
    log.block("\n".join(plan.splitlines()[:14]) + "\n...")

    log.heading("A5  Constraint rule in a sharded table")
    log("Try: ALTER TABLE patients ADD UNIQUE (hospital_no)   -- hospital_no is not the distribution key")
    log.block(psql(c, "ALTER TABLE patients ADD CONSTRAINT uq_hosp UNIQUE (hospital_no)", check=False))
    log("Each worker can only check uniqueness inside its own shards, so global uniqueness of a non-key column\n"
        "is not enforced. Options: make hospital_no derive from patient_id, check it in a lookup table, or\n"
        "keep patient registration on a single (non-distributed) table.")

    log.heading("A6  Cross-shard transaction (two-phase commit across workers)")
    rows = psql(c, "SELECT p, (SELECT nodename FROM citus_shards WHERE shardid = "
                   "get_shard_id_for_distribution_column('patients', p)) FROM unnest(ARRAY[1,2,3,4,5,6]) p")
    placement = dict(line.split("|") for line in rows.splitlines())
    a = next(p for p, n in placement.items() if n == "citus-w1")
    b = next(p for p, n in placement.items() if n == "citus-w2")
    log(f"patient {a} lives on citus-w1, patient {b} on citus-w2. One transaction updates both:")
    res = psql(c, f"BEGIN; UPDATE appointments SET status = status WHERE patient_id = {a}; "
                  f"UPDATE appointments SET status = status WHERE patient_id = {b}; COMMIT;", flags="-X")
    log.block(res)
    log("Because the transaction wrote to two workers, Citus committed it with two-phase commit\n"
        "(PREPARE TRANSACTION on each worker, then COMMIT PREPARED), so the change is atomic across\n"
        "machines; pg_dist_transaction records it so an interrupted commit can be recovered.")
    log.save()
    compose("--profile", "sharding", "stop", "citus-coord", "citus-w1", "citus-w2")


# ===================================================================================== B. MongoDB
def mongo_primary() -> str | None:
    for node in ("gc-mongo1", "gc-mongo2", "gc-mongo3"):
        r = sh(["docker", "exec", node, "mongosh", "--quiet", "--eval", "db.hello().isWritablePrimary"],
               check=False, timeout=20)
        if r.returncode == 0 and r.stdout.strip() == "true":
            return node
    return None


def rs_states(via: str) -> str:
    return mongosh(via, "rs.status().members.map(m => m.name + ' ' + m.stateStr + (m.health ? '' : ' (down)')).join('\\n')",
                   check=False)


def part_mongo() -> None:
    log = Log("mongo_replica_set_output.txt")
    log.heading("B. MONGODB REPLICA SET rs0 - 3 members (1 primary, 2 secondaries)")
    compose("up", "-d", "--wait", "mongo1", "mongo2", "mongo3")
    primary, _ = wait_until(mongo_primary, 60)
    log(f"current primary: {primary}")
    log.block(rs_states(primary))

    log.heading("B1  Majority write, then read from a secondary")
    log.block(mongosh(primary, """
        const r = db.getSiblingDB('gracecare').ops_probe.insertOne(
            {note: 'majority write', at: new Date()}, {writeConcern: {w: 'majority', wtimeout: 5000}});
        print('insert acknowledged by a majority of members: ' + r.acknowledged)"""))
    secondary = next(n for n in ("gc-mongo1", "gc-mongo2", "gc-mongo3") if n != primary)
    log.block(mongosh(secondary, """
        db.getMongo().setReadPref('secondary');
        print('read on secondary """ + secondary + """, ops_probe documents: ' +
              db.getSiblingDB('gracecare').ops_probe.countDocuments({}));
        print('patients on this secondary: ' + db.getSiblingDB('gracecare').patients.estimatedDocumentCount())"""))

    log.heading("B2  Automatic failover: the primary container is stopped")
    t0 = time.perf_counter()
    sh(["docker", "stop", "-t", "0", primary])
    log(f"docker stop {primary}  (simulated crash)")
    new_primary, _ = wait_until(lambda: mongo_primary(), 60, 0.5)
    elapsed = time.perf_counter() - t0
    log(f"new primary elected: {new_primary} after {elapsed:.1f} s (no human action)")
    log.block(rs_states(new_primary))
    log.block(mongosh(new_primary, """
        const r = db.getSiblingDB('gracecare').ops_probe.insertOne({note: 'write after failover', at: new Date()},
                                                                  {writeConcern: {w: 'majority', wtimeout: 5000}});
        print('majority write accepted by the new primary: ' + r.acknowledged)"""))
    sh(["docker", "start", primary])
    log(f"docker start {primary} - it rejoins, catches up from the oplog, and (priority 2) takes over again:")
    back, _ = wait_until(lambda: mongo_primary() == primary and primary, 90, 1)
    log.block(rs_states(primary))

    log.heading("B3  Losing the majority: 2 of 3 members down (network partition / outage)")
    others = [n for n in ("gc-mongo1", "gc-mongo2", "gc-mongo3") if n != primary]
    sh(["docker", "stop", "-t", "0", *others])
    log(f"docker stop {' '.join(others)}")
    _, waited = wait_until(lambda: "true" not in mongosh(primary, "db.hello().isWritablePrimary", check=False), 60, 0.5)
    log(f"after {waited:.1f} s {primary} can no longer see a majority and STEPS DOWN to secondary:")
    log.block(mongosh(primary, "print(db.hello().isWritablePrimary ? 'PRIMARY' : 'SECONDARY (read-only)')"))
    log.block(mongosh(primary, """
        try { db.getSiblingDB('gracecare').ops_probe.insertOne({note: 'during outage'});
              print('write accepted'); }
        catch (e) { print('write rejected: ' + e.codeName + ' - ' + e.message.split('\\n')[0]); }""", check=False))
    log.block(mongosh(primary, """
        db.getMongo().setReadPref('secondaryPreferred');
        print('reads still work (possibly stale): patients = ' +
              db.getSiblingDB('gracecare').patients.estimatedDocumentCount())"""))
    log("CAP: during the partition MongoDB keeps CONSISTENCY - the minority side refuses writes so two sides\n"
        "can never accept conflicting changes - and gives up write AVAILABILITY until a majority returns.")
    sh(["docker", "start", *others])
    wait_until(mongo_primary, 120, 1)
    log("members restarted; replica set healthy again:")
    log.block(rs_states(wait_until(mongo_primary, 120, 1)[0]))
    mongosh(wait_until(mongo_primary, 60)[0], "db.getSiblingDB('gracecare').ops_probe.drop()")
    log.save()


# ===================================================================================== C. PostgreSQL
P, R = "gc-pg-primary", "gc-pg-replica"


def part_replication() -> None:
    log = Log("postgres_replication_output.txt")
    log.heading("C. POSTGRESQL STREAMING REPLICATION - primary (15432) -> hot standby replica (15433)")
    compose("up", "-d", "--wait", "pg-primary", "pg-replica")
    wait_until(lambda: psql(P, "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming'") == "1", 120)
    alter_system(P, "ALTER SYSTEM RESET synchronous_standby_names")
    psql(P, "CREATE TABLE IF NOT EXISTS gc.repl_probe (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, "
            "note text, written_at timestamptz DEFAULT clock_timestamp())")
    psql(P, "TRUNCATE gc.repl_probe")

    log.heading("C1  Replication status")
    log.block(psql_table(P, "SELECT application_name, client_addr, state, sync_state, "
                            "pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_gap "
                            "FROM pg_stat_replication"))
    log.block(psql_table(R, "SELECT pg_is_in_recovery() AS replica_in_recovery, "
                            "(SELECT count(*) FROM gc.patients) AS patients_on_replica"))

    log.heading("C2  Replication delay of a single write (asynchronous, same host)")
    delays = []
    for i in range(10):
        note = f"probe {i}"
        psql(P, f"INSERT INTO gc.repl_probe (note) VALUES ('{note}')")
        _, d = wait_until(lambda: psql(R, f"SELECT count(*) FROM gc.repl_probe WHERE note = '{note}'") == "1", 30, 0.005)
        delays.append(d * 1000)
    log(f"10 single-row writes: visible on the replica after median {statistics.median(delays):.0f} ms "
        f"(max {max(delays):.0f} ms) - includes the docker exec round trip used to poll")

    log.heading("C3  Write burst - how far does the replica fall behind?")
    t0 = time.perf_counter()
    psql(P, "INSERT INTO gc.repl_probe (note) SELECT 'bulk ' || g FROM generate_series(1, 300000) g")
    commit_s = time.perf_counter() - t0
    lag = psql(P, "SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) FROM pg_stat_replication")
    _, catch = wait_until(lambda: psql(R, "SELECT count(*) FROM gc.repl_probe") ==
                          psql(P, "SELECT count(*) FROM gc.repl_probe"), 120, 0.1)
    log(f"300,000-row insert committed on the primary in {commit_s:.1f} s; WAL not yet replayed at commit: {lag}; "
        f"replica caught up {catch:.2f} s later")

    log.heading("C4  The replica is read-only")
    log.block(psql(R, "INSERT INTO gc.repl_probe (note) VALUES ('write on replica')", check=False))

    log.heading("C5  Stale read (eventual consistency) - replica deliberately applies WAL 3 s late")
    alter_system(R, "ALTER SYSTEM SET recovery_min_apply_delay = '3s'")
    time.sleep(1)
    psql(P, "INSERT INTO gc.repl_probe (note) VALUES ('stale-read test')")
    t0 = time.perf_counter()
    log(f"primary: row inserted and committed")
    immediately = psql(R, "SELECT count(*) FROM gc.repl_probe WHERE note = 'stale-read test'")
    log(f"replica, immediately: rows with note 'stale-read test' = {immediately}   <- stale")
    _, d = wait_until(lambda: psql(R, "SELECT count(*) FROM gc.repl_probe WHERE note = 'stale-read test'") == "1", 30, 0.2)
    log(f"replica, after {time.perf_counter() - t0:.1f} s: rows = 1   <- consistent again")
    alter_system(R, "ALTER SYSTEM RESET recovery_min_apply_delay")
    log("Lesson: a clinician who saves a prescription and is then routed to a lagging replica may not see it.\n"
        "GraceCare therefore sends read-your-own-writes traffic (clinical screens) to the primary and only\n"
        "reports/dashboards to replicas.")

    log.heading("C6  Synchronous vs asynchronous commit - latency cost of zero data loss")

    def commit_latency(n=200) -> float:
        res = sh(["docker", "exec", "-i", P, "bash", "-c",
                  f"for i in $(seq {n}); do echo \"INSERT INTO gc.repl_probe (note) VALUES ('lat');\"; done | "
                  f"(time -p psql -U gc -d gracecare -q -X) 2>&1 | grep real"], timeout=120)
        return float(res.stdout.split()[1]) * 1000 / n

    async_ms = commit_latency()
    alter_system(P, "ALTER SYSTEM SET synchronous_standby_names = 'replica1'")
    wait_until(lambda: psql(P, "SELECT sync_state FROM pg_stat_replication") == "sync", 30)
    log.block(psql_table(P, "SELECT application_name, sync_state FROM pg_stat_replication"))
    sync_ms = commit_latency()
    log(f"200 single-row autocommit INSERTs: asynchronous {async_ms:.2f} ms/commit, "
        f"synchronous {sync_ms:.2f} ms/commit ({sync_ms / async_ms:.1f}x)")
    log("With synchronous commit the primary only reports success after the standby has the WAL on disk:\n"
        "RPO = 0 (no committed transaction can be lost in a failover), paid for with extra latency.")

    log.heading("C7  Synchronous standby is DOWN - availability vs consistency")
    sh(["docker", "stop", R])
    log("docker stop gc-pg-replica")
    # the INSERT runs in the background because it will not return on its own
    writer = subprocess.Popen(["docker", "exec", "-i", P, "psql", "-U", "gc", "-d", "gracecare", "-AtX", "-c",
                               "INSERT INTO gc.repl_probe (note) VALUES ('during standby outage')"],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(6)
    log("an INSERT was started on the primary; 6 s later it has still not returned. pg_stat_activity:")
    log.block(psql_table(P, "SELECT wait_event_type, wait_event, date_trunc('second', now() - query_start) AS waiting_for, "
                            "left(query, 45) AS query FROM pg_stat_activity WHERE wait_event = 'SyncRep'"))
    log("(statement_timeout does not end this wait - in a test run a 4 s statement_timeout still hung for\n"
        " 2 minutes: the commit is already written locally, so the server waits for the standby to confirm)")
    psql(P, "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep'")
    o, e = writer.communicate(timeout=60)
    log("after pg_cancel_backend() the client receives:")
    log.block((o + e).strip())
    log.block(psql_table(P, "SELECT count(*) AS rows_marked_during_outage FROM gc.repl_probe "
                            "WHERE note = 'during standby outage'"))
    log("The row IS committed locally but was never confirmed by a standby. With strict synchronous\n"
        "replication the hospital has to choose: keep waiting (consistent, not available) or drop to\n"
        "asynchronous (available, small risk of losing recent commits). Here we choose availability:")
    alter_system(P, "ALTER SYSTEM RESET synchronous_standby_names")
    t0 = time.perf_counter()
    psql(P, "INSERT INTO gc.repl_probe (note) VALUES ('after switching to async')")
    log(f"synchronous_standby_names reset -> next INSERT committed in {(time.perf_counter() - t0) * 1000:.0f} ms")
    compose("up", "-d", "--wait", "pg-replica")
    wait_until(lambda: psql(P, "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming'") == "1", 120)
    log("replica restarted and streaming again (it caught up from the WAL kept by replication slot replica1_slot)")

    log.heading("C8  Failover - the primary fails, the replica is promoted")
    before = psql(R, "SELECT count(*) FROM gc.appointments")
    t0 = time.perf_counter()
    sh(["docker", "stop", "-t", "0", P])
    log(f"docker stop -t 0 gc-pg-primary   (crash, t = 0)")
    log(f"replica still serves reads: appointments = {before}; writes are rejected until promotion")
    log.block(psql(R, "SELECT pg_promote(wait => true)"), indent="    pg_promote() -> ")
    log.block(psql_table(R, "SELECT pg_is_in_recovery() AS in_recovery, "
                            "pg_walfile_name(pg_current_wal_lsn()) AS current_wal_file"))
    log("the first 8 hex digits of the WAL file name are the timeline: promotion started timeline 2,\n"
        "so WAL written by the new primary can never be confused with WAL from the old one")
    psql(R, "INSERT INTO gc.repl_probe (note) VALUES ('first write on promoted node')")
    log(f"write accepted on the promoted node at t = {time.perf_counter() - t0:.1f} s "
        "(manual promotion; Patroni would do this automatically in ~10-30 s)")
    log("Split-brain risk: if the old primary came back as a writer, two nodes would accept different writes.\n"
        "Production setups fence it (Patroni + a DCS such as etcd) and re-join it as a replica with pg_rewind.")

    log.heading("C9  Lab reset - rebuild the original topology")
    sh(["docker", "rm", "-f", R])
    sh(["docker", "volume", "rm", "gracecare_pg_replica_data"])
    compose("up", "-d", "--wait", "pg-primary")
    psql(P, "TRUNCATE gc.repl_probe")
    compose("up", "-d", "--wait", "pg-replica")
    wait_until(lambda: psql(P, "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming'") == "1", 180)
    log("old primary restarted as primary, promoted replica discarded, fresh replica cloned with pg_basebackup:")
    log.block(psql_table(P, "SELECT application_name, state, sync_state FROM pg_stat_replication"))
    psql(P, "DROP TABLE gc.repl_probe")
    log.save()


def main() -> None:
    parts = sys.argv[1:] or ["sharding", "mongo", "replication"]
    if "sharding" in parts:
        part_sharding()
    if "mongo" in parts:
        part_mongo()
    if "replication" in parts:
        part_replication()


if __name__ == "__main__":
    main()
