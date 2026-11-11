"""
Portfolio 5 – replication, consistency, availability and failover on the 4-node cluster

  R0  Topology: who is primary, who is a standby, how they are connected
  R1  Replication + replication transparency: a write on the primary appears on the replica
  R2  Replicas are read-only (single-primary design)
  R3  Eventual consistency: replica2 applies changes 15 s late -> a STALE READ, then convergence
  R4  ASYNCHRONOUS replication + network partition -> primary stays AVAILABLE, replica falls behind,
      catches up after the partition heals                              (the "AP" side of CAP)
  R5  SYNCHRONOUS replication: cost per commit, then the same partition -> commits WAIT
      until the replica is back                                         (the "CP" side of CAP)
  R6  Failover (only with --failover): primary crashes, replica1 is promoted to primary

A "network partition" is simulated with `docker pause fk-replica1`: the container is frozen,
so from the primary's point of view the replica stops answering, exactly like a cut link.

Usage (after `docker compose up -d` and loading the data, see README):
  pip install "psycopg[binary]"
  python distributed_demo.py               # R0–R5
  python distributed_demo.py --failover    # R0–R6 (afterwards reset with: docker compose down -v)
Output is printed AND saved to evidence/distributed_demo_output.txt
"""
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import psycopg

MODE = os.environ.get("FK_MODE", "docker")      # "local" is only used to test without Docker
PASSWORD = os.environ.get("FK_PASSWORD", "finesse")
PORTS = {"primary": 5440, "replica1": 5441, "replica2": 5442}
CONTAINER = {"primary": "fk-primary", "replica1": "fk-replica1", "replica2": "fk-replica2"}
OUT = Path(__file__).parent / "evidence" / "distributed_demo_output.txt"
lines = []


def log(text=""):
    print(text)
    lines.append(text)


def header(title):
    log("\n" + "=" * 78 + "\n" + title + "\n" + "=" * 78)


def connect(node, autocommit=True):
    return psycopg.connect(host="localhost", port=PORTS[node], user="postgres", password=PASSWORD,
                           dbname="finesse_klass", autocommit=autocommit, connect_timeout=5)


def q(node, sql, params=None):
    with connect(node) as c:
        cur = c.execute(sql, params)
        return cur.fetchall() if cur.description else None


# --------------------------------------------------------------------------- node control
def _local_pids(node):
    out = subprocess.run(["pgrep", "-f", f"(postgres: {node}:|/tmp/dd/{node})"], capture_output=True, text=True)
    return out.stdout.split()


def pause(node):
    log(f">>> PARTITION: {node} is cut off (docker pause {CONTAINER[node]})")
    if MODE == "docker":
        subprocess.run(["docker", "pause", CONTAINER[node]], check=True)
    else:
        subprocess.run(["kill", "-STOP", *_local_pids(node)], check=True)


def unpause(node):
    log(f">>> HEAL: {node} is reachable again (docker unpause {CONTAINER[node]})")
    if MODE == "docker":
        subprocess.run(["docker", "unpause", CONTAINER[node]], check=True)
    else:
        subprocess.run(["kill", "-CONT", *_local_pids(node)], check=True)


def crash(node):
    log(f">>> CRASH: {node} goes down (docker kill {CONTAINER[node]})")
    if MODE == "docker":
        subprocess.run(["docker", "kill", CONTAINER[node]], check=True, capture_output=True)
    else:
        subprocess.run(["su", "postgres", "-c", f"/usr/lib/postgresql/16/bin/pg_ctl -D /tmp/dd/{node} stop -m immediate"],
                       check=True, capture_output=True)


# --------------------------------------------------------------------------- helpers
def probe(note, conn=None):
    """Write one row on the primary (one auto-committed transaction); return its id and commit time in ms."""
    if conn is None:
        with connect("primary") as c:
            return probe(note, c)
    t0 = time.perf_counter()
    (rid,) = conn.execute("INSERT INTO fk.replication_probe (note) VALUES (%s) RETURNING id", (note,)).fetchone()
    return rid, (time.perf_counter() - t0) * 1000


def visible(node, rid):
    return q(node, "SELECT count(*) FROM fk.replication_probe WHERE id = %s", (rid,))[0][0] == 1


def wait_visible(node, rid, timeout=60):
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < timeout:
        if visible(node, rid):
            return time.perf_counter() - t0
        time.sleep(0.05)
    return None


