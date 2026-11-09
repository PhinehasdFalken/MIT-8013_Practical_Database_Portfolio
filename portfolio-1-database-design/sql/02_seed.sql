-- =====================================================================
-- Finesse Klass – synthetic but realistic data
-- Run after 01_schema.sql:  psql -U postgres -d finesse_klass -f sql/02_seed.sql
--
-- * setseed() makes the "random" data identical on every machine, so the
--   row counts in the README can be reproduced exactly.
-- * Volumes are large enough for the query optimiser to make real choices
--   in Portfolio 2 (a few seconds to load on a laptop):
--     40,000 customers | ~2,900 variants | 250,000 orders | ~350,000 order lines
-- * "Today" is fixed at 2026-11-01 so results do not drift with the clock.
-- =====================================================================
SET search_path TO fk;
SELECT setseed(0.2026);

-- ---------------------------------------------------------------- regions & states
INSERT INTO region (region_id, region_name) VALUES
 (1,'South-West'),(2,'South-East'),(3,'South-South'),
 (4,'North-Central'),(5,'North-West'),(6,'North-East');

INSERT INTO state (state_id, state_name, region_id) VALUES
 (1,'Lagos',1),(2,'Ogun',1),(3,'Oyo',1),(4,'Osun',1),(5,'Ondo',1),(6,'Ekiti',1),
 (7,'Anambra',2),(8,'Enugu',2),(9,'Imo',2),(10,'Abia',2),(11,'Ebonyi',2),
 (12,'Rivers',3),(13,'Delta',3),(14,'Edo',3),(15,'Akwa Ibom',3),(16,'Cross River',3),(17,'Bayelsa',3),
 (18,'FCT',4),(19,'Kwara',4),(20,'Plateau',4),(21,'Niger',4),(22,'Benue',4),(23,'Kogi',4),(24,'Nasarawa',4),
 (25,'Kano',5),(26,'Kaduna',5),(27,'Katsina',5),(28,'Sokoto',5),(29,'Kebbi',5),(30,'Zamfara',5),(31,'Jigawa',5),
 (32,'Bauchi',6),(33,'Borno',6),(34,'Adamawa',6),(35,'Gombe',6),(36,'Taraba',6),(37,'Yobe',6);

-- ---------------------------------------------------------------- catalogue
INSERT INTO category (category_id, category_name) VALUES
 (1,'Loafers'),(2,'Oxfords & Brogues'),(3,'Sneakers'),
 (4,'Sandals & Slides'),(5,'Boots'),(6,'Mules');

-- 6 categories x 20 collections = 120 products, e.g. "Ikoyi Penny Loafer"
INSERT INTO product (category_id, product_name, material, base_price, bespoke_available)
SELECT c.category_id,
       col.name || ' ' || (ARRAY['Penny Loafer','Wingtip Brogue','Court Sneaker',
                                 'Leather Slide','Chelsea Boot','Suede Mule'])[c.category_id],
       (ARRAY['Calf leather','Suede','Patent leather','Nubuck','Ostrich leather'])[1 + (col.n % 5)],
       round((25000 + random() * 95000)::numeric, -2),           -- NGN 25,000 – 120,000
       c.category_id IN (1, 2, 5) AND random() < 0.6             -- formal styles can be bespoke
FROM category c
CROSS JOIN (SELECT n, (ARRAY['Ikoyi','Lekki','Maitama','Asokoro','Ikeja','GRA','Banana Island',
                             'Victoria','Trans-Amadi','Independence','Wuse','Bodija','Awka',
                             'Onitsha','Calabar','Kano Royal','Zaria','Jos Plateau','Owerri','Benin'])[n] AS name
            FROM generate_series(1, 20) n) col
ORDER BY c.category_id, col.n;

-- sizes 39–46, two or three colours per product
INSERT INTO product_variant (product_id, size_eu, colour, sku, unit_price, stock_qty)
SELECT p.product_id, s.size_eu, col.colour,
       'FK-' || lpad(p.product_id::text, 3, '0') || '-' || s.size_eu || '-' || upper(left(col.colour, 3)),
       p.base_price + CASE WHEN s.size_eu >= 45 THEN 2500 ELSE 0 END,  -- larger lasts cost more
       floor(random() * 26)::int                                        -- 0–25 pairs
FROM product p
CROSS JOIN generate_series(39, 46) AS s(size_eu)
CROSS JOIN LATERAL (
    -- 2 or 3 colours per product, rotating through the palette
    SELECT (ARRAY['Black','Brown','Tan','Burgundy','Navy','White'])[1 + (p.product_id + k) % 6] AS colour
    FROM generate_series(0, 1 + p.product_id % 2) AS k
) col;

-- ---------------------------------------------------------------- customers
INSERT INTO customer (first_name, last_name, email, phone, instagram_handle, created_at)
SELECT fn, ln,
       lower(fn) || '.' || lower(ln) || n || '@' || (ARRAY['gmail.com','yahoo.com','outlook.com'])[1 + n % 3],
       '+234' || (ARRAY['803','806','813','816','703','706','805','807','905','909'])[1 + n % 10]
              || lpad((1000000 + n * 7)::text, 7, '0'),
       CASE WHEN random() < 0.7 THEN lower(fn) || '_' || lower(left(ln, 3)) || n END,
       timestamp '2023-06-01' + random() * interval '880 days'
