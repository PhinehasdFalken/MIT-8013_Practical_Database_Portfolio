"""
Portfolio 3 – concurrency demo with two real database sessions (A and B)

Scenario: Finesse Klass has ONE last pair of the Banana Island Wingtip
Brogue, size 44, white (SKU FK-027-44-WHI). Two customers try to buy it
at the same moment.

  S1  The problem – LOST UPDATE: naive "read stock, then write stock" -> the pair is sold twice
  S2  Fix 1 – pessimistic LOCKING (SELECT ... FOR UPDATE)           -> B waits, then sees 0
  S3  Fix 2 – stricter ISOLATION (REPEATABLE READ)                  -> B gets a serialisation error, retries
  S4  Fix 3 – ATOMIC conditional UPDATE (... WHERE stock_qty >= 1)  -> B updates 0 rows
  S5  ISOLATION: no dirty reads; non-repeatable read in READ COMMITTED vs a stable snapshot in REPEATABLE READ
  S6  DEADLOCK: two orders lock two variants in opposite order; then the fix (lock in a fixed order)

The script controls the order of steps exactly, so the race happens every
time. Statements that have to WAIT for a lock run in a background thread,
and a third "observer" connection shows the wait in pg_stat_activity.
At the end, all demo orders are deleted and stock/prices are restored.

Usage:
  pip install "psycopg[binary]"
  python concurrency_demo.py "postgresql://postgres:YOURPASSWORD@localhost:5432/finesse_klass"
Output is printed AND saved to evidence/concurrency_demo_output.txt
"""
import sys
import threading
import time
from pathlib import Path

import psycopg
from psycopg import errors

DSN = sys.argv[1] if len(sys.argv) > 1 else "postgresql://postgres@localhost:5432/finesse_klass"
LAST_PAIR = "FK-027-44-WHI"                     # Banana Island Wingtip Brogue, 44, white
SKU_X, SKU_Y = "FK-087-44-BUR", "FK-047-43-WHI"  # used in the deadlock scenario
CUSTOMER = {"A": 101, "B": 202}                  # Kemi Bello and Halima Afolabi
OUT = Path(__file__).parent / "evidence" / "concurrency_demo_output.txt"
_log_lines: list[str] = []
_t0 = time.monotonic()
demo_orders: list[int] = []        # every order created by the demo (deleted at the end)
scenario_orders: list[int] = []    # orders created in the current scenario only


def log(text=""):
    print(text)
    _log_lines.append(text)


def header(title):
    global _t0
    _t0 = time.monotonic()
    scenario_orders.clear()
    log("\n" + "=" * 78)
    log(title)
    log("=" * 78)


class Session:
    def __init__(self, name):
        self.name = name
        self.conn = psycopg.connect(DSN, autocommit=True)   # we send BEGIN/COMMIT ourselves
        self.conn.execute("SET search_path TO fk")
        self.conn.execute("SELECT set_config('application_name', %s, false)", (f"session_{name}",))
        self.pid = self.conn.info.backend_pid

    def run(self, sql, params=None, note=""):
        shown = " ".join(sql.split())
        for p in params or ():                       # show real values instead of %s in the log
            shown = shown.replace("%s", f"'{p}'" if isinstance(p, str) else str(p), 1)
        log(f"[t+{time.monotonic() - _t0:5.2f}s] {self.name} | {shown}" + (f"   -- {note}" if note else ""))
        cur = self.conn.execute(sql, params)
        rows = cur.fetchall() if cur.description else None
        if rows is not None:
            log(f"{'':10}{self.name} |   -> {rows}")
        return rows

    def run_waiting(self, sql, params=None, note=""):
        """Start a statement that is expected to block; returns a handle to join later."""
        box = {}

        def target():
            try:
                box["rows"] = self.run(sql, params, note)
            except Exception as exc:            # deadlock / serialisation errors are captured
                box["error"] = exc
                log(f"{'':10}{self.name} |   !! {type(exc).__name__}: {str(exc).splitlines()[0]}")
        th = threading.Thread(target=target)
        th.start()
        time.sleep(1.2)                          # give it time to hit the lock
        return th, box

    def close(self):
        self.conn.close()


