// =====================================================================
// Portfolio 4 – Finesse Klass document model: sample documents + queries
// Run: docker exec fk-mongo mongosh finesse_klass --quiet --file /scripts/01_documents_and_queries.js
// =====================================================================
const line = (t) => print("\n" + "=".repeat(70) + "\n" + t + "\n" + "=".repeat(70));

line("D1  One PRODUCT document – variants embedded, attributes differ by category");
printjson(db.products.findOne({ name: "Banana Island Chelsea Boot" },
  { name: 1, category: 1, material: 1, attributes: 1, variants: { $slice: 3 } }));
print("--- a product from another category has DIFFERENT attribute fields (schema flexibility):");
printjson(db.products.findOne({ name: "Banana Island Court Sneaker" }, { name: 1, attributes: 1, _id: 0 }));

line("D2  One ORDER document – items, payments, delivery (and bespoke measurements) embedded");
printjson(db.orders.findOne({ type: "bespoke", "payments.1": { $exists: true }, "bespoke.monogram": { $exists: true } }));

line("D3  Collection sizes");
["products", "customers", "orders"].forEach(c => print(c.padEnd(10), db[c].countDocuments()));

// ---------------------------------------------------------------------
line("M1  Customer-service lookup: order history of customer 1234 (≈ P2 Q1, but no joins needed)");
db.orders.find({ "customer.id": 1234 },
               { order_date: 1, status: 1, total: 1, "items.product": 1, "items.size_eu": 1 })
         .sort({ order_date: -1 }).limit(5).forEach(printjson);

line("M2  Catalogue: Loafers in size 42 that are in stock ($elemMatch on the embedded array)");
db.products.aggregate([
  { $match: { category: "Loafers", variants: { $elemMatch: { size_eu: 42, stock: { $gt: 0 } } } } },
  { $project: { _id: 0, name: 1,
      in_stock_42: { $filter: { input: "$variants", as: "v",
                                cond: { $and: [{ $eq: ["$$v.size_eu", 42] }, { $gt: ["$$v.stock", 0] }] } } } } },
  { $project: { name: 1, "in_stock_42.colour": 1, "in_stock_42.stock": 1 } },
  { $limit: 5 }
]).forEach(printjson);

line("M3  Management report: monthly revenue per category, Jan–Oct 2026 (≈ P2 Q3, aggregation pipeline)");
db.orders.aggregate([
  { $match: { order_date: { $gte: ISODate("2026-01-01"), $lt: ISODate("2026-11-01") },
              status: { $ne: "cancelled" } } },
  { $unwind: "$items" },
  { $group: { _id: { month: { $dateToString: { format: "%Y-%m", date: "$order_date" } },
                     category: "$items.category" },
              revenue: { $sum: { $multiply: ["$items.qty", "$items.unit_price"] } } } },
  { $sort: { "_id.month": 1, "_id.category": 1 } },
  { $limit: 12 }
]).forEach(d => print(d._id.month, d._id.category.padEnd(18), d.revenue.toString()));

line("M4  Merchandising: top 5 best-selling variants since 2026-08-03 (≈ P2 Q5)");
db.orders.aggregate([
  { $match: { order_date: { $gte: ISODate("2026-08-03") }, status: { $ne: "cancelled" } } },
  { $unwind: "$items" },
  { $group: { _id: { product: "$items.product", size: "$items.size_eu", colour: "$items.colour" },
              pairs_sold: { $sum: "$items.qty" } } },
  { $sort: { pairs_sold: -1 } },
  { $limit: 5 }
]).forEach(printjson);

line("M5  Flexible schema: bespoke orders in ostrich leather with a monogram (fields exist only on bespoke orders)");
print("orders that HAVE a bespoke section :", db.orders.countDocuments({ bespoke: { $exists: true } }));
print("orders WITHOUT one (no NULL columns):", db.orders.countDocuments({ bespoke: { $exists: false } }));
db.orders.find({ "bespoke.leather": "Ostrich", "bespoke.monogram": { $exists: true } },
               { _id: 1, "customer.name": 1, bespoke: 1 }).limit(3).forEach(printjson);

line("M6  Schema validation still protects key fields: inserting an order with an unknown status");
try {
  db.orders.insertOne({ _id: 999999999, order_date: new Date(), status: "lost", type: "standard",
                        customer: { id: 1 }, items: [{ sku: "X" }], total: NumberDecimal("100.00") });
  print("inserted (unexpected)");
} catch (e) { print("REJECTED:", e.errmsg || e.message); }
