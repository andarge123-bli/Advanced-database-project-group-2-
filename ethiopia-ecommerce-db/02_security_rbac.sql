-- =============================================================================
-- SECURITY & ROLE-BASED ACCESS CONTROL (RBAC)
-- File: 02_security_rbac.sql
-- MySQL 8 native ROLE support
-- =============================================================================

USE eth_ecommerce;

-- =============================================================================
-- SECTION 1: MySQL ROLE DEFINITIONS
-- =============================================================================

-- Drop if exists (idempotent)
DROP ROLE IF EXISTS
    'eth_admin'@'%',
    'eth_seller'@'%',
    'eth_customer'@'%',
    'eth_analyst'@'%',
    'eth_support'@'%',
    'eth_readonly'@'%';

CREATE ROLE
    'eth_admin'@'%',      -- Full platform control
    'eth_seller'@'%',     -- Manage own products, view own orders
    'eth_customer'@'%',   -- Browse, order, review
    'eth_analyst'@'%',    -- Read-only analytics and reporting
    'eth_support'@'%',    -- Read orders/users, limited updates
    'eth_readonly'@'%';   -- Read-only across all tables (monitoring)

-- =============================================================================
-- SECTION 2: GRANT PERMISSIONS PER ROLE
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 2.1  eth_admin — Superuser for the database (NOT mysql root)
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE, REFERENCES, TRIGGER
    ON eth_ecommerce.*
    TO 'eth_admin'@'%';

-- Grant event management
GRANT EVENT ON eth_ecommerce.* TO 'eth_admin'@'%';

-- ---------------------------------------------------------------------------
-- 2.2  eth_seller — Product and order management for own data
-- ---------------------------------------------------------------------------
-- Products: full CRUD on own products
GRANT SELECT, INSERT, UPDATE ON eth_ecommerce.products         TO 'eth_seller'@'%';
GRANT SELECT, INSERT, UPDATE ON eth_ecommerce.product_variants TO 'eth_seller'@'%';
GRANT SELECT, INSERT, UPDATE ON eth_ecommerce.product_images   TO 'eth_seller'@'%';
GRANT SELECT                 ON eth_ecommerce.categories       TO 'eth_seller'@'%';

-- Inventory: view and adjust own warehouse stock
GRANT SELECT, UPDATE         ON eth_ecommerce.inventory             TO 'eth_seller'@'%';
GRANT SELECT, INSERT         ON eth_ecommerce.inventory_transactions TO 'eth_seller'@'%';

-- Orders: view own orders
GRANT SELECT                 ON eth_ecommerce.orders      TO 'eth_seller'@'%';
GRANT SELECT                 ON eth_ecommerce.order_items TO 'eth_seller'@'%';

-- Payments: view own payment records (read-only)
GRANT SELECT                 ON eth_ecommerce.payments TO 'eth_seller'@'%';

-- Own seller profile
GRANT SELECT, UPDATE         ON eth_ecommerce.seller_profiles TO 'eth_seller'@'%';

-- Reviews: read product reviews
GRANT SELECT                 ON eth_ecommerce.product_reviews TO 'eth_seller'@'%';

-- ---------------------------------------------------------------------------
-- 2.3  eth_customer — Shopper role
-- ---------------------------------------------------------------------------
GRANT SELECT                       ON eth_ecommerce.products          TO 'eth_customer'@'%';
GRANT SELECT                       ON eth_ecommerce.product_variants   TO 'eth_customer'@'%';
GRANT SELECT                       ON eth_ecommerce.product_images     TO 'eth_customer'@'%';
GRANT SELECT                       ON eth_ecommerce.categories         TO 'eth_customer'@'%';
GRANT SELECT                       ON eth_ecommerce.regions            TO 'eth_customer'@'%';

-- Orders: customers can only create/view own
GRANT SELECT, INSERT               ON eth_ecommerce.orders             TO 'eth_customer'@'%';
GRANT SELECT, INSERT               ON eth_ecommerce.order_items        TO 'eth_customer'@'%';

-- Payments: initiate and view own
GRANT SELECT, INSERT               ON eth_ecommerce.payments           TO 'eth_customer'@'%';

