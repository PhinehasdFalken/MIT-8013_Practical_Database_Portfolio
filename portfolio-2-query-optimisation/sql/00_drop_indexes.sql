-- =====================================================================
-- Portfolio 2 – reset to the Portfolio 1 baseline (only PK / UNIQUE indexes)
-- Run this before the baseline measurements so they are fair.
-- =====================================================================
SET search_path TO fk;
DROP MATERIALIZED VIEW IF EXISTS mv_monthly_category_revenue;
DROP INDEX IF EXISTS idx_order_customer_date;
DROP INDEX IF EXISTS idx_order_customer_covering;
DROP INDEX IF EXISTS idx_order_customer_plain;
DROP INDEX IF EXISTS idx_order_status_date;
DROP INDEX IF EXISTS idx_order_date;
DROP INDEX IF EXISTS idx_payment_order_hash;
DROP INDEX IF EXISTS idx_payment_order_btree;
DROP INDEX IF EXISTS idx_variant_stock;
DROP STATISTICS IF EXISTS st_order_status_date;
ANALYZE;
