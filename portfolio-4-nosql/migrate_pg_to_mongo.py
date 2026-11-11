"""
Portfolio 4 – move the SAME Finesse Klass data from PostgreSQL (Portfolio 1)
into a MongoDB DOCUMENT model.

Relational (13 tables, joined at query time)  ->  Document (3 collections, data that is
read together is stored together):

  products   – one document per style; its size/colour VARIANTS are EMBEDDED,
               plus a flexible "attributes" sub-document that differs per category
  customers  – one document per customer; ADDRESSES are EMBEDDED
  orders     – one document per order; ITEMS, PAYMENTS, DELIVERY and (bespoke only)
               MEASUREMENTS are EMBEDDED; a small snapshot of the customer and the
               delivery address is copied in

Usage:
  docker compose up -d
  pip install "psycopg[binary]" pymongo
  python migrate_pg_to_mongo.py "postgresql://postgres:YOURPASSWORD@localhost:5432/finesse_klass" "mongodb://localhost:27017"
"""
import sys
import time
from datetime import datetime
from decimal import Decimal

import psycopg
from bson.decimal128 import Decimal128
from pymongo import MongoClient

PG = sys.argv[1] if len(sys.argv) > 1 else "postgresql://postgres@localhost:5432/finesse_klass"
MONGO = sys.argv[2] if len(sys.argv) > 2 else "mongodb://localhost:27017"
BATCH = 5000


def money(x):
    return Decimal128(Decimal(str(x)).quantize(Decimal("0.01"))) if x is not None else None


def ts(x):
    return datetime.fromisoformat(x) if isinstance(x, str) else x


# Category-specific attributes: the same "product" has DIFFERENT fields per category.
# In the relational model this would need extra tables or many NULL columns.
CATEGORY_ATTRS = {
    "Loafers":           lambda pid: {"construction": "Blake-stitched", "sole": "leather", "heel_height_cm": 2.5},
    "Oxfords & Brogues": lambda pid: {"construction": "Goodyear-welted", "sole": "leather", "lacing": "closed",
                                      "brogueing": ["full", "semi", "quarter"][pid % 3]},
    "Sneakers":          lambda pid: {"sole": "rubber cupsole", "closure": "laces", "lining": "leather"},
    "Sandals & Slides":  lambda pid: {"sole": "rubber", "strap": ["single", "double", "crossover"][pid % 3]},
    "Boots":             lambda pid: {"construction": "Goodyear-welted", "shaft_height_cm": 14 + pid % 4,
                                      "closure": "elastic side panels"},
    "Mules":             lambda pid: {"sole": "leather", "backless": True, "heel_height_cm": 1.5},
}

PRODUCTS_SQL = """
SELECT p.product_id, p.product_name, c.category_name, p.material, p.base_price, p.bespoke_available, p.is_active,
       json_agg(json_build_object('sku', v.sku, 'size_eu', v.size_eu, 'colour', v.colour,
                                  'price', v.unit_price, 'stock', v.stock_qty) ORDER BY v.size_eu, v.colour)
FROM fk.product p JOIN fk.category c USING (category_id) JOIN fk.product_variant v USING (product_id)
GROUP BY p.product_id, c.category_name ORDER BY p.product_id
"""
CUSTOMERS_SQL = """
SELECT cu.customer_id, cu.first_name, cu.last_name, cu.email, cu.phone, cu.instagram_handle, cu.created_at,
       json_agg(json_build_object('address_id', a.address_id, 'street', a.street, 'city', a.city,
                                  'state', s.state_name, 'region', r.region_name, 'is_default', a.is_default)
                ORDER BY a.is_default DESC, a.address_id)
FROM fk.customer cu JOIN fk.address a USING (customer_id)
JOIN fk.state s USING (state_id) JOIN fk.region r USING (region_id)
GROUP BY cu.customer_id ORDER BY cu.customer_id
"""
ORDERS_SQL = """
SELECT o.order_id, o.order_date, o.order_type, o.status, o.total_amount,
       cu.customer_id, cu.first_name, cu.last_name, cu.phone,
       a.street, a.city, s.state_name, r.region_name,
       (SELECT json_agg(json_build_object('line_no', oi.line_no, 'sku', v.sku, 'product', p.product_name,
                                          'category', c.category_name, 'size_eu', v.size_eu, 'colour', v.colour,
                                          'qty', oi.quantity, 'unit_price', oi.unit_price) ORDER BY oi.line_no)
          FROM fk.order_item oi JOIN fk.product_variant v USING (variant_id)
          JOIN fk.product p USING (product_id) JOIN fk.category c USING (category_id)
         WHERE oi.order_id = o.order_id),
       (SELECT json_agg(json_build_object('reference', pa.reference, 'method', pa.method, 'amount', pa.amount,
                                          'status', pa.status, 'paid_at', pa.paid_at) ORDER BY pa.reference)
          FROM fk.payment pa WHERE pa.order_id = o.order_id),
       d.courier, d.tracking_no, d.dispatched_at, d.delivered_at,
       b.foot_length_cm, b.foot_width_cm, b.leather_choice, b.monogram, b.notes
FROM fk.customer_order o
JOIN fk.customer cu USING (customer_id)
JOIN fk.address a ON a.address_id = o.address_id
JOIN fk.state s ON s.state_id = a.state_id
JOIN fk.region r ON r.region_id = s.region_id
LEFT JOIN fk.delivery d ON d.order_id = o.order_id
LEFT JOIN fk.bespoke_spec b ON b.order_id = o.order_id
ORDER BY o.order_id
"""