FROM (SELECT n,
             (ARRAY['Chinedu','Amaka','Tunde','Ngozi','Emeka','Funmi','Ibrahim','Aisha','Segun','Kemi',
                    'Obinna','Zainab','Femi','Adaeze','Musa','Halima','Kosi','Tolu','Uche','Bisi'])[1 + floor(random()*20)::int] AS fn,
             (ARRAY['Okafor','Adeyemi','Bello','Eze','Okonkwo','Abubakar','Balogun','Nwosu','Ogunleye','Usman',
                    'Uchegbu','Afolabi','Ibe','Lawal','Obi','Danjuma','Akande','Chukwu','Yusuf','Ojo'])[1 + floor(random()*20)::int] AS ln
      FROM generate_series(1, 40000) n) x;

-- every customer gets a default address; ~40% also have a second one.
-- Lagos and Abuja dominate, as they do for most Instagram fashion brands.
INSERT INTO address (customer_id, street, city, state_id, is_default)
SELECT c.customer_id,
       (10 + floor(random()*190)::int) || ' ' ||
       (ARRAY['Admiralty Way','Awolowo Road','Adetokunbo Ademola St','Allen Avenue','Aminu Kano Crescent',
              'Ogui Road','Aba Road','Ahmadu Bello Way','Murtala Mohammed Way','Zik Avenue'])[1 + floor(random()*10)::int],
       s.state_name,
       s.state_id,
       a.k = 1
FROM customer c
CROSS JOIN LATERAL generate_series(1, CASE WHEN random() + c.customer_id * 0 < 0.4 THEN 2 ELSE 1 END) AS a(k)
CROSS JOIN LATERAL (
    SELECT CASE
             WHEN r < 0.38 THEN 1     -- Lagos
             WHEN r < 0.52 THEN 18    -- FCT
             WHEN r < 0.60 THEN 12    -- Rivers
             WHEN r < 0.66 THEN 7     -- Anambra
             WHEN r < 0.71 THEN 8     -- Enugu
             WHEN r < 0.75 THEN 2     -- Ogun
             WHEN r < 0.78 THEN 3     -- Oyo
             WHEN r < 0.81 THEN 25    -- Kano
             WHEN r < 0.84 THEN 13    -- Delta
             ELSE 4 + floor(random() * 34)::int  -- everyone else
           END AS sid
    FROM (SELECT random() + a.k * 0 + c.customer_id * 0 AS r) z
) pick
JOIN state s ON s.state_id = pick.sid;

-- ---------------------------------------------------------------- orders
-- Customer choice is skewed (random()^2): a small group of loyal customers
-- place many orders – realistic, and it gives the optimiser uneven
-- statistics to work with in Portfolio 2.
INSERT INTO customer_order (customer_id, address_id, order_date, order_type, status)
SELECT a.customer_id, a.address_id, g.order_date,
       CASE WHEN g.r_type < 0.08 THEN 'bespoke' ELSE 'standard' END,
       CASE
         WHEN g.order_date < timestamp '2026-10-11' THEN
              CASE WHEN g.r_status < 0.05 THEN 'cancelled' ELSE 'delivered' END
         ELSE (ARRAY['pending','paid','in_production','dispatched','delivered','cancelled'])
              [1 + floor(g.r_status * 6)::int]
       END
FROM (SELECT n,
             1 + floor(40000 * random() ^ 2)::int                     AS cid,
             timestamp '2024-01-01' + random() * interval '1035 days' AS order_date,
             random() AS r_type, random() AS r_status
      FROM generate_series(1, 250000) n) g
JOIN address a ON a.customer_id = g.cid AND a.is_default
ORDER BY g.order_date;                       -- rows arrive in date order, as in real life

-- standard orders: 1–3 lines of any variant
INSERT INTO order_item (order_id, line_no, variant_id, quantity, unit_price)
SELECT o.order_id, l.line_no, v.variant_id,
       CASE WHEN random() < 0.85 THEN 1 ELSE 2 END,
       v.unit_price
FROM customer_order o
CROSS JOIN LATERAL generate_series(1, 1 + (random() + o.order_id * 0 < 0.30)::int
                                        + (random() + o.order_id * 0 < 0.10)::int) AS l(line_no)
JOIN LATERAL (SELECT 1 + floor(random() * (SELECT max(variant_id) FROM product_variant)
                             + o.order_id * 0 + l.line_no * 0)::int AS vid) pv ON true
JOIN product_variant v ON v.variant_id = pv.vid
WHERE o.order_type = 'standard'
ON CONFLICT (order_id, variant_id) DO NOTHING;

