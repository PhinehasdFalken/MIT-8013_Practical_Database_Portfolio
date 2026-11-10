-- =====================================================================
-- T3  SAVEPOINT – undo only PART of a transaction
-- Run: psql -U postgres -d finesse_klass -f sql/03_savepoint.sql
--
-- Story: a bespoke Ikoyi Penny Loafer order. The customer asked for the
-- monogram "PHINEHAS", but the workshop stamp holds at most 6 letters
-- (monogram VARCHAR(6)). Losing the whole order over the monogram would be
-- bad business, so a SAVEPOINT is set before the risky step; on failure we
-- roll back only to the savepoint, save the measurements without the
-- monogram, and still COMMIT the order.
-- =====================================================================
\set ON_ERROR_STOP off
SET search_path TO fk;
\pset pager off

BEGIN;
INSERT INTO customer_order (customer_id, address_id, order_type, status)
SELECT 1234, address_id, 'bespoke', 'pending' FROM address WHERE customer_id = 1234 AND is_default
RETURNING order_id \gset
\echo 'bespoke order_id =' :order_id

INSERT INTO order_item (order_id, line_no, variant_id, quantity, unit_price)
SELECT :order_id, 1, variant_id, 1, unit_price + 15000            -- bespoke surcharge
FROM product_variant WHERE sku = 'FK-001-42-TAN';

SAVEPOINT before_measurements;
\echo '--- risky step: measurements with an 8-letter monogram (column allows 6)'
INSERT INTO bespoke_spec (order_id, foot_length_cm, foot_width_cm, leather_choice, monogram)
VALUES (:order_id, 27.4, 10.2, 'Italian calf', 'PHINEHAS');

\echo '--- undo only the failed step'
ROLLBACK TO SAVEPOINT before_measurements;

INSERT INTO bespoke_spec (order_id, foot_length_cm, foot_width_cm, leather_choice, monogram, notes)
VALUES (:order_id, 27.4, 10.2, 'Italian calf', 'PKU', 'Customer asked for PHINEHAS – shortened to initials, confirm by DM');

UPDATE customer_order
SET total_amount = (SELECT sum(quantity * unit_price) FROM order_item WHERE order_id = :order_id)
WHERE order_id = :order_id;
COMMIT;

\echo '--- AFTER COMMIT: order, line and measurements all saved'
SELECT order_id, order_type, status, total_amount FROM customer_order WHERE order_id = :order_id;
SELECT order_id, foot_length_cm, foot_width_cm, leather_choice, monogram, notes FROM bespoke_spec WHERE order_id = :order_id;
