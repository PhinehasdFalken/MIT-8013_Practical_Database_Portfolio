-- =====================================================================
-- T1  COMMIT – placing an order is ONE transaction (all-or-nothing)
-- Run: psql -U postgres -d finesse_klass -f sql/01_commit_place_order.sql
--
-- Business story: Ngozi Ibe (customer 1234) buys a Banana Island Chelsea
-- Boot (size 44, burgundy) and a Banana Island Court Sneaker (43, white)
-- and pays by bank transfer. Six changes must happen together:
--   1 order header, 2 order lines, 2 stock decrements (+ audit rows),
--   order total, 1 payment, order status -> 'paid'.
-- =====================================================================
\set ON_ERROR_STOP on
SET search_path TO fk;
\pset pager off

\echo '--- BEFORE: stock of the two variants'
SELECT sku, stock_qty FROM product_variant WHERE sku IN ('FK-087-44-BUR', 'FK-047-43-WHI') ORDER BY sku;

BEGIN;   -- ===================== transaction starts =====================

-- 1. order header (delivery to the customer's default address)
INSERT INTO customer_order (customer_id, address_id, order_type, status)
SELECT 1234, address_id, 'standard', 'pending'
FROM address WHERE customer_id = 1234 AND is_default
RETURNING order_id \gset
\echo 'new order_id =' :order_id

-- 2. order lines, priced from the catalogue at the moment of sale
INSERT INTO order_item (order_id, line_no, variant_id, quantity, unit_price)
SELECT :order_id, 1, variant_id, 1, unit_price FROM product_variant WHERE sku = 'FK-087-44-BUR';
INSERT INTO order_item (order_id, line_no, variant_id, quantity, unit_price)
SELECT :order_id, 2, variant_id, 1, unit_price FROM product_variant WHERE sku = 'FK-047-43-WHI';

-- 3. take the pairs out of stock (the CHECK stock_qty >= 0 guards against overselling)
UPDATE product_variant v SET stock_qty = v.stock_qty - oi.quantity
FROM order_item oi
WHERE oi.order_id = :order_id AND oi.variant_id = v.variant_id;

INSERT INTO stock_movement (variant_id, change_qty, reason, order_id)
SELECT variant_id, -quantity, 'sale', order_id FROM order_item WHERE order_id = :order_id;

-- 4. derived total
UPDATE customer_order
SET total_amount = (SELECT sum(quantity * unit_price) FROM order_item WHERE order_id = :order_id)
WHERE order_id = :order_id;

-- 5. payment confirmed by the bank, order becomes 'paid'
INSERT INTO payment (order_id, reference, method, amount, status, paid_at)
SELECT order_id, 'FKP' || order_id || '-T1', 'transfer', total_amount, 'successful', now()
FROM customer_order WHERE order_id = :order_id;

UPDATE customer_order SET status = 'paid' WHERE order_id = :order_id;

COMMIT;  -- ===================== all six changes become permanent together

\echo '--- AFTER COMMIT: the order, its lines, its payment and the new stock'
SELECT order_id, customer_id, status, total_amount FROM customer_order WHERE order_id = :order_id;
SELECT oi.line_no, v.sku, oi.quantity, oi.unit_price FROM order_item oi
JOIN product_variant v USING (variant_id) WHERE oi.order_id = :order_id ORDER BY oi.line_no;
SELECT reference, method, amount, status FROM payment WHERE order_id = :order_id;
SELECT sku, stock_qty FROM product_variant WHERE sku IN ('FK-087-44-BUR', 'FK-047-43-WHI') ORDER BY sku;
