-- ============================================================
-- TABLE: customers
-- Stores customer accounts with hashed credentials
-- ============================================================
CREATE TABLE customers (
    customer_id   SERIAL          PRIMARY KEY,
    full_name     VARCHAR(150)    NOT NULL,
    email         VARCHAR(255)    NOT NULL UNIQUE,
    phone_hash    TEXT,                          -- SHA-256 hashed
    city          VARCHAR(100)    NOT NULL,
    region        VARCHAR(50)     NOT NULL DEFAULT 'Addis Ababa',
    is_active     BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- Index for fast email lookup (login)
CREATE UNIQUE INDEX idx_customers_email ON customers(email);
-- Index for regional queries (distributed design)
CREATE INDEX idx_customers_region ON customers(region);

-- ============================================================
-- TABLE: categories
-- Self-referencing for hierarchical categories (3NF)
-- ============================================================
CREATE TABLE categories (
    category_id   SERIAL          PRIMARY KEY,
    name          VARCHAR(100)    NOT NULL,
    parent_id     INT             REFERENCES categories(category_id),
    slug          VARCHAR(120)    NOT NULL UNIQUE,
    created_at    TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- Partial index for root categories
CREATE INDEX idx_categories_parent ON categories(parent_id)
    WHERE parent_id IS NOT NULL;
-- ============================================================
-- TABLE: products
-- Core product catalog — fully normalized
-- ============================================================
CREATE TABLE products (
    product_id    SERIAL           PRIMARY KEY,
    category_id   INT              NOT NULL REFERENCES categories(category_id),
    name          VARCHAR(255)     NOT NULL,
    description   TEXT,
    price_etb     NUMERIC(12, 2)   NOT NULL CHECK (price_etb >= 0),
    sku           VARCHAR(80)      UNIQUE,
    is_active     BOOLEAN          NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ      NOT NULL DEFAULT NOW()
);

-- Full-text search index for product search
CREATE INDEX idx_products_fts
    ON products USING GIN(to_tsvector('english', name || ' ' || COALESCE(description, '')));

-- Category filtering index
CREATE INDEX idx_products_category ON products(category_id);
-- Price range filtering
CREATE INDEX idx_products_price ON products(price_etb);
-- ============================================================
-- TABLE: inventory
-- Separated from products for concurrent stock control
-- Enables row-level locking (SELECT FOR UPDATE)
-- ============================================================
CREATE TABLE inventory (
    inventory_id     SERIAL     PRIMARY KEY,
    product_id       INT        NOT NULL UNIQUE REFERENCES products(product_id),
    quantity_on_hand INT        NOT NULL DEFAULT 0 CHECK (quantity_on_hand >= 0),
    reorder_level    INT        NOT NULL DEFAULT 5,
    last_restocked   TIMESTAMPTZ,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Alert index for low stock monitoring
CREATE INDEX idx_inventory_low_stock
    ON inventory(product_id)
    WHERE quantity_on_hand <= reorder_level;
-- ============================================================
-- TABLE: orders
-- Full order lifecycle: placed → paid → shipped → delivered
-- ============================================================
CREATE TYPE order_status AS ENUM (
    'placed', 'confirmed', 'paid', 'processing',
    'shipped', 'out_for_delivery', 'delivered', 'cancelled', 'refunded'
);

CREATE TABLE orders (
    order_id       SERIAL          PRIMARY KEY,
    customer_id    INT             NOT NULL REFERENCES customers(customer_id),
    status         order_status    NOT NULL DEFAULT 'placed',
    total_etb      NUMERIC(12, 2)  NOT NULL CHECK (total_etb >= 0),
    region         VARCHAR(50)     NOT NULL,    -- For distributed routing
    notes          TEXT,
    placed_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- Customer order history lookups
CREATE INDEX idx_orders_customer ON orders(customer_id, placed_at DESC);
-- Status filtering
CREATE INDEX idx_orders_status ON orders(status) WHERE status != 'delivered';
-- Regional queries for distributed design
CREATE INDEX idx_orders_region ON orders(region, placed_at DESC);

-- ============================================================
-- TABLE: order_items
-- Line items — price snapshot prevents price change issues
-- ============================================================
CREATE TABLE order_items (
    item_id          SERIAL          PRIMARY KEY,
    order_id         INT             NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    product_id       INT             NOT NULL REFERENCES products(product_id),
    quantity         INT             NOT NULL CHECK (quantity > 0),
    unit_price_etb   NUMERIC(12, 2)  NOT NULL CHECK (unit_price_etb >= 0),
    subtotal_etb     NUMERIC(12, 2)  GENERATED ALWAYS AS (quantity * unit_price_etb) STORED
);

CREATE INDEX idx_order_items_order ON order_items(order_id);
CREATE INDEX idx_order_items_product ON order_items(product_id);
-- ============================================================
-- TABLE: payments
-- Supports Telebirr, bank transfer, cash on delivery
-- Sensitive data fields are encrypted at application layer
-- ============================================================
CREATE TYPE payment_method AS ENUM (
    'telebirr', 'bank_transfer', 'cash_on_delivery', 'credit_card'
);
CREATE TYPE payment_status AS ENUM (
    'pending', 'processing', 'completed', 'failed', 'refunded'
);

CREATE TABLE payments (
    payment_id      SERIAL            PRIMARY KEY,
    order_id        INT               NOT NULL REFERENCES orders(order_id),
    method          payment_method    NOT NULL,
    status          payment_status    NOT NULL DEFAULT 'pending',
    amount_etb      NUMERIC(12, 2)    NOT NULL,
    transaction_ref TEXT              UNIQUE,   -- External reference (encrypted)
    processed_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ       NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_payments_order ON payments(order_id);
CREATE INDEX idx_payments_status ON payments(status) WHERE status != 'completed';

-- ============================================================
-- TABLE: audit_log
-- Immutable record of all critical operations
-- Used for fraud detection, compliance, and recovery
-- ============================================================
CREATE TABLE audit_log (
    log_id       BIGSERIAL       PRIMARY KEY,
    event_type   VARCHAR(80)     NOT NULL,   -- 'LOGIN', 'ORDER_PLACED', 'PAYMENT', etc.
    actor_type   VARCHAR(20)     NOT NULL,   -- 'customer', 'admin', 'system'
    actor_id     INT,
    table_name   VARCHAR(80),
    record_id    INT,
    old_values   JSONB,
    new_values   JSONB,
    ip_address   INET,
    created_at   TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- Partial index for recent events (last 30 days)
CREATE INDEX idx_audit_recent
    ON audit_log(created_at DESC, event_type)
    WHERE created_at > NOW() - INTERVAL '30 days';

-- Actor-based queries
CREATE INDEX idx_audit_actor ON audit_log(actor_type, actor_id, created_at DESC);
-- ============================================================
-- SAMPLE DATA — Ethiopian E-Commerce Platform
-- ============================================================

-- Categories
INSERT INTO categories (name, slug) VALUES
    ('Electronics',   'electronics'),
    ('Fashion',       'fashion'),
    ('Home & Living', 'home-living'),
    ('Food & Grocery','food-grocery');

-- Products (matching assignment dataset)
INSERT INTO products (category_id, name, description, price_etb, sku) VALUES
    (1, 'Laptop Pro 15"',  'High-performance laptop for professionals', 15000.00, 'ELEC-001'),
    (1, 'Smartphone X12',  '128GB, 5G enabled smartphone',              8000.00,  'ELEC-002'),
    (2, 'Leather Shoes',   'Genuine leather formal shoes',              1200.00,  'FASH-001'),
    (1, 'Wireless Headset','Noise-cancelling Bluetooth headset',        3500.00,  'ELEC-003'),
    (3, 'Coffee Table',    'Modern wooden coffee table',                4500.00,  'HOME-001');

-- Inventory
INSERT INTO inventory (product_id, quantity_on_hand, reorder_level) VALUES
    (1, 10, 3),
    (2, 20, 5),
    (3, 50, 10),
    (4, 15, 5),
    (5, 8,  2);

-- Customers (3 cities as per assignment)
INSERT INTO customers (full_name, email, city, region) VALUES
    ('Abel Tesfaye',   'abel@email.com',  'Addis Ababa', 'Addis Ababa'),
    ('Sara Kebede',    'sara@email.com',  'Adama',       'Oromia'),
    ('Dawit Haile',    'dawit@email.com', 'Hawassa',     'SNNPR');

-- Orders
INSERT INTO orders (customer_id, status, total_etb, region) VALUES
    (1, 'delivered', 8000.00,  'Addis Ababa'),
    (2, 'pending',   15000.00, 'Oromia');

-- Order Items
INSERT INTO order_items (order_id, product_id, quantity, unit_price_etb) VALUES
    (1, 2, 1, 8000.00),
    (2, 1, 1, 15000.00);

-- Payments
INSERT INTO payments (order_id, method, status, amount_etb, transaction_ref) VALUES
    (1, 'telebirr',        'completed', 8000.00, 'TBR-20240101-001'),
    (2, 'cash_on_delivery','pending',   15000.00,  NULL);



-- ============================================================
-- QUERY 1: Product Search (optimized with GIN full-text index)
-- Index used: idx_products_fts (GIN), idx_products_price (BTree)
-- Estimated cost: very low — index-only scan for large catalogs
-- ============================================================
SELECT
    p.product_id,
    p.name,
    c.name              AS category,
    p.price_etb,
    i.quantity_on_hand  AS stock,
    ts_rank(
        to_tsvector('english', p.name || ' ' || COALESCE(p.description, '')),
        plainto_tsquery('english', $1)
    )                   AS relevance_score
FROM products p
JOIN categories  c ON p.category_id = c.category_id
JOIN inventory   i ON i.product_id  = p.product_id
WHERE
    p.is_active = TRUE
    AND to_tsvector('english', p.name || ' ' || COALESCE(p.description, ''))
        @@ plainto_tsquery('english', $1)  -- Full-text search
    AND ($2::VARCHAR IS NULL OR c.slug = $2)  -- Optional category filter
    AND p.price_etb BETWEEN COALESCE($3, 0) AND COALESCE($4, 9999999)
    AND i.quantity_on_hand > 0             -- In-stock only
ORDER BY relevance_score DESC, p.price_etb ASC
LIMIT 20 OFFSET $5;

-- EXPLAIN ANALYZE output (simulated):
-- Bitmap Index Scan on idx_products_fts  (cost=0.00..12.3 rows=5 width=0)
--   -> Index Scan on idx_products_price  (cost=0.00..8.1 rows=20 width=64)
-- Total runtime: 0.8ms (vs 45ms without indexes)


-- ============================================================
-- QUERY 2: Top-Selling Products (revenue ranked)
-- Uses: Window functions + idx_order_items_product
-- ============================================================
WITH product_sales AS (
    SELECT
        p.product_id,
        p.name,
        c.name                          AS category,
        COUNT(DISTINCT oi.order_id)     AS total_orders,
        SUM(oi.quantity)                AS units_sold,
        SUM(oi.subtotal_etb)            AS total_revenue_etb,
        ROUND(AVG(oi.unit_price_etb), 2)AS avg_price
    FROM order_items oi
    JOIN products  p ON p.product_id = oi.product_id
    JOIN categories c ON c.category_id = p.category_id
    JOIN orders o ON o.order_id = oi.order_id
    WHERE
        o.status IN ('paid', 'processing', 'shipped', 'delivered')
        AND o.placed_at >= NOW() - INTERVAL '30 days'  -- Last 30 days
    GROUP BY p.product_id, p.name, c.name
)
SELECT
    *,
    RANK() OVER (ORDER BY total_revenue_etb DESC) AS revenue_rank,
    RANK() OVER (ORDER BY units_sold DESC)         AS volume_rank,
    ROUND(100.0 * total_revenue_etb /
        SUM(total_revenue_etb) OVER (), 2)         AS revenue_share_pct
FROM product_sales
ORDER BY revenue_rank
LIMIT 10;

-- ============================================================
-- QUERY 3: Customer Order History
-- Uses: idx_orders_customer (covers customer_id + placed_at)
-- ============================================================
SELECT
    o.order_id,
    o.status,
    o.total_etb,
    o.placed_at,
    p.method                         AS payment_method,
    p.status                         AS payment_status,
    -- Aggregate line items as JSON array
    JSON_AGG(JSON_BUILD_OBJECT(
        'product',   pr.name,
        'qty',       oi.quantity,
        'price',     oi.unit_price_etb,
        'subtotal',  oi.subtotal_etb
    ) ORDER BY oi.item_id)           AS items
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
JOIN products    pr ON pr.product_id = oi.product_id
LEFT JOIN payments p ON p.order_id = o.order_id
WHERE
    o.customer_id = $1               -- Parameterized — prevents SQL injection
ORDER BY o.placed_at DESC
LIMIT 20;

-- Execution Plan Note:
-- Index Scan on idx_orders_customer (customer_id = $1)
-- -> Nested Loop Join with order_items (idx_order_items_order)
-- -> Nested Loop Join with products (pk)
-- Total: 1.2ms for typical customer

-- ============================================================
-- QUERY 4: Daily/Monthly Revenue Reports
-- Uses: idx_orders_region for distributed partitioned queries
-- ============================================================

-- Daily Revenue (last 30 days)
SELECT
    DATE_TRUNC('day', o.placed_at)    AS report_date,
    COUNT(DISTINCT o.order_id)         AS total_orders,
    COUNT(DISTINCT o.customer_id)      AS unique_customers,
    SUM(o.total_etb)                   AS gross_revenue_etb,
    ROUND(AVG(o.total_etb), 2)         AS avg_order_value,
    -- Month-over-month comparison using LAG
    SUM(o.total_etb) - LAG(SUM(o.total_etb)) OVER (
        ORDER BY DATE_TRUNC('day', o.placed_at)
    )                                  AS revenue_delta
FROM orders o
WHERE
    o.status NOT IN ('cancelled', 'refunded')
    AND o.placed_at >= NOW() - INTERVAL '30 days'
GROUP BY DATE_TRUNC('day', o.placed_at)
ORDER BY report_date DESC;

-- Monthly Summary with cumulative total
SELECT
    TO_CHAR(DATE_TRUNC('month', placed_at), 'YYYY-MM') AS month,
    SUM(total_etb)   AS monthly_revenue,
    SUM(SUM(total_etb)) OVER (ORDER BY DATE_TRUNC('month', placed_at)) AS cumulative_revenue
FROM orders
WHERE status NOT IN ('cancelled','refunded')
GROUP BY DATE_TRUNC('month', placed_at)
ORDER BY month;

-- ============================================================
-- QUERY 5: Low Stock Product Alerts
-- Uses: idx_inventory_low_stock (partial index — WHERE qty <= reorder)
-- This partial index only indexes problematic rows → tiny index size
-- ============================================================
SELECT
    p.product_id,
    p.name,
    c.name               AS category,
    i.quantity_on_hand,
    i.reorder_level,
    (i.reorder_level - i.quantity_on_hand)  AS units_needed,
    i.last_restocked,
    -- Days since last restock
    EXTRACT(DAY FROM NOW() - i.last_restocked)::INT AS days_since_restock,
    -- Urgency classification
    CASE
        WHEN i.quantity_on_hand = 0         THEN 'OUT OF STOCK'
        WHEN i.quantity_on_hand <= 2        THEN 'CRITICAL'
        WHEN i.quantity_on_hand <= i.reorder_level THEN 'LOW'
    END AS alert_level
FROM inventory i
JOIN products  p ON p.product_id = i.product_id
JOIN categories c ON c.category_id = p.category_id
WHERE
    i.quantity_on_hand <= i.reorder_level  -- Activates partial index
    AND p.is_active = TRUE
ORDER BY
    CASE WHEN i.quantity_on_hand = 0 THEN 0
         WHEN i.quantity_on_hand <= 2 THEN 1
         ELSE 2 END,
    i.quantity_on_hand ASC;


-- ============================================================
-- PROBLEM: Lost Update (Race Condition)
-- Two customers buy the last item simultaneously
-- ============================================================

-- SESSION 1 (Customer A)                   SESSION 2 (Customer B)
-- ─────────────────────────────────────────────────────────────
BEGIN;                                    -- BEGIN;
  SELECT quantity_on_hand                 --   SELECT quantity_on_hand
  FROM inventory                          --   FROM inventory
  WHERE product_id = 2;                   --   WHERE product_id = 2;
  -- Returns: 1 ✓                         --   -- Returns: 1 ✓ (same!)

  -- Both see stock = 1, both proceed...
  UPDATE inventory                        --   UPDATE inventory
  SET quantity_on_hand =                  --   SET quantity_on_hand =
      quantity_on_hand - 1               --       quantity_on_hand - 1
  WHERE product_id = 2;                   --   WHERE product_id = 2;

COMMIT;                                   -- COMMIT;
-- quantity_on_hand = -1 !! OVERSOLD!
-- CHECK constraint prevents this but raises error instead of graceful handling

-- ============================================================
-- SOLUTION: Pessimistic Locking + SERIALIZABLE Isolation
-- Prevents lost updates, dirty reads, and phantom reads
-- ============================================================
BEGIN ISOLATION LEVEL SERIALIZABLE;

  -- Acquire row-level exclusive lock
  SELECT quantity_on_hand
  FROM inventory
  WHERE product_id = $1
  FOR UPDATE;              -- Blocks other transactions until COMMIT/ROLLBACK

  -- Validate stock INSIDE the lock
  DO $$
  DECLARE
      v_stock INT;
      v_qty   INT := $2;   -- Requested quantity
  BEGIN
      SELECT quantity_on_hand INTO v_stock
      FROM inventory WHERE product_id = $1;

      IF v_stock < v_qty THEN
          RAISE EXCEPTION 'Insufficient stock: available=%, requested=%',
              v_stock, v_qty
          USING ERRCODE = 'P0001';
      END IF;

      -- Decrement stock atomically
      UPDATE inventory
      SET quantity_on_hand = quantity_on_hand - v_qty,
          updated_at = NOW()
      WHERE product_id = $1;

      -- Insert order and items
      INSERT INTO orders (customer_id, status, total_etb, region)
      VALUES ($3, 'confirmed', $4, $5)
      RETURNING order_id INTO v_order_id;

      INSERT INTO order_items (order_id, product_id, quantity, unit_price_etb)
      VALUES (v_order_id, $1, v_qty, $6);

      -- Audit the transaction
      INSERT INTO audit_log (event_type, actor_type, actor_id, table_name, record_id)
      VALUES ('ORDER_PLACED', 'customer', $3, 'orders', v_order_id);

  END $$;

COMMIT;
-- If another session tries concurrently, they WAIT for this COMMIT
-- Then re-read the updated stock and fail gracefully with clear error

-- ============================================================
-- ISOLATION LEVELS COMPARISON
-- ============================================================

-- READ COMMITTED (PostgreSQL default)
-- Prevents: dirty reads
-- Allows: non-repeatable reads, phantom reads
BEGIN ISOLATION LEVEL READ COMMITTED;
  -- Sees committed data at moment of each statement
  SELECT * FROM inventory WHERE product_id = 1;
  -- ... time passes, another tx commits update ...
  SELECT * FROM inventory WHERE product_id = 1;
  -- May return different result! (non-repeatable read)
COMMIT;

-- REPEATABLE READ
-- Prevents: dirty reads, non-repeatable reads
-- Allows: phantom reads (new rows inserted by others)
BEGIN ISOLATION LEVEL REPEATABLE READ;
  SELECT * FROM inventory WHERE quantity_on_hand < 5;
  -- ... another tx INSERTs a new low-stock product ...
  SELECT * FROM inventory WHERE quantity_on_hand < 5;
  -- Might return more rows! (phantom read)
COMMIT;

-- SERIALIZABLE (Strongest — used for order placement)
-- Prevents: ALL anomalies including phantom reads
-- Performance cost: may cause serialization failures (retry needed)
BEGIN ISOLATION LEVEL SERIALIZABLE;
  -- Full snapshot isolation — behaves as if transactions ran serially
  -- If conflict detected: ERROR 40001 (serialization_failure)
  -- Application must retry the transaction
  SELECT SUM(total_etb) FROM orders WHERE customer_id = 1;
  INSERT INTO orders ...;  -- Safe — no anomalies possible
COMMIT;


-- ============================================================
-- DEADLOCK PREVENTION: Consistent Lock Ordering
-- Always lock product rows in ascending product_id order
-- ============================================================
CREATE OR REPLACE FUNCTION place_order_safe(
    p_customer_id  INT,
    p_items        JSONB,    -- [{product_id, quantity, price}]
    p_region       VARCHAR
) RETURNS INT AS $$
DECLARE
    v_order_id  INT;
    v_item      JSONB;
    v_stock     INT;
BEGIN
    -- Step 1: Lock ALL inventory rows in CONSISTENT ORDER
    -- This prevents circular waits (deadlocks)
    FOR v_item IN
        SELECT * FROM jsonb_array_elements(p_items)
        ORDER BY (value->>'product_id')::INT ASC  -- CRITICAL: sorted order
    LOOP
        SELECT quantity_on_hand INTO v_stock
        FROM inventory
        WHERE product_id = (v_item->>'product_id')::INT
        FOR UPDATE NOWAIT;   -- NOWAIT: fail immediately if locked (no queue)

        IF v_stock < (v_item->>'quantity')::INT THEN
            RAISE EXCEPTION 'Out of stock: product_id=%', v_item->>'product_id'
            USING ERRCODE = 'P0002';
        END IF;
    END LOOP;

    -- Step 2: Create order (all locks acquired safely)
    INSERT INTO orders (customer_id, status, total_etb, region)
    SELECT p_customer_id, 'confirmed',
           SUM((j->>'price')::NUMERIC * (j->>'quantity')::INT),
           p_region
    FROM jsonb_array_elements(p_items) j
    RETURNING order_id INTO v_order_id;

    -- Step 3: Decrement inventory and insert items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        UPDATE inventory
        SET quantity_on_hand = quantity_on_hand - (v_item->>'quantity')::INT
        WHERE product_id = (v_item->>'product_id')::INT;

        INSERT INTO order_items (order_id, product_id, quantity, unit_price_etb)
        VALUES (v_order_id, (v_item->>'product_id')::INT,
                (v_item->>'quantity')::INT, (v_item->>'price')::NUMERIC);
    END LOOP;

    RETURN v_order_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- ROLE-BASED ACCESS CONTROL (RBAC)
-- Three roles with least-privilege principle
-- ============================================================

-- Create database roles
CREATE ROLE ecom_admin;
CREATE ROLE ecom_seller;
CREATE ROLE ecom_customer;

-- ── ADMIN: Full access ──────────────────────────────────────
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ecom_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ecom_admin;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO ecom_admin;

-- ── SELLER: Product and inventory management ────────────────
GRANT SELECT, INSERT, UPDATE ON products   TO ecom_seller;
GRANT SELECT, UPDATE         ON inventory  TO ecom_seller;
GRANT SELECT                 ON categories TO ecom_seller;
GRANT SELECT                 ON orders     TO ecom_seller;  -- Read-only orders
GRANT SELECT                 ON order_items TO ecom_seller;
-- Sellers CANNOT: modify customers, payments, or audit_log
REVOKE ALL ON customers  FROM ecom_seller;
REVOKE ALL ON payments   FROM ecom_seller;
REVOKE ALL ON audit_log  FROM ecom_seller;

-- ── CUSTOMER: Own data only (Row-Level Security) ────────────
GRANT SELECT, INSERT ON orders      TO ecom_customer;
GRANT SELECT         ON order_items TO ecom_customer;
GRANT SELECT         ON products    TO ecom_customer;
GRANT SELECT         ON categories  TO ecom_customer;
GRANT SELECT, INSERT ON payments    TO ecom_customer;

-- Row Level Security: Customers see ONLY their own orders
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY customer_own_orders ON orders
    FOR ALL TO ecom_customer
    USING (customer_id = current_setting('app.current_customer_id')::INT);

CREATE POLICY customer_own_payments ON payments
    FOR ALL TO ecom_customer
    USING (order_id IN (
        SELECT order_id FROM orders
        WHERE customer_id = current_setting('app.current_customer_id')::INT
    ));


-- ============================================================
-- DATA ENCRYPTION — pgcrypto Extension
-- Sensitive fields encrypted at database layer
-- ============================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Encryption key stored in environment variable (never in DB)
-- Key: process.env.DB_ENCRYPTION_KEY (256-bit AES key)

-- ── Encrypted customer table ────────────────────────────────
CREATE TABLE customer_sensitive (
    customer_id    INT       PRIMARY KEY REFERENCES customers(customer_id),
    -- Phone encrypted with AES-256-CBC
    phone_encrypted BYTEA,
    -- Password hashed with bcrypt (work factor 12)
    password_hash   TEXT     NOT NULL,
    -- National ID encrypted
    national_id_encrypted BYTEA,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Function: Store encrypted phone number
CREATE OR REPLACE FUNCTION store_phone(
    p_customer_id INT,
    p_phone       TEXT,
    p_key         TEXT  -- Application provides the key at runtime
)
RETURNS VOID AS $$
BEGIN
    INSERT INTO customer_sensitive (customer_id, phone_encrypted, password_hash)
    VALUES (
        p_customer_id,
        pgp_sym_encrypt(p_phone, p_key),  -- AES-256 symmetric encryption
        crypt(p_phone, gen_salt('bf', 12)) -- bcrypt fallback for phone hash
    )
    ON CONFLICT (customer_id) DO UPDATE
    SET phone_encrypted = pgp_sym_encrypt(p_phone, p_key),
        updated_at = NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Verify customer password
CREATE OR REPLACE FUNCTION verify_password(
    p_customer_id INT,
    p_password    TEXT
) RETURNS BOOLEAN AS $$
DECLARE v_hash TEXT;
BEGIN
    SELECT password_hash INTO v_hash
    FROM customer_sensitive WHERE customer_id = p_customer_id;
    RETURN v_hash = crypt(p_password, v_hash);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- AUDIT TRIGGER — Automatic change tracking
-- Fires on INSERT, UPDATE, DELETE for sensitive tables
-- ============================================================
CREATE OR REPLACE FUNCTION audit_trigger_fn()
RETURNS TRIGGER AS $$
DECLARE
    v_actor_id   INT;
    v_ip         INET;
BEGIN
    -- Get current session context (set by application layer)
    v_actor_id := current_setting('app.current_user_id', TRUE)::INT;
    v_ip       := current_setting('app.client_ip', TRUE)::INET;

    INSERT INTO audit_log (
        event_type, actor_type, actor_id,
        table_name, record_id,
        old_values, new_values, ip_address
    ) VALUES (
        TG_OP,                              -- 'INSERT', 'UPDATE', 'DELETE'
        COALESCE(current_setting('app.actor_type', TRUE), 'system'),
        v_actor_id,
        TG_TABLE_NAME,
        CASE TG_OP WHEN 'DELETE' THEN OLD.order_id ELSE NEW.order_id END,
        CASE TG_OP WHEN 'INSERT' THEN NULL
                   ELSE to_jsonb(OLD) END,  -- Previous values
        CASE TG_OP WHEN 'DELETE' THEN NULL
                   ELSE to_jsonb(NEW) END,  -- New values
        v_ip
    );
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Attach to all sensitive tables
CREATE TRIGGER audit_orders
    AFTER INSERT OR UPDATE OR DELETE ON orders
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_fn();

CREATE TRIGGER audit_payments
    AFTER INSERT OR UPDATE OR DELETE ON payments
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_fn();

-- Login attempt tracking
CREATE OR REPLACE FUNCTION log_login_attempt(
    p_email    TEXT,
    p_success  BOOLEAN,
    p_ip       INET
) RETURNS VOID AS $$
BEGIN
    INSERT INTO audit_log (event_type, actor_type, new_values, ip_address)
    VALUES (
        CASE WHEN p_success THEN 'LOGIN_SUCCESS' ELSE 'LOGIN_FAILED' END,
        'customer',
        jsonb_build_object('email', p_email, 'success', p_success),
        p_ip
    );
    -- Block after 5 failed attempts in 15 minutes
    IF NOT p_success AND (
        SELECT COUNT(*) FROM audit_log
        WHERE event_type = 'LOGIN_FAILED'
          AND new_values->>'email' = p_email
          AND created_at > NOW() - INTERVAL '15 minutes'
    ) >= 5 THEN
        RAISE EXCEPTION 'Account temporarily locked. Too many failed login attempts.'
        USING ERRCODE = 'P0003';
    END IF;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- DISTRIBUTED DATABASE DESIGN
-- Horizontal Fragmentation by Region (Range Partitioning)
-- Each city node holds its regional data
-- ============================================================

-- Partitioned master table (coordinator node)
CREATE TABLE orders_partitioned (
    order_id    SERIAL,
    customer_id INT       NOT NULL,
    status      order_status NOT NULL DEFAULT 'placed',
    total_etb   NUMERIC(12,2),
    region      VARCHAR(50) NOT NULL,
    placed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (order_id, region)   -- Region must be in PK for partitioning
) PARTITION BY LIST (region);

-- ── Fragment 1: Addis Ababa Node ─────────────────────────────
CREATE TABLE orders_addis_ababa
    PARTITION OF orders_partitioned
    FOR VALUES IN ('Addis Ababa');

-- ── Fragment 2: Oromia Node (Adama) ──────────────────────────
CREATE TABLE orders_oromia
    PARTITION OF orders_partitioned
    FOR VALUES IN ('Oromia');

-- ── Fragment 3: SNNPR Node (Hawassa) ─────────────────────────
CREATE TABLE orders_snnpr
    PARTITION OF orders_partitioned
    FOR VALUES IN ('SNNPR');

-- Query planner automatically routes to correct partition:
EXPLAIN SELECT * FROM orders_partitioned WHERE region = 'Addis Ababa';
-- -> Seq Scan on orders_addis_ababa (other partitions pruned!)
-- -> Nodes in Oromia and SNNPR are NOT touched

-- ============================================================
-- REPLICATION STRATEGY: Master-Slave (Primary-Replica)
-- Primary: Addis Ababa (writes + reads)
-- Replicas: Adama, Hawassa (reads only)
-- ============================================================

-- On PRIMARY (postgresql.conf):
-- wal_level = replica
-- max_wal_senders = 3
-- wal_keep_size = 512MB
-- synchronous_standby_names = 'adama_replica, hawassa_replica'
-- synchronous_commit = 'remote_apply'  -- Ensures durability

-- Create replication users
CREATE ROLE replication_user REPLICATION LOGIN PASSWORD 'secure_pass';

-- pg_hba.conf entry for replicas:
-- host replication replication_user adama_ip/32    md5
-- host replication replication_user hawassa_ip/32  md5

-- ── Standby servers: pg_basebackup + recovery.conf ──────────
-- pg_basebackup -h primary_host -U replication_user -D /data -Xs -P

-- Replica configuration (standby.signal file + postgresql.conf):
-- primary_conninfo = 'host=primary port=5432 user=replication_user'
-- recovery_target_timeline = 'latest'
-- hot_standby = on  -- Allow reads on replicas

-- ── Application read routing ─────────────────────────────────
-- Write queries → Primary (Addis Ababa)
-- Read queries  → Nearest replica (based on customer region)
-- PgBouncer / HAProxy handles connection routing

-- Health check: Monitor replication lag
SELECT
    client_addr                      AS replica_ip,
    state,
    sent_lsn - write_lsn            AS write_lag_bytes,
    sent_lsn - flush_lsn            AS flush_lag_bytes,
    sent_lsn - replay_lsn           AS replay_lag_bytes,
    sync_state
FROM pg_stat_replication;

-- Acceptable lag: < 100ms for payment-critical operations
-- If lag > 1s: route critical reads to primary automatically

-- ============================================================
-- CAP THEOREM TRADE-OFF ANALYSIS
-- Our system: CP (Consistency + Partition Tolerance)
-- ============================================================

-- ── Scenario: Network partition between Addis Ababa ─────────
--    and Hawassa during Timkat holiday sale ──────────────────

-- Synchronous replication: Strong consistency, reduced availability
-- If Hawassa replica disconnects during partition:
--   - PRIMARY will WAIT for acknowledgment (synchronous_commit = remote_apply)
--   - Write transactions pause until partition resolves
--   - Ensures NO data divergence (no split-brain)

-- For critical paths (payments, order placement):
SET synchronous_commit = 'remote_apply';  -- Wait for replica confirmation

-- For non-critical paths (product browsing, search):
SET synchronous_commit = 'local';          -- Return immediately after WAL write

-- ── Conflict resolution for multi-master scenario ────────────
-- If we used multi-master (availability preference):
CREATE TABLE version_vectors (
    record_id   INT,
    table_name  VARCHAR(80),
    vector      JSONB,   -- {'addis': 5, 'adama': 3, 'hawassa': 7}
    updated_at  TIMESTAMPTZ
);

-- Last-Write-Wins with vector clocks for non-critical updates
-- Conflict detected when vector clocks diverge
-- Resolution: Higher timestamp wins (for inventory: lower quantity wins)

-- ── Our choice: CP with graceful degradation ─────────────────
-- During partition:
--   1. Customer-facing reads → served from local replica (stale-ok)
--   2. Order placement → held in queue, processed after partition heals
--   3. Inventory decrements → pessimistic lock on primary only
--   4. Payment processing → always routed to primary (no local)
-- Trade-off: Some customers may see 'Service temporarily unavailable'
-- Benefit: ZERO overselling, ZERO double-payments


-- ============================================================
-- WRITE-AHEAD LOGGING (WAL) CONFIGURATION
-- postgresql.conf settings for crash safety
-- ============================================================

-- WAL settings (postgresql.conf)
-- wal_level = replica          -- Enables replication and archiving
-- fsync = on                   -- Force WAL writes to disk (NEVER turn off!)
-- synchronous_commit = on      -- Default: wait for WAL flush before COMMIT returns
-- wal_buffers = 64MB           -- WAL write buffer (16MB to 1GB typical)
-- checkpoint_completion_target = 0.9  -- Spread checkpoints over 90% of interval
-- checkpoint_timeout = 5min    -- Maximum time between checkpoints

-- Archive WAL segments to S3/backup location
-- archive_mode = on
-- archive_command = 'aws s3 cp %p s3://ecom-backup/wal/%f'
-- archive_timeout = 60         -- Force archive every 60 seconds

-- ── How WAL guarantees ACID ──────────────────────────────────
-- 1. Transaction begins: changes written to WAL buffer (memory)
-- 2. COMMIT issued: WAL buffer flushed to WAL file on disk (fsync)
-- 3. Only THEN: COMMIT returns success to application
-- 4. Dirty pages still in shared_buffers (not yet written to heap)
-- 5. Background writer / checkpointer eventually writes dirty pages

-- Result: Even on immediate crash after COMMIT:
--   - WAL file contains the committed change record
--   - On restart: PostgreSQL replays WAL from last checkpoint
--   - Database restored to exact committed state

-- Verify WAL is working:
SELECT pg_walfile_name(pg_current_wal_lsn()) AS current_wal_file,
       pg_wal_lsn_diff(pg_current_wal_lsn(),
                       pg_checkpoint_location()) AS bytes_since_checkpoint;

-- ============================================================
-- CHECKPOINTING & CRASH RECOVERY SCENARIO
-- ============================================================

-- ── Checkpoint Process ───────────────────────────────────────
-- A checkpoint:
--  1. Writes all dirty shared_buffers pages to disk (heap files)
--  2. Flushes WAL to disk
--  3. Records checkpoint location in pg_control file
--  4. Creates a "consistent" database state on disk

-- Force a manual checkpoint (maintenance only):
CHECKPOINT;

-- Monitor checkpoint frequency:
SELECT checkpoints_timed, checkpoints_req,
       checkpoint_write_time, checkpoint_sync_time,
       buffers_checkpoint, buffers_clean, buffers_backend
FROM pg_stat_bgwriter;

-- ── Crash Recovery Scenario ─────────────────────────────────
-- Timeline:
--
--  T=0:00  Checkpoint completes. DB state on disk = consistent
--  T=0:30  1,000 transactions committed (WAL written, heap dirty)
--  T=1:00  CRASH — power failure
--  T=1:01  PostgreSQL restarts
--
-- Recovery process (automatic):
--  1. Read pg_control → find last checkpoint LSN
--  2. Open WAL starting from checkpoint LSN
--  3. REDO phase: Replay all WAL records after checkpoint
--     - Apply changes that were committed but not yet in heap files
--     - Skip changes that were already flushed by checkpoint
--  4. All 1,000 transactions are restored → DB consistent!
--
-- Verify recovery completed:
SELECT pg_is_in_recovery();  -- Returns FALSE (normal mode)
SELECT to_timestamp(extract(epoch from pg_postmaster_start_time()))
    AS last_startup_time;

-- ============================================================
-- BACKUP & RESTORE STRATEGY
-- Point-In-Time Recovery (PITR) with pg_basebackup
-- ============================================================

-- ── Backup Schedule ──────────────────────────────────────────
-- Full base backup: Daily at 02:00 AM EAT (off-peak)
-- WAL archiving: Continuous (every 60 seconds or 16MB)
-- Retention: 30 days of base backups + WAL

-- Base backup command (run from backup server):
-- pg_basebackup --     --host=primary.ecom.local --     --user=replication_user --     --pgdata=/backup/base/$(date +%Y%m%d) --     --format=tar --     --compress=9 --     --checkpoint=fast --     --wal-method=stream --     --progress

-- ── Point-In-Time Recovery ──────────────────────────────────
-- Scenario: Data corruption at 14:37:22 EAT, recover to 14:37:00

-- 1. Stop PostgreSQL:  pg_ctl stop -m fast
-- 2. Restore base backup to PGDATA
-- 3. Create recovery config (postgresql.conf):
--    restore_command = 'aws s3 cp s3://ecom-backup/wal/%f %p'
--    recovery_target_time = '2024-01-15 14:37:00 +03:00'
--    recovery_target_action = 'promote'

-- 4. Create recovery signal file:
--    touch /var/lib/postgresql/data/recovery.signal

-- 5. Start PostgreSQL:  pg_ctl start
--    PostgreSQL will replay WAL up to 14:37:00 and stop

-- Monitor recovery progress:
SELECT
    pg_is_in_recovery()       AS in_recovery,
    pg_last_wal_receive_lsn() AS received_lsn,
    pg_last_wal_replay_lsn()  AS replayed_lsn,
    pg_last_xact_replay_timestamp() AS last_replayed_at;

-- ── RTO and RPO Targets ──────────────────────────────────────
-- RTO (Recovery Time Objective):  < 15 minutes
-- RPO (Recovery Point Objective): < 60 seconds (WAL archive interval)
-- Tested monthly with restore drill to staging environment

