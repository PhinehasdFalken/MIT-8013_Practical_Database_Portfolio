"""
Portfolio 2 – benchmark runner (baseline vs indexed)

What it does (Study Session 4 §4.1.3.2 "Methods and Metrics of Evaluating Query Optimisation"):
  * Method: execution-plan analysis (EXPLAIN) + benchmarking a fixed query workload.
  * Metrics: execution time, logical I/O (buffer hits), physical I/O (blocks read
    from disk), optimiser cost, estimated vs actual rows.

Steps
  1. Drop every Portfolio-2 index      (sql/00_drop_indexes.sql)   -> BASELINE
  2. Run Q1–Q6 from sql/01_queries.sql, RUNS times each (first run = cache warm-up)
  3. Create the chosen indexes         (sql/02_create_indexes.sql) -> INDEXED
  4. Run Q1–Q6 again
  5. Write evidence/plans/*.txt, evidence/results.csv, evidence/results.md
     and evidence/execution_time_chart.png

Usage
  pip install "psycopg[binary]" matplotlib
  python run_benchmark.py "postgresql://postgres:YOURPASSWORD@localhost:5432/finesse_klass"
"""
import csv
import json
import re
import statistics
import sys
from pathlib import Path

import psycopg

HERE = Path(__file__).parent
EVIDENCE = HERE / "evidence"
PLANS = EVIDENCE / "plans"
RUNS = 6                       # 1 warm-up + 5 measured runs
DSN = sys.argv[1] if len(sys.argv) > 1 else "postgresql://postgres@localhost:5432/finesse_klass"


def load_queries():
    text = (HERE / "sql" / "01_queries.sql").read_text(encoding="utf-8")
    parts = re.split(r"^-- @(Q\d+) \| (.*?) \| (.*?)$", text, flags=re.M)
    queries = []
    for i in range(1, len(parts), 4):
        queries.append({"id": parts[i], "title": parts[i + 1].strip(),
                        "concept": parts[i + 2].strip(),
                        "sql": parts[i + 3].strip().rstrip(";")})
    return queries


def scan_nodes(plan, found=None):
    """Collect the access paths (Seq Scan, Index Scan, ...) used in a plan tree."""
    found = [] if found is None else found
    node = plan["Node Type"]
    if "Scan" in node:
        rel = plan.get("Relation Name") or plan.get("Index Name") or ""
        idx = plan.get("Index Name")
        found.append(f"{node} on {plan.get('Relation Name', '')}" + (f" ({idx})" if idx and node != "Bitmap Index Scan" else "")
                     if node != "Bitmap Index Scan" else f"Bitmap Index Scan ({rel})")
    for child in plan.get("Plans", []):
        scan_nodes(child, found)
    return found


