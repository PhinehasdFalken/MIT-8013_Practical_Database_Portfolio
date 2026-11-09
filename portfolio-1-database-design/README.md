# Portfolio 1 – Database Design and Modelling

**Case study:** Finesse Klass, a bespoke and ready-to-wear shoe brand that sells through Instagram and WhatsApp (see the [root README](../README.md#selected-case-study) for the full case-study statement).

This portfolio follows the database design stages from Study Session 1 (§1.1.2):

| Stage (course)            | What was done here                                                                                      | File                                                                                      |
| ------------------------- | ------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| 1. Requirements analysis  | Users, data and operations of Finesse Klass identified                                                  | [root README](../README.md#selected-case-study)                                           |
| 2. Conceptual design      | ER diagram in Chen notation (entities, attributes, relationships, cardinalities)                        | `er-diagram/finesse_klass_er_chen.png`                                                    |
| 3. Logical design         | ER converted to a relational schema with PKs, FKs and constraints, then normalised to BCNF              | `sql/01_schema.sql`, `normalisation.md`, `er-diagram/finesse_klass_relational_schema.png` |
| 4. Physical design        | Deliberately left to **Portfolio 2** (indexes, clustering), where the effect of each choice is measured | `../portfolio-2-query-optimisation`                                                       |
| 6. Testing and evaluation | Data validation and integrity checks: 11 constraint tests, all correctly rejected                       | `sql/03_constraint_tests.sql`, `evidence/constraint_tests_output.txt`                     |

---

## 1. Conceptual model – ER diagram

![Chen ER diagram](er-diagram/finesse_klass_er_chen.png)

The diagram uses the notation listed in the course: **entity = rectangle**, **attribute = ellipse** (primary key underlined), **composite attribute = ellipse joined to ellipses** (`name` → `first_name`, `last_name`), **derived attribute = dashed ellipse** (`total_amount`), **relationship = diamond**.

Key relationships and cardinalities:

| Relationship                                 | Cardinality | Business meaning                                                                                                                                                                                                    |
| -------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CUSTOMER _Places_ CUSTOMER ORDER             | 1 : N       | a customer can place many orders; each order belongs to one customer                                                                                                                                                |
| CUSTOMER ORDER _Contains_ PRODUCT VARIANT    | **M : N**   | an order holds many shoes and a shoe appears in many orders. The relationship has its own attributes (`quantity`, `unit_price` at sale, `line_no`), so in the relational schema it becomes the **ORDER_ITEM** table |
| PRODUCT _Offered as_ PRODUCT VARIANT         | 1 : N       | one style (for example _Ikoyi Penny Loafer_) is sold in many size and colour combinations; stock is held per variant                                                                                                |
| CUSTOMER ORDER _Measured by_ BESPOKE SPEC    | 1 : 0..1    | only made-to-measure orders have foot measurements                                                                                                                                                                  |
| CUSTOMER ORDER _Paid by_ PAYMENT             | 1 : N       | a failed card attempt followed by a successful transfer gives two payment rows                                                                                                                                      |
| CUSTOMER ORDER _Fulfilled by_ DELIVERY       | 1 : 0..1    | an order has a delivery record once it is dispatched                                                                                                                                                                |
| REGION _Contains_ STATE _Located in_ ADDRESS | 1 : N : N   | used for delivery planning and, in Portfolio 5, for horizontal fragmentation                                                                                                                                        |

## 2. Logical model – relational schema

![Relational schema](er-diagram/finesse_klass_relational_schema.png)

This diagram is **generated from the live PostgreSQL catalogue** (`er-diagram/generate_schema_diagram.py`), so it always matches the DDL.

### Keys and constraints (the three kinds of integrity)

| Integrity type        | How it is enforced                                         | Example                                                                                                                                                         |
| --------------------- | ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Entity integrity      | every table has a `PRIMARY KEY`                            | `order_item` has the composite PK `(order_id, line_no)`                                                                                                         |
| Referential integrity | 14 `FOREIGN KEY`s                                          | `order_item.variant_id → product_variant`                                                                                                                       |
| Candidate keys        | `UNIQUE`                                                   | `customer.email`, `customer.phone`, `product_variant.sku`, `payment.reference`                                                                                  |
| Domain integrity      | `CHECK`, `NOT NULL`                                        | `size_eu BETWEEN 36 AND 48`, `stock_qty >= 0`, status lists                                                                                                     |
| Business rules        | composite FKs, a partial unique index, cross-column CHECKs | an order can only go to the customer's own address; one default address per customer; `delivered_at >= dispatched_at`; a successful payment must have `paid_at` |

## 3. Normalisation

The full derivation is in **[normalisation.md](normalisation.md)**. It starts from the unnormalised Instagram order sheet, shows the insertion, update and deletion anomalies, lists the functional dependencies, and goes through 1NF → 2NF → 3NF → BCNF. It also explains the one deliberate exception (`total_amount`, a stored derived attribute).

## 4. How to run it (step by step)

You need PostgreSQL 14 or newer (tested on 16). Open a terminal **inside this folder** (on Windows use **Command Prompt (cmd)** – see the note in the root README):

```bash
# 1. create an empty database (enter your postgres password when asked)
psql -U postgres -c "CREATE DATABASE finesse_klass"

# 2. create the tables, keys and constraints
psql -U postgres -d finesse_klass -f sql/01_schema.sql > evidence/schema_output.txt 2>&1

# 3. load the data (about 30 seconds; the file ends with a row count per table)
psql -U postgres -d finesse_klass -f sql/02_seed.sql > evidence/seed_output.txt 2>&1

# 4. prove the constraints work (every statement is supposed to fail)
psql -U postgres -d finesse_klass -f sql/03_constraint_tests.sql > evidence/constraint_tests_output.txt 2>&1

# 5. table list and the structure of the orders table
psql -U postgres -d finesse_klass -c "\dt fk.*" -c "\d fk.customer_order" > evidence/table_structure.txt
```

Open each `evidence/*.txt` file to check it, and run the same commands once without `> …` to take screenshots of the terminal.

If `psql` is "not recognised" on Windows, add `C:\Program Files\PostgreSQL\16\bin` to your PATH, or run the commands from the _SQL Shell (psql)_ that came with PostgreSQL.

Optional: regenerate the schema diagram (needs Graphviz):

```bash
pip install "psycopg[binary]"
python er-diagram/generate_schema_diagram.py "postgresql://postgres:YOURPASSWORD@localhost:5432/finesse_klass"
dot -Tpng -Gdpi=110 finesse_klass_relational_schema.dot -o er-diagram/finesse_klass_relational_schema.png
```

### Expected result of the seed (identical on every machine because of `setseed`)

| table           |   rows |     | table          |    rows |
| --------------- | -----: | --- | -------------- | ------: |
| customer        | 40,000 |     | customer_order | 250,000 |
| address         | 56,045 |     | order_item     | 341,643 |
| product         |    120 |     | payment        | 264,082 |
| product_variant |  2,400 |     | delivery       | 234,228 |
| bespoke_spec    | 19,945 |     | stock_movement |   2,317 |

## 5. Evidence

| File                                   | Shows                                                                            |
| -------------------------------------- | -------------------------------------------------------------------------------- |
| `evidence/schema_output.txt`           | DDL ran without errors                                                           |
| `evidence/seed_output.txt`             | row counts after loading                                                         |
| `evidence/table_structure.txt`         | `\dt` table list and `\d customer_order` (keys, checks, FKs)                     |
| `evidence/constraint_tests_output.txt` | 11 rejected violations (entity, referential, domain and business-rule integrity) |
| `evidence/screenshots/`                | screenshots of the same runs on my machine                                       |
