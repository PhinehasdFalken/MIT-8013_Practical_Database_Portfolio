// =====================================================================
// Portfolio 4 – the "last pair" problem (Portfolio 3) in the document store
// Run: docker exec fk-mongo mongosh finesse_klass --quiet --file /scripts/03_atomic_stock.js
//
// In MongoDB a write to ONE document is atomic. Because the variants are
// embedded in the product document, "check stock >= 1 AND decrement it" can be
// a single conditional update – the same idea as fix S4 in Portfolio 3.
// =====================================================================
const SKU = "FK-027-44-WHI";
const line = (t) => print("\n" + "=".repeat(70) + "\n" + t + "\n" + "=".repeat(70));
const stockOf = () => db.products.findOne({ "variants.sku": SKU }, { _id: 0, "variants.$": 1 }).variants[0].stock;

db.products.updateOne({ "variants.sku": SKU }, { $set: { "variants.$.stock": 1 } });
line(`A1  Setup: ${SKU} has ${stockOf()} pair left`);

// the condition (stock >= 1) and the change ($inc -1) are evaluated together, atomically
const buyLastPair = (customer) => {
  const res = db.products.updateOne(
    { variants: { $elemMatch: { sku: SKU, stock: { $gte: 1 } } } },
    { $inc: { "variants.$.stock": -1 } });
  print(`${customer.padEnd(8)} matched=${res.matchedCount} modified=${res.modifiedCount} -> `
        + (res.modifiedCount === 1 ? "SOLD to " + customer : "sold out, no order created"));
  return res.modifiedCount === 1;
};

line("A2  Two customers try to buy it");
buyLastPair("Kemi");
buyLastPair("Halima");
print("stock now:", stockOf());

line("A3  The schema validator is a second safety net: stock can never go below 0");
try {
  db.products.updateOne({ "variants.sku": SKU }, { $inc: { "variants.$.stock": -1 } });
  print("updated (unexpected)");
} catch (e) { print("REJECTED:", e.errmsg || e.message); }
print("stock still:", stockOf());

line("A4  Limitation (and why payments stay in PostgreSQL)");
print("A sale touches the PRODUCT document (stock) AND creates an ORDER document. Those are TWO documents.");
print("Atomicity across several documents needs a multi-document transaction, which in MongoDB requires a");
print("replica set and costs performance - the BASE trade-off described in the course. Finesse Klass therefore");
print("keeps orders/payments in the ACID relational database (Portfolio 3) and uses MongoDB for the catalogue.");

db.products.updateOne({ "variants.sku": SKU }, { $set: { "variants.$.stock": 1 } });   // restore