def replication_status():
    rows = q("primary", """
        SELECT application_name, state, sync_state,
               pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint AS replay_lag_bytes
        FROM pg_stat_replication ORDER BY application_name""")
    for name, state, sync, lag in rows:
        log(f"    {name:<9} state={state:<10} sync_state={sync:<6} replay lag={lag:>9,} bytes")


# =========================================================================== demo
def main():
    failover = "--failover" in sys.argv
    q("primary", "CREATE TABLE IF NOT EXISTS fk.replication_probe "
                 "(id serial PRIMARY KEY, note text, written_at timestamptz DEFAULT now())")
    q("primary", "ALTER SYSTEM SET synchronous_standby_names = ''")
    q("primary", "SELECT pg_reload_conf()")
    time.sleep(1)
    log(f"Finesse Klass distributed demo – {q('primary', 'SHOW server_version')[0][0]} – mode={MODE}")

    # ------------------------------------------------------------------- R0
    header("R0  TOPOLOGY")
    for node in ("primary", "replica1", "replica2"):
        rec, orders = q(node, "SELECT pg_is_in_recovery(), (SELECT count(*) FROM fk.customer_order)")[0]
        log(f"  {node:<9} port {PORTS[node]}  role={'STANDBY (read-only)' if rec else 'PRIMARY (read/write)':<20}"
            f" orders={orders:,}")
    log("  replication connections seen by the primary (pg_stat_replication):")
    replication_status()
    delay = q("replica2", "SHOW recovery_min_apply_delay")[0][0]
    log(f"  replica2 recovery_min_apply_delay = {delay}")

    # ------------------------------------------------------------------- R1
    header("R1  REPLICATION + TRANSPARENCY: write on the primary, read on replica1")
    rid, ms = probe("R1 new order event")
    secs = wait_visible("replica1", rid)
    log(f"  primary  : INSERT probe id={rid} committed in {ms:.1f} ms")
    log(f"  replica1 : same row visible after {secs * 1000:.0f} ms (the reader does not need to know which copy it uses)")
    lsn_p = q("primary", "SELECT pg_current_wal_lsn()")[0][0]
    lsn_r = q("replica1", "SELECT pg_last_wal_replay_lsn()")[0][0]
    log(f"  WAL position: primary {lsn_p} / replica1 replayed up to {lsn_r}")

    # ------------------------------------------------------------------- R2
    header("R2  A STANDBY IS READ-ONLY")
    try:
        q("replica1", "INSERT INTO fk.replication_probe (note) VALUES ('write on replica')")
        log("  insert succeeded (unexpected)")
    except psycopg.Error as e:
        log(f"  replica1 refused the write: {type(e).__name__}: {str(e).splitlines()[0]}")

    # ------------------------------------------------------------------- R3
    header("R3  EVENTUAL CONSISTENCY: replica2 applies changes 15 s late")
    q("primary", "UPDATE fk.product_variant SET unit_price = unit_price + 1000 WHERE sku = 'FK-087-44-BUR'")
    new_price = q("primary", "SELECT unit_price FROM fk.product_variant WHERE sku = 'FK-087-44-BUR'")[0][0]
    t0 = time.perf_counter()
    time.sleep(0.5)
    r1 = q("replica1", "SELECT unit_price FROM fk.product_variant WHERE sku = 'FK-087-44-BUR'")[0][0]
    r2 = q("replica2", "SELECT unit_price FROM fk.product_variant WHERE sku = 'FK-087-44-BUR'")[0][0]
    log(f"  primary  : price changed to {new_price}")
    log(f"  replica1 : {r1}   {'(up to date)' if r1 == new_price else '(stale)'}")
    log(f"  replica2 : {r2}   {'(up to date)' if r2 == new_price else '<- STALE READ: old price still served'}")
    while q("replica2", "SELECT unit_price FROM fk.product_variant WHERE sku = 'FK-087-44-BUR'")[0][0] != new_price:
        time.sleep(0.5)
    log(f"  replica2 converged to {new_price} after {time.perf_counter() - t0:.1f} s – all copies agree again")
    q("primary", "UPDATE fk.product_variant SET unit_price = unit_price - 1000 WHERE sku = 'FK-087-44-BUR'")

    # ------------------------------------------------------------------- R4
    header("R4  ASYNCHRONOUS replication during a PARTITION -> availability first (AP behaviour)")
    pause("replica1")
    rid, ms = probe("R4 order during partition")
    log(f"  primary  : write committed in {ms:.1f} ms although replica1 is unreachable -> AVAILABLE")
    time.sleep(1)
    for _ in range(3):
        probe("R4 more traffic")
    log("  replication status while partitioned (replica1's replay position stops moving):")
    replication_status()
    unpause("replica1")
    secs = wait_visible("replica1", rid)
    log(f"  replica1 caught up {secs * 1000:.0f} ms after the partition healed -> copies CONVERGE (eventual consistency)")
    replication_status()

    # ------------------------------------------------------------------- R5
    header("R5  SYNCHRONOUS replication -> consistency first (CP behaviour)")
    n = 200
    bench = connect("primary")                      # one open connection, so only the COMMIT is timed
    t0 = time.perf_counter()
    for _ in range(n):
        probe("async commit", bench)
    async_ms = (time.perf_counter() - t0) * 1000 / n
    q("primary", "ALTER SYSTEM SET synchronous_standby_names = 'replica1'")
    q("primary", "SELECT pg_reload_conf()")
    time.sleep(1.5)
    log("  synchronous_standby_names = 'replica1' -> a COMMIT returns only after replica1 confirms it")
    replication_status()
    t0 = time.perf_counter()
    for _ in range(n):
        probe("sync commit", bench)
    sync_ms = (time.perf_counter() - t0) * 1000 / n
    bench.close()
    log(f"  average commit time over {n} single-row orders: async {async_ms:.2f} ms  vs  sync {sync_ms:.2f} ms"
        f"  (x{sync_ms / async_ms:.1f}: the price of never losing a committed order)")

    pause("replica1")
    box = {}

    def sync_write():
        t = time.perf_counter()
        box["id"], _ = probe("R5 order during partition")
        box["secs"] = time.perf_counter() - t
    th = threading.Thread(target=sync_write)
    th.start()
    time.sleep(5)
    waiting = q("primary", "SELECT wait_event FROM pg_stat_activity "
                           "WHERE query LIKE 'INSERT INTO fk.replication_probe%%' AND state = 'active'")
    log(f"  primary  : after 5 s the COMMIT is still waiting (wait_event = {waiting[0][0] if waiting else '?'})"
        " -> the system gives up AVAILABILITY to keep the copies CONSISTENT")
    unpause("replica1")
    th.join()
    log(f"  primary  : the COMMIT completed {box['secs']:.1f} s after it was issued, right after replica1 returned")
    q("primary", "ALTER SYSTEM SET synchronous_standby_names = ''")
    q("primary", "SELECT pg_reload_conf()")
    log("  (synchronous replication switched off again)")

    # ------------------------------------------------------------------- R6
    if failover:
        header("R6  FAILOVER: the primary crashes, replica1 is promoted")
        rid, _ = probe("R6 last order before the crash")
        wait_visible("replica1", rid)
        crash("primary")
        time.sleep(2)
        n_orders = q("replica1", "SELECT count(*) FROM fk.customer_order")[0][0]
        log(f"  replica1 still answers READS: {n_orders:,} orders (catalogue and order history stay online)")
        try:
            q("replica1", "INSERT INTO fk.replication_probe (note) VALUES ('new order')")
        except psycopg.Error as e:
            log(f"  but WRITES fail: {str(e).splitlines()[0]}")
        t0 = time.perf_counter()
        q("replica1", "SELECT pg_promote(wait => true)")
        log(f"  pg_promote() -> replica1 is now a primary after {time.perf_counter() - t0:.1f} s")
        q("replica1", "INSERT INTO fk.replication_probe (note) VALUES ('first order after failover')")
        rec = q("replica1", "SELECT pg_is_in_recovery()")[0][0]
        log(f"  replica1: in recovery = {rec}; new orders are accepted again; the last order before the crash "
            f"is {'present' if q('replica1', 'SELECT count(*) FROM fk.replication_probe WHERE id=%s', (rid,))[0][0] else 'MISSING'}")
        log("  Reset the lab afterwards with: docker compose down -v   (then follow the README set-up again)")

    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"\nSaved to {OUT}")


if __name__ == "__main__":
    main()
