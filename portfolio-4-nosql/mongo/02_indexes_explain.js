// =====================================================================
// Portfolio 4 – indexing in the document store (links back to Portfolio 2)
// Run: docker exec fk-mongo mongosh finesse_klass --quiet --file /scripts/02_indexes_explain.js
// =====================================================================
const line = (t) => print("\n" + "=".repeat(70) + "\n" + t + "\n" + "=".repeat(70));
const summary = (label, exp) => {
  const s = exp.executionStats;
  let stage = exp.queryPlanner.winningPlan;
  const stages = [];
  while (stage) { stages.push(stage.stage + (stage.indexName ? `(${stage.indexName})` : "")); stage = stage.inputStage; }
  print(`${label.padEnd(34)} plan=${stages.join(" <- ").padEnd(46)} docsExamined=${String(s.totalDocsExamined).padStart(7)}`
        + ` keysExamined=${String(s.totalKeysExamined).padStart(6)} returned=${String(s.nReturned).padStart(5)} time=${s.executionTimeMillis} ms`);
};

// start from a clean state (only the default _id index)
db.orders.dropIndexes();
db.products.dropIndexes();

const q1 = () => db.orders.find({ "customer.id": 1234 }).sort({ order_date: -1 });
const q2 = () => db.orders.find({ status: { $in: ["pending", "paid", "in_production"] },
                                 order_date: { $gte: ISODate("2026-10-02") } });
const q3 = () => db.products.find({ variants: { $elemMatch: { sku: "FK-027-44-WHI" } } });

line("I1  BEFORE indexing – every query is a COLLSCAN (full collection scan)");
summary("M1 order history (customer 1234)", q1().explain("executionStats"));
summary("Q2 open orders, last 30 days", q2().explain("executionStats"));
summary("lookup product by variant SKU", q3().explain("executionStats"));

db.orders.createIndex({ "customer.id": 1, order_date: -1 }, { name: "ix_customer_date" });
db.orders.createIndex({ status: 1, order_date: 1 }, { name: "ix_status_date" });          // same idea as P2
db.products.createIndex({ "variants.sku": 1 }, { name: "ix_variant_sku", unique: true }); // multikey index on an embedded array

line("I2  AFTER indexing – IXSCAN on B-tree indexes (same design rules as Portfolio 2)");
summary("M1 order history (customer 1234)", q1().explain("executionStats"));
summary("Q2 open orders, last 30 days", q2().explain("executionStats"));
summary("lookup product by variant SKU", q3().explain("executionStats"));

line("I3  Indexes now on the collections");
db.orders.getIndexes().forEach(i => print("orders  ", i.name, JSON.stringify(i.key)));
db.products.getIndexes().forEach(i => print("products", i.name, JSON.stringify(i.key), i.unique ? "unique" : ""));
print("\nNote: 'variants.sku' is a MULTIKEY index – MongoDB indexes every element of the embedded array,");
print("so a SKU inside any product document is found directly, like the UNIQUE(sku) constraint in Portfolio 1.");