def observe_wait(observer, session):
    rows = observer.execute(
        "SELECT state, wait_event_type, wait_event, pg_blocking_pids(pid) "
        "FROM pg_stat_activity WHERE pid = %s", (session.pid,)).fetchall()
    for state, wtype, wevent, blockers in rows:
        log(f"{'':10}OBSERVER | session {session.name}: state={state}, waiting on {wtype}/{wevent}, "
            f"blocked by pid {blockers} (session A pid = {A.pid})")


def stock():
    return observer.execute("SELECT stock_qty FROM product_variant WHERE sku = %s", (LAST_PAIR,)).fetchone()[0]


def reset_last_pair():
    observer.execute("UPDATE product_variant SET stock_qty = 1 WHERE sku = %s", (LAST_PAIR,))
    log(f"setup: stock of {LAST_PAIR} set to 1 (the last pair)")


def create_order(s: Session, sku=LAST_PAIR):
    """Order header + order line for one pair (inside the session's open transaction)."""
    (order_id,) = s.run(
        "INSERT INTO customer_order (customer_id, address_id, status) "
        "SELECT %s, address_id, 'paid' FROM address WHERE customer_id = %s AND is_default "
        "RETURNING order_id", (CUSTOMER[s.name], CUSTOMER[s.name]))[0]
    demo_orders.append(order_id)
    scenario_orders.append(order_id)
    s.run("INSERT INTO order_item (order_id, line_no, variant_id, quantity, unit_price) "
          "SELECT %s, 1, variant_id, 1, unit_price FROM product_variant WHERE sku = %s", (order_id, sku))
    s.run("INSERT INTO stock_movement (variant_id, change_qty, reason, order_id) "
          "SELECT variant_id, -1, 'sale', %s FROM product_variant WHERE sku = %s", (order_id, sku))
    return order_id


def audit(label):
    sold = observer.execute(
        "SELECT count(*) FROM order_item oi JOIN product_variant v USING (variant_id) "
        "WHERE v.sku = %s AND oi.order_id = ANY(%s)", (LAST_PAIR, list(scenario_orders))).fetchone()[0]
    log(f"RESULT {label}: stock now = {stock()}, orders that received the last pair in this scenario = {sold}")


# ---------------------------------------------------------------------------
A, B, observer = Session("A"), Session("B"), psycopg.connect(DSN, autocommit=True)
observer.execute("SET search_path TO fk")
price_before = observer.execute("SELECT unit_price FROM product_variant WHERE sku = %s", (LAST_PAIR,)).fetchone()[0]
log(f"Finesse Klass concurrency demo – PostgreSQL {observer.execute('SHOW server_version').fetchone()[0]}")
log(f"Session A = customer {CUSTOMER['A']} (pid {A.pid}), Session B = customer {CUSTOMER['B']} (pid {B.pid})")

