-- =====================================================================
-- Portfolio 5 – HORIZONTAL FRAGMENTATION of orders by region, with ALLOCATION
-- of the northern fragment to a DIFFERENT SERVER (the Abuja site).
-- Run on the PRIMARY (Lagos site):
--   docker exec fk-primary psql -U postgres -d finesse_klass -f /p5/01_horizontal_fragmentation.sql
--
-- Course (Study Session 2): horizontal fragments are "subsets of rows"; a good
-- fragmentation must be COMPLETE (no data lost) and RECONSTRUCTABLE (the
-- original can be rebuilt); queries should touch "only the relevant portion";
-- users should not need to know where data is (LOCATION/FRAGMENTATION TRANSPARENCY).
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off
SET search_path TO fk;
\if :{?site_host}
\else
  \set site_host 'fk-site-abuja'
\endif
\if :{?site_port}
\else
  \set site_port '5432'
\endif

-- ---------------------------------------------------------------- remote site connection
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
DROP SERVER IF EXISTS site_abuja CASCADE;
CREATE SERVER site_abuja FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host :'site_host', port :'site_port', dbname 'finesse_site_north', batch_size '1000');
CREATE USER MAPPING FOR CURRENT_USER SERVER site_abuja OPTIONS (user 'postgres', password 'finesse');

-- ---------------------------------------------------------------- fragmentation schema
-- One logical table, four fragments. The fragmentation predicate is region_id
-- (copied from address -> state -> region when the order is placed).
DROP TABLE IF EXISTS order_frag CASCADE;
CREATE TABLE order_frag (
    order_id      BIGINT        NOT NULL,
    region_id     SMALLINT      NOT NULL,
    customer_id   INTEGER       NOT NULL,
    order_date    TIMESTAMP     NOT NULL,
    status        VARCHAR(15)   NOT NULL,
    total_amount  NUMERIC(12,2) NOT NULL
) PARTITION BY LIST (region_id);

--   F1  South-West  (Lagos site)        local
--   F2  South-East  (Lagos site)        local
--   F3  South-South (Lagos site)        local
--   F4  North (NC + NW + NE)            stored on the ABUJA SITE (foreign partition)
CREATE TABLE of_south_west  PARTITION OF order_frag FOR VALUES IN (1);
CREATE TABLE of_south_east  PARTITION OF order_frag FOR VALUES IN (2);
CREATE TABLE of_south_south PARTITION OF order_frag FOR VALUES IN (3);
CREATE FOREIGN TABLE of_north PARTITION OF order_frag FOR VALUES IN (4, 5, 6)
    SERVER site_abuja OPTIONS (schema_name 'public', table_name 'order_frag_north');

-- ---------------------------------------------------------------- load (rows are ROUTED automatically)
\echo '--- loading 250k orders into the fragmented table; northern rows travel to the Abuja site'
\timing on
INSERT INTO order_frag (order_id, region_id, customer_id, order_date, status, total_amount)
SELECT o.order_id, s.region_id, o.customer_id, o.order_date, o.status, o.total_amount
FROM customer_order o
JOIN address a ON a.address_id = o.address_id
JOIN state   s ON s.state_id   = a.state_id;
\timing off
ANALYZE order_frag;

-- ---------------------------------------------------------------- 1. allocation
\echo '=== 1. ALLOCATION: rows per fragment and the server that stores it'
SELECT 'of_south_west'  AS fragment, 'Lagos site (primary)' AS stored_at, count(*) AS orders FROM of_south_west
UNION ALL SELECT 'of_south_east',  'Lagos site (primary)', count(*) FROM of_south_east
UNION ALL SELECT 'of_south_south', 'Lagos site (primary)', count(*) FROM of_south_south
UNION ALL SELECT 'of_north',       'Abuja site (remote)',  count(*) FROM of_north;

-- ---------------------------------------------------------------- 2. correctness rules
\echo '=== 2a. COMPLETENESS: every order is in some fragment (fragment total = original total)'
SELECT (SELECT count(*) FROM customer_order) AS original_rows,
       (SELECT count(*) FROM order_frag)     AS rows_in_all_fragments;

\echo '=== 2b. DISJOINTNESS: no order is stored in two fragments'
SELECT count(*) AS rows, count(DISTINCT order_id) AS distinct_orders FROM order_frag;

\echo '=== 2c. RECONSTRUCTION: union of fragments = original (both differences must be 0)'
SELECT (SELECT count(*) FROM (SELECT order_id, total_amount FROM customer_order
                              EXCEPT SELECT order_id, total_amount FROM order_frag) x) AS missing_after_union,
       (SELECT count(*) FROM (SELECT order_id, total_amount FROM order_frag
                              EXCEPT SELECT order_id, total_amount FROM customer_order) y) AS extra_after_union;

\echo '=== 2d. The remote site enforces its own predicate: a Lagos order cannot be stored in Abuja'
\set ON_ERROR_STOP off
INSERT INTO of_north VALUES (999999999, 1, 1, now(), 'pending', 1000);
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------- 3. transparency + pruning
\echo '=== 3a. FRAGMENTATION TRANSPARENCY + PRUNING: the query names only order_frag;'
\echo '        the optimiser reads ONLY the South-East fragment'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*), sum(total_amount) FROM order_frag WHERE region_id = 2;

\echo '=== 3b. LOCATION TRANSPARENCY: the same kind of query for the North-West. The user still names'
\echo '        only order_frag; the DBMS sends it to the Abuja site ("Foreign Scan" + "Remote SQL").'
EXPLAIN (VERBOSE, COSTS OFF)
SELECT count(*), sum(total_amount) FROM order_frag WHERE region_id = 5;
SELECT count(*) AS north_west_orders, sum(total_amount) AS revenue FROM order_frag WHERE region_id = 5;

\echo '=== 3c. DISTRIBUTED QUERY OPTIMISATION – network cost of a GLOBAL report (revenue per region)'
\echo '--- 3c-i  default plan: every northern order is SHIPPED from Abuja to Lagos, then aggregated'
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT region_id, count(*), sum(total_amount) FROM order_frag GROUP BY region_id;
\echo '--- 3c-ii partition-wise aggregation: each site aggregates its OWN fragment; Abuja ships only totals'
SET enable_partitionwise_aggregate = on;
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT region_id, count(*), sum(total_amount) FROM order_frag GROUP BY region_id;
\echo '--- the report itself (identical either way)'
SELECT r.region_name, f.orders, f.revenue
FROM (SELECT region_id, count(*) AS orders, sum(total_amount) AS revenue FROM order_frag GROUP BY region_id) f
JOIN region r USING (region_id) ORDER BY f.orders DESC;
RESET enable_partitionwise_aggregate;

\echo '=== 3d. A new order from Kano is routed to the Abuja site automatically (insert transparency)'
INSERT INTO order_frag VALUES (900000001, 5, 1, timestamp '2026-11-01 10:00', 'pending', 64500);
SELECT tableoid::regclass AS stored_in_fragment, order_id, region_id FROM order_frag WHERE order_id = 900000001;
DELETE FROM order_frag WHERE order_id = 900000001;
