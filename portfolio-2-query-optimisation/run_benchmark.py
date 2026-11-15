"""Portfolio 2 - before/after benchmark of the GraceCare query workload.

Steps
  1. drop all optimisations (baseline = Part 1 schema only), ANALYZE
  2. for every query: save EXPLAIN (ANALYZE, BUFFERS) + time it RUNS times, keep the median
  3. create the optimisations (indexes + materialised view), ANALYZE, repeat step 2
  4. measure what the indexes cost: size on disk and slower bulk INSERTs
  5. write results/summary.md, results/plans/*.txt and results/query_outputs.txt

Run inside the tools container:
    docker compose run --rm tools python portfolio-2-query-optimisation/run_benchmark.py
"""
from __future__ import annotations

import re
import statistics
from pathlib import Path

from gclib import pg_connect

HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results"
PLANS = RESULTS / "plans"
RUNS = 9  # timed executions per query (after one warm-up); the median is reported

# which queries run in which phase; q5_..._mv and q6b only exist after optimisation
BASELINE = ["q1_patient_history", "q2_doctor_day_list", "q3_critical_unreviewed",
            "q4_phone_search", "q5_monthly_dx_report", "q6a_daily_count_nonsargable"]
OPTIMISED = BASELINE + ["q5_monthly_dx_report_mv", "q6b_daily_count_sargable"]


def load_queries() -> dict[str, str]:
    text = (HERE / "queries.sql").read_text(encoding="utf-8")
    blocks = re.split(r"^-- name: ", text, flags=re.M)[1:]
    queries = {}
    for block in blocks:
        name, _, body = block.partition("\n")
        sql = "\n".join(l for l in body.splitlines() if not l.strip().startswith("--")).strip()
        queries[name.strip()] = sql.rstrip(";")
    return queries


def run_sql_file(conn, path: Path) -> None:
    sql = path.read_text(encoding="utf-8")
    with conn.cursor() as cur:
        cur.execute(sql)


def explain(conn, sql: str) -> str:
    with conn.cursor() as cur:
        cur.execute("EXPLAIN (ANALYZE, BUFFERS) " + sql)
        return "\n".join(r[0] for r in cur.fetchall())


def time_query(conn, sql: str) -> float:
    """Median server-side execution time (ms). TIMING OFF keeps EXPLAIN overhead minimal."""
    times = []
    with conn.cursor() as cur:
        for i in range(RUNS + 1):
            cur.execute("EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON) " + sql)
            plan = "\n".join(r[0] for r in cur.fetchall())
            ms = float(re.search(r"Execution Time: ([\d.]+) ms", plan).group(1))
            if i > 0:                       # first run only warms the cache
                times.append(ms)
    return statistics.median(times)


def access_paths(plan: str) -> str:
    """Short description of how each table was read, e.g. 'Seq Scan on lab_orders'."""
    found = re.findall(r"((?:Parallel )?(?:Seq Scan|Bitmap Index Scan|Bitmap Heap Scan|Index Only Scan|Index Scan)"
                       r"(?: using \w+)? on \w+)", plan)
    seen, out = set(), []
    for f in found:
        if f not in seen:
            seen.add(f)
            out.append(f)
    return "<br>".join(out)


def run_phase(conn, phase: str, names: list[str], queries: dict[str, str]) -> dict:
    out = {}
    for name in names:
        plan = explain(conn, queries[name])
        (PLANS / f"{phase}__{name}.txt").write_text(plan + "\n", encoding="utf-8")
        ms = time_query(conn, queries[name])
        buffers = re.search(r"Buffers: shared hit=(\d+)(?: read=(\d+))?", plan)
        pages = int(buffers.group(1)) + int(buffers.group(2) or 0) if buffers else 0
        out[name] = {"ms": ms, "paths": access_paths(plan), "pages": pages}
        print(f"  {phase:9} {name:32} {ms:10.3f} ms   {pages:>7} pages")
    return out


def index_costs(conn) -> tuple[list, dict]:
    with conn.cursor() as cur:
        cur.execute("""
            SELECT c.relname, pg_size_pretty(pg_relation_size(c.oid)), pg_relation_size(c.oid)
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'gc' AND (c.relname LIKE 'idx\\_%' OR c.relname LIKE 'mv\\_%'
                                        OR c.relname LIKE 'uq\\_mv%')
            ORDER BY 3 DESC""")
        sizes = cur.fetchall()
        cur.execute("SELECT pg_size_pretty(pg_total_relation_size('appointments')),"
                    "       pg_size_pretty(pg_relation_size('appointments'))")
        tbl = cur.fetchone()
    return sizes, {"appointments_total": tbl[0], "appointments_heap": tbl[1]}


def write_cost(conn) -> dict[str, float]:
    """Isolate the cost of index maintenance on INSERT.

    All lab_orders rows are copied into a scratch table that has no triggers, once with no
    indexes and once with the same two indexes Part 2 adds to lab_orders. The two variants
    are alternated (to cancel out caching effects) 11 times; the first round is a warm-up and
    the median of the rest is reported.

    The scratch table is UNLOGGED: on Docker Desktop the time to flush WAL to disk varied
    between runs by a factor of 5, which hid the effect being measured. UNLOGGED removes that
    noise but keeps the real work of maintaining the indexes. On a normal (logged) table the
    index changes are also written to WAL, so the real overhead is somewhat higher.
    """
    conn.execute("DROP TABLE IF EXISTS bench_lab_orders")
    conn.execute("CREATE UNLOGGED TABLE bench_lab_orders (LIKE lab_orders INCLUDING DEFAULTS)")
    times: dict[str, list[float]] = {"no_index": [], "two_indexes": []}
    for round_no in range(11):
        for variant in ("no_index", "two_indexes"):
            conn.execute("DROP INDEX IF EXISTS bench_idx_appt, bench_idx_crit")
            conn.execute("TRUNCATE bench_lab_orders")
            if variant == "two_indexes":
                conn.execute("CREATE INDEX bench_idx_appt ON bench_lab_orders (appointment_id)")
                conn.execute("CREATE INDEX bench_idx_crit ON bench_lab_orders (resulted_at) "
                             "WHERE result_flag = 'CRITICAL' AND status = 'RESULTED'")
            plan = "\n".join(r[0] for r in conn.execute(
                "EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON) "
                "INSERT INTO bench_lab_orders SELECT * FROM lab_orders").fetchall())
            if round_no > 0:
                times[variant].append(float(re.search(r"Execution Time: ([\d.]+) ms", plan).group(1)))
    rows = conn.execute("SELECT count(*) FROM bench_lab_orders").fetchone()[0]
    conn.execute("DROP TABLE bench_lab_orders")
    return {"rows": rows, **{k: statistics.median(v) for k, v in times.items()}}


