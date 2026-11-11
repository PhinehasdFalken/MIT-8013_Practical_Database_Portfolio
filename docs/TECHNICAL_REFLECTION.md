# Individual Technical Reflection

## Design choices

I chose **Finesse Klass**, my own shoe brand, because I know its data problems first-hand. Orders arrive as Instagram and WhatsAppp DMs, many sizes have only one or two pairs left, and bespoke orders carry measurements that standard orders do not. Those three facts shaped most of the decisions:

- **Product vs variant.** Stock belongs to a _size and colour of a style_, not to the style. Separating `product` from `product_variant` is what lets the database protect the last pair with a simple `CHECK (stock_qty >= 0)`.
- **Composite foreign keys for business rules.** I did not want to rely on the application to stop an order from being delivered to _another_ customer's address, or measurements from being attached to a standard order. Two composite FKs make the database enforce both.
- **One deliberate departure from full normalisation.** `total_amount` is a stored derived attribute. Normalisation removes redundancy, but the course also warns that over-normalising makes queries complex. The total is written in exactly one place (the order transaction), which keeps the redundancy under control.

## What the measurements taught me

- **Indexes are not automatically good.** They made selective lookups hundreds of times faster (Q1, Q4), but almost nothing for reports that read a large share of the table (Q3, Q5). For the 22-page variant table (Q6), an index saved no I/O and would only slow down every sale. Reading the plans, not just the timings, showed me _why_: low selectivity, or a bottleneck that moved to the joins.
- **The optimiser had already done my rewrite.** Turning an `IN` subquery into a `JOIN` by hand brought no reliable gain, because PostgreSQL had already flattened the subquery into a semi-join. Rewriting `NOT IN` as `NOT EXISTS` did help (about 2×). "Rewriting" has to be measured, not assumed.
- **Statistics can mislead the optimiser.** The open-orders dashboard was estimated at about 80 rows but returned 2,596. Open orders are always recent, so the two conditions are correlated, and per-column statistics assume they are independent. Before this I had only seen this in theory.
- **There is only one physical order.** Clustering the orders by customer made a customer's history 6× cheaper to read but the weekly report 48× more expensive. That is a concrete version of the course's "only one clustering field".

## Challenges

- **Reproducing a race condition on demand.** A lost update only happens if two transactions interleave in a particular order. I needed a script that drives two sessions step by step, with an observer session to prove a session was _waiting on a lock_, not just slow.
- **Understanding CAP as a dial, not a label.** The same PostgreSQL cluster behaved like an "AP" system with asynchronous replication and like a "CP" system with synchronous replication. During the simulated partition, the synchronous commit simply waited. That made it clear the choice is made per workload: payments versus catalogue reads.
- **Keeping the NoSQL model honest.** Embedding items and customer names in order documents made reads simple, but it re-introduced the redundancy I had normalised away in Portfolio 1. MongoDB's single-document atomicity also does not cover "decrement stock _and_ create the order". That is why payments stay in the relational database.

## Lessons for my own work

As a backend developer I usually let the ORM decide. After this portfolio I will (1) read `EXPLAIN (ANALYZE, BUFFERS)` before adding an index, (2) never write stock with a value computed in application code, but always with an atomic conditional update, (3) choose replication mode per kind of data, and (4) use different data models where they fit — relational for money, document for the catalogue, key-value for carts — instead of forcing one database to do everything.
