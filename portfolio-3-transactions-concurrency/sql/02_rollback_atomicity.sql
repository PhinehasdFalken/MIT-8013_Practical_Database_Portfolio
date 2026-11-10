-- =====================================================================
-- T2  ROLLBACK – atomicity: a failure part-way through undoes EVERYTHING
-- Run: psql -U postgres -d finesse_klass -f sql/02_rollback_atomicity.sql
--
-- Story A (automatic rollback): Ngozi orders the Chelsea Boot (in stock) AND a
-- Penny Loafer FK-011-39-BRO that is SOLD OUT (stock 0). The first stock
-- decrement succeeds, the second violates CHECK (stock_qty >= 0). The whole
-- transaction must be undone – including the boot that was already "taken".
--
-- Story B (explicit rollback): staff start an order, then the customer
-- changes her mind on the phone. The clerk issues ROLLBACK.
-- =====================================================================
\set ON_ERROR_STOP off
SET search_path TO fk;
\pset pager off

\echo '--- BEFORE: stock and number of orders for customer 1234'
SELECT sku, stock_qty FROM product_variant WHERE sku IN ('FK-087-44-BUR', 'FK-011-39-BRO') ORDER BY sku;
SELECT count(*) AS orders_of_customer_1234 FROM customer_order WHERE customer_id = 1234;

\echo '=== Story A: failure inside the transaction ==='
BEGIN;
INSERT INTO customer_order (customer_id, address_id, order_type, status)
SELECT 1234, address_id, 'standard', 'pending' FROM address WHERE customer_id = 1234 AND is_default
RETURNING order_id \gset
INSERT INTO order_item (order_id, line_no, variant_id, quantity, unit_price)
SELECT :order_id, 1, variant_id, 1, unit_price FROM product_variant WHERE sku = 'FK-087-44-BUR';
INSERT INTO order_item (order_id, line_no, variant_id, quantity, unit_price)
SELECT :order_id, 2, variant_id, 1, unit_price FROM product_variant WHERE sku = 'FK-011-39-BRO';

\echo '--- step 1: take the boot out of stock (succeeds)'
UPDATE product_variant SET stock_qty = stock_qty - 1 WHERE sku = 'FK-087-44-BUR';
\echo '--- inside the transaction the boot stock is already reduced:'
SELECT sku, stock_qty FROM product_variant WHERE sku = 'FK-087-44-BUR';

\echo '--- step 2: take the sold-out loafer out of stock (FAILS: stock would be -1)'
UPDATE product_variant SET stock_qty = stock_qty - 1 WHERE sku = 'FK-011-39-BRO';

\echo '--- step 3: any further statement is refused – the transaction is aborted'
UPDATE customer_order SET status = 'paid' WHERE order_id = :order_id;
ROLLBACK;

\echo '--- AFTER ROLLBACK: boot stock is back, the order and its lines do not exist'
SELECT sku, stock_qty FROM product_variant WHERE sku IN ('FK-087-44-BUR', 'FK-011-39-BRO') ORDER BY sku;
SELECT count(*) AS order_rows FROM customer_order WHERE order_id = :order_id;
SELECT count(*) AS line_rows  FROM order_item    WHERE order_id = :order_id;

\echo '=== Story B: customer changes her mind – explicit ROLLBACK ==='
BEGIN;
INSERT INTO customer_order (customer_id, address_id, order_type, status)
SELECT 1234, address_id, 'standard', 'pending' FROM address WHERE customer_id = 1234 AND is_default
RETURNING order_id AS cancelled_order_id \gset
UPDATE product_variant SET stock_qty = stock_qty - 1 WHERE sku = 'FK-087-44-BUR';
\echo '--- pair reserved inside the transaction; customer says "no, cancel it"'
ROLLBACK;
SELECT count(*) AS order_rows FROM customer_order WHERE order_id = :cancelled_order_id;
SELECT sku, stock_qty FROM product_variant WHERE sku = 'FK-087-44-BUR';
SELECT count(*) AS orders_of_customer_1234 FROM customer_order WHERE customer_id = 1234;
\echo '--- Note: identity numbers used by rolled-back inserts are not reused (a gap in order_id is normal).'
