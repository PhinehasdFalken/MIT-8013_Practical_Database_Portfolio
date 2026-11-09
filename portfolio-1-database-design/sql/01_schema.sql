-- =====================================================================
-- Finesse Klass – Relational Schema (Portfolio 1: Logical Design)
-- Target DBMS : PostgreSQL 14+ (tested on PostgreSQL 16)
-- Run with    : psql -U postgres -d finesse_klass -f sql/01_schema.sql
--
-- Design notes
--   * Every table has a primary key (entity integrity).
--   * Every relationship is a FOREIGN KEY (referential integrity).
--   * CHECK / NOT NULL / UNIQUE enforce the business rules (domain integrity).
--   * The schema is in BCNF – see ../normalisation.md for the derivation.
--   * Foreign-key columns are deliberately NOT indexed here. PostgreSQL only
--     indexes PRIMARY KEY and UNIQUE columns automatically. Index selection is
--     part of PHYSICAL design and is done (and measured) in Portfolio 2.
-- =====================================================================

DROP SCHEMA IF EXISTS fk CASCADE;
CREATE SCHEMA fk;
SET search_path TO fk;

-- ---------------------------------------------------------------------
-- Reference data: where customers live (needed for delivery and, later,
-- for horizontal fragmentation by region in Portfolio 5).
-- ---------------------------------------------------------------------
CREATE TABLE region (
    region_id    SMALLINT     PRIMARY KEY,
    region_name  VARCHAR(30)  NOT NULL UNIQUE
);

CREATE TABLE state (
    state_id     SMALLINT     PRIMARY KEY,
    state_name   VARCHAR(40)  NOT NULL UNIQUE,
    region_id    SMALLINT     NOT NULL REFERENCES region (region_id)
);

-- ---------------------------------------------------------------------
-- Customers and their delivery addresses
-- ---------------------------------------------------------------------
CREATE TABLE customer (
    customer_id       INTEGER      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name        VARCHAR(50)  NOT NULL,
    last_name         VARCHAR(50)  NOT NULL,
    email             VARCHAR(120) NOT NULL UNIQUE,          -- candidate key
    phone             VARCHAR(20)  NOT NULL UNIQUE,          -- candidate key
    instagram_handle  VARCHAR(40)  UNIQUE,                   -- most orders start as Instagram DMs
    created_at        TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT chk_customer_email CHECK (email LIKE '%_@_%._%')
);

CREATE TABLE address (
    address_id   INTEGER      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  INTEGER      NOT NULL REFERENCES customer (customer_id) ON DELETE CASCADE,
    street       VARCHAR(150) NOT NULL,
    city         VARCHAR(60)  NOT NULL,
    state_id     SMALLINT     NOT NULL REFERENCES state (state_id),
    is_default   BOOLEAN      NOT NULL DEFAULT false,
    -- lets customer_order prove that the address belongs to the ordering customer
    CONSTRAINT uq_address_owner UNIQUE (address_id, customer_id)
);
-- business rule: a customer can have at most ONE default address
CREATE UNIQUE INDEX ux_address_one_default ON address (customer_id) WHERE is_default;

-- ---------------------------------------------------------------------
-- Catalogue: a PRODUCT (e.g. "Ikoyi Penny Loafer") is sold in many
-- VARIANTS (size + colour). Stock is held per variant.
-- ---------------------------------------------------------------------
CREATE TABLE category (
    category_id    SMALLINT    PRIMARY KEY,
    category_name  VARCHAR(40) NOT NULL UNIQUE
);

CREATE TABLE product (
    product_id         INTEGER       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_id        SMALLINT      NOT NULL REFERENCES category (category_id),
    product_name       VARCHAR(80)   NOT NULL UNIQUE,
    material           VARCHAR(40)   NOT NULL,
    base_price         NUMERIC(10,2) NOT NULL CHECK (base_price > 0),
    bespoke_available  BOOLEAN       NOT NULL DEFAULT false,  -- can be made to measure
    is_active          BOOLEAN       NOT NULL DEFAULT true
);

CREATE TABLE product_variant (
    variant_id  INTEGER       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id  INTEGER       NOT NULL REFERENCES product (product_id),
    size_eu     SMALLINT      NOT NULL CHECK (size_eu BETWEEN 36 AND 48),
    colour      VARCHAR(20)   NOT NULL,
    sku         VARCHAR(30)   NOT NULL UNIQUE,
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty   INTEGER       NOT NULL DEFAULT 0 CHECK (stock_qty >= 0),  -- no overselling, ever
    CONSTRAINT uq_variant UNIQUE (product_id, size_eu, colour)
);