def main():
    t0 = time.time()
    mongo = MongoClient(MONGO)
    db = mongo["finesse_klass"]
    for name in ("products", "customers", "orders"):
        db.drop_collection(name)

    # A document store is schema-flexible, but MongoDB can still VALIDATE the fields that
    # must never be wrong (domain integrity, as in Portfolio 1).
    db.create_collection("orders", validator={"$jsonSchema": {
        "bsonType": "object",
        "required": ["_id", "order_date", "status", "type", "customer", "items", "total"],
        "properties": {
            "status": {"enum": ["pending", "paid", "in_production", "dispatched", "delivered", "cancelled"]},
            "type": {"enum": ["standard", "bespoke"]},
            "items": {"bsonType": "array", "minItems": 1},
            "total": {"bsonType": "decimal"},
        }}})
    db.create_collection("products", validator={"$jsonSchema": {
        "bsonType": "object", "required": ["_id", "name", "category", "variants"],
        "properties": {"variants": {"bsonType": "array", "items": {
            "bsonType": "object", "required": ["sku", "size_eu", "stock"],
            "properties": {"size_eu": {"bsonType": "int", "minimum": 36, "maximum": 48},
                           "stock": {"bsonType": "int", "minimum": 0}}}}}}})

    with psycopg.connect(PG) as pg:
        # ---------------- products
        docs = []
        for pid, name, cat, material, base, bespoke, active, variants in pg.execute(PRODUCTS_SQL):
            docs.append({
                "_id": pid, "name": name, "category": cat, "material": material,
                "base_price": money(base), "bespoke_available": bespoke, "active": active,
                "attributes": CATEGORY_ATTRS[cat](pid),
                "variants": [{"sku": v["sku"], "size_eu": v["size_eu"], "colour": v["colour"],
                              "price": money(v["price"]), "stock": v["stock"]} for v in variants],
            })
        db.products.insert_many(docs)
        print(f"products : {len(docs):>7,} documents ({sum(len(d['variants']) for d in docs):,} embedded variants)")

        # ---------------- customers
        n = 0
        batch = []
        for cid, fn, ln, email, phone, ig, created, addrs in pg.execute(CUSTOMERS_SQL):
            doc = {"_id": cid, "name": {"first": fn, "last": ln}, "email": email, "phone": phone,
                   "created_at": created, "addresses": addrs}
            if ig:                                   # field simply absent when unknown – no NULL needed
                doc["instagram"] = ig
            batch.append(doc)
            if len(batch) == BATCH:
                db.customers.insert_many(batch); n += len(batch); batch = []
        if batch:
            db.customers.insert_many(batch); n += len(batch)
        print(f"customers: {n:>7,} documents")

        # ---------------- orders (server-side cursor: rows are streamed, not loaded all at once)
        n = 0
        batch = []
        with pg.cursor(name="orders_cur") as cur:
            cur.itersize = BATCH
            cur.execute(ORDERS_SQL)
            for (oid, odate, otype, status, total, cid, fn, ln, phone, street, city, state, region,
                 items, payments, courier, tracking, dispatched, delivered,
                 foot_len, foot_w, leather, monogram, notes) in cur:
                doc = {
                    "_id": oid, "order_date": odate, "type": otype, "status": status, "total": money(total),
                    "customer": {"id": cid, "name": f"{fn} {ln}", "phone": phone},           # extended reference
                    "ship_to": {"street": street, "city": city, "state": state, "region": region},  # snapshot
                    "items": [{**i, "unit_price": money(i["unit_price"])} for i in (items or [])],
                    "payments": [{**p, "amount": money(p["amount"]), "paid_at": ts(p["paid_at"])}
                                 for p in (payments or [])],
                }
                if courier:
                    doc["delivery"] = {"courier": courier, "tracking_no": tracking,
                                       "dispatched_at": dispatched, "delivered_at": delivered}
                if otype == "bespoke" and foot_len is not None:                    # only bespoke orders
                    doc["bespoke"] = {"foot_length_cm": float(foot_len), "foot_width_cm": float(foot_w),
                                      "leather": leather}
                    if monogram:
                        doc["bespoke"]["monogram"] = monogram
                    if notes:
                        doc["bespoke"]["notes"] = notes
                batch.append(doc)
                if len(batch) == BATCH:
                    db.orders.insert_many(batch, ordered=False); n += len(batch); batch = []
        if batch:
            db.orders.insert_many(batch, ordered=False); n += len(batch)
        print(f"orders   : {n:>7,} documents")

    print(f"done in {time.time() - t0:.1f} s")
    stats = db.command("dbStats")
    print(f"MongoDB data size: {stats['dataSize'] / 1e6:.1f} MB, storage: {stats['storageSize'] / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