def measure(conn, q, phase):
    times = []
    for run in range(RUNS):
        (raw,) = conn.execute("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + q["sql"]).fetchone()
        doc = raw[0] if isinstance(raw, list) else json.loads(raw)[0]
        if run > 0:                                   # discard warm-up run
            times.append(doc["Execution Time"])
    top = doc["Plan"]
    # human-readable plan for the evidence folder / screenshots
    text_plan = "\n".join(r[0] for r in conn.execute("EXPLAIN (ANALYZE, BUFFERS) " + q["sql"]))
    (PLANS / f"{q['id']}_{phase}.txt").write_text(
        f"-- {q['id']} [{phase}] {q['title']}\n-- {q['sql']}\n\n{text_plan}\n", encoding="utf-8")
    return {
        "query": q["id"], "phase": phase,
        "median_ms": round(statistics.median(times), 3),
        "min_ms": round(min(times), 3), "max_ms": round(max(times), 3),
        "total_cost": top["Total Cost"],
        "est_rows": top["Plan Rows"], "actual_rows": top["Actual Rows"],
        "buffer_hits": top.get("Shared Hit Blocks", 0),
        "blocks_read": top.get("Shared Read Blocks", 0),
        "access_paths": "; ".join(dict.fromkeys(scan_nodes(top))),
    }


def run_file(conn, name):
    conn.execute((HERE / "sql" / name).read_text(encoding="utf-8"))


def main():
    PLANS.mkdir(parents=True, exist_ok=True)
    queries = load_queries()
    results = []
    with psycopg.connect(DSN, autocommit=True) as conn:
        conn.execute("SET search_path TO fk")
        version = conn.execute("SHOW server_version").fetchone()[0]

        print("Phase 1/2: BASELINE (only primary-key / unique indexes)")
        run_file(conn, "00_drop_indexes.sql")
        for q in queries:
            r = measure(conn, q, "baseline"); results.append(r)
            print(f"  {q['id']}: {r['median_ms']:>9.3f} ms  cost={r['total_cost']:>10.2f}  buffers={r['buffer_hits'] + r['blocks_read']}")

        print("Phase 2/2: INDEXED (sql/02_create_indexes.sql)")
        run_file(conn, "02_create_indexes.sql")
        for q in queries:
            r = measure(conn, q, "indexed"); results.append(r)
            print(f"  {q['id']}: {r['median_ms']:>9.3f} ms  cost={r['total_cost']:>10.2f}  buffers={r['buffer_hits'] + r['blocks_read']}")

    # ---------------- CSV
    with open(EVIDENCE / "results.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(results[0].keys()))
        w.writeheader(); w.writerows(results)

    # ---------------- Markdown summary
    by = {(r["query"], r["phase"]): r for r in results}
    lines = [f"# Portfolio 2 – benchmark results (PostgreSQL {version}, median of {RUNS - 1} warm runs)\n",
             "| Query | Concept | Baseline ms | Indexed ms | Speed-up | Baseline cost → Indexed cost | Buffers (logical+physical I/O) | Est. rows / actual rows (indexed) | Access path after indexing |",
             "|---|---|---:|---:|---:|---|---|---|---|"]
    for q in queries:
        b, i = by[(q["id"], "baseline")], by[(q["id"], "indexed")]
        speed = b["median_ms"] / i["median_ms"] if i["median_ms"] else float("inf")
        lines.append(
            f"| {q['id']} | {q['concept']} | {b['median_ms']:.3f} | {i['median_ms']:.3f} | {speed:,.1f}× | "
            f"{b['total_cost']:,.0f} → {i['total_cost']:,.0f} | "
            f"{b['buffer_hits'] + b['blocks_read']:,} → {i['buffer_hits'] + i['blocks_read']:,} | "
            f"{i['est_rows']:,} / {i['actual_rows']:,} | {i['access_paths']} |")
    (EVIDENCE / "results.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    # ---------------- keep README in sync with THIS machine's run
    short = [f"*Generated by `run_benchmark.py` – PostgreSQL {version}, median of {RUNS - 1} warm runs.*", "",
             "| Query | Baseline | Indexed | Speed-up | Buffers (hit+read) | Est. / actual rows (indexed) |",
             "|---|---:|---:|---:|---:|---:|"]
    for q in queries:
        b, i = by[(q["id"], "baseline")], by[(q["id"], "indexed")]
        speed = b["median_ms"] / i["median_ms"] if i["median_ms"] else float("inf")
        short.append(f"| {q['id']} {q['title'].split(':')[0]} | {b['median_ms']:.3f} ms | {i['median_ms']:.3f} ms | "
                     f"**{speed:,.1f}×** | {b['buffer_hits'] + b['blocks_read']:,} → {i['buffer_hits'] + i['blocks_read']:,} | "
                     f"{i['est_rows']:,} / {i['actual_rows']:,} |")
    readme = HERE / "README.md"
    text = readme.read_text(encoding="utf-8")
    start, end = "<!-- RESULTS:START -->", "<!-- RESULTS:END -->"
    if start in text and end in text:
        head, rest = text.split(start, 1)
        _, tail = rest.split(end, 1)
        readme.write_text(head + start + "\n" + "\n".join(short) + "\n" + end + tail, encoding="utf-8")

    # ---------------- Chart
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        ids = [q["id"] for q in queries]
        base = [by[(x, "baseline")]["median_ms"] for x in ids]
        idx = [by[(x, "indexed")]["median_ms"] for x in ids]
        fig, ax = plt.subplots(figsize=(8, 4.2))
        xs = range(len(ids))
        ax.bar([x - 0.2 for x in xs], base, width=0.4, label="Baseline (PK/UNIQUE only)", color="#9aa5b1")
        ax.bar([x + 0.2 for x in xs], idx, width=0.4, label="With chosen indexes", color="#2f5d8a")
        ax.set_yscale("log"); ax.set_xticks(list(xs)); ax.set_xticklabels(ids)
        ax.set_ylabel("Median execution time (ms, log scale)")
        ax.set_title("Finesse Klass workload – effect of physical design")
        for x, b_, i_ in zip(xs, base, idx):
            ratio = b_ / i_ if i_ else 0
            label = f"{ratio:,.0f}×" if ratio >= 10 else f"{ratio:.1f}×"
            ax.text(x + 0.2, i_, label, ha="center", va="bottom", fontsize=8)
        ax.legend(frameon=False); ax.spines[["top", "right"]].set_visible(False)
        fig.tight_layout(); fig.savefig(EVIDENCE / "execution_time_chart.png", dpi=150)
    except ImportError:
        print("matplotlib not installed – chart skipped")

    print("\nWrote evidence/results.md, evidence/results.csv, evidence/plans/, evidence/execution_time_chart.png")


if __name__ == "__main__":
    main()