-- Addresses
GRANT SELECT, INSERT, UPDATE       ON eth_ecommerce.user_addresses     TO 'eth_customer'@'%';

-- Reviews
GRANT SELECT, INSERT               ON eth_ecommerce.product_reviews    TO 'eth_customer'@'%';

-- Notifications
GRANT SELECT, UPDATE               ON eth_ecommerce.notifications      TO 'eth_customer'@'%';

-- ---------------------------------------------------------------------------
-- 2.4  eth_analyst — Read-only analytics role
-- ---------------------------------------------------------------------------
GRANT SELECT ON eth_ecommerce.daily_sales_summary  TO 'eth_analyst'@'%';
GRANT SELECT ON eth_ecommerce.product_sales_stats  TO 'eth_analyst'@'%';
GRANT SELECT ON eth_ecommerce.customer_ltv         TO 'eth_analyst'@'%';
GRANT SELECT ON eth_ecommerce.orders               TO 'eth_analyst'@'%';
GRANT SELECT ON eth_ecommerce.order_items          TO 'eth_analyst'@'%';
GRANT SELECT ON eth_ecommerce.payments             TO 'eth_analyst'@'%';
GRANT SELECT ON eth_ecommerce.products             TO 'eth_analyst'@'%';
GRANT SELECT ON eth_ecommerce.product_reviews      TO 'eth_analyst'@'%';
GRANT SELECT ON eth_ecommerce.regions              TO 'eth_analyst'@'%';
GRANT SELECT ON eth_ecommerce.seller_profiles      TO 'eth_analyst'@'%';
GRANT SELECT ON eth_ecommerce.inventory            TO 'eth_analyst'@'%';

-- ---------------------------------------------------------------------------
-- 2.5  eth_support — Customer service role
-- ---------------------------------------------------------------------------
GRANT SELECT, UPDATE ON eth_ecommerce.orders         TO 'eth_support'@'%';
GRANT SELECT         ON eth_ecommerce.order_items    TO 'eth_support'@'%';
GRANT SELECT         ON eth_ecommerce.payments       TO 'eth_support'@'%';
GRANT SELECT, INSERT ON eth_ecommerce.refunds        TO 'eth_support'@'%';
GRANT SELECT, UPDATE ON eth_ecommerce.users          TO 'eth_support'@'%';
GRANT SELECT         ON eth_ecommerce.user_addresses TO 'eth_support'@'%';
GRANT SELECT         ON eth_ecommerce.fraud_logs     TO 'eth_support'@'%';
GRANT SELECT         ON eth_ecommerce.audit_logs     TO 'eth_support'@'%';
GRANT SELECT, INSERT ON eth_ecommerce.notifications  TO 'eth_support'@'%';

-- ---------------------------------------------------------------------------
-- 2.6  eth_readonly — Monitoring / observability
-- ---------------------------------------------------------------------------
GRANT SELECT ON eth_ecommerce.* TO 'eth_readonly'@'%';

-- =============================================================================
-- SECTION 3: APPLICATION DATABASE USERS
-- =============================================================================
-- NOTE: Replace placeholder passwords with strong secrets from your secrets vault.
-- These users are granted roles; MySQL 8 role activation is via SET ROLE.
-- ---------------------------------------------------------------------------

-- App API user (backend application)
DROP USER IF EXISTS 'eth_app_api'@'%';
CREATE USER 'eth_app_api'@'%'
    IDENTIFIED WITH caching_sha2_password BY '<<APP_API_STRONG_PASSWORD>>'
    PASSWORD EXPIRE INTERVAL 90 DAY
    FAILED_LOGIN_ATTEMPTS 5
    PASSWORD_LOCK_TIME 1;
GRANT 'eth_admin'@'%' TO 'eth_app_api'@'%';
-- Auto-activate the role on login
ALTER USER 'eth_app_api'@'%' DEFAULT ROLE 'eth_admin'@'%';

-- Read-only analytics user (BI tools, Metabase, etc.)
DROP USER IF EXISTS 'eth_bi_reader'@'%';
CREATE USER 'eth_bi_reader'@'%'
    IDENTIFIED WITH caching_sha2_password BY '<<BI_READER_STRONG_PASSWORD>>'
    PASSWORD EXPIRE INTERVAL 90 DAY;
