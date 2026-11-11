"""
Portfolio 4 – KEY-VALUE store (Redis) for the fast, short-lived parts of Finesse Klass

Course: a key-value store "stores data as simple key-value pairs, offering extremely
fast lookup times" (example given: Redis). Used here for three things that do NOT need
joins or long-term durability but DO need speed:

  K1  Shopping cart per customer (a HASH under key cart:<customer_id>) that expires after 48 h
  K2  "Drop day" stock counter: a limited release of 5 pairs, sold with atomic DECR
  K3  Cache of a product page (JSON string with a 5-minute expiry) – cache-aside pattern

Usage:
  docker compose up -d
  pip install redis
  python redis/redis_keyvalue_demo.py            # Redis at localhost:6379
Output is printed AND saved to evidence/redis_demo_output.txt
"""
import json
import sys
import threading
import time
from pathlib import Path

import redis

r = redis.Redis(host=sys.argv[1] if len(sys.argv) > 1 else "localhost", port=6379, decode_responses=True)
OUT = Path(__file__).resolve().parent.parent / "evidence" / "redis_demo_output.txt"
lines = []


def log(text=""):
    print(text)
    lines.append(text)


def cmd(*args):
    """Run one Redis command and log it the way redis-cli would show it."""
    result = r.execute_command(*args)
    log(f"redis> {' '.join(str(a) for a in args)}")
    log(f"       {result}")
    return result


log(f"Redis {r.info()['redis_version']} – Finesse Klass key-value demo")

# --------------------------------------------------------------------------- K1
log("\n=== K1  Shopping cart for customer 1234 (Ngozi) – HASH: field = SKU, value = quantity")
r.delete("cart:1234")
cmd("HSET", "cart:1234", "FK-087-44-BUR", 1)            # Chelsea boot
cmd("HSET", "cart:1234", "FK-047-43-WHI", 1)            # sneaker
cmd("HINCRBY", "cart:1234", "FK-047-43-WHI", 1)         # changes her mind: 2 pairs of sneakers
cmd("HGETALL", "cart:1234")
cmd("EXPIRE", "cart:1234", 48 * 3600)                   # abandoned carts clean themselves up
cmd("TTL", "cart:1234")
cmd("HDEL", "cart:1234", "FK-087-44-BUR")               # removes the boot
cmd("HGETALL", "cart:1234")
log("-> At checkout the cart is turned into an ORDER inside a PostgreSQL transaction (Portfolio 3),")
log("   then deleted. Losing a cart in a crash is acceptable; losing an order is not.")

# --------------------------------------------------------------------------- K2
log("\n=== K2  Drop day: 'Lekki Court Sneaker – Limited White', 5 pairs, 8 buyers at the same moment")
cmd("SET", "drop:FK-LTD-01:stock", 5)
sold, refused = [], []
lock = threading.Lock()


def buyer(name):
    left = r.decr("drop:FK-LTD-01:stock")               # ATOMIC: check-and-decrement cannot interleave
    with lock:
        if left >= 0:
            sold.append(name)
        else:
            r.incr("drop:FK-LTD-01:stock")              # give back the over-decrement
            refused.append(name)


names = ["Amaka", "Tunde", "Kemi", "Musa", "Zainab", "Femi", "Halima", "Obinna"]
threads = [threading.Thread(target=buyer, args=(n,)) for n in names]
for t in threads: t.start()
for t in threads: t.join()
log(f"8 concurrent DECR calls -> sold to {len(sold)}: {sorted(sold)}")
log(f"                          refused {len(refused)}: {sorted(refused)}")
cmd("GET", "drop:FK-LTD-01:stock")
log("-> Exactly 5 pairs sold, never 6: Redis executes each command one at a time, so DECR is atomic.")
log("   (Same guarantee as the atomic conditional UPDATE in Portfolio 3 S4, but in memory.)")

# --------------------------------------------------------------------------- K3
log("\n=== K3  Cache-aside for a product page (key product:<id>, JSON value, 300 s expiry)")
r.delete("product:87")


def get_product_page(pid):
    t0 = time.perf_counter()
    cached = r.get(f"product:{pid}")
    if cached:
        return json.loads(cached), "HIT ", (time.perf_counter() - t0) * 1000
    time.sleep(0.040)   # stands in for the ~40 ms catalogue query + page assembly on a cache miss
    page = {"id": pid, "name": "Banana Island Chelsea Boot", "price": 57200, "sizes": list(range(39, 47))}
    r.set(f"product:{pid}", json.dumps(page), ex=300)
    return page, "MISS", (time.perf_counter() - t0) * 1000


for i in range(3):
    page, status, ms = get_product_page(87)
    log(f"request {i + 1}: cache {status}  {ms:6.2f} ms")
cmd("TTL", "product:87")
log("-> First request builds the page and stores it; later requests are served from memory until it expires.")
log("   Expiry gives EVENTUAL consistency: a price change is visible on the page within 300 s at most.")

# --------------------------------------------------------------------------- summary
log("\n=== Keys in this demo")
for k in sorted(r.scan_iter("*")):
    log(f"{k:<26} type={r.type(k):<7} ttl={r.ttl(k)}")

OUT.parent.mkdir(exist_ok=True)
OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"\nSaved to {OUT}")