def query_outputs(conn, queries: dict[str, str]) -> str:
    lines = []
    with conn.cursor() as cur:
        for name in OPTIMISED:
            cur.execute(queries[name])
            cols = [d.name for d in cur.description]
            rows = cur.fetchall()
            lines.append(f"--- {name}  ({len(rows)} rows, first 12 shown)")
            lines.append(" | ".join(cols))
            for r in rows[:12]:
                lines.append(" | ".join("" if v is None else str(v) for v in r))
            lines.append("")
    return "\n".join(lines)


def main() -> None:
    PLANS.mkdir(parents=True, exist_ok=True)
    queries = load_queries()
    conn = pg_connect(autocommit=True)
    with conn.cursor() as cur:
        cur.execute("SELECT version()")
        version = cur.fetchone()[0]

    print("Phase 1: baseline (no optimisation objects)")
    run_sql_file(conn, HERE / "drop_optimisations.sql")
    before = run_phase(conn, "baseline", BASELINE, queries)

    print("Phase 2: optimised")
    run_sql_file(conn, HERE / "optimisations.sql")
    after = run_phase(conn, "optimised", OPTIMISED, queries)

    print("Phase 3: write cost of indexes")
    wc = write_cost(conn)
    sizes, tbl = index_costs(conn)

    (RESULTS / "query_outputs.txt").write_text(query_outputs(conn, queries), encoding="utf-8")

    # ---------------------------------------------------------------- summary.md
    md = ["# Portfolio 2 - benchmark results", "",
          f"- Server: `{version.split(',')[0]}` in Docker (Africa/Lagos time zone)",
          f"- Each time is the **median of {RUNS} runs** after one warm-up run "
          "(server-side `Execution Time`, `EXPLAIN (ANALYZE, TIMING OFF)`).",
          "- Pages = shared buffers touched in one run (hit + read), i.e. 8 kB blocks of work.",
          "- Full plans: `results/plans/baseline__*.txt` and `results/plans/optimised__*.txt`.", "",
          "## Query timings", "",
          "| Query | Baseline ms | Optimised ms | Speed-up | Pages before -> after | Access path before | Access path after |",
          "|---|---:|---:|---:|---:|---|---|"]

    def row(label, b, a):
        speed = b["ms"] / a["ms"] if a["ms"] else float("inf")
        speed_txt = f"{speed:,.1f}x" if speed < 10 else f"{speed:,.0f}x"
        md.append(f"| {label} | {b['ms']:.3f} | {a['ms']:.3f} | **{speed_txt}** | "
                  f"{b['pages']:,} -> {a['pages']:,} | {b['paths']} | {a['paths']} |")

    row("Q1 patient history", before["q1_patient_history"], after["q1_patient_history"])
    row("Q2 doctor day list", before["q2_doctor_day_list"], after["q2_doctor_day_list"])
    row("Q3 critical results not reviewed", before["q3_critical_unreviewed"], after["q3_critical_unreviewed"])
    row("Q4 phone-number fragment search", before["q4_phone_search"], after["q4_phone_search"])
    row("Q5 monthly report, indexes only", before["q5_monthly_dx_report"], after["q5_monthly_dx_report"])
    row("Q5 monthly report, materialised view", before["q5_monthly_dx_report"], after["q5_monthly_dx_report_mv"])
    row("Q6 daily count as written (`start_at::date = ...`)",
        before["q6a_daily_count_nonsargable"], after["q6a_daily_count_nonsargable"])
    row("Q6 daily count rewritten as a range (baseline column = Q6 as written, with index)",
        after["q6a_daily_count_nonsargable"], after["q6b_daily_count_sargable"])

    md += ["", "## What the optimisations cost", "",
           "| Object | Size |", "|---|---:|"]
    md += [f"| `{name}` | {pretty} |" for name, pretty, _ in sizes]
    md += ["", f"Table `appointments`: heap {tbl['appointments_heap']}, "
               f"heap + all indexes {tbl['appointments_total']}.", "",
           f"Write test: bulk INSERT of all {wc['rows']:,} lab_orders rows into a trigger-free copy of the table, "
           "UNLOGGED to remove disk-flush noise, variants alternated, median of 10 rounds after a warm-up:", "",
           "| Variant | ms |", "|---|---:|",
           f"| No indexes | {wc['no_index']:.1f} |",
           f"| With the 2 indexes Part 2 adds to lab_orders | {wc['two_indexes']:.1f} |",
           f"| Index maintenance overhead | {100 * (wc['two_indexes'] - wc['no_index']) / wc['no_index']:+.0f}% |", ""]
    (RESULTS / "summary.md").write_text("\n".join(md), encoding="utf-8")
    print("\n".join(md))
    conn.close()


if __name__ == "__main__":
    main()
