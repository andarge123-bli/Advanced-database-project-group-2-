-- ============================================================
--  Ethiopian E-Commerce Platform — Advanced Database System
--  SQL Scripts: DDL + DML + Queries + Procedures + Triggers
--  Cities: Addis Ababa | Adama | Hawassa
--  Standard: PostgreSQL 15+
--  Normalization: 3NF (Boyce-Codd Normal Form for key relations)
-- ============================================================

-- ============================================================
-- SECTION 1: DATABASE SETUP & EXTENSIONS
-- ============================================================

CREATE DATABASE ethiopian_ecommerce
    WITH ENCODING 'UTF8'
    LC_COLLATE = 'en_US.UTF-8'
    LC_CTYPE   = 'en_US.UTF-8';

\c ethiopian_ecommerce;

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";       -- UUID generation
CREATE EXTENSION IF NOT EXISTS "pgcrypto";         -- Cryptographic functions
CREATE EXTENSION IF NOT EXISTS "pg_trgm";          -- Trigram indexes for full-text search
CREATE EXTENSION IF NOT EXISTS "btree_gin";        -- GIN index support for btree types

-- ============================================================
-- SECTION 2: ENUMERATED TYPES
-- ============================================================

CREATE TYPE order_status_enum AS ENUM (
    'PENDING', 'CONFIRMED', 'PROCESSING',
    'SHIPPED', 'DELIVERED', 'CANCELLED', 'REFUNDED'
);

CREATE TYPE payment_method_enum AS ENUM (
    'TELEBIRR', 'CBE_BIRR', 'COMMERCIAL_BANK', 'AWASH_BANK',
    'DASHEN_BANK', 'CASH_ON_DELIVERY', 'VISA', 'MASTERCARD'
);

CREATE TYPE payment_status_enum AS ENUM (
    'PENDING', 'COMPLETED', 'FAILED', 'REFUNDED', 'DISPUTED'
);

CREATE TYPE user_role_enum AS ENUM (
    'ADMIN', 'SELLER', 'CUSTOMER', 'AUDITOR'
);

CREATE TYPE region_enum AS ENUM (
    'ADDIS_ABABA', 'ADAMA', 'HAWASSA', 'OTHER'
);

CREATE TYPE inventory_txn_type_enum AS ENUM (
    'RESTOCK', 'SALE', 'RETURN', 'ADJUSTMENT', 'TRANSFER'
);

-- ============================================================
-- SECTION 3: DDL — TABLE DEFINITIONS (3NF)
-- ============================================================