GRANT 'eth_analyst'@'%' TO 'eth_bi_reader'@'%';
ALTER USER 'eth_bi_reader'@'%' DEFAULT ROLE 'eth_analyst'@'%';

-- Replica / replication user (for MySQL master-replica)
DROP USER IF EXISTS 'eth_replicator'@'%';
CREATE USER 'eth_replicator'@'%'
    IDENTIFIED WITH caching_sha2_password BY '<<REPLICATION_STRONG_PASSWORD>>';
GRANT REPLICATION SLAVE ON *.* TO 'eth_replicator'@'%';

-- ProxySQL health check user
DROP USER IF EXISTS 'proxysql_monitor'@'%';
CREATE USER 'proxysql_monitor'@'%'
    IDENTIFIED WITH caching_sha2_password BY '<<PROXYSQL_MONITOR_PASSWORD>>';
GRANT SELECT ON performance_schema.* TO 'proxysql_monitor'@'%';

-- =============================================================================
-- SECTION 4: ROW-LEVEL SECURITY HELPERS (Views with DEFINER restrictions)
-- =============================================================================
-- Because MySQL doesn't have native RLS, we implement it through views
-- and application-layer tenant checks.

-- Seller sees only their own products
CREATE OR REPLACE SQL SECURITY DEFINER VIEW seller_own_products AS
    SELECT p.*
    FROM products p
    WHERE p.seller_id = (
        -- Application must SET @current_seller_id before querying this view
        SELECT @current_seller_id
    ) AND p.deleted_at IS NULL;

-- Seller sees only their own orders
CREATE OR REPLACE SQL SECURITY DEFINER VIEW seller_own_orders AS
    SELECT o.*
    FROM orders o
    WHERE o.seller_id = @current_seller_id
      AND o.deleted_at IS NULL;

-- Customer sees only their own orders
CREATE OR REPLACE SQL SECURITY DEFINER VIEW customer_own_orders AS
    SELECT o.*
    FROM orders o
    WHERE o.customer_id = @current_customer_id
      AND o.deleted_at IS NULL;

-- =============================================================================
-- SECTION 5: ENCRYPTION KEY MANAGEMENT
-- =============================================================================
-- Sensitive columns (phone_number, ip_address, bank account numbers) are
-- stored encrypted using AES-256-CBC via MySQL AES_ENCRYPT / AES_DECRYPT.
--
-- Key derivation example (do NOT hardcode keys in SQL; use MySQL keyring):
--   SET @enc_key = SHA2('<<MASTER_KEY_FROM_VAULT>>', 256);
--   INSERT INTO users (phone_number, ...) VALUES (AES_ENCRYPT('+251911000001', @enc_key), ...);
--   SELECT CAST(AES_DECRYPT(phone_number, @enc_key) AS CHAR) FROM users WHERE user_id = 1;
--
-- In production: use MySQL Enterprise Transparent Data Encryption (TDE) or
-- HashiCorp Vault with MySQL Keyring Plugin for key management.
--
-- Column-level encryption is best paired with application-layer encryption
-- (e.g., AWS KMS envelope encryption or a similar HSM-backed approach).
-- =============================================================================

-- =============================================================================
-- SECTION 6: AUDIT LOG HELPER PROCEDURE
-- =============================================================================

DELIMITER $$

DROP PROCEDURE IF EXISTS log_audit_event $$
CREATE PROCEDURE log_audit_event(
    IN p_user_id       BIGINT UNSIGNED,
    IN p_session_id    VARCHAR(128),
    IN p_action        VARCHAR(100),
    IN p_entity_type   VARCHAR(50),
    IN p_entity_id     BIGINT UNSIGNED,
    IN p_old_values    JSON,
    IN p_new_values    JSON,
    IN p_status        VARCHAR(10),
    IN p_message       VARCHAR(1000)
)
BEGIN
    INSERT INTO audit_logs (
        user_id, session_id, action, entity_type, entity_id,
        old_values, new_values, status, message
    ) VALUES (
        p_user_id, p_session_id, p_action, p_entity_type, p_entity_id,
        p_old_values, p_new_values, p_status, p_message
    );
END $$

DELIMITER ;

-- =============================================================================
-- END OF SECURITY & RBAC
-- =============================================================================
