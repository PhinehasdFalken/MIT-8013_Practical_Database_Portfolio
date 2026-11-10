-- =====================================================================
-- Portfolio 2 – optimisation experiments (run AFTER run_benchmark.py)
--   psql -U postgres -d finesse_klass -f sql/03_experiments.sql > evidence/experiments_output.txt
-- Each experiment tests one technique from Study Session 4 and prints the
-- plan BEFORE and AFTER, so the effect can be read directly from the output.
-- The script restores the database to its normal state at the end.
-- =====================================================================
SET search_path TO fk;
\pset pager off

-- ---------------------------------------------------------------------
\echo '=================================================================='
\echo 'E1  COVERING INDEX -> index-only scan (Q1)'
\echo '    Course: "When all required columns are included in the index, the'
\echo '    DBMS can avoid accessing the base table, reducing cost."'
\echo '=================================================================='
\echo '--- E1a  with idx_order_customer_date (key columns only): must visit the table'
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, order_date, status, total_amount
FROM customer_order WHERE customer_id = 1234 ORDER BY order_date DESC;

CREATE INDEX idx_order_customer_covering
    ON customer_order (customer_id, order_date DESC) INCLUDE (order_id, status, total_amount);
VACUUM (ANALYZE) customer_order;          -- updates the visibility map so index-only scans are possible

\echo '--- E1b  with covering index: Index Only Scan, Heap Fetches: 0'
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, order_date, status, total_amount
FROM customer_order WHERE customer_id = 1234 ORDER BY order_date DESC;
DROP INDEX idx_order_customer_covering;

-- ---------------------------------------------------------------------
\echo '=================================================================='
\echo 'E2  HASH vs B+ TREE: exact match vs range (payment.order_id)'
\echo '    Course: hashed organisation = "extremely fast lookup" for exact'
\echo '    match but "poor for range queries"; B+ trees support ranges.'
\echo '=================================================================='
\echo '--- E2a  exact match  -> hash index used'
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM payment WHERE order_id = 182733;
\echo '--- E2b  range (100 orders) with ONLY the hash index -> cannot be used, full scan'
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM payment WHERE order_id BETWEEN 182700 AND 182799;
CREATE INDEX idx_payment_order_btree ON payment (order_id);
ANALYZE payment;
\echo '--- E2c  same range with a B+ tree index -> index range scan'
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM payment WHERE order_id BETWEEN 182700 AND 182799;
\echo '--- E2d  index sizes: hash vs B+ tree on the same column'
SELECT indexrelname AS index_name, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes WHERE relname = 'payment' AND indexrelname LIKE 'idx_payment_order%';
DROP INDEX idx_payment_order_btree;

-- ---------------------------------------------------------------------
\echo '=================================================================='
\echo 'E3  QUERY REWRITING / SUBQUERY FLATTENING'
\echo '    Course: "a nested query can often be rewritten as a join".'
\echo '    Question: Lagos customers who have placed a bespoke order.'
\echo '=================================================================='
\echo '--- E3a  nested IN-subquery form'
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.customer_id, c.first_name, c.last_name
FROM customer c
WHERE c.customer_id IN (SELECT o.customer_id FROM customer_order o WHERE o.order_type = 'bespoke')
  AND c.customer_id IN (SELECT a.customer_id FROM address a WHERE a.state_id = 1 AND a.is_default);
\echo '--- E3b  hand-written JOIN form (compare plan shape and cost with E3a)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT DISTINCT c.customer_id, c.first_name, c.last_name
FROM customer c
JOIN address a        ON a.customer_id = c.customer_id AND a.state_id = 1 AND a.is_default
JOIN customer_order o ON o.customer_id = c.customer_id AND o.order_type = 'bespoke';
\echo '--- E3c  "customers who have NEVER ordered" written with NOT IN'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM customer c
WHERE c.customer_id NOT IN (SELECT customer_id FROM customer_order);
\echo '--- E3d  the same question rewritten with NOT EXISTS (anti-join)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM customer c
WHERE NOT EXISTS (SELECT 1 FROM customer_order o WHERE o.customer_id = c.customer_id);

-- ---------------------------------------------------------------------
\echo '=================================================================='
\echo 'E4  MEMORY USAGE (Q3 monthly revenue report)'
\echo '    Course: "If the memory is insufficient, the system may need to use'
\echo '    temporary disk storage, increasing the I/O cost."'
\echo '=================================================================='
\echo '--- E4a  work_mem = 4MB (default): look for "external merge  Disk"'
SET work_mem = '4MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT date_trunc('month', o.order_date)::date AS month, cat.category_name,
       sum(oi.quantity * oi.unit_price) AS revenue, count(DISTINCT o.order_id) AS orders
FROM customer_order o
JOIN order_item oi ON oi.order_id = o.order_id
JOIN product_variant v ON v.variant_id = oi.variant_id
JOIN product p ON p.product_id = v.product_id
JOIN category cat ON cat.category_id = p.category_id
WHERE o.order_date >= timestamp '2026-01-01' AND o.order_date < timestamp '2026-11-01'
  AND o.status <> 'cancelled'