try:
    # ------------------------------------------------------------------- S1
    header("S1  PROBLEM: LOST UPDATE – the last pair is sold twice (READ COMMITTED, no locking)")
    reset_last_pair()
    A.run("BEGIN")
    a_stock = A.run("SELECT stock_qty FROM product_variant WHERE sku = %s", (LAST_PAIR,), "A sees 1 pair")[0][0]
    B.run("BEGIN")
    b_stock = B.run("SELECT stock_qty FROM product_variant WHERE sku = %s", (LAST_PAIR,), "B ALSO sees 1 pair")[0][0]
    create_order(A)
    A.run("UPDATE product_variant SET stock_qty = %s WHERE sku = %s", (a_stock - 1, LAST_PAIR), "app writes 1-1 = 0")
    A.run("COMMIT")
    create_order(B)
    B.run("UPDATE product_variant SET stock_qty = %s WHERE sku = %s", (b_stock - 1, LAST_PAIR),
          "B writes 1-1 = 0, overwriting A's update (lost update)")
    B.run("COMMIT")
    audit("S1")
    log("=> One physical pair, TWO paid orders. The CHECK (stock_qty >= 0) could not help: 0 is a legal value.")

    # ------------------------------------------------------------------- S2
    header("S2  FIX 1: PESSIMISTIC LOCKING – SELECT ... FOR UPDATE")
    reset_last_pair()
    A.run("BEGIN")
    A.run("SELECT stock_qty FROM product_variant WHERE sku = %s FOR UPDATE", (LAST_PAIR,), "A locks the row")
    B.run("BEGIN")
    th, box = B.run_waiting("SELECT stock_qty FROM product_variant WHERE sku = %s FOR UPDATE", (LAST_PAIR,),
                            "B asks for the same lock ...")
    observe_wait(observer, B)
    create_order(A)
    A.run("UPDATE product_variant SET stock_qty = stock_qty - 1 WHERE sku = %s", (LAST_PAIR,))
    A.run("COMMIT", note="releases the lock")
    th.join()
    if box["rows"][0][0] < 1:
        B.run("ROLLBACK", note="B now sees 0 -> 'Sorry, this size has just sold out'")
    audit("S2")

    # ------------------------------------------------------------------- S3
    header("S3  FIX 2: ISOLATION LEVEL REPEATABLE READ – the database detects the conflict")
    reset_last_pair()
    A.run("BEGIN ISOLATION LEVEL REPEATABLE READ")
    A.run("SELECT stock_qty FROM product_variant WHERE sku = %s", (LAST_PAIR,))
    B.run("BEGIN ISOLATION LEVEL REPEATABLE READ")
    B.run("SELECT stock_qty FROM product_variant WHERE sku = %s", (LAST_PAIR,), "B also sees 1")
    create_order(A)
    A.run("UPDATE product_variant SET stock_qty = stock_qty - 1 WHERE sku = %s", (LAST_PAIR,))
    A.run("COMMIT")
    try:
        B.run("UPDATE product_variant SET stock_qty = stock_qty - 1 WHERE sku = %s", (LAST_PAIR,),
              "B tries to update a row changed after its snapshot")
    except errors.SerializationFailure as exc:
        log(f"{'':10}B |   !! SerializationFailure: {str(exc).splitlines()[0]}")
        B.run("ROLLBACK")
        log("          B | application retries the whole transaction:")
        B.run("BEGIN ISOLATION LEVEL REPEATABLE READ")
        left = B.run("SELECT stock_qty FROM product_variant WHERE sku = %s", (LAST_PAIR,))[0][0]
        if left < 1:
            B.run("ROLLBACK", note="retry sees 0 -> sold out, no second order")
    audit("S3")

    # ------------------------------------------------------------------- S4
    header("S4  FIX 3: ATOMIC CONDITIONAL UPDATE – check and decrement in ONE statement")
    reset_last_pair()
    A.run("BEGIN")
    B.run("BEGIN")
    A.run("UPDATE product_variant SET stock_qty = stock_qty - 1 WHERE sku = %s AND stock_qty >= 1 RETURNING stock_qty",
          (LAST_PAIR,), "A wins the pair")
    th, box = B.run_waiting(
        "UPDATE product_variant SET stock_qty = stock_qty - 1 WHERE sku = %s AND stock_qty >= 1 RETURNING stock_qty",
        (LAST_PAIR,), "B waits for A's row lock ...")
    observe_wait(observer, B)
    create_order(A)
    A.run("COMMIT")
    th.join()
    if not box.get("rows"):
        B.run("ROLLBACK", note="0 rows updated -> condition re-checked after A committed -> sold out")
    audit("S4")

    # ------------------------------------------------------------------- S5
    header("S5  ISOLATION: dirty read? non-repeatable read? (price change during a customer's checkout)")
    log("-- (a) READ COMMITTED (PostgreSQL default)")
    A.run("BEGIN")
    A.run("UPDATE product_variant SET unit_price = unit_price + 5000 WHERE sku = %s", (LAST_PAIR,), "not committed yet")
    B.run("BEGIN")
    B.run("SELECT unit_price FROM product_variant WHERE sku = %s", (LAST_PAIR,),
          "B does NOT see A's uncommitted price -> no dirty read")
    A.run("COMMIT")
    B.run("SELECT unit_price FROM product_variant WHERE sku = %s", (LAST_PAIR,),
          "same query, same transaction, NEW value -> non-repeatable read")
    B.run("COMMIT")
    log("-- (b) REPEATABLE READ")
    B.run("BEGIN ISOLATION LEVEL REPEATABLE READ")
    B.run("SELECT unit_price FROM product_variant WHERE sku = %s", (LAST_PAIR,), "B's snapshot is taken here")
    A.run("BEGIN")
    A.run("UPDATE product_variant SET unit_price = unit_price - 5000 WHERE sku = %s", (LAST_PAIR,), "price restored")
    A.run("COMMIT")
    B.run("SELECT unit_price FROM product_variant WHERE sku = %s", (LAST_PAIR,),
          "still the snapshot value -> checkout total stays consistent")
    B.run("COMMIT")
    B.run("SELECT unit_price FROM product_variant WHERE sku = %s", (LAST_PAIR,), "new transaction sees the committed price")

    # ------------------------------------------------------------------- S6
    header("S6  DEADLOCK: two 2-pair orders lock the same two variants in opposite order")
    A.run("BEGIN")
    B.run("BEGIN")
    A.run("UPDATE product_variant SET stock_qty = stock_qty - 1 WHERE sku = %s", (SKU_X,), "A locks X")
    B.run("UPDATE product_variant SET stock_qty = stock_qty - 1 WHERE sku = %s", (SKU_Y,), "B locks Y")
    th_a, box_a = A.run_waiting("UPDATE product_variant SET stock_qty = stock_qty - 1 WHERE sku = %s", (SKU_Y,),
                                "A wants Y (held by B) ...")
    th_b, box_b = B.run_waiting("UPDATE product_variant SET stock_qty = stock_qty - 1 WHERE sku = %s", (SKU_X,),
                                "B wants X (held by A) -> cycle")
    th_a.join(); th_b.join()
    victim = "A" if "error" in box_a else "B"
    survivor = "B" if victim == "A" else "A"
    log(f"=> PostgreSQL detected the cycle and aborted session {victim}; session {survivor} could continue.")
    {"A": A, "B": B}[victim].run("ROLLBACK")
    {"A": A, "B": B}[survivor].run("ROLLBACK", note="(demo only – nothing is kept)")

    log("\n-- Fix: every transaction locks its variants in the SAME order (ascending variant_id)")
    lock_sql = ("SELECT variant_id, sku FROM product_variant WHERE sku IN (%s, %s) "
                "ORDER BY variant_id FOR UPDATE")
    A.run("BEGIN")
    A.run(lock_sql, (SKU_X, SKU_Y), "A locks both, lowest id first")
    B.run("BEGIN")
    th, box = B.run_waiting(lock_sql, (SKU_Y, SKU_X), "B asks in the same order -> simply waits, no cycle")
    observe_wait(observer, B)
    A.run("ROLLBACK", note="A finishes (demo: nothing kept)")
    th.join()
    B.run("ROLLBACK")
    log("=> With a consistent lock order the second transaction waits instead of deadlocking.")

finally:
    # ------------------------------------------------------------------- cleanup
    header("CLEANUP: remove demo orders, restore the last pair")
    for s in (A, B):
        try:
            s.conn.execute("ROLLBACK")
        except Exception:
            pass
    if demo_orders:
        observer.execute("DELETE FROM stock_movement WHERE order_id = ANY(%s)", (demo_orders,))
        observer.execute("DELETE FROM customer_order WHERE order_id = ANY(%s)", (demo_orders,))  # lines cascade
    observer.execute("UPDATE product_variant SET stock_qty = 1, unit_price = %s WHERE sku = %s", (price_before, LAST_PAIR))
    log(f"deleted demo orders {demo_orders}; {LAST_PAIR} back to stock 1, price {price_before}")
    A.close(); B.close(); observer.close()
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text("\n".join(_log_lines) + "\n", encoding="utf-8")
    print(f"\nSaved to {OUT}")
