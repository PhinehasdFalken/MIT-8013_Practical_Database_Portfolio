# Portfolio 4 – NoSQL and Advanced Data Models

**Case study:** Finesse Klass. The **same data** as Portfolios 1–3 is migrated from PostgreSQL into two NoSQL models from Study Session 1 (§1.1.3.5):

| NoSQL type (course) | Product used | Finesse Klass use |
|---|---|---|
| **Document store**: "stores data as JSON-like documents… self-describing… highly flexible" | **MongoDB 7** | product catalogue (variants embedded, attributes that differ by category) and read-optimised order documents |
| **Key-value store**: "simple key-value pairs, offering extremely fast lookup times" | **Redis 7** | shopping carts, a drop-day stock counter, a page cache |

## 1. From relational to document model

| Relational (Portfolio 1) | Document model (MongoDB) | Why |
|---|---|---|
| `product` + `product_variant` + `category` (3 tables, joined) | **`products`**: one document per style, **variants embedded** as an array, category stored as a field | variants are always read with their product; at most 24 per product (bounded) |
| `customer` + `address` + `state` + `region` | **`customers`**: **addresses embedded** with state and region names | a customer has 1–2 addresses, always shown together |
| `customer_order` + `order_item` + `payment` + `delivery` + `bespoke_spec` (5 tables) | **`orders`**: one document holding items, payments, delivery and (bespoke only) measurements | an order is written once and then read as a whole: the customer's receipt, the courier label, the workshop ticket |
| price at sale in `order_item.unit_price` | items keep a **snapshot** (product name, size, colour, price) | the receipt must not change when the catalogue changes |
| FK `customer_id` | `customer: {id, name, phone}`: the id **plus** a small copy (extended reference) | the order list can show a name without a second lookup |

**Schema flexibility, shown with real documents** (`evidence/mongo_01_…`):
- **D1:** a boot has `attributes: {construction, shaft_height_cm, closure}`, while a sneaker has `{sole, closure, lining}`. In the relational model this would need extra tables or many NULL columns.
- **M5:** 19,946 bespoke orders *have* a `bespoke` sub-document; the other 230,056 simply *don't have the field*. No NULLs needed.
- `instagram` is **absent** for customers without a handle.

**Integrity is still possible:** a `$jsonSchema` validator restricts `status` and `type` to fixed lists, requires at least one item, keeps `stock` at 0 or above, and keeps `size_eu` within the EU 36–48 range. M6 and A3 show invalid writes being **rejected** ("Document failed validation").

**What the denormalisation costs:** product names and customer names are copied into every order. Mongo's *uncompressed* data size is 205 MB, against 91 MB of table data in PostgreSQL. Its compressed on-disk storage (WiredTiger) is only about 35–42 MB. If a product is renamed, old orders keep the old name. That is intended for receipts, but it means the copies are **not** a single source of truth. This is the redundancy that normalisation (Portfolio 1) removes. Here it is accepted *on purpose* for faster reads.

## 2. Queries – the same business questions as Portfolio 2

| # | Question | MongoDB feature | Result |
|---|---|---|---|
| M1 | order history of customer 1234 | `find` + `sort` on embedded field `customer.id` | each order arrives **complete** (items included): no join |
| M2 | Loafers in size 42 that are in stock | `$elemMatch` + `$filter` on the embedded `variants` array | 5 styles listed with colours and stock |
| M3 | monthly revenue per category, 2026 | aggregation pipeline `$match → $unwind → $group` | **identical** to PostgreSQL (e.g. Boots, Jan 2026 = ₦142,588,000.00 in both) |
| M4 | top-selling variants, last 90 days | `$unwind` + `$group` + `$sort` | top 5 variants |
| M5 | bespoke ostrich orders with a monogram | query on fields that exist only on some documents | 19,946 vs 230,056 documents |

## 3. Implementation evidence: indexing (`mongo/02_indexes_explain.js`)

The same physical-design rules as Portfolio 2 apply:

| Query | Before (no index) | After |
|---|---|---|
| M1 customer history | `SORT <- COLLSCAN`, **250,002** documents examined, ~100 ms | `FETCH <- IXSCAN(ix_customer_date)`, **24** examined, 2–3 ms |
| Q2 open orders, 30 days | `COLLSCAN`, 250,002 examined, ~115–170 ms | `IXSCAN(ix_status_date)`, 2,598 examined, 4 ms |
| product by SKU | `COLLSCAN` (120 documents) | `IXSCAN(ix_variant_sku)`: a **multikey** index that indexes every element of the embedded array, and is `unique` like `UNIQUE(sku)` in Portfolio 1 |

