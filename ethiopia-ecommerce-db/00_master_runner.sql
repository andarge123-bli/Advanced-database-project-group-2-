-- =============================================================================
-- MASTER RUNNER — Ethiopia E-Commerce Platform
-- File: 00_master_runner.sql
-- =============================================================================
-- Run this file in order, or execute individual scripts as needed.
-- Tested on: MySQL 8.0.35+
-- Character Set: utf8mb4 / utf8mb4_unicode_ci
-- Engine: InnoDB
-- =============================================================================
-- EXECUTION ORDER (required):
--
-- Step 1: Schema & DDL
--   SOURCE 01_schema_ddl.sql;
--
-- Step 2: Security & RBAC
--   SOURCE 02_security_rbac.sql;
--
-- Step 3: Triggers
--   SOURCE 03_triggers.sql;
--
-- Step 4: Stored Procedures & Functions
--   SOURCE 04_stored_procedures.sql;
--
-- Step 5: Views
--   SOURCE 05_views.sql;
--
-- Step 6: Events (MySQL Event Scheduler)
--   SOURCE 06_events.sql;
--
-- Step 7: Sample Data
--   SOURCE 07_sample_data.sql;
--
-- Step 8: Optimized Queries & EXPLAIN examples
--   SOURCE 08_queries_explain.sql;
--
-- Step 9: Distributed Architecture & Partitioning
--   SOURCE 09_distributed_arch.sql;
-- =============================================================================
-- QUICK VERIFICATION after running all scripts:
-- =============================================================================

USE eth_ecommerce;

-- Verify tables created
SELECT TABLE_NAME, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH,
       ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) AS size_mb
FROM   information_schema.TABLES
WHERE  TABLE_SCHEMA = 'eth_ecommerce'
ORDER BY TABLE_NAME;

-- Verify stored procedures
SELECT ROUTINE_NAME, ROUTINE_TYPE, CREATED
FROM   information_schema.ROUTINES
WHERE  ROUTINE_SCHEMA = 'eth_ecommerce'
ORDER BY ROUTINE_TYPE, ROUTINE_NAME;

-- Verify triggers
SELECT TRIGGER_NAME, EVENT_MANIPULATION, EVENT_OBJECT_TABLE,
       ACTION_TIMING, CREATED
FROM   information_schema.TRIGGERS
WHERE  TRIGGER_SCHEMA = 'eth_ecommerce'
ORDER BY EVENT_OBJECT_TABLE, ACTION_TIMING;

-- Verify events
SELECT EVENT_NAME, STATUS, INTERVAL_VALUE, INTERVAL_FIELD,
       LAST_EXECUTED, NEXT_EXECUTION
FROM   information_schema.EVENTS
WHERE  EVENT_SCHEMA = 'eth_ecommerce'
ORDER BY EVENT_NAME;

-- Verify views
SELECT TABLE_NAME AS view_name
FROM   information_schema.VIEWS
WHERE  TABLE_SCHEMA = 'eth_ecommerce'
ORDER BY TABLE_NAME;

-- Verify indexes
SELECT TABLE_NAME, INDEX_NAME, COLUMN_NAME, NON_UNIQUE, SEQ_IN_INDEX
FROM   information_schema.STATISTICS
WHERE  TABLE_SCHEMA = 'eth_ecommerce'
ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX;

-- =============================================================================
-- QUICK FUNCTIONAL TEST:
-- =============================================================================

-- Test: Place an order via stored procedure
SET @v_order_id = NULL;
SET @v_order_num = NULL;
SET @v_ok = 0;
SET @v_msg = '';

CALL sp_place_order(
    10,     -- customer_id (Selam Getachew)
    2,      -- seller_id   (EthTech Store)
    1,      -- shipping_address_id
    1,      -- billing_address_id
    1,      -- warehouse_id (Addis Main)
    1,      -- payment_method (Telebirr)
    'NEWUSER20',  -- coupon_code
    UUID(), -- idempotency_key (generate fresh UUID each run)
    '[{"variant_id":2,"quantity":1,"unit_price":16999.00}]',  -- items (Galaxy A54 White)
    @v_order_id,
    @v_order_num,
    @v_ok,
    @v_msg
);

SELECT @v_ok AS success, @v_msg AS message, @v_order_id AS order_id, @v_order_num AS order_number;

-- Verify inventory was reserved
SELECT variant_id, warehouse_id, quantity_on_hand, reserved_quantity,
       (quantity_on_hand - reserved_quantity) AS available
FROM   inventory
WHERE  variant_id = 2 AND warehouse_id = 1;

-- View the new order
SELECT * FROM vw_order_detail WHERE order_id = @v_order_id;

-- =============================================================================
-- END OF MASTER RUNNER
-- =============================================================================
