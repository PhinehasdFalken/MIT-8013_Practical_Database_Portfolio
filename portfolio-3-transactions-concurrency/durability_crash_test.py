"""
Portfolio 3 – DURABILITY: does a committed order survive a crash?

Uses a throwaway PostgreSQL 16 container (so your real database is never touched):
  1. start container fk-crash-test
  2. COMMIT an order row                       -> must survive
  3. in a second session, INSERT another row but do NOT commit
  4. `docker kill` the container               -> the server dies instantly, like a power cut
                                                  (no clean shutdown, no final checkpoint)
  5. `docker start` it again                   -> PostgreSQL replays its write-ahead log (WAL)
  6. check: committed row present, uncommitted row absent; show the recovery lines from the log
  7. remove the container

Usage:
  pip install "psycopg[binary]"
  python durability_crash_test.py
Output is printed AND saved to evidence/04_durability_crash_test.txt
"""
import os
import subprocess
import time
from pathlib import Path

import psycopg

MODE = os.environ.get("FK_MODE", "docker")          # "local" exists only for testing without Docker
NAME, PORT, PASSWORD = "fk-crash-test", 5450, "finesse"
OUT = Path(__file__).parent / "evidence" / "04_durability_crash_test.txt"
LOCAL_DIR = "/tmp/fk_crash_test"
lines = []


def log(t=""):
    print(t)
    lines.append(t)


def sh(*cmd, check=True):
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def dsn():
    return f"host=localhost port={PORT} user=postgres password={PASSWORD} dbname=postgres connect_timeout=3"


def wait_ready(timeout=90):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            with psycopg.connect(dsn()) as c:
                c.execute("SELECT 1")
                return
        except psycopg.OperationalError:
            time.sleep(1)
    raise SystemExit("PostgreSQL did not become ready")


def start_server():
    if MODE == "docker":
        sh("docker", "rm", "-f", NAME, check=False)
        sh("docker", "run", "-d", "--name", NAME, "-e", f"POSTGRES_PASSWORD={PASSWORD}",
           "-p", f"{PORT}:5432", "postgres:16")
    else:
        sh("bash", "-c", f"rm -rf {LOCAL_DIR} && mkdir -p {LOCAL_DIR} && chown postgres {LOCAL_DIR} && "
                         f"su postgres -c '/usr/lib/postgresql/16/bin/initdb -D {LOCAL_DIR}/data -U postgres --auth=trust >/dev/null && "
                         f"/usr/lib/postgresql/16/bin/pg_ctl -D {LOCAL_DIR}/data -o \"-p {PORT} -k /tmp\" -l {LOCAL_DIR}/log start >/dev/null'")
    wait_ready()


def crash():
    if MODE == "docker":
        sh("docker", "kill", NAME)
    else:
        sh("su", "postgres", "-c", f"/usr/lib/postgresql/16/bin/pg_ctl -D {LOCAL_DIR}/data stop -m immediate")


def restart():
    if MODE == "docker":
        sh("docker", "start", NAME)
    else:
        sh("su", "postgres", "-c", f"/usr/lib/postgresql/16/bin/pg_ctl -D {LOCAL_DIR}/data -o '-p {PORT} -k /tmp' -l {LOCAL_DIR}/log start")
    wait_ready()
    time.sleep(1)


def server_log():
    if MODE == "docker":
        r = sh("docker", "logs", NAME)
        return (r.stdout + r.stderr).splitlines()
    return Path(f"{LOCAL_DIR}/log").read_text().splitlines()


def cleanup():
    if MODE == "docker":
        sh("docker", "rm", "-f", NAME, check=False)
    else:
        sh("su", "postgres", "-c", f"/usr/lib/postgresql/16/bin/pg_ctl -D {LOCAL_DIR}/data stop -m fast", check=False)


log("=== Durability test: a committed Finesse Klass order survives a crash")
log(f"1. starting a throwaway PostgreSQL 16 server ({'docker container ' + NAME if MODE == 'docker' else 'local test server'}) ...")
start_server()
try:
    with psycopg.connect(dsn(), autocommit=True) as c:
        c.execute("CREATE TABLE customer_order (order_ref text PRIMARY KEY, total_amount numeric(12,2), "
                  "status text, created_at timestamptz DEFAULT now())")
        c.execute("BEGIN")
        c.execute("INSERT INTO customer_order (order_ref, total_amount, status) VALUES ('FK-T1-COMMITTED', 120100, 'paid')")
        c.execute("COMMIT")
    log("2. session A: INSERT order FK-T1-COMMITTED ... COMMIT   -> committed")

    b = psycopg.connect(dsn(), autocommit=True)
    b.execute("BEGIN")
    b.execute("INSERT INTO customer_order (order_ref, total_amount, status) VALUES ('FK-T2-NOT-COMMITTED', 57200, 'pending')")
    log("3. session B: BEGIN; INSERT order FK-T2-NOT-COMMITTED   -> transaction still open (no COMMIT)")

    crash()
    log("4. CRASH: server killed instantly (docker kill = power cut: no clean shutdown, no final checkpoint)")
    try:
        b.close()
    except Exception:
        pass

    restart()
    log("5. server started again; recovery messages from the PostgreSQL log:")
    for line in server_log():
        if any(k in line for k in ("not properly shut down", "redo starts", "redo done", "ready to accept connections")):
            log("     " + line.split("LOG:", 1)[-1].strip() if "LOG:" in line else "     " + line.strip())

    with psycopg.connect(dsn()) as c:
        rows = c.execute("SELECT order_ref, total_amount, status FROM customer_order ORDER BY order_ref").fetchall()
    log("6. orders present after recovery:")
    for r in rows:
        log(f"     {r[0]:<22} {r[1]:>10} {r[2]}")
    refs = {r[0] for r in rows}
    log(f"   committed order present      : {'YES' if 'FK-T1-COMMITTED' in refs else 'NO'}  (durability)")
    log(f"   uncommitted order present    : {'YES' if 'FK-T2-NOT-COMMITTED' in refs else 'NO'}   (atomicity – it was never committed)")
finally:
    cleanup()
    log("7. throwaway server removed")
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"\nSaved to {OUT}")
