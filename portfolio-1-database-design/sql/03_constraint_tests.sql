-- =====================================================================
-- Finesse Klass – constraint tests (evidence that integrity rules are enforced)
-- Run:  psql -U postgres -d finesse_klass -f sql/03_constraint_tests.sql
-- Every statement below is SUPPOSED to fail. Each ERROR line is the evidence.
-- Nothing is changed in the database (each failed statement is rolled back).
-- =====================================================================
\set ON_ERROR_STOP off
SET search_path TO fk;

\echo '--- T1 Entity integrity: duplicate primary key on category'
INSERT INTO category (category_id, category_name) VALUES (1, 'Duplicate Loafers');

\echo '--- T2 Candidate key: a second customer with an e-mail that already exists'
INSERT INTO customer (first_name, last_name, email, phone)
SELECT 'Test', 'User', email, '+2340000000000' FROM customer WHERE customer_id = 1;

\echo '--- T3 Domain integrity: shoe size outside the EU 36-48 range'
INSERT INTO product_variant (product_id, size_eu, colour, sku, unit_price, stock_qty)
VALUES (1, 52, 'Black', 'FK-TEST-52', 50000, 3);

\echo '--- T4 Domain integrity: stock can never go negative (no overselling)'
UPDATE product_variant SET stock_qty = stock_qty - 1000 WHERE variant_id = 1;

\echo '--- T5 Referential integrity: order line for a variant that does not exist'
INSERT INTO order_item (order_id, line_no, variant_id, quantity, unit_price)
VALUES (1, 9, 999999, 1, 50000);

\echo '--- T6 Composite FK: order delivered to ANOTHER customer''s address'
INSERT INTO customer_order (customer_id, address_id)
SELECT 1, address_id FROM address WHERE customer_id = 2 LIMIT 1;

\echo '--- T7 Composite FK: bespoke measurements attached to a STANDARD order'
INSERT INTO bespoke_spec (order_id, foot_length_cm, foot_width_cm, leather_choice)
SELECT order_id, 27.5, 10.0, 'Suede' FROM customer_order WHERE order_type = 'standard' LIMIT 1;

\echo '--- T8 Business rule: a customer can only have one default address'
INSERT INTO address (customer_id, street, city, state_id, is_default)
VALUES (1, '1 Test Street', 'Lagos', 1, true);

\echo '--- T9 Business rule: a parcel cannot be delivered before it is dispatched'
UPDATE delivery SET delivered_at = dispatched_at - interval '1 day'
WHERE delivery_id = (SELECT min(delivery_id) FROM delivery WHERE delivered_at IS NOT NULL);

\echo '--- T10 Business rule: a successful payment must have a payment time'
INSERT INTO payment (order_id, reference, method, amount, status, paid_at)
VALUES (1, 'FKP-TEST-1', 'card', 1000, 'successful', NULL);

\echo '--- T11 Domain integrity: unknown order status'
UPDATE customer_order SET status = 'lost' WHERE order_id = 1;

\echo '--- Done: 11 tests, 11 expected errors above.'
