# Normalisation – from the Instagram order sheet to BCNF

Study Session 1 (§1.1.7) describes normalisation as breaking large tables into smaller related ones. The goals are to remove redundancy, protect integrity and prevent **insertion, update and deletion anomalies**. The normal forms are applied one after another (1NF → 2NF → 3NF → BCNF). This file applies those steps to Finesse Klass.

---

## Step 0 – The unnormalised table (UNF)

Before a database, orders arriving through Instagram DMs are typed into a single spreadsheet, one row per order:

| order_no | date | customer | phone | instagram | delivery address | state | region | items | total | payments |
|---|---|---|---|---|---|---|---|---|---|---|
| 1001 | 02-Mar-26 | Amaka Eze | 0803 111 2222 | @amaka_eze | 12 Admiralty Way, Lekki | Lagos | South-West | Ikoyi Penny Loafer 42 Black ×1; Lekki Court Sneaker 43 White ×2 | 171,000 | FKP1001-1 card FAILED; FKP1001-2 transfer OK |
| 1002 | 02-Mar-26 | Tunde Bello | 0806 333 4444 | @tunde_b | 4 Aminu Kano Cres, Wuse | FCT | North-Central | Ikoyi Penny Loafer 44 Brown ×1 | 52,000 | FKP1002-1 card OK |
| 1003 | 05-Mar-26 | Amaka Eze | 0803 111 2222 | @amaka_eze | 12 Admiralty Way, Lekki | Lagos | South-West | Maitama Chelsea Boot 41 Tan ×1 (bespoke: 26.5 cm × 9.8 cm, ostrich) | 98,000 | FKP1003-1 transfer OK |

**Problems:**
- `items` and `payments` are **repeating groups**: several values are packed into one cell.
- `customer` is a **composite** value (first name + last name).
- Amaka's phone number, Instagram handle and address are written again on every order she places (**redundancy**).

---

## Step 1 – First Normal Form (1NF): make every value atomic

Course rule: 1NF ensures **atomicity**. Each cell holds one value, and there are no repeating groups.

- Split `customer` into `first_name` and `last_name`.
- Give each item its own row and split it into `sku` (product, size, colour), `qty` and `unit_price`.
- Move payments into their own rows (one row per payment attempt), because an order can have several attempts.

`ORDER_SHEET_1NF (order_no, sku, date, first_name, last_name, phone, instagram, street, city, state, region, product_name, category, material, size_eu, colour, qty, unit_price_at_sale, list_price, …)`
**Primary key = (order_no, sku)**

The table is now in 1NF, but the anomalies are still there:

| Anomaly | Example in the 1NF table |
|---|---|
| **Update** | Amaka changes her phone number. Every row for every item she has ever bought must be edited. If one row is missed, the data contradicts itself. |
| **Insertion** | A new style, the *Benin Suede Mule*, cannot be added to the catalogue until somebody orders it, because `order_no` is part of the key and cannot be NULL. |
| **Deletion** | If the only order for a size-47 boot is deleted, the business also loses the fact that this variant exists. |

### Functional dependencies (FDs) found in the data

```
FD1  order_no            → date, phone, street, city, state
FD2  phone               → first_name, last_name, instagram, email
FD3  sku                 → product_name, size_eu, colour, list_price
FD4  product_name        → category, material, base_price, bespoke_available
FD5  state               → region
FD6  (order_no, sku)     → qty, unit_price_at_sale
FD7  payment_reference   → order_no, method, amount, status, paid_at
FD8  order_no            → foot_length, foot_width, leather   (bespoke orders only)
```

---

## Step 2 – Second Normal Form (2NF): remove partial dependencies

Course rule: in 2NF, every non-key attribute depends on the **whole** primary key.

With key `(order_no, sku)`, FD1 and FD3 are **partial dependencies**: `date` depends on `order_no` alone, and `product_name` depends on `sku` alone. Each one gets its own relation:

```
ORDER      (order_no, date, phone, street, city, state, region, foot_length, foot_width, leather)
ORDER_LINE (order_no, sku, qty, unit_price_at_sale)
VARIANT    (sku, product_name, category, material, size_eu, colour, list_price, base_price)
PAYMENT    (payment_reference, order_no, method, amount, status, paid_at)
```

Only FD6 is left in `ORDER_LINE`, and it depends on the full key. The insertion anomaly is fixed: a new style can be added to `VARIANT` without an order.

---

## Step 3 – Third Normal Form (3NF): remove transitive dependencies