GROUP BY 1, 2 HAVING sum(oi.quantity * oi.unit_price) > 0 ORDER BY 1, 2;
\echo '--- E4b  work_mem = 64MB: sort fits in memory'
SET work_mem = '64MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT date_trunc('month', o.order_date)::date AS month, cat.category_name,
       sum(oi.quantity * oi.unit_price) AS revenue, count(DISTINCT o.order_id) AS orders
FROM customer_order o
JOIN order_item oi ON oi.order_id = o.order_id
JOIN product_variant v ON v.variant_id = oi.variant_id
JOIN product p ON p.product_id = v.product_id
JOIN category cat ON cat.category_id = p.category_id
WHERE o.order_date >= timestamp '2026-01-01' AND o.order_date < timestamp '2026-11-01'
  AND o.status <> 'cancelled'
GROUP BY 1, 2 HAVING sum(oi.quantity * oi.unit_price) > 0 ORDER BY 1, 2;
RESET work_mem;

-- ---------------------------------------------------------------------
\echo '=================================================================='
\echo 'E5  MATERIALISED VIEW for the monthly report (Q3)'
\echo '    Course: results that are "frequently used and do not change often"'
\echo '    can be materialised (stored as actual tables).'
\echo '=================================================================='
CREATE MATERIALIZED VIEW mv_monthly_category_revenue AS
SELECT date_trunc('month', o.order_date)::date AS month, cat.category_name,
       sum(oi.quantity * oi.unit_price) AS revenue, count(DISTINCT o.order_id) AS orders
FROM customer_order o
JOIN order_item oi ON oi.order_id = o.order_id
JOIN product_variant v ON v.variant_id = oi.variant_id
JOIN product p ON p.product_id = v.product_id
JOIN category cat ON cat.category_id = p.category_id
WHERE o.status <> 'cancelled'
GROUP BY 1, 2;
CREATE INDEX ON mv_monthly_category_revenue (month);
ANALYZE mv_monthly_category_revenue;
\echo '--- E5a  the report now reads the pre-computed table'
EXPLAIN (ANALYZE, BUFFERS)
SELECT month, category_name, revenue, orders
FROM mv_monthly_category_revenue
WHERE month >= date '2026-01-01' AND month < date '2026-11-01'
ORDER BY 1, 2;
\echo '--- E5b  cost of keeping it current (run nightly, e.g. after close of business)'
\timing on
REFRESH MATERIALIZED VIEW mv_monthly_category_revenue;
\timing off

-- ---------------------------------------------------------------------
\echo '=================================================================='
\echo 'E6  STATISTICS & ESTIMATED vs ACTUAL ROWS (Q2)'
\echo '    Course: the optimiser uses "selectivity of predicates" and'
\echo '    "histograms or frequency distributions" to estimate row counts.'
\echo '=================================================================='
\echo '--- E6a  what the optimiser knows about status (most common values + frequencies)'
SELECT attname, most_common_vals, most_common_freqs
FROM pg_stats WHERE schemaname = 'fk' AND tablename = 'customer_order' AND attname = 'status';
\echo '--- E6b  selectivity of each predicate on its own vs together'
SELECT
  round(avg((status IN ('pending','paid','in_production'))::int)::numeric, 4)              AS sel_status,
  round(avg((order_date >= timestamp '2026-10-02')::int)::numeric, 4)                      AS sel_date,
  round(avg((status IN ('pending','paid','in_production'))::int)::numeric
      * avg((order_date >= timestamp '2026-10-02')::int)::numeric * count(*))              AS rows_if_independent,
  sum((status IN ('pending','paid','in_production') AND order_date >= timestamp '2026-10-02')::int) AS actual_rows
FROM customer_order;
\echo '--- E6c  Q2 filter on its own: compare "rows=" (estimate) with "actual ... rows="'
EXPLAIN (ANALYZE)
SELECT order_id FROM customer_order
WHERE status IN ('pending','paid','in_production') AND order_date >= timestamp '2026-10-02';

-- ---------------------------------------------------------------------
\echo '=================================================================='
\echo 'E7  CLUSTERED FILE ORGANISATION (only ONE physical order per table)'
\echo '    Course example: clustering Orders on customer_id puts one'
\echo '    customer''s orders in the same blocks. Trade-off: "only one field'
\echo '    can be used for clustering".'
\echo '=================================================================='
-- force a plain index path so heap block reads are visible
SET enable_indexonlyscan = off;
\echo '--- E7a  rows stored in DATE order (as loaded): one customer''s orders are scattered'
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, order_date, status, total_amount FROM customer_order WHERE customer_id = 1234;
\echo '--- E7b  last-week report in DATE order (data is naturally clustered by date)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*), sum(total_amount) FROM customer_order WHERE order_date >= timestamp '2026-10-25';

CLUSTER customer_order USING idx_order_customer_date;   -- physically re-order by customer
ANALYZE customer_order;

\echo '--- E7c  after CLUSTER by customer: the customer''s orders sit in 1-2 blocks'
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, order_date, status, total_amount FROM customer_order WHERE customer_id = 1234;
\echo '--- E7d  ...but the date-range report now touches many more blocks'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*), sum(total_amount) FROM customer_order WHERE order_date >= timestamp '2026-10-25';

-- restore the original (date) physical order so later portfolios are unaffected
CLUSTER customer_order USING idx_order_date;
ANALYZE customer_order;
RESET enable_indexonlyscan;
\echo '=== experiments finished; table restored to date order ==='