## 4. Concurrency in the document model (`mongo/03_atomic_stock.js`)

Because the variants are **inside** the product document, "check stock ≥ 1 *and* decrement" is **one atomic single-document update**:
```js
db.products.updateOne({ variants: { $elemMatch: { sku: "FK-027-44-WHI", stock: { $gte: 1 } } } },
                      { $inc: { "variants.$.stock": -1 } })
```
Kemi → `modified=1` (sold); Halima → `modified=0` (sold out). This is the same idea as fix S4 in Portfolio 3.

**Limitation:** a sale also creates an *order* document, which is a **second** document. Atomicity across documents needs a multi-document transaction (a replica set in MongoDB). The course notes that NoSQL systems often relax strict ACID in favour of availability and scale (BASE). So **payments and orders stay in PostgreSQL** (ACID), and MongoDB serves the catalogue.

## 5. Key-value model (`redis/redis_keyvalue_demo.py`)

| # | Key design | What it shows |
|---|---|---|
| K1 | `cart:<customer_id>` → HASH {SKU: qty}, `EXPIRE` 48 h | carts need speed, not durability; abandoned carts delete themselves (`TTL 172800`) |
| K2 | `drop:FK-LTD-01:stock` → integer, `DECR` | **8 buyers at the same moment, 5 pairs → exactly 5 sold, 3 refused**. Each Redis command runs one at a time, so `DECR` is atomic |
| K3 | `product:<id>` → JSON string, `EX 300` | cache-aside: miss ≈ 41 ms, hits ≈ 0.2 ms; the expiry gives **eventual consistency** (a price change shows up within 300 s) |

## 6. Suitability: which model for which part of Finesse Klass?

| Part of the business | Best fit | Reason (course concepts) |
|---|---|---|
| Orders, payments, stock ledger | **Relational (PostgreSQL)** | needs **ACID** across several tables. Course: ACID is "essential where data integrity and reliability are critical" |
| Product catalogue | **Document (MongoDB)** | flexible attributes per category; product + variants read as one unit; schema can change without migrations (a new "Loafers" field needs no `ALTER TABLE`) |
| Order history / receipts | Document (read copy) | one read returns a complete order; good for the customer's "My orders" page |
| Carts, sessions, drop-day counters, page cache | **Key-value (Redis)** | extremely fast lookups, built-in expiry, atomic counters; losing data in a crash is acceptable |
| "Customers who bought X also bought Y" (future) | Graph (e.g. Neo4j) | relationship traversal without joins (Study Session 5); not implemented here |

This **polyglot** design matches the course's conclusion that "no single database fits all scenarios". The choice depends on data characteristics, workload and consistency requirements.

## 7. How to run it

```bash
# 1. start MongoDB and Redis (inside this folder)
docker compose up -d

# 2. copy the Finesse Klass data from PostgreSQL into MongoDB (about 25 s)
pip install "psycopg[binary]" pymongo redis
python migrate_pg_to_mongo.py "postgresql://postgres:YOURPASSWORD@localhost:5432/finesse_klass" "mongodb://localhost:27017" > evidence/migration_output.txt

# 3. run the MongoDB scripts (the ./mongo folder is mounted at /scripts in the container)
docker exec fk-mongo mongosh finesse_klass --quiet --file /scripts/01_documents_and_queries.js > evidence/mongo_01_documents_and_queries_output.txt
docker exec fk-mongo mongosh finesse_klass --quiet --file /scripts/02_indexes_explain.js > evidence/mongo_02_indexes_explain_output.txt
docker exec fk-mongo mongosh finesse_klass --quiet --file /scripts/03_atomic_stock.js > evidence/mongo_03_atomic_stock_output.txt

# 4. key-value demo
python redis/redis_keyvalue_demo.py
```
Optional: install **MongoDB Compass**, connect to `mongodb://localhost:27017`, and take screenshots of a product document, an order document, and the *Explain Plan* tab for M1 (COLLSCAN before, IXSCAN after).

## 8. Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | MongoDB + Redis containers |
| `migrate_pg_to_mongo.py` | relational → document migration (with schema validators) |
| `mongo/01_documents_and_queries.js` | sample documents, M1–M6 |
| `mongo/02_indexes_explain.js` | COLLSCAN vs IXSCAN evidence |
| `mongo/03_atomic_stock.js` | atomic single-document stock update |
| `redis/redis_keyvalue_demo.py` | K1–K3 |
| `evidence/` | outputs of all runs (+ `screenshots/`) |
