
from __future__ import annotations

import json
import statistics
import time
from pathlib import Path

import redis

from gclib import REDIS_URL, Report, pg_connect

HERE = Path(__file__).resolve().parent
out = Report(HERE / "results" / "redis_demo_output.txt")
r = redis.Redis.from_url(REDIS_URL, decode_responses=True)
pg = pg_connect(autocommit=True)
TTL_SECONDS = 300

BANNER_SQL = """
SELECT p.hospital_no, p.first_name || ' ' || p.last_name AS name, p.sex,
       date_part('year', age(current_date, p.date_of_birth))::int AS age, p.genotype, p.blood_group,
       (SELECT max(a.start_at) FROM appointments a
         WHERE a.patient_id = p.patient_id AND a.status = 'COMPLETED')            AS last_visit,
       (SELECT count(*) FROM appointments a WHERE a.patient_id = p.patient_id)     AS visits,
       (SELECT array_agg(DISTINCT d.icd10_code) FROM diagnoses d JOIN appointments a USING (appointment_id)
         WHERE a.patient_id = p.patient_id)                                        AS conditions
FROM patients p WHERE p.hospital_no = %s"""


def banner_from_db(hospital_no: str) -> dict:
    cur = pg.execute(BANNER_SQL, (hospital_no,))
    cols = [c.name for c in cur.description]
    return dict(zip(cols, cur.fetchone()))


def get_banner(hospital_no: str) -> tuple[dict, str]:
    """Cache-aside: try Redis first; on a miss read PostgreSQL and fill the cache."""
    key = f"patient:{hospital_no}:banner"
    cached = r.get(key)
    if cached is not None:
        return json.loads(cached), "HIT"
    banner = banner_from_db(hospital_no)
    r.set(key, json.dumps(banner, default=str), ex=TTL_SECONDS)
    return banner, "MISS"


def r1_r2() -> None:
    out.heading("R1  Cache-aside for the patient banner (TTL 300 s)")
    sample = [f"GC{n:08d}" for n in range(1000, 1200)]
    for h in sample:
        r.delete(f"patient:{h}:banner")

    def timed(h):
        t = time.perf_counter()
        _, kind = get_banner(h)
        return kind, (time.perf_counter() - t) * 1000

    misses = [timed(h) for h in sample]            # first access: cache is empty
    hits = [timed(h) for h in sample]              # second access: served from Redis
    assert all(k == "MISS" for k, _ in misses) and all(k == "HIT" for k, _ in hits)
    m_ms = statistics.median(ms for _, ms in misses)
    h_ms = statistics.median(ms for _, ms in hits)
    out(f"200 patients, first lookup  (MISS -> PostgreSQL + SET): median {m_ms:.3f} ms")
    out(f"200 patients, second lookup (HIT  -> Redis GET)       : median {h_ms:.3f} ms  ({m_ms / h_ms:.1f}x faster)")
    key = f"patient:{sample[0]}:banner"
    out(f"example key {key}: TTL remaining {r.ttl(key)} s, value {r.get(key)}")
    info = r.info("memory")
    out(f"Redis memory used: {info['used_memory_human']} (maxmemory 128 MB, policy allkeys-lru evicts "
        "the least recently used keys when full)")

    out.heading("R2  Invalidation on write - the cache must never show stale clinical data")
    h = sample[0]
    old, _ = get_banner(h)
    pg.execute("UPDATE patients SET genotype = CASE genotype WHEN 'AS' THEN 'AA' ELSE 'AS' END "
               "WHERE hospital_no = %s", (h,))
    out(f"genotype changed in PostgreSQL (was {old['genotype']}).")
    stale, kind = get_banner(h)
    out(f"read without invalidation -> {kind}, genotype {stale['genotype']}  <- STALE for up to {TTL_SECONDS} s")
    r.delete(f"patient:{h}:banner")                # the application deletes the key after every write
    fresh, kind = get_banner(h)
    out(f"after DEL patient:{h}:banner -> {kind}, genotype {fresh['genotype']}  <- correct")
    pg.execute("UPDATE patients SET genotype = %s WHERE hospital_no = %s", (old["genotype"], h))
    r.delete(f"patient:{h}:banner")
    out("(test change reverted)")


def r3() -> None:
    out.heading("R3  A&E triage queue - sorted set, most urgent first, then first come first served")
    q = "ae:triage:queue"
    r.delete(q)
    # Manchester-style triage categories: 1 immediate ... 5 non-urgent
    arrivals = [("GC00000311", 4, "sprained ankle"), ("GC00000312", 2, "chest pain"),
                ("GC00000313", 3, "high fever, child"), ("GC00000314", 1, "road traffic accident, unconscious"),
                ("GC00000315", 4, "cut finger"), ("GC00000316", 2, "snake bite")]
    base = time.time()
    for i, (h, cat, why) in enumerate(arrivals):
        score = cat * 10**10 + (base + i)           # category dominates; arrival time breaks ties
        r.zadd(q, {h: score})
        r.hset(f"ae:triage:{h}", mapping={"category": cat, "complaint": why})
        out(f"  arrival {i + 1}: {h} category {cat} ({why})")
    out(f"queue length (ZCARD) = {r.zcard(q)}")
    out("doctor calls next patient (ZPOPMIN) six times:")
    while r.zcard(q):
        h, _ = r.zpopmin(q)[0]
        info = r.hgetall(f"ae:triage:{h}")
        out(f"  -> {h} category {info['category']} ({info['complaint']})")
        r.delete(f"ae:triage:{h}")
    out("ZADD and ZPOPMIN are O(log n) and atomic, so several triage nurses and doctors can share the queue.")


def r4() -> None:
    out.heading("R4  Live ward occupancy counters (atomic HINCRBY)")
    key = "ward:occupancy"
    r.delete(key)
    rows = pg.execute("""SELECT w.name, count(a.admission_id) FROM wards w JOIN beds b USING (ward_id)
                         LEFT JOIN admissions a ON a.bed_id = b.bed_id AND a.discharged_at IS NULL
                         GROUP BY w.name""").fetchall()
    r.hset(key, mapping={name: n for name, n in rows})
    out(f"loaded from PostgreSQL: {r.hgetall(key)}")
    r.hincrby(key, "Medical Ward", 1)       # admission
    r.hincrby(key, "Maternity Ward", -1)    # discharge
    out(f"after one admission (Medical) and one discharge (Maternity): {r.hgetall(key)}")
    out("The dashboard reads one hash instead of running an aggregate over admissions every few seconds.\n"
        "PostgreSQL stays the system of record; the counters are rebuilt from it after a Redis restart.")


def main() -> None:
    out(f"Redis {r.info('server')['redis_version']} at {REDIS_URL}")
    r1_r2(); r3(); r4()
    out.save()


if __name__ == "__main__":
    main()