-- bespoke orders: exactly one made-to-measure pair of a bespoke-capable product
INSERT INTO order_item (order_id, line_no, variant_id, quantity, unit_price)
SELECT o.order_id, 1, v.variant_id, 1, v.unit_price + 15000           -- bespoke surcharge
FROM customer_order o
JOIN LATERAL (SELECT pv.variant_id, pv.unit_price
              FROM product_variant pv JOIN product p USING (product_id)
              WHERE p.bespoke_available
              ORDER BY random() + o.order_id * 0
              LIMIT 1) v ON true
WHERE o.order_type = 'bespoke';

INSERT INTO bespoke_spec (order_id, foot_length_cm, foot_width_cm, leather_choice, monogram, notes)
SELECT order_id,
       round((24 + random() * 7)::numeric, 1),
       round((8.5 + random() * 3)::numeric, 1),
       (ARRAY['Italian calf','Ostrich','Crocodile-embossed','Suede','Python-embossed'])[1 + floor(random()*5)::int],
       CASE WHEN random() < 0.4 THEN upper(substr(md5(order_id::text), 1, 3)) END,
       CASE WHEN random() < 0.3 THEN 'Wide fit on left foot' END
FROM customer_order WHERE order_type = 'bespoke';

-- derived total, computed once from the order lines
UPDATE customer_order o
SET total_amount = s.total
FROM (SELECT order_id, sum(quantity * unit_price) AS total FROM order_item GROUP BY order_id) s
WHERE s.order_id = o.order_id;

-- ---------------------------------------------------------------- payments
-- one successful payment for every order that got past 'pending';
-- 6% of them had an earlier failed attempt; cancelled orders show a failed attempt
INSERT INTO payment (order_id, reference, method, amount, status, paid_at)
SELECT o.order_id, 'FKP' || o.order_id || '-2',
       (ARRAY['card','transfer','pos','ussd'])[1 + floor(random()*4)::int],
       o.total_amount, 'successful',
       o.order_date + random() * interval '6 hours'
FROM customer_order o
WHERE o.status NOT IN ('pending', 'cancelled');

INSERT INTO payment (order_id, reference, method, amount, status, paid_at)
SELECT o.order_id, 'FKP' || o.order_id || '-1', 'card', o.total_amount, 'failed', NULL
FROM customer_order o
WHERE o.status = 'cancelled' OR (o.status <> 'pending' AND random() < 0.06);

INSERT INTO payment (order_id, reference, method, amount, status, paid_at)
SELECT o.order_id, 'FKP' || o.order_id || '-1', 'transfer', o.total_amount, 'pending', NULL
FROM customer_order o
WHERE o.status = 'pending';

-- ---------------------------------------------------------------- deliveries
INSERT INTO delivery (order_id, courier, tracking_no, dispatched_at, delivered_at)
SELECT o.order_id,
       (ARRAY['GIGL','DHL','Kwik','Sendbox','FK Rider'])[1 + floor(random()*5)::int],
       'TRK' || lpad(o.order_id::text, 9, '0'),
       o.order_date + interval '1 day' + random() * interval '3 days'
                    + CASE WHEN o.order_type = 'bespoke' THEN interval '14 days' ELSE interval '0' END,
       CASE WHEN o.status = 'delivered'
            THEN o.order_date + interval '5 days' + random() * interval '4 days'
                 + CASE WHEN o.order_type = 'bespoke' THEN interval '14 days' ELSE interval '0' END
       END
FROM customer_order o
WHERE o.status IN ('dispatched', 'delivered');

-- ---------------------------------------------------------------- opening stock audit
INSERT INTO stock_movement (variant_id, change_qty, reason, moved_at)
SELECT variant_id, stock_qty, 'restock', timestamp '2026-10-25'
FROM product_variant WHERE stock_qty > 0;

-- The bulk UPDATE of total_amount above wrote a new version of every order row
-- elsewhere in the table, scattering the date order the rows were inserted in.
-- order_id follows order_date, so clustering on the primary key restores the
-- natural "orders arrive in date order" physical layout (see Portfolio 2, E7).
CLUSTER customer_order USING customer_order_pkey;

-- refresh optimiser statistics after the bulk load
ANALYZE;

-- ---------------------------------------------------------------- summary
SELECT 'region' AS table_name, count(*) FROM region
UNION ALL SELECT 'state', count(*) FROM state
UNION ALL SELECT 'category', count(*) FROM category
UNION ALL SELECT 'product', count(*) FROM product
UNION ALL SELECT 'product_variant', count(*) FROM product_variant
UNION ALL SELECT 'customer', count(*) FROM customer
UNION ALL SELECT 'address', count(*) FROM address
UNION ALL SELECT 'customer_order', count(*) FROM customer_order
UNION ALL SELECT 'order_item', count(*) FROM order_item
UNION ALL SELECT 'bespoke_spec', count(*) FROM bespoke_spec
UNION ALL SELECT 'payment', count(*) FROM payment
UNION ALL SELECT 'delivery', count(*) FROM delivery
UNION ALL SELECT 'stock_movement', count(*) FROM stock_movement
ORDER BY 1;
