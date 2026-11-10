-- =====================================================================
-- Portfolio 2 – the Finesse Klass workload (6 business queries)
-- Each query is preceded by a marker line "-- @Qn | title | course concept"
-- that run_benchmark.py uses to find it. You can also paste any query
-- into psql / pgAdmin with EXPLAIN (ANALYZE, BUFFERS) in front of it.
-- =====================================================================

-- @Q1 | Customer-service lookup: one customer's order history | equality search on a FK column
SELECT o.order_id, o.order_date, o.status, o.total_amount
FROM customer_order o
WHERE o.customer_id = 1234
ORDER BY o.order_date DESC;

-- @Q2 | Operations dashboard: open orders from the last 30 days with customer and state | multi-column (composite) index + joins
SELECT o.order_id, o.order_date, o.status, c.first_name, c.last_name, c.phone, s.state_name
FROM customer_order o
JOIN customer c ON c.customer_id = o.customer_id
JOIN address  a ON a.address_id  = o.address_id
JOIN state    s ON s.state_id    = a.state_id
WHERE o.status IN ('pending', 'paid', 'in_production')
  AND o.order_date >= timestamp '2026-10-02'
ORDER BY o.order_date;

-- @Q3 | Management report: monthly revenue per category, Jan–Oct 2026 | join order + aggregation (GROUP BY / HAVING)
SELECT date_trunc('month', o.order_date)::date AS month,
       cat.category_name,
       sum(oi.quantity * oi.unit_price)        AS revenue,
       count(DISTINCT o.order_id)              AS orders
FROM customer_order o
JOIN order_item      oi  ON oi.order_id    = o.order_id
JOIN product_variant v   ON v.variant_id   = oi.variant_id
JOIN product         p   ON p.product_id   = v.product_id
JOIN category        cat ON cat.category_id = p.category_id
WHERE o.order_date >= timestamp '2026-01-01'
  AND o.order_date <  timestamp '2026-11-01'
  AND o.status <> 'cancelled'
GROUP BY 1, 2
HAVING sum(oi.quantity * oi.unit_price) > 0
ORDER BY 1, 2;

-- @Q4 | Finance: all payment attempts for one order | exact-match search (hash vs B-tree)
SELECT payment_id, reference, method, amount, status, paid_at
FROM payment
WHERE order_id = 182733;

-- @Q5 | Merchandising: top 10 best-selling variants in the last 90 days | selection pushdown + join order + aggregation
SELECT p.product_name, v.size_eu, v.colour, sum(oi.quantity) AS pairs_sold
FROM order_item oi
JOIN customer_order  o ON o.order_id   = oi.order_id
JOIN product_variant v ON v.variant_id = oi.variant_id
JOIN product         p ON p.product_id = v.product_id
WHERE o.order_date >= timestamp '2026-08-03'
  AND o.status <> 'cancelled'
GROUP BY p.product_name, v.size_eu, v.colour
ORDER BY pairs_sold DESC
LIMIT 10;

-- @Q6 | Stock control: variants with 2 or fewer pairs left | small table – does an index help?
SELECT p.product_name, v.size_eu, v.colour, v.stock_qty
FROM product_variant v
JOIN product p ON p.product_id = v.product_id
WHERE v.stock_qty <= 2
ORDER BY v.stock_qty, p.product_name;