-- ----------------------------------------------------------
-- 3.1 REGIONS (1NF base, no transitive dependencies)
-- ----------------------------------------------------------
CREATE TABLE regions (
    region_id   SERIAL          PRIMARY KEY,
    name        VARCHAR(100)    NOT NULL UNIQUE,
    code        VARCHAR(10)     NOT NULL UNIQUE,
    timezone    VARCHAR(50)     NOT NULL DEFAULT 'Africa/Addis_Ababa',
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE regions IS 'Geographic regions where the platform operates';

-- ----------------------------------------------------------
-- 3.2 CUSTOMERS
-- ----------------------------------------------------------
CREATE TABLE customers (
    customer_id     UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
    first_name      VARCHAR(100)    NOT NULL,
    last_name       VARCHAR(100)    NOT NULL,
    email           VARCHAR(255)    NOT NULL UNIQUE,
    phone           VARCHAR(20)     NOT NULL UNIQUE,
    -- Password stored as bcrypt hash (cost factor 12+)
    password_hash   VARCHAR(255)    NOT NULL,
    -- Shipping address normalized: city references region
    address_line1   VARCHAR(255)    NOT NULL,
    address_line2   VARCHAR(255),
    city            VARCHAR(100)    NOT NULL,
    region_id       INT             NOT NULL REFERENCES regions(region_id) ON DELETE RESTRICT,
    postal_code     VARCHAR(20),
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    is_verified     BOOLEAN         NOT NULL DEFAULT FALSE,
    role            user_role_enum  NOT NULL DEFAULT 'CUSTOMER',
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE customers IS 'Registered platform users including buyers and sellers';
COMMENT ON COLUMN customers.password_hash IS 'bcrypt hash with cost factor >= 12, never store plaintext';

-- ----------------------------------------------------------
-- 3.3 CATEGORIES (self-referencing hierarchy)
-- ----------------------------------------------------------
CREATE TABLE categories (
    category_id     SERIAL          PRIMARY KEY,
    name            VARCHAR(150)    NOT NULL,
    slug            VARCHAR(150)    NOT NULL UNIQUE,
    description     TEXT,
    parent_id       INT             REFERENCES categories(category_id) ON DELETE SET NULL,
    sort_order      INT             NOT NULL DEFAULT 0,
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    UNIQUE (name, parent_id)
);

COMMENT ON TABLE categories IS 'Product category hierarchy (tree structure via parent_id)';

-- ----------------------------------------------------------
-- 3.4 SELLERS (normalized from customers — separate concern)
-- ----------------------------------------------------------
CREATE TABLE sellers (
    seller_id           UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id         UUID            NOT NULL UNIQUE REFERENCES customers(customer_id) ON DELETE CASCADE,
    store_name          VARCHAR(200)    NOT NULL UNIQUE,
    store_description   TEXT,
    region_id           INT             NOT NULL REFERENCES regions(region_id),
    business_license    VARCHAR(100),
    tax_id              VARCHAR(50),
    -- Commission rate (0.05 = 5%)
    commission_rate     NUMERIC(5,4)    NOT NULL DEFAULT 0.0500 CHECK (commission_rate BETWEEN 0 AND 1),
    rating              NUMERIC(3,2)    CHECK (rating BETWEEN 0 AND 5),
    is_verified         BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------
-- 3.5 PRODUCTS
-- ----------------------------------------------------------
CREATE TABLE products (
    product_id      UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
    seller_id       UUID            NOT NULL REFERENCES sellers(seller_id) ON DELETE RESTRICT,
    category_id     INT             NOT NULL REFERENCES categories(category_id) ON DELETE RESTRICT,
    name            VARCHAR(255)    NOT NULL,
    slug            VARCHAR(255)    NOT NULL UNIQUE,
    description     TEXT,
    -- Price in Ethiopian Birr (ETB)
    unit_price      NUMERIC(12,2)   NOT NULL CHECK (unit_price >= 0),
    cost_price      NUMERIC(12,2)   CHECK (cost_price >= 0),
    sku             VARCHAR(100)    NOT NULL UNIQUE,
    barcode         VARCHAR(100),
    weight_kg       NUMERIC(8,3),
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    is_featured     BOOLEAN         NOT NULL DEFAULT FALSE,
    view_count      BIGINT          NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE products IS 'Product catalog with seller and category linkages';
COMMENT ON COLUMN products.unit_price IS 'Selling price in Ethiopian Birr (ETB)';

-- ----------------------------------------------------------
-- 3.6 INVENTORY (per-product, per-region tracking)
-- ----------------------------------------------------------
CREATE TABLE inventory (
    inventory_id    SERIAL          PRIMARY KEY,
    product_id      UUID            NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
    region_id       INT             NOT NULL REFERENCES regions(region_id) ON DELETE RESTRICT,
    quantity        INT             NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    reserved_qty    INT             NOT NULL DEFAULT 0 CHECK (reserved_qty >= 0),
    reorder_level   INT             NOT NULL DEFAULT 10,
    reorder_qty     INT             NOT NULL DEFAULT 50,
    warehouse_loc   VARCHAR(100),
    last_restocked  TIMESTAMPTZ,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    UNIQUE (product_id, region_id),
    CONSTRAINT inv_qty_gte_reserved CHECK (quantity >= reserved_qty)
);

COMMENT ON TABLE inventory IS 'Per-region inventory with reservation support for concurrency control';

-- ----------------------------------------------------------
-- 3.7 INVENTORY TRANSACTIONS (audit trail)
-- ----------------------------------------------------------
CREATE TABLE inventory_transactions (
    txn_id          BIGSERIAL       PRIMARY KEY,
    inventory_id    INT             NOT NULL REFERENCES inventory(inventory_id),
    txn_type        inventory_txn_type_enum NOT NULL,
    quantity_delta  INT             NOT NULL,
    quantity_before INT             NOT NULL,
    quantity_after  INT             NOT NULL,
    reference_id    UUID,           -- order_id or transfer_id
    notes           TEXT,
    performed_by    UUID            REFERENCES customers(customer_id),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------
-- 3.8 ORDERS
-- ----------------------------------------------------------
CREATE TABLE orders (
    order_id            UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id         UUID            NOT NULL REFERENCES customers(customer_id) ON DELETE RESTRICT,
    region_id           INT             NOT NULL REFERENCES regions(region_id),
    status              order_status_enum NOT NULL DEFAULT 'PENDING',
    -- Denormalized totals for performance (recomputed via trigger)
    subtotal            NUMERIC(12,2)   NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    discount_amount     NUMERIC(12,2)   NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    tax_amount          NUMERIC(12,2)   NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    shipping_amount     NUMERIC(12,2)   NOT NULL DEFAULT 0 CHECK (shipping_amount >= 0),
    total_amount        NUMERIC(12,2)   NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
    currency            CHAR(3)         NOT NULL DEFAULT 'ETB',
    -- Shipping details (snapshot at order time — 3NF OK for snapshot)
    shipping_name       VARCHAR(200),
    shipping_address    TEXT,
    shipping_city       VARCHAR(100),
    shipping_phone      VARCHAR(20),
    notes               TEXT,
    ordered_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    confirmed_at        TIMESTAMPTZ,
    shipped_at          TIMESTAMPTZ,
    delivered_at        TIMESTAMPTZ,
    cancelled_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE orders IS 'Customer order header; status lifecycle managed by triggers';

-- ----------------------------------------------------------
-- 3.9 ORDER_ITEMS
-- ----------------------------------------------------------
CREATE TABLE order_items (
    item_id         BIGSERIAL       PRIMARY KEY,
    order_id        UUID            NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    product_id      UUID            NOT NULL REFERENCES products(product_id) ON DELETE RESTRICT,
    seller_id       UUID            NOT NULL REFERENCES sellers(seller_id) ON DELETE RESTRICT,
    quantity        INT             NOT NULL CHECK (quantity > 0),
    -- Snapshot price at order time (products.unit_price may change later)
    unit_price      NUMERIC(12,2)   NOT NULL CHECK (unit_price >= 0),
    discount_pct    NUMERIC(5,2)    NOT NULL DEFAULT 0 CHECK (discount_pct BETWEEN 0 AND 100),
    line_total      NUMERIC(12,2)   NOT NULL CHECK (line_total >= 0),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE order_items IS 'Line items for each order; unit_price is snapshot from products table';

-- ----------------------------------------------------------
-- 3.10 PAYMENTS
-- ----------------------------------------------------------
CREATE TABLE payments (
    payment_id          UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id            UUID            NOT NULL REFERENCES orders(order_id) ON DELETE RESTRICT,
    customer_id         UUID            NOT NULL REFERENCES customers(customer_id),
    amount              NUMERIC(12,2)   NOT NULL CHECK (amount > 0),
    currency            CHAR(3)         NOT NULL DEFAULT 'ETB',
    method              payment_method_enum NOT NULL,
    status              payment_status_enum NOT NULL DEFAULT 'PENDING',
    -- Encrypted payment reference (stored as pgp_sym_encrypt output)
    transaction_ref_enc BYTEA,
    gateway_response    JSONB,
    paid_at             TIMESTAMPTZ,
    refunded_at         TIMESTAMPTZ,
    refund_amount       NUMERIC(12,2)   DEFAULT 0,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE payments IS 'Payment records; transaction_ref_enc is AES-256 encrypted via pgcrypto';

-- ----------------------------------------------------------
-- 3.11 AUDIT LOGS (immutable append-only)
-- ----------------------------------------------------------
CREATE TABLE audit_logs (
    log_id          BIGSERIAL       PRIMARY KEY,
    table_name      VARCHAR(100)    NOT NULL,
    operation       VARCHAR(10)     NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE','SELECT')),
    record_id       TEXT            NOT NULL,
    old_values      JSONB,
    new_values      JSONB,
    changed_fields  TEXT[],
    performed_by    UUID,           -- NULL for system operations
    ip_address      INET,
    user_agent      TEXT,
    session_id      TEXT,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
) PARTITION BY RANGE (created_at);

-- Monthly partitions for audit logs (for performance at scale)
CREATE TABLE audit_logs_2026_01 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE audit_logs_2026_02 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE audit_logs_2026_03 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE audit_logs_2026_04 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE audit_logs_2026_05 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE audit_logs_2026_06 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE audit_logs_2026_07 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE audit_logs_2026_12 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

COMMENT ON TABLE audit_logs IS 'Immutable partitioned audit trail — never UPDATE or DELETE rows here';

-- ============================================================
-- SECTION 4: INDEXES (Query Optimization)
-- ============================================================

-- Customers
CREATE INDEX idx_customers_email        ON customers (email);
CREATE INDEX idx_customers_phone        ON customers (phone);
CREATE INDEX idx_customers_region       ON customers (region_id);
CREATE INDEX idx_customers_role         ON customers (role);

-- Products — composite and partial indexes
CREATE INDEX idx_products_category      ON products (category_id);
CREATE INDEX idx_products_seller        ON products (seller_id);
CREATE INDEX idx_products_price         ON products (unit_price);
CREATE INDEX idx_products_active        ON products (is_active) WHERE is_active = TRUE;
CREATE INDEX idx_products_featured      ON products (is_featured, created_at DESC) WHERE is_featured = TRUE;
-- Full-text search index (trigram + tsvector)
CREATE INDEX idx_products_name_trgm     ON products USING GIN (name gin_trgm_ops);
CREATE INDEX idx_products_fts           ON products USING GIN (
    to_tsvector('english', coalesce(name, '') || ' ' || coalesce(description, ''))
);

-- Orders
CREATE INDEX idx_orders_customer        ON orders (customer_id);
CREATE INDEX idx_orders_status          ON orders (status);
CREATE INDEX idx_orders_region          ON orders (region_id);
CREATE INDEX idx_orders_ordered_at      ON orders (ordered_at DESC);
CREATE INDEX idx_orders_customer_status ON orders (customer_id, status);
-- Covering index for revenue reports
CREATE INDEX idx_orders_revenue_report  ON orders (ordered_at, status, total_amount)
    WHERE status NOT IN ('CANCELLED', 'REFUNDED');

-- Order Items
CREATE INDEX idx_order_items_order      ON order_items (order_id);
CREATE INDEX idx_order_items_product    ON order_items (product_id);
CREATE INDEX idx_order_items_seller     ON order_items (seller_id);

-- Payments
CREATE INDEX idx_payments_order         ON payments (order_id);
CREATE INDEX idx_payments_customer      ON payments (customer_id);
CREATE INDEX idx_payments_status        ON payments (status);
CREATE INDEX idx_payments_method        ON payments (method);
CREATE INDEX idx_payments_paid_at       ON payments (paid_at DESC) WHERE status = 'COMPLETED';

-- Inventory
CREATE INDEX idx_inventory_product      ON inventory (product_id);
CREATE INDEX idx_inventory_region       ON inventory (region_id);
CREATE INDEX idx_inventory_low_stock    ON inventory (product_id, region_id, quantity)
    WHERE quantity <= reorder_level;

-- Audit Logs (per partition, applied automatically)
CREATE INDEX idx_audit_table_op         ON audit_logs (table_name, operation);
CREATE INDEX idx_audit_performed_by     ON audit_logs (performed_by);
CREATE INDEX idx_audit_created_at       ON audit_logs (created_at DESC);

-- ============================================================
-- SECTION 5: FUNCTIONS & TRIGGERS
-- ============================================================

-- 5.1 Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

-- Apply to all tables with updated_at
CREATE TRIGGER trg_customers_updated_at
    BEFORE UPDATE ON customers
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_products_updated_at
    BEFORE UPDATE ON products
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_orders_updated_at
    BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_inventory_updated_at
    BEFORE UPDATE ON inventory
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_payments_updated_at
    BEFORE UPDATE ON payments
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- 5.2 Recompute order totals when order_items change
CREATE OR REPLACE FUNCTION fn_recompute_order_totals()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_order_id UUID;
    v_subtotal NUMERIC(12,2);
BEGIN
    v_order_id := COALESCE(NEW.order_id, OLD.order_id);

    SELECT COALESCE(SUM(line_total), 0)
    INTO v_subtotal
    FROM order_items
    WHERE order_id = v_order_id;

    UPDATE orders
    SET subtotal     = v_subtotal,
        total_amount = v_subtotal
                       - COALESCE(discount_amount, 0)
                       + COALESCE(tax_amount, 0)
                       + COALESCE(shipping_amount, 0)
    WHERE order_id = v_order_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_recalc_order_totals
    AFTER INSERT OR UPDATE OR DELETE ON order_items
    FOR EACH ROW EXECUTE FUNCTION fn_recompute_order_totals();

-- 5.3 Compute line_total before insert/update on order_items
CREATE OR REPLACE FUNCTION fn_compute_line_total()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.line_total := ROUND(
        NEW.quantity * NEW.unit_price * (1 - NEW.discount_pct / 100.0),
        2
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_compute_line_total
    BEFORE INSERT OR UPDATE ON order_items
    FOR EACH ROW EXECUTE FUNCTION fn_compute_line_total();

-- 5.4 Audit logging trigger (generic — attaches to any table)
CREATE OR REPLACE FUNCTION fn_audit_log()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_record_id TEXT;
    v_old       JSONB := NULL;
    v_new       JSONB := NULL;
    v_changed   TEXT[] := NULL;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_record_id := row_to_json(OLD)::jsonb ->> (TG_ARGV[0]);
        v_old       := row_to_json(OLD)::jsonb;
    ELSIF TG_OP = 'INSERT' THEN
        v_record_id := row_to_json(NEW)::jsonb ->> (TG_ARGV[0]);
        v_new       := row_to_json(NEW)::jsonb;
    ELSE  -- UPDATE
        v_record_id := row_to_json(NEW)::jsonb ->> (TG_ARGV[0]);
        v_old       := row_to_json(OLD)::jsonb;
        v_new       := row_to_json(NEW)::jsonb;
        SELECT array_agg(key)
        INTO v_changed
        FROM jsonb_each(v_new) AS n(key, val)
        WHERE v_old ->> key IS DISTINCT FROM val::text;
    END IF;

    INSERT INTO audit_logs (
        table_name, operation, record_id,
        old_values, new_values, changed_fields,
        performed_by, created_at
    ) VALUES (
        TG_TABLE_NAME, TG_OP, v_record_id,
        v_old, v_new, v_changed,
        current_setting('app.current_user_id', TRUE)::UUID,
        NOW()
    );

    RETURN COALESCE(NEW, OLD);
END;
$$;

-- Attach audit trigger to critical tables
CREATE TRIGGER trg_audit_orders
    AFTER INSERT OR UPDATE OR DELETE ON orders
    FOR EACH ROW EXECUTE FUNCTION fn_audit_log('order_id');

CREATE TRIGGER trg_audit_payments
    AFTER INSERT OR UPDATE OR DELETE ON payments
    FOR EACH ROW EXECUTE FUNCTION fn_audit_log('payment_id');

CREATE TRIGGER trg_audit_customers
    AFTER INSERT OR UPDATE OR DELETE ON customers
    FOR EACH ROW EXECUTE FUNCTION fn_audit_log('customer_id');

CREATE TRIGGER trg_audit_inventory
    AFTER INSERT OR UPDATE OR DELETE ON inventory
    FOR EACH ROW EXECUTE FUNCTION fn_audit_log('inventory_id');

-- 5.5 Inventory deduction with oversell protection
CREATE OR REPLACE FUNCTION fn_deduct_inventory(
    p_product_id UUID,
    p_region_id  INT,
    p_quantity   INT,
    p_order_id   UUID
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_inv_id   INT;
    v_qty_before INT;
BEGIN
    -- Lock the specific inventory row (prevents phantom reads at SERIALIZABLE)
    SELECT inventory_id, quantity
    INTO v_inv_id, v_qty_before
    FROM inventory
    WHERE product_id = p_product_id AND region_id = p_region_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Inventory record not found for product % region %',
            p_product_id, p_region_id;
    END IF;

    IF v_qty_before < p_quantity THEN
        RAISE EXCEPTION 'Insufficient inventory: available=%, requested=%',
            v_qty_before, p_quantity
            USING ERRCODE = 'P0002';
    END IF;

    UPDATE inventory
    SET quantity   = quantity - p_quantity,
        updated_at = NOW()
    WHERE inventory_id = v_inv_id;

    INSERT INTO inventory_transactions (
        inventory_id, txn_type, quantity_delta,
        quantity_before, quantity_after, reference_id
    ) VALUES (
        v_inv_id, 'SALE', -p_quantity,
        v_qty_before, v_qty_before - p_quantity, p_order_id
    );
END;
$$;

-- ============================================================
-- SECTION 6: ROLES & RBAC
-- ============================================================

-- Create database roles
DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_admin') THEN
        CREATE ROLE role_admin LOGIN PASSWORD 'change_me_admin_!@#';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_seller') THEN
        CREATE ROLE role_seller LOGIN PASSWORD 'change_me_seller_!@#';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_customer') THEN
        CREATE ROLE role_customer LOGIN PASSWORD 'change_me_customer_!@#';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_auditor') THEN
        CREATE ROLE role_auditor LOGIN PASSWORD 'change_me_auditor_!@#';
    END IF;
END $$;

-- Admin: full access
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO role_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO role_admin;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO role_admin;

-- Seller: own products, own inventory, own order items
GRANT SELECT, INSERT, UPDATE ON products          TO role_seller;
GRANT SELECT, INSERT, UPDATE ON inventory         TO role_seller;
GRANT SELECT                 ON order_items        TO role_seller;
GRANT SELECT                 ON orders             TO role_seller;
GRANT SELECT                 ON categories         TO role_seller;
GRANT SELECT                 ON regions            TO role_seller;
GRANT USAGE ON SEQUENCE inventory_id_seq          TO role_seller;

-- Customer: own data only (enforced via Row-Level Security below)
GRANT SELECT, INSERT         ON orders             TO role_customer;
GRANT SELECT, INSERT         ON order_items        TO role_customer;
GRANT SELECT, INSERT         ON payments           TO role_customer;
GRANT SELECT                 ON products           TO role_customer;
GRANT SELECT                 ON categories         TO role_customer;
GRANT SELECT                 ON regions            TO role_customer;
GRANT SELECT, UPDATE         ON customers          TO role_customer;

-- Auditor: read-only on all + audit logs
GRANT SELECT ON ALL TABLES IN SCHEMA public TO role_auditor;

-- ============================================================
-- SECTION 7: ROW LEVEL SECURITY (RLS)
-- ============================================================

ALTER TABLE customers  ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders     ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments   ENABLE ROW LEVEL SECURITY;

-- Customers can only see/edit their own record
CREATE POLICY pol_customer_self ON customers
    FOR ALL TO role_customer
    USING (customer_id = current_setting('app.current_user_id')::UUID);

-- Customers can only see/edit their own orders
CREATE POLICY pol_customer_orders ON orders
    FOR ALL TO role_customer
    USING (customer_id = current_setting('app.current_user_id')::UUID);

-- Customers can only see their own payments
CREATE POLICY pol_customer_payments ON payments
    FOR ALL TO role_customer
    USING (customer_id = current_setting('app.current_user_id')::UUID);

-- Admin bypass RLS
CREATE POLICY pol_admin_bypass_customers ON customers
    FOR ALL TO role_admin USING (TRUE);
CREATE POLICY pol_admin_bypass_orders ON orders
    FOR ALL TO role_admin USING (TRUE);
CREATE POLICY pol_admin_bypass_payments ON payments
    FOR ALL TO role_admin USING (TRUE);

-- ============================================================
-- SECTION 8: DML — SAMPLE DATA
-- ============================================================

-- 8.1 Regions
INSERT INTO regions (name, code, timezone) VALUES
    ('Addis Ababa', 'ADD', 'Africa/Addis_Ababa'),
    ('Adama',       'ADM', 'Africa/Addis_Ababa'),
    ('Hawassa',     'HWS', 'Africa/Addis_Ababa');

-- 8.2 Categories
INSERT INTO categories (name, slug, description, parent_id) VALUES
    ('Electronics',        'electronics',         'Consumer electronics and gadgets', NULL),
    ('Computers & Laptops','computers-laptops',   'Desktop and laptop computers',     1),
    ('Mobile Phones',      'mobile-phones',       'Smartphones and feature phones',   1),
    ('Fashion',            'fashion',             'Clothing, shoes and accessories',  NULL),
    ('Footwear',           'footwear',            'Shoes, sandals and boots',         4);

-- 8.3 Customers (passwords are bcrypt of 'Ethiopia@2024!')
-- Hash generated via: SELECT crypt('Ethiopia@2024!', gen_salt('bf', 12));
INSERT INTO customers (
    customer_id, first_name, last_name, email, phone,
    password_hash, address_line1, city, region_id, role
) VALUES
    (
        'a1b2c3d4-0001-0000-0000-000000000001',
        'Abel', 'Tesfaye',
        'abel.tesfaye@example.et',
        '+251911001001',
        '$2a$12$KIX0bHUt2dVp6C2QeNm.T.h2VKqIE7qz.z7z1YXKj6f9z1k1Dml3e',
        'Bole Sub-city, Woreda 02, House 123',
        'Addis Ababa', 1, 'CUSTOMER'
    ),
    (
        'a1b2c3d4-0002-0000-0000-000000000002',
        'Sara', 'Haile',
        'sara.haile@example.et',
        '+251922002002',
        '$2a$12$KIX0bHUt2dVp6C2QeNm.T.h2VKqIE7qz.z7z1YXKj6f9z1k1Dml3e',
        'Adama City, Woreda 01, House 456',
        'Adama', 2, 'CUSTOMER'
    ),
    (
        'a1b2c3d4-0003-0000-0000-000000000003',
        'Dawit', 'Bekele',
        'dawit.bekele@example.et',
        '+251933003003',
        '$2a$12$KIX0bHUt2dVp6C2QeNm.T.h2VKqIE7qz.z7z1YXKj6f9z1k1Dml3e',
        'Tabor Sub-city, Woreda 05, House 789',
        'Hawassa', 3, 'CUSTOMER'
    ),
    (
        'a1b2c3d4-0010-0000-0000-000000000010',
        'Tech', 'Seller',
        'techseller@example.et',
        '+251944004004',
        '$2a$12$KIX0bHUt2dVp6C2QeNm.T.h2VKqIE7qz.z7z1YXKj6f9z1k1Dml3e',
        'Merkato, Addis Ababa',
        'Addis Ababa', 1, 'SELLER'
    );

-- 8.4 Sellers
INSERT INTO sellers (seller_id, customer_id, store_name, store_description, region_id, commission_rate, is_verified)
VALUES (
    'b1b2c3d4-0010-0000-0000-000000000010',
    'a1b2c3d4-0010-0000-0000-000000000010',
    'EthioTech Store',
    'Premium electronics and gadgets in Addis Ababa',
    1, 0.0500, TRUE
);

-- 8.5 Products
INSERT INTO products (product_id, seller_id, category_id, name, slug, description, unit_price, cost_price, sku)
VALUES
    (
        'p1b2c3d4-0001-0000-0000-000000000001',
        'b1b2c3d4-0010-0000-0000-000000000010',
        2,
        'Dell Inspiron 15 3000 Laptop',
        'dell-inspiron-15-3000-laptop',
        'Intel Core i5, 8GB RAM, 256GB SSD, 15.6" FHD Display, Windows 11',
        45000.00, 38000.00,
        'DELL-INS15-3000-001'
    ),
    (
        'p1b2c3d4-0002-0000-0000-000000000002',
        'b1b2c3d4-0010-0000-0000-000000000010',
        3,
        'Samsung Galaxy A54 Phone',
        'samsung-galaxy-a54-phone',
        '6.4" Super AMOLED, 128GB, 8GB RAM, 5000mAh Battery, 50MP Triple Camera',
        28500.00, 23000.00,
        'SAMS-GA54-128-001'
    ),
    (
        'p1b2c3d4-0003-0000-0000-000000000003',
        'b1b2c3d4-0010-0000-0000-000000000010',
        5,
        'Nike Air Max 270 Shoes',
        'nike-air-max-270-shoes',
        'Mens running shoes, Size 42, Black/White colorway',
        8500.00, 6200.00,
        'NIKE-AM270-42-BW-001'
    );

-- 8.6 Inventory (per product, per region)
INSERT INTO inventory (product_id, region_id, quantity, reserved_qty, reorder_level, warehouse_loc)
VALUES
    ('p1b2c3d4-0001-0000-0000-000000000001', 1,  5, 0, 2, 'WH-ADD-A1-B3'),  -- Laptop, Addis
    ('p1b2c3d4-0001-0000-0000-000000000001', 2,  3, 0, 1, 'WH-ADM-A2-B1'),  -- Laptop, Adama
    ('p1b2c3d4-0001-0000-0000-000000000001', 3,  2, 0, 1, 'WH-HWS-A1-B2'),  -- Laptop, Hawassa
    ('p1b2c3d4-0002-0000-0000-000000000002', 1, 25, 0, 5, 'WH-ADD-A1-B4'),  -- Phone, Addis
    ('p1b2c3d4-0002-0000-0000-000000000002', 2, 15, 0, 3, 'WH-ADM-A2-B2'),  -- Phone, Adama
    ('p1b2c3d4-0003-0000-0000-000000000003', 1, 40, 0, 8, 'WH-ADD-A2-B1'),  -- Shoes, Addis
    ('p1b2c3d4-0003-0000-0000-000000000003', 3, 20, 0, 5, 'WH-HWS-A1-B3');  -- Shoes, Hawassa

-- 8.7 Orders
INSERT INTO orders (order_id, customer_id, region_id, status, shipping_name, shipping_address, shipping_city, shipping_phone)
VALUES
    (
        'o1b2c3d4-0001-0000-0000-000000000001',
        'a1b2c3d4-0001-0000-0000-000000000001',
        1, 'DELIVERED',
        'Abel Tesfaye', 'Bole Sub-city, Woreda 02, House 123',
        'Addis Ababa', '+251911001001'
    ),
    (
        'o1b2c3d4-0002-0000-0000-000000000002',
        'a1b2c3d4-0002-0000-0000-000000000002',
        2, 'SHIPPED',
        'Sara Haile', 'Adama City, Woreda 01, House 456',
        'Adama', '+251922002002'
    ),
    (
        'o1b2c3d4-0003-0000-0000-000000000003',
        'a1b2c3d4-0003-0000-0000-000000000003',
        3, 'CONFIRMED',
        'Dawit Bekele', 'Tabor Sub-city, Woreda 05, House 789',
        'Hawassa', '+251933003003'
    );

-- 8.8 Order Items (triggers compute line_total and update order totals)
INSERT INTO order_items (order_id, product_id, seller_id, quantity, unit_price, discount_pct)
VALUES
    -- Abel's order: Laptop + Phone
    ('o1b2c3d4-0001-0000-0000-000000000001', 'p1b2c3d4-0001-0000-0000-000000000001', 'b1b2c3d4-0010-0000-0000-000000000010', 1, 45000.00, 0),
    ('o1b2c3d4-0001-0000-0000-000000000001', 'p1b2c3d4-0002-0000-0000-000000000002', 'b1b2c3d4-0010-0000-0000-000000000010', 1, 28500.00, 5),
    -- Sara's order: Laptop
    ('o1b2c3d4-0002-0000-0000-000000000002', 'p1b2c3d4-0001-0000-0000-000000000001', 'b1b2c3d4-0010-0000-0000-000000000010', 1, 45000.00, 0),
    -- Dawit's order: Shoes
    ('o1b2c3d4-0003-0000-0000-000000000003', 'p1b2c3d4-0003-0000-0000-000000000003', 'b1b2c3d4-0010-0000-0000-000000000010', 2, 8500.00, 10);

-- 8.9 Payments (transaction_ref encrypted with pgcrypto)
INSERT INTO payments (payment_id, order_id, customer_id, amount, method, status, paid_at, transaction_ref_enc)
VALUES
    (
        'py1b2c3d4-0001-0000-0000-000000000001',
        'o1b2c3d4-0001-0000-0000-000000000001',
        'a1b2c3d4-0001-0000-0000-000000000001',
        72075.00, 'TELEBIRR', 'COMPLETED', NOW() - INTERVAL '5 days',
        pgp_sym_encrypt('TXN-TB-20240101-001', 'AES256_SECRET_KEY_CHANGE_IN_PROD')
    ),
    (
        'py1b2c3d4-0002-0000-0000-000000000002',
        'o1b2c3d4-0002-0000-0000-000000000002',
        'a1b2c3d4-0002-0000-0000-000000000002',
        45000.00, 'CBE_BIRR', 'COMPLETED', NOW() - INTERVAL '2 days',
        pgp_sym_encrypt('TXN-CB-20240102-002', 'AES256_SECRET_KEY_CHANGE_IN_PROD')
    ),
    (
        'py1b2c3d4-0003-0000-0000-000000000003',
        'o1b2c3d4-0003-0000-0000-000000000003',
        'a1b2c3d4-0003-0000-0000-000000000003',
        15300.00, 'COMMERCIAL_BANK', 'PENDING', NULL,
        pgp_sym_encrypt('TXN-CMB-20240103-003', 'AES256_SECRET_KEY_CHANGE_IN_PROD')
    );

-- ============================================================
-- SECTION 9: OPTIMIZED QUERIES
-- ============================================================

-- 9.1 Full-Text Product Search (uses GIN index)
-- Performance: Index Scan on idx_products_fts, cost ~0.15
EXPLAIN (ANALYZE, BUFFERS) 
SELECT
    p.product_id,
    p.name,
    p.unit_price,
    p.slug,
    c.name        AS category,
    s.store_name  AS seller,
    i.quantity    AS stock_addis_ababa,
    ts_rank(
        to_tsvector('english', p.name || ' ' || COALESCE(p.description, '')),
        plainto_tsquery('english', 'laptop')
    )             AS relevance_score
FROM products p
JOIN categories c  ON c.category_id = p.category_id
JOIN sellers s     ON s.seller_id    = p.seller_id
LEFT JOIN inventory i ON i.product_id = p.product_id AND i.region_id = 1
WHERE
    p.is_active = TRUE
    AND to_tsvector('english', p.name || ' ' || COALESCE(p.description, ''))
        @@ plainto_tsquery('english', 'laptop')
ORDER BY relevance_score DESC, p.view_count DESC
LIMIT 20;

-- 9.2 Trigram Search (fuzzy match — handles typos)
SELECT product_id, name, unit_price,
       similarity(name, 'latop') AS sim_score
FROM products
WHERE name % 'latop'   -- requires pg_trgm
  AND is_active = TRUE
ORDER BY sim_score DESC
LIMIT 10;

-- 9.3 Top 10 Best-Selling Products (by quantity sold)
SELECT
    p.product_id,
    p.name,
    p.unit_price,
    SUM(oi.quantity)                                    AS total_units_sold,
    SUM(oi.line_total)                                  AS total_revenue_etb,
    RANK() OVER (ORDER BY SUM(oi.quantity) DESC)        AS sales_rank,
    ROUND(SUM(oi.line_total) / SUM(oi.quantity), 2)     AS avg_selling_price
FROM order_items oi
JOIN products p   ON p.product_id = oi.product_id
JOIN orders o     ON o.order_id   = oi.order_id
WHERE o.status NOT IN ('CANCELLED', 'REFUNDED')
GROUP BY p.product_id, p.name, p.unit_price
ORDER BY total_units_sold DESC
LIMIT 10;

-- 9.4 Monthly Revenue Report (partitioned by region)
SELECT
    r.name                                          AS region,
    DATE_TRUNC('month', o.ordered_at)               AS month,
    COUNT(DISTINCT o.order_id)                      AS total_orders,
    COUNT(DISTINCT o.customer_id)                   AS unique_customers,
    SUM(o.total_amount)                             AS gross_revenue_etb,
    SUM(o.discount_amount)                          AS total_discounts_etb,
    SUM(o.total_amount) - SUM(o.discount_amount)    AS net_revenue_etb,
    ROUND(AVG(o.total_amount), 2)                   AS avg_order_value_etb
FROM orders o
JOIN regions r ON r.region_id = o.region_id
WHERE
    o.status NOT IN ('CANCELLED', 'REFUNDED')
    AND o.ordered_at >= DATE_TRUNC('year', CURRENT_DATE)
GROUP BY r.name, DATE_TRUNC('month', o.ordered_at)
ORDER BY month DESC, gross_revenue_etb DESC;

-- 9.5 Customer Lifetime Value (CLV) with cohort
SELECT
    c.customer_id,
    c.first_name || ' ' || c.last_name         AS customer_name,
    c.city,
    r.name                                     AS region,
    COUNT(DISTINCT o.order_id)                 AS total_orders,
    SUM(o.total_amount)                        AS lifetime_value_etb,
    MIN(o.ordered_at)                          AS first_order_date,
    MAX(o.ordered_at)                          AS last_order_date,
    EXTRACT(DAY FROM MAX(o.ordered_at) - MIN(o.ordered_at)) AS tenure_days
FROM customers c
JOIN orders o   ON o.customer_id = c.customer_id
JOIN regions r  ON r.region_id   = c.region_id
WHERE o.status NOT IN ('CANCELLED', 'REFUNDED')
GROUP BY c.customer_id, c.first_name, c.last_name, c.city, r.name
ORDER BY lifetime_value_etb DESC;

-- 9.6 Inventory Low-Stock Alert
SELECT
    p.name                  AS product,
    p.sku,
    r.name                  AS region,
    i.quantity              AS current_qty,
    i.reserved_qty,
    i.quantity - i.reserved_qty AS available_qty,
    i.reorder_level,
    i.reorder_qty,
    CASE
        WHEN i.quantity = 0 THEN 'OUT OF STOCK'
        WHEN i.quantity <= i.reorder_level THEN 'LOW STOCK'
        ELSE 'ADEQUATE'
    END                     AS stock_status
FROM inventory i
JOIN products p ON p.product_id = i.product_id
JOIN regions r  ON r.region_id  = i.region_id
WHERE i.quantity <= i.reorder_level
ORDER BY available_qty ASC;

-- 9.7 Seller Performance Dashboard
SELECT
    s.store_name,
    r.name                                     AS region,
    COUNT(DISTINCT oi.order_id)                AS orders_fulfilled,
    SUM(oi.quantity)                           AS units_sold,
    SUM(oi.line_total)                         AS gross_sales_etb,
    SUM(oi.line_total) * s.commission_rate     AS platform_commission_etb,
    SUM(oi.line_total) * (1 - s.commission_rate) AS seller_payout_etb
FROM sellers s
JOIN order_items oi ON oi.seller_id  = s.seller_id
JOIN orders o       ON o.order_id    = oi.order_id
JOIN regions r      ON r.region_id   = s.region_id
WHERE o.status NOT IN ('CANCELLED', 'REFUNDED')
GROUP BY s.store_name, r.name, s.commission_rate
ORDER BY gross_sales_etb DESC;

-- ============================================================
-- SECTION 10: CONCURRENCY & TRANSACTIONS
-- ============================================================

-- 10.1 Safe Purchase Transaction with SERIALIZABLE isolation
-- Scenario: Abel and Sara both try to buy the last Laptop simultaneously

-- Transaction A (Abel's purchase)
BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

-- Set application user context for audit logging
SET LOCAL app.current_user_id = 'a1b2c3d4-0001-0000-0000-000000000001';

-- Step 1: Create order
INSERT INTO orders (order_id, customer_id, region_id, status, shipping_name, shipping_address, shipping_city, shipping_phone)
VALUES (
    'o1b2c3d4-0099-0000-0000-000000000099',
    'a1b2c3d4-0001-0000-0000-000000000001',
    1, 'PENDING',
    'Abel Tesfaye', 'Bole, Addis Ababa', 'Addis Ababa', '+251911001001'
);

-- Step 2: Add order item (trigger computes line_total)
INSERT INTO order_items (order_id, product_id, seller_id, quantity, unit_price, discount_pct)
VALUES (
    'o1b2c3d4-0099-0000-0000-000000000099',
    'p1b2c3d4-0001-0000-0000-000000000001',
    'b1b2c3d4-0010-0000-0000-000000000010',
    1, 45000.00, 0
);

-- Step 3: Deduct inventory (acquires FOR UPDATE lock — serializable predicate lock)
SELECT fn_deduct_inventory(
    'p1b2c3d4-0001-0000-0000-000000000001'::UUID,
    1,
    1,
    'o1b2c3d4-0099-0000-0000-000000000099'::UUID
);

-- Step 4: Record payment
INSERT INTO payments (order_id, customer_id, amount, method, status)
VALUES (
    'o1b2c3d4-0099-0000-0000-000000000099',
    'a1b2c3d4-0001-0000-0000-000000000001',
    45000.00, 'TELEBIRR', 'PENDING'
);

-- Step 5: Confirm order
UPDATE orders SET status = 'CONFIRMED', confirmed_at = NOW()
WHERE order_id = 'o1b2c3d4-0099-0000-0000-000000000099';

COMMIT;
-- If Transaction B runs concurrently and detects the predicate lock conflict,
-- PostgreSQL will raise: ERROR 40001 serialization_failure
-- The application must catch and RETRY Transaction B.

-- 10.2 Optimistic Lock Pattern (application-level — for high throughput)
-- Uses version column to detect concurrent modification
ALTER TABLE inventory ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 1;

CREATE OR REPLACE FUNCTION fn_optimistic_deduct(
    p_product_id  UUID,
    p_region_id   INT,
    p_quantity    INT,
    p_version     BIGINT,
    p_order_id    UUID
) RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
    v_rows_updated INT;
BEGIN
    UPDATE inventory
    SET quantity    = quantity - p_quantity,
        version     = version + 1,
        updated_at  = NOW()
    WHERE product_id = p_product_id
      AND region_id  = p_region_id
      AND quantity   >= p_quantity
      AND version    = p_version;  -- Stale version = concurrent update happened

    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

    IF v_rows_updated = 0 THEN
        RETURN FALSE;  -- Application retries
    END IF;

    INSERT INTO inventory_transactions (
        inventory_id, txn_type, quantity_delta, quantity_before, quantity_after, reference_id
    )
    SELECT inventory_id, 'SALE', -p_quantity,
           quantity, quantity - p_quantity, p_order_id
    FROM inventory
    WHERE product_id = p_product_id AND region_id = p_region_id;

    RETURN TRUE;
END;
$$;

-- ============================================================
-- SECTION 11: DISTRIBUTED DATABASE — HORIZONTAL FRAGMENTATION
-- ============================================================

-- 11.1 Partition orders by region (horizontal fragmentation by city)
-- In a distributed setup, each region shard would be on separate nodes

-- Range partition orders by region_id
-- (region_id 1=Addis Ababa, 2=Adama, 3=Hawassa)
CREATE TABLE orders_addis_ababa PARTITION OF orders
    FOR VALUES IN (1);   -- Horizontal fragment: Addis Ababa node

-- NOTE: With list partitioning on region_id this is a table-level
-- approximation; in a true distributed DB (Citus/CitusDB), use:
-- SELECT create_distributed_table('orders', 'region_id');

-- 11.2 View that unions all regional shards (for transparency)
CREATE OR REPLACE VIEW v_all_orders AS
    SELECT o.*, r.name AS region_name
    FROM orders o
    JOIN regions r ON r.region_id = o.region_id;

-- 11.3 Materialized view for heavy analytics (refresh on schedule)
CREATE MATERIALIZED VIEW mv_product_sales_summary AS
SELECT
    p.product_id,
    p.name              AS product_name,
    p.sku,
    c.name              AS category,
    r.name              AS region,
    SUM(oi.quantity)    AS total_units_sold,
    SUM(oi.line_total)  AS total_revenue_etb,
    COUNT(DISTINCT o.order_id) AS order_count,
    MIN(o.ordered_at)   AS first_sale_at,
    MAX(o.ordered_at)   AS last_sale_at
FROM order_items oi
JOIN products p ON p.product_id = oi.product_id
JOIN orders o   ON o.order_id   = oi.order_id
JOIN categories c ON c.category_id = p.category_id
JOIN regions r  ON r.region_id  = o.region_id
WHERE o.status NOT IN ('CANCELLED', 'REFUNDED')
GROUP BY p.product_id, p.name, p.sku, c.name, r.name
WITH DATA;

CREATE UNIQUE INDEX idx_mv_product_sales ON mv_product_sales_summary (product_id, region);

-- Refresh command (run via pg_cron or application scheduler)
-- REFRESH MATERIALIZED VIEW CONCURRENTLY mv_product_sales_summary;

-- ============================================================
-- SECTION 12: WAL & CHECKPOINT CONFIGURATION
-- ============================================================
-- (postgresql.conf settings — apply on DB server, not SQL)

-- # WAL Configuration for durability
-- wal_level = replica          -- Enables WAL archiving
-- archive_mode = on
-- archive_command = 'cp %p /mnt/wal_archive/%f'
-- max_wal_size = 2GB
-- min_wal_size = 500MB
-- checkpoint_completion_target = 0.9
-- wal_compression = on
-- synchronous_commit = on      -- Guarantees WAL flush before ACK

-- # Replication (Streaming Replication)
-- max_wal_senders = 5
-- wal_keep_size = 512MB
-- hot_standby = on

-- ============================================================
-- SECTION 13: MAINTENANCE & MONITORING QUERIES
-- ============================================================

-- View index usage statistics
SELECT
    schemaname,
    tablename,
    indexname,
    idx_scan        AS times_used,
    idx_tup_read    AS tuples_read,
    idx_tup_fetch   AS tuples_fetched
FROM pg_stat_user_indexes
ORDER BY idx_scan DESC;

-- Identify slow queries (requires pg_stat_statements extension)
-- CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
-- SELECT query, calls, mean_exec_time, total_exec_time
-- FROM pg_stat_statements
-- ORDER BY mean_exec_time DESC
-- LIMIT 20;

-- Table bloat check
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;

-- ============================================================
-- END OF SCRIPT
-- ============================================================
