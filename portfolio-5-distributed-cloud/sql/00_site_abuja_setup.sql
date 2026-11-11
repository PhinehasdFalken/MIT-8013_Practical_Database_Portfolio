-- =====================================================================
-- Run on the ABUJA SITE (fk-site-abuja, database finesse_site_north)
--   docker exec fk-site-abuja psql -U postgres -d finesse_site_north -f /p5/00_site_abuja_setup.sql
-- The table that will hold the NORTHERN fragment of the orders.
-- The CHECK constraint is the fragment's defining predicate: only rows with
-- region_id 4, 5 or 6 (North-Central, North-West, North-East) may be stored here.
-- =====================================================================
DROP TABLE IF EXISTS order_frag_north;
CREATE TABLE order_frag_north (
    order_id      BIGINT        PRIMARY KEY,
    region_id     SMALLINT      NOT NULL CHECK (region_id IN (4, 5, 6)),
    customer_id   INTEGER       NOT NULL,
    order_date    TIMESTAMP     NOT NULL,
    status        VARCHAR(15)   NOT NULL,
    total_amount  NUMERIC(12,2) NOT NULL
);
CREATE INDEX ON order_frag_north (region_id, order_date);
SELECT 'Abuja site ready: ' || current_database() AS info;
