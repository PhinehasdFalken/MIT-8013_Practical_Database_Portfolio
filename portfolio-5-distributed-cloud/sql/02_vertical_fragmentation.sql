-- =====================================================================
-- Portfolio 5 – VERTICAL FRAGMENTATION of the customer table
-- Run on the PRIMARY:
--   docker exec fk-primary psql -U postgres -d finesse_klass -f /p5/02_vertical_fragmentation.sql
--
-- Course: vertical fragments are "subsets of columns – useful when different
-- applications need access to different attributes".
--   * Marketing / analytics needs: who, where, since when      -> customer_profile
--   * Only customer care and dispatch need contact details     -> customer_contact
-- Keeping the personal contact data in its own fragment supports the data-privacy
-- principles of Study Session 6 (data minimisation, least-privilege access, NDPA 2023):
-- the contact fragment can be placed on a restricted site and granted to fewer roles.
-- The primary key is repeated in BOTH fragments so the table can be rebuilt with a join.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off
SET search_path TO fk;

DROP TABLE IF EXISTS customer_profile, customer_contact;

CREATE TABLE customer_profile AS
SELECT c.customer_id, c.first_name, c.last_name, c.created_at, s.region_id
FROM customer c
JOIN address a ON a.customer_id = c.customer_id AND a.is_default
JOIN state   s ON s.state_id = a.state_id;
ALTER TABLE customer_profile ADD PRIMARY KEY (customer_id);

CREATE TABLE customer_contact AS
SELECT customer_id, email, phone, instagram_handle FROM customer;
ALTER TABLE customer_contact ADD PRIMARY KEY (customer_id);

\echo '=== V1. The two fragments (same rows, different columns)'
SELECT * FROM customer_profile ORDER BY customer_id LIMIT 3;
SELECT * FROM customer_contact ORDER BY customer_id LIMIT 3;

\echo '=== V2. COMPLETENESS: every column of customer is in at least one fragment; every row in both'
SELECT (SELECT count(*) FROM customer) AS customers,
       (SELECT count(*) FROM customer_profile) AS profile_rows,
       (SELECT count(*) FROM customer_contact) AS contact_rows;

\echo '=== V3. RECONSTRUCTION (lossless join on the shared key): rebuilt table minus original = 0 rows'
SELECT count(*) AS differences FROM (
    SELECT p.customer_id, p.first_name, p.last_name, k.email, k.phone, k.instagram_handle, p.created_at
    FROM customer_profile p JOIN customer_contact k USING (customer_id)
    EXCEPT
    SELECT customer_id, first_name, last_name, email, phone, instagram_handle, created_at FROM customer
) d;

\echo '=== V4. Access control per fragment: a marketing role may read profiles but NOT contacts'
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fk_marketing') THEN
    REVOKE ALL ON SCHEMA fk FROM fk_marketing;
    DROP ROLE fk_marketing;
  END IF;
END $$;
CREATE ROLE fk_marketing NOLOGIN;
GRANT USAGE ON SCHEMA fk TO fk_marketing;
GRANT SELECT ON customer_profile TO fk_marketing;
SET ROLE fk_marketing;
SELECT region_id, count(*) AS customers FROM customer_profile GROUP BY region_id ORDER BY region_id;
\set ON_ERROR_STOP off
SELECT email FROM customer_contact LIMIT 1;
\set ON_ERROR_STOP on
RESET ROLE;
