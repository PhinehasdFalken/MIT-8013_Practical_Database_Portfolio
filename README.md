# Advanced Database Systems Portfolio – Finesse Klass

**Course:** MIT 8103 Advanced Database Systems – First Semester Continuous Assessment, 2026/2027
**Student:** Uchegbu Phinehas Kosisor – 301919344
**Programme:** Master of Information Technology, Miva Open University

---

## Selected case study

**Organisation:** **Finesse Klass**, a Nigerian shoe brand that sells ready-to-wear and **bespoke (made-to-measure)** men's and women's shoes. Most orders start as Instagram direct messages and are delivered nationwide. The brand is real (it is my own business); the volumes and records in this portfolio are **simulated** with a deterministic generator, so no real customer data is used.

| Item | Description |
|---|---|
| **Nature of the business** | Online fashion retail: a catalogue of styles (loafers, brogues, sneakers, slides, boots, mules), each sold in many size/colour variants with limited stock per size, plus bespoke orders built from the customer's foot measurements in a workshop |
| **Users of the database** | *Owner / DBA* (catalogue, pricing, reports); *customer-care staff* who turn Instagram DMs into orders and answer "where is my order?"; *workshop staff* (bespoke specifications, production status); *dispatch staff* (couriers, tracking numbers); *finance* (payments, failed and reversed payments, reconciliation); *customers* (checkout, order history) |
| **Major data stored** | customers and delivery addresses (state → geopolitical region); categories, products and variants (size, colour, SKU, price, stock); orders and order lines; bespoke measurements; payments (card, transfer, POS, USSD; failed attempts kept); deliveries; a stock-movement audit trail |
| **Key operations supported** | place an order and take stock (without ever selling the same last pair twice); record payments and retries; capture bespoke measurements; dispatch and track deliveries; look up a customer's order history; daily operations dashboard of open orders; monthly revenue by category; best-sellers; low-stock alerts |
| **Simulated scale** | 40,000 customers · 120 styles / 2,400 variants · 250,000 orders (Jan 2024 – Oct 2026) · 341,643 order lines · 264,082 payments |

The same case study and the same data are used in **all five portfolio activities**.

## Portfolio overview

| # | Activity | Highlights | Folder |
|---|---|---|---|
| 1 | Database Design and Modelling | Chen ER diagram, 13-table schema with PK/FK/CHECK/composite-FK rules, normalisation from the Instagram order sheet to **BCNF**, 11 integrity tests | [portfolio-1-database-design](portfolio-1-database-design/) |
| 2 | Query Processing and Optimisation | 6-query workload benchmarked before/after physical design (**hundreds of times faster** for selective lookups, e.g. 2,942 → 2 buffers), plus 7 experiments: covering index, hash vs B+ tree, rewriting, memory, materialised view (thousands of times faster), statistics, clustering trade-off | [portfolio-2-query-optimisation](portfolio-2-query-optimisation/) |
| 3 | Transactions and Concurrency | COMMIT, automatic and explicit ROLLBACK, SAVEPOINT, crash-recovery durability test; **"last pair" lost update** reproduced with two sessions and fixed three ways (locking, isolation, atomic update); isolation anomalies; deadlock and fix | [portfolio-3-transactions-concurrency](portfolio-3-transactions-concurrency/) |
| 4 | NoSQL and Advanced Data Models | the same data in a MongoDB **document** model (embedded variants and items, flexible attributes, schema validation, COLLSCAN → IXSCAN, atomic single-document stock update) and a Redis **key-value** model (carts, drop-day counter, cache) | [portfolio-4-nosql](portfolio-4-nosql/) |
| 5 | Distributed and Cloud Database | 4-node cluster: streaming replication, **delayed replica** (stale reads → eventual consistency), **async vs sync under a network partition (CAP)**, failover; horizontal fragmentation with one fragment on a **remote site**, vertical fragmentation; cloud deployment discussion | [portfolio-5-distributed-cloud](portfolio-5-distributed-cloud/) |

Each folder has its own **README** that explains what was done, why (with the related course concept), how to run it, and where the evidence is.

## Repository structure

```
advanced-database-portfolio/
├── portfolio-1-database-design/        sql/ (schema, seed, constraint tests), er-diagram/, normalisation.md, evidence/
├── portfolio-2-query-optimisation/     sql/ (workload, indexes, experiments), run_benchmark.py, evidence/ (plans, chart)
├── portfolio-3-transactions-concurrency/ sql/ (commit, rollback, savepoint), concurrency_demo.py, evidence/
├── portfolio-4-nosql/                  docker-compose.yml, migrate_pg_to_mongo.py, mongo/, redis/, evidence/
├── portfolio-5-distributed-cloud/      docker-compose.yml, docker/, sql/ (fragmentation), distributed_demo.py, evidence/
├── docs/                               AI use declaration, technical reflection
├── requirements.txt                    Python packages used by the scripts
└── README.md
```

## Set-up

| Tool | Used for | Version tested |
|---|---|---|
| PostgreSQL | Portfolios 1–3 (local install) | 16 (any 14+ works) |
| Docker Desktop | MongoDB + Redis (P4), 4-node PostgreSQL cluster (P5) | Docker Engine 24+ with Compose v2 |
| Python | benchmark, concurrency demo, migration, distributed demo | 3.10+ |
| Graphviz (optional) | re-rendering the diagrams | 2.43+ |

```bash
pip install -r requirements.txt
```

**Run order:** P1 (creates and loads `finesse_klass`) → P2 → P3 → P4 → P5. Every folder's README lists the exact commands.

**Windows note:** run the commands in **Command Prompt (cmd)**. In *Windows PowerShell 5*, `>` saves files as UTF-16, which GitHub cannot display properly. In *Git Bash*, the container paths such as `/p1/...` get rewritten. Command Prompt avoids both problems.

## Evidence

Every script writes its output into the `evidence/` folder of its portfolio: execution plans, benchmark tables, two-session timelines, Mongo `explain()` output, replication logs. Screenshots of the same runs on my machine are in each `evidence/screenshots/` folder.

## References

- Miva Open University (2025). *MIT 8103 Advanced Database Systems* [course material], Study Sessions 1–6.
- Elmasri, R. & Navathe, S. B. (2016). *Fundamentals of Database Systems* (7th ed.). Pearson.
- Silberschatz, A., Korth, H. F. & Sudarshan, S. (2020). *Database System Concepts* (7th ed.). McGraw-Hill Education.
- Özsu, M. T. & Valduriez, P. (2020). *Principles of Distributed Database Systems* (4th ed.). Springer.
- Brewer, E. A. (2012). CAP twelve years later: How the "rules" have changed. *Computer*, 45(2), 23–29.
- PostgreSQL Global Development Group (2024). *PostgreSQL 16 Documentation: Query planning*.
- Nigeria Data Protection Commission (2023). *Nigeria Data Protection Act (NDPA) 2023*.

(The non-course references are those listed in the course material's own reference list.)

## AI use declaration

See [docs/AI_USE_DECLARATION.md](docs/AI_USE_DECLARATION.md).
