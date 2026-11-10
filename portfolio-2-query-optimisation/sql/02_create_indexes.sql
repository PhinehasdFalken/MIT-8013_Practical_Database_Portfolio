-- =====================================================================
-- Portfolio 2 – physical design: indexes chosen from the baseline plans
-- (Study Session 4: "use of indexes", multi-column indexes, hashed
--  organisation for exact-match search, B+ tree for range search)
-- =====================================================================
SET search_path TO fk;

-- Q1: equality on customer_id + ORDER BY order_date DESC.
-- A multi-column B+ tree index gives both the filter AND the sort order,
-- so the Sort node disappears.
CREATE INDEX IF NOT EXISTS idx_order_customer_date
    ON customer_order (customer_id, order_date DESC);

-- Q2: equality on status + range on order_date. Equality column first,
-- range column second, so the index can jump straight to
-- ('pending', 2026-10-02) and read forward.
CREATE INDEX IF NOT EXISTS idx_order_status_date
    ON customer_order (status, order_date);

-- Q3 / Q5: date-range reports.
CREATE INDEX IF NOT EXISTS idx_order_date
    ON customer_order (order_date);

-- Q4: pure exact-match lookup (order_id = ?), never a range.
-- Hashed file organisation is described in the course as ideal for
-- exact-match search, so a HASH index is used here.
CREATE INDEX IF NOT EXISTS idx_payment_order_hash
    ON payment USING hash (order_id);

-- Q6: low-stock alert. Created to TEST whether the optimiser uses it
-- on a 2,400-row table (cost-based optimisation may ignore it).
CREATE INDEX IF NOT EXISTS idx_variant_stock
    ON product_variant (stock_qty);

-- Fresh statistics so the cost-based optimiser can see the new access paths
ANALYZE customer_order;
ANALYZE payment;
ANALYZE product_variant;