Course rule: 3NF **eliminates transitive dependencies**, where a non-key attribute depends on another non-key attribute.

| Relation | Transitive chain | Fix |
|---|---|---|
| ORDER | `order_no → phone → first_name, last_name, instagram` (FD2) | new **CUSTOMER** relation; ORDER keeps only a reference to the customer |
| ORDER | `order_no → street, city, state → region` (FD5) | new **ADDRESS** relation (a customer can save several addresses), plus **STATE (state → region)** and **REGION** |
| VARIANT | `sku → product_name → category, material, base_price` (FD4) | new **PRODUCT** relation, plus **CATEGORY** |
| ORDER | `foot_length`, `foot_width`, `leather` apply only to bespoke orders, so standard orders would carry NULLs | new **BESPOKE_SPEC** relation (1 : 0..1 with ORDER) |

The update anomaly is now fixed: Amaka's phone number is stored **once**, in CUSTOMER.

---

## Step 4 – Boyce-Codd Normal Form (BCNF)

Course rule: BCNF is a stricter form of 3NF. Every determinant must be a candidate key.

The determinants of each final relation:

| Relation | Determinants | Candidate keys | BCNF? |
|---|---|---|---|
| customer | customer_id, email, phone | customer_id, email, phone | ✅ |
| product_variant | variant_id, sku, (product_id, size_eu, colour) | all three | ✅ |
| order_item | (order_id, line_no), (order_id, variant_id) | both | ✅ |
| state | state_id, state_name | both | ✅ |
| payment | payment_id, reference | both | ✅ |
| address, product, customer_order, delivery, bespoke_spec, … | their primary key (and UNIQUE columns) | same | ✅ |

The only dependency that could break BCNF was `state → region` inside ADDRESS, and Step 3 already removed it. **The final schema is in BCNF.**

---

## Final relations (implemented in `sql/01_schema.sql`)

```
REGION        (region_id, region_name)
STATE         (state_id, state_name, region_id→REGION)
CUSTOMER      (customer_id, first_name, last_name, email, phone, instagram_handle, created_at)
ADDRESS       (address_id, customer_id→CUSTOMER, street, city, state_id→STATE, is_default)
CATEGORY      (category_id, category_name)
PRODUCT       (product_id, category_id→CATEGORY, product_name, material, base_price, bespoke_available, is_active)
PRODUCT_VARIANT (variant_id, product_id→PRODUCT, size_eu, colour, sku, unit_price, stock_qty)
CUSTOMER_ORDER(order_id, customer_id→CUSTOMER, address_id→ADDRESS, order_date, order_type, status, total_amount*)
ORDER_ITEM    (order_id→CUSTOMER_ORDER, line_no, variant_id→PRODUCT_VARIANT, quantity, unit_price)
BESPOKE_SPEC  (order_id→CUSTOMER_ORDER, foot_length_cm, foot_width_cm, leather_choice, monogram, notes)
PAYMENT       (payment_id, order_id→CUSTOMER_ORDER, reference, method, amount, status, paid_at)
DELIVERY      (delivery_id, order_id→CUSTOMER_ORDER, courier, tracking_no, dispatched_at, delivered_at)
STOCK_MOVEMENT(movement_id, variant_id→PRODUCT_VARIANT, change_qty, reason, order_id→CUSTOMER_ORDER, moved_at)
```

### Design decisions worth explaining

1. **Surrogate keys (`customer_id` and others) instead of phone or Instagram handle.** Customers change phone numbers and handles. A key that changes would have to be updated in every referencing table. Phone and email stay as **candidate keys** (UNIQUE).
2. **`order_item.unit_price` is not redundant.** It records the price *at the time of sale*, which is a different fact from today's catalogue price in `product_variant`. If it were removed, every old invoice would change whenever a price changed.
3. **`total_amount` (marked \*) is a deliberate, controlled exception.** It is a *derived attribute* (the dashed ellipse in the ER diagram), equal to the sum of the order lines. The course notes that "excessive normalisation can increase query complexity", so there is a balance to strike. Revenue reports read 250,000 orders often, so the total is stored once instead of being re-summed from about 340,000 order lines each time. To keep it from drifting, only the place-order transaction writes it (Portfolio 3).
4. **Composite foreign keys enforce rules the course lists under data integrity.** `(address_id, customer_id)` makes sure an order is delivered to the *ordering customer's* address. `(order_id, order_type)` makes sure only *bespoke* orders can have foot measurements. Both are proven in `evidence/constraint_tests_output.txt` (tests T6 and T7).