-- ---------------------------------------------------------------------
-- Orders ("order" is a reserved word in SQL, hence customer_order)
-- ---------------------------------------------------------------------
CREATE TABLE customer_order (
    order_id      BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id   INTEGER       NOT NULL REFERENCES customer (customer_id),
    address_id    INTEGER       NOT NULL,
    order_date    TIMESTAMP     NOT NULL DEFAULT now(),
    order_type    VARCHAR(10)   NOT NULL DEFAULT 'standard'
                  CHECK (order_type IN ('standard', 'bespoke')),
    status        VARCHAR(15)   NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'paid', 'in_production',
                                    'dispatched', 'delivered', 'cancelled')),
    -- DERIVED attribute (sum of its order lines). Stored on purpose so that
    -- revenue reports do not have to re-aggregate every order line; it is
    -- written only by the place-order transaction (Portfolio 3).
    total_amount  NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
    -- the delivery address must belong to the same customer
    CONSTRAINT fk_order_address FOREIGN KEY (address_id, customer_id)
        REFERENCES address (address_id, customer_id),
    -- lets bespoke_spec prove that its order really is a bespoke order
    CONSTRAINT uq_order_type UNIQUE (order_id, order_type)
);

CREATE TABLE order_item (
    order_id    BIGINT        NOT NULL REFERENCES customer_order (order_id) ON DELETE CASCADE,
    line_no     SMALLINT      NOT NULL CHECK (line_no > 0),
    variant_id  INTEGER       NOT NULL REFERENCES product_variant (variant_id),
    quantity    SMALLINT      NOT NULL CHECK (quantity BETWEEN 1 AND 10),
    -- price AT THE TIME OF SALE. Not redundant with product_variant.unit_price:
    -- catalogue prices change, invoices must not.
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    PRIMARY KEY (order_id, line_no),
    CONSTRAINT uq_order_variant UNIQUE (order_id, variant_id)
);

-- Made-to-measure details exist only for bespoke orders (1 : 0..1)
CREATE TABLE bespoke_spec (
    order_id        BIGINT       PRIMARY KEY,
    order_type      VARCHAR(10)  NOT NULL DEFAULT 'bespoke' CHECK (order_type = 'bespoke'),
    foot_length_cm  NUMERIC(4,1) NOT NULL CHECK (foot_length_cm BETWEEN 20 AND 35),
    foot_width_cm   NUMERIC(4,1) NOT NULL CHECK (foot_width_cm BETWEEN 7 AND 15),
    leather_choice  VARCHAR(30)  NOT NULL,
    monogram        VARCHAR(6),
    notes           TEXT,
    CONSTRAINT fk_bespoke_order FOREIGN KEY (order_id, order_type)
        REFERENCES customer_order (order_id, order_type) ON DELETE CASCADE
);

CREATE TABLE payment (
    payment_id  BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id    BIGINT        NOT NULL REFERENCES customer_order (order_id),
    reference   VARCHAR(30)   NOT NULL UNIQUE,   -- gateway / bank reference
    method      VARCHAR(10)   NOT NULL CHECK (method IN ('card', 'transfer', 'pos', 'ussd')),
    amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    status      VARCHAR(10)   NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'successful', 'failed', 'reversed')),
    paid_at     TIMESTAMP,
    CONSTRAINT chk_paid_at CHECK (status <> 'successful' OR paid_at IS NOT NULL)
);

CREATE TABLE delivery (
    delivery_id    BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id       BIGINT       NOT NULL UNIQUE REFERENCES customer_order (order_id),  -- 1 : 0..1
    courier        VARCHAR(30)  NOT NULL,
    tracking_no    VARCHAR(30)  UNIQUE,
    dispatched_at  TIMESTAMP,
    delivered_at   TIMESTAMP,
    CONSTRAINT chk_delivery_dates CHECK (
        delivered_at IS NULL OR (dispatched_at IS NOT NULL AND delivered_at >= dispatched_at))
);

-- Audit trail of every stock change (restock, sale, return, adjustment)
CREATE TABLE stock_movement (
    movement_id  BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    variant_id   INTEGER     NOT NULL REFERENCES product_variant (variant_id),
    change_qty   INTEGER     NOT NULL CHECK (change_qty <> 0),
    reason       VARCHAR(12) NOT NULL CHECK (reason IN ('restock', 'sale', 'return', 'adjustment')),
    order_id     BIGINT      REFERENCES customer_order (order_id),
    moved_at     TIMESTAMP   NOT NULL DEFAULT now()
);

-- Make the schema the default for this database so later scripts need no prefix
ALTER DATABASE finesse_klass SET search_path TO fk, public;
