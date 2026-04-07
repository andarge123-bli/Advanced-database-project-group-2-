-- =============================================================================
-- OPTIMIZED QUERIES, EXPLAIN PLANS & PERFORMANCE ANALYSIS
-- File: 08_queries_explain.sql
-- =============================================================================

USE eth_ecommerce;

-- =============================================================================
-- SECTION 1: PRODUCT SEARCH & FILTERING
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Query 1A: Full-text product search (BEFORE optimization — slow LIKE scan)
-- BEFORE: Full table scan, O(n) for every keyword search
-- ---------------------------------------------------------------------------
-- EXPLAIN ANALYZE
-- SELECT product_id, product_name, base_price, rating
-- FROM   products
-- WHERE  product_name LIKE '%Galaxy%'   -- FULL TABLE SCAN! No index used.
--   AND  is_active = 1;
-- Result: type=ALL, rows examined=entire table, slow at scale

-- ---------------------------------------------------------------------------
-- Query 1B: Full-text product search (AFTER — uses FULLTEXT index)
-- Index: FULLTEXT KEY ft_product_search (product_name, short_desc, brand)
-- ---------------------------------------------------------------------------
EXPLAIN
SELECT product_id, product_name, base_price, rating,
       MATCH(product_name, short_desc, brand)
           AGAINST ('Galaxy smartphone 5G' IN NATURAL LANGUAGE MODE) AS relevance_score
FROM   products
WHERE  MATCH(product_name, short_desc, brand)
           AGAINST ('Galaxy smartphone 5G' IN NATURAL LANGUAGE MODE)
  AND  is_active  = 1
  AND  deleted_at IS NULL
ORDER BY relevance_score DESC
LIMIT  20;
-- Result: type=fulltext, uses ft_product_search, extremely fast

-- ---------------------------------------------------------------------------
-- Query 2: Category + price range filter (uses composite covering index)
-- Index: idx_prod_cat_price (category_id, base_price, is_active, deleted_at)
-- ---------------------------------------------------------------------------
EXPLAIN
SELECT p.product_id, p.product_name, p.base_price, p.sale_price,
       p.rating, p.review_count, sp.business_name AS seller
FROM   products p
JOIN   seller_profiles sp ON sp.seller_id = p.seller_id
WHERE  p.category_id = 10              -- Electronics > Smartphones
  AND  p.base_price BETWEEN 10000 AND 30000
  AND  p.is_active  = 1
  AND  p.deleted_at IS NULL
ORDER BY p.rating DESC, p.review_count DESC
LIMIT  24 OFFSET 0;
-- idx_prod_cat_price is a covering index for WHERE clause → index range scan
-- seller JOIN is a small nested-loop (sellers table is tiny)

-- ---------------------------------------------------------------------------
-- Query 3: Hierarchical category tree (all descendants of a root category)
-- Uses recursive CTE — excellent for nested categories
-- ---------------------------------------------------------------------------
EXPLAIN
WITH RECURSIVE category_tree AS (
    SELECT category_id, parent_id, category_name, 0 AS depth
    FROM   categories
    WHERE  category_id = 1  -- Root: Electronics
      AND  deleted_at IS NULL

    UNION ALL

    SELECT c.category_id, c.parent_id, c.category_name, ct.depth + 1
    FROM   categories c
    JOIN   category_tree ct ON ct.category_id = c.parent_id
    WHERE  c.deleted_at IS NULL
)
SELECT * FROM category_tree ORDER BY depth, category_name;
-- Uses idx_cat_parent for each recursive level join

-- =============================================================================
-- SECTION 2: ORDER QUERIES
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Query 4: Customer order history (covering index)
-- Index: idx_ord_customer_date (customer_id, placed_at)
-- ---------------------------------------------------------------------------
EXPLAIN
SELECT o.order_id, o.order_number, os.status_name,
       o.total_amount, o.payment_status, o.placed_at,
       o.delivered_at
FROM   orders o
JOIN   order_statuses os ON os.status_id = o.status_id
WHERE  o.customer_id = 10
  AND  o.deleted_at IS NULL
ORDER BY o.placed_at DESC
LIMIT  10;
-- idx_ord_customer_date → index range scan on customer_id=10, sorted by placed_at DESC

-- ---------------------------------------------------------------------------
-- Query 5: Order detail with items (single query, no N+1)
-- ---------------------------------------------------------------------------
SELECT
    o.order_number,
    os.status_name,
    o.total_amount,
    p.product_name,
    pv.variant_name,
    oi.quantity,
    oi.unit_price,
    oi.line_total
FROM orders o
JOIN order_statuses   os ON os.status_id  = o.status_id
JOIN order_items      oi ON oi.order_id   = o.order_id
JOIN products         p  ON p.product_id  = oi.product_id
JOIN product_variants pv ON pv.variant_id = oi.variant_id
WHERE o.order_id   = 1001
  AND o.deleted_at IS NULL
  AND oi.status    = 'ACTIVE';
-- All PKs → const lookups, single-pass join, effectively O(1) per order

-- =============================================================================
-- SECTION 3: INVENTORY QUERIES
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Query 6: Available inventory across all warehouses for a product
-- ---------------------------------------------------------------------------
SELECT
    w.warehouse_name,
    r.region_name,
    pv.variant_name,
    inv.quantity_on_hand,
    inv.reserved_quantity,
    GREATEST(0, inv.quantity_on_hand - inv.reserved_quantity) AS available,
    CASE
        WHEN inv.quantity_on_hand = 0                                 THEN 'OUT_OF_STOCK'
        WHEN (inv.quantity_on_hand - inv.reserved_quantity) <= 0      THEN 'FULLY_RESERVED'
        WHEN (inv.quantity_on_hand - inv.reserved_quantity)
             <= inv.reorder_point                                      THEN 'LOW_STOCK'
        ELSE 'IN_STOCK'
    END AS availability
FROM   inventory inv
JOIN   product_variants pv ON pv.variant_id   = inv.variant_id
JOIN   warehouses       w  ON w.warehouse_id  = inv.warehouse_id
JOIN   regions          r  ON r.region_id     = w.region_id
WHERE  pv.product_id = 1   -- Galaxy A54
ORDER BY r.region_name, pv.variant_name;
-- uq_inv_variant_wh ensures we get at most one row per variant+warehouse

-- ---------------------------------------------------------------------------
-- Query 7: Low stock alerts (uses idx_inv_low_stock)
-- ---------------------------------------------------------------------------
EXPLAIN
SELECT p.product_name, pv.variant_sku, w.warehouse_name,
       inv.quantity_on_hand, inv.reserved_quantity,
       inv.reorder_point, inv.reorder_quantity
FROM   inventory inv
JOIN   product_variants pv ON pv.variant_id  = inv.variant_id
JOIN   products         p  ON p.product_id   = pv.product_id
JOIN   warehouses       w  ON w.warehouse_id = inv.warehouse_id
WHERE  inv.low_stock_alert = 1
ORDER BY inv.quantity_on_hand ASC
LIMIT  50;
-- idx_inv_low_stock (low_stock_alert, quantity_on_hand) → index scan, O(alerts) not O(all_inventory)

-- =============================================================================
-- SECTION 4: REVENUE & ANALYTICS QUERIES
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Query 8: Daily revenue report for a date range
-- ---------------------------------------------------------------------------
EXPLAIN
SELECT
    DATE(o.placed_at)                    AS order_date,
    r.region_name,
    COUNT(DISTINCT o.order_id)           AS orders,
    SUM(o.total_amount)                  AS revenue,
    SUM(o.tax_amount)                    AS vat,
    AVG(o.total_amount)                  AS aov
FROM   orders o
JOIN   regions r ON r.region_id = o.region_id
WHERE  o.placed_at      BETWEEN '2026-01-01' AND '2026-04-07 23:59:59'
  AND  o.payment_status = 'SUCCESS'
  AND  o.deleted_at IS NULL
GROUP BY DATE(o.placed_at), r.region_id
ORDER BY order_date, revenue DESC;
-- idx_ord_placed_at used for range scan
-- For production: query daily_sales_summary instead (pre-aggregated)

-- ---------------------------------------------------------------------------
-- Query 8B: FAST version — query pre-aggregated summary table
-- ---------------------------------------------------------------------------
SELECT
    dss.summary_date,
    r.region_name,
    SUM(dss.total_orders)               AS orders,
    SUM(dss.total_revenue)              AS revenue,
    SUM(dss.total_refunds)              AS refunds,
    AVG(dss.avg_order_value)            AS aov
FROM   daily_sales_summary dss
JOIN   regions r ON r.region_id = dss.region_id
WHERE  dss.summary_date BETWEEN '2026-01-01' AND '2026-04-07'
GROUP BY dss.summary_date, r.region_id
ORDER BY dss.summary_date, revenue DESC;
-- PK (summary_date, region_id, seller_id) → covering index range scan
-- This is 100-1000x faster than scanning raw orders table

-- ---------------------------------------------------------------------------
-- Query 9: Monthly revenue by region (window function)
-- ---------------------------------------------------------------------------
SELECT
    DATE_FORMAT(dss.summary_date, '%Y-%m')  AS month,
    r.region_name,
    SUM(dss.total_revenue)                  AS monthly_revenue,
    LAG(SUM(dss.total_revenue)) OVER (
        PARTITION BY r.region_id
        ORDER BY DATE_FORMAT(dss.summary_date, '%Y-%m')
    )                                       AS prev_month_revenue,
    ROUND(
        (SUM(dss.total_revenue)
         - LAG(SUM(dss.total_revenue)) OVER (
               PARTITION BY r.region_id
               ORDER BY DATE_FORMAT(dss.summary_date, '%Y-%m')
           )
        ) / NULLIF(
            LAG(SUM(dss.total_revenue)) OVER (
                PARTITION BY r.region_id
                ORDER BY DATE_FORMAT(dss.summary_date, '%Y-%m')
            ), 0
        ) * 100, 2
    )                                       AS growth_pct
FROM   daily_sales_summary dss
JOIN   regions r ON r.region_id = dss.region_id
GROUP BY DATE_FORMAT(dss.summary_date, '%Y-%m'), r.region_id
ORDER BY month, monthly_revenue DESC;

-- ---------------------------------------------------------------------------
-- Query 10: Top 10 products this month by revenue
-- ---------------------------------------------------------------------------
SELECT
    p.product_name,
    p.sku,
    c.category_name,
    SUM(pss.units_sold)  AS units_this_month,
    SUM(pss.revenue)     AS revenue_this_month,
    p.rating
FROM   product_sales_stats pss
JOIN   products   p ON p.product_id    = pss.product_id
JOIN   categories c ON c.category_id  = p.category_id
WHERE  pss.period_date >= DATE_FORMAT(NOW(), '%Y-%m-01')
GROUP BY p.product_id, c.category_id
ORDER BY revenue_this_month DESC
LIMIT  10;

-- =============================================================================
-- SECTION 5: CONCURRENCY DEMONSTRATION
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Scenario: Two concurrent buyers trying to purchase the last 5 units of
-- Samsung Galaxy A54 Black 128GB (variant_id=1, warehouse_id=1)
-- Only 5 units available. Buyer A wants 3, Buyer B wants 3.
-- Expected: One succeeds, one gets INSUFFICIENT_STOCK error.
-- ---------------------------------------------------------------------------

-- SESSION A (Buyer A):
-- START TRANSACTION;
-- CALL sp_place_order(
--     10, 2, 1, 1, 1, 1, NULL, 'idem-buyer-A-001',
--     '[{"variant_id":1,"quantity":3,"unit_price":16999.00}]',
--     @oid, @onum, @ok, @msg
-- );
-- SELECT @ok, @msg, @onum;
-- COMMIT;

-- SESSION B (Buyer B — runs concurrently):
-- START TRANSACTION;
-- CALL sp_place_order(
--     11, 2, 3, 3, 1, 1, NULL, 'idem-buyer-B-001',
--     '[{"variant_id":1,"quantity":3,"unit_price":16999.00}]',
--     @oid, @onum, @ok, @msg
-- );
-- SELECT @ok, @msg, @onum;
-- COMMIT;

-- Result: sp_place_order uses SELECT ... FOR UPDATE on inventory.
-- The first session acquires the lock, reserves 3 units.
-- The second session blocks until the first commits.
-- After first commits: 2 units available. Buyer B's request for 3 fails
-- with: "INSUFFICIENT_STOCK: variant_id=1 needs=3 available=2"
-- This eliminates overselling under REPEATABLE READ + row-level locking.

-- ---------------------------------------------------------------------------
-- Isolation Level Demonstration
-- ---------------------------------------------------------------------------

-- Dirty Read Prevention (READ COMMITTED):
-- TX A: UPDATE inventory SET quantity_on_hand=0 WHERE inventory_id=1;
-- TX B: SELECT quantity_on_hand FROM inventory WHERE inventory_id=1;
-- With READ COMMITTED: TX B sees original value until TX A commits.

-- Non-Repeatable Read Prevention (REPEATABLE READ — MySQL default):
-- TX A: BEGIN; SELECT * FROM orders WHERE order_id=1001; -- sees status=DELIVERED
-- TX B: BEGIN; UPDATE orders SET status_id=6 WHERE order_id=1001; COMMIT;
-- TX A: SELECT * FROM orders WHERE order_id=1001; -- STILL sees DELIVERED (snapshot)

-- Phantom Prevention (SERIALIZABLE):
-- Use when critical: SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE;
-- Then: SELECT SUM(quantity_on_hand) FROM inventory WHERE variant_id=1;
-- Prevents new rows from appearing between two reads in same TX.

-- =============================================================================
-- SECTION 6: FRAUD DETECTION QUERY
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Query 11: Detect velocity fraud — customers with >5 orders in 1 hour
-- ---------------------------------------------------------------------------
SELECT
    o.customer_id,
    CONCAT(u.first_name, ' ', u.last_name) AS customer_name,
    COUNT(o.order_id)                      AS orders_last_hour,
    SUM(o.total_amount)                    AS total_value,
    MAX(o.total_amount)                    AS max_single_order
FROM   orders o
JOIN   users u ON u.user_id = o.customer_id
WHERE  o.placed_at >= DATE_SUB(NOW(3), INTERVAL 1 HOUR)
  AND  o.deleted_at IS NULL
GROUP BY o.customer_id
HAVING orders_last_hour > 5
ORDER BY total_value DESC;

-- ---------------------------------------------------------------------------
-- Query 12: Payment failure rate by method (fraud indicator)
-- ---------------------------------------------------------------------------
SELECT
    pmt.method_name,
    COUNT(p.payment_id)                                  AS total_attempts,
    SUM(IF(p.status = 'FAILED', 1, 0))                  AS failures,
    SUM(IF(p.status = 'SUCCESS', 1, 0))                 AS successes,
    ROUND(
        SUM(IF(p.status = 'FAILED', 1, 0))
        / COUNT(p.payment_id) * 100, 2
    )                                                    AS failure_rate_pct
FROM   payments p
JOIN   payment_method_types pmt ON pmt.method_id = p.method_id
WHERE  p.created_at >= DATE_SUB(NOW(3), INTERVAL 24 HOUR)
GROUP BY pmt.method_id
ORDER BY failure_rate_pct DESC;

-- =============================================================================
-- SECTION 7: SELLER ANALYTICS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Query 13: Seller commission report (monthly)
-- ---------------------------------------------------------------------------
SELECT
    sp.business_name,
    r.region_name,
    DATE_FORMAT(o.placed_at, '%Y-%m')    AS month,
    COUNT(o.order_id)                    AS orders,
    SUM(o.total_amount)                  AS gross_sales,
    ROUND(SUM(o.total_amount * sp.commission_rate), 2) AS platform_fee,
    ROUND(SUM(o.total_amount * (1 - sp.commission_rate)), 2) AS seller_payout
FROM   orders o
JOIN   seller_profiles sp ON sp.seller_id = o.seller_id
JOIN   regions         r  ON r.region_id  = sp.region_id
WHERE  o.payment_status = 'SUCCESS'
  AND  o.placed_at >= DATE_FORMAT(DATE_SUB(NOW(), INTERVAL 3 MONTH), '%Y-%m-01')
  AND  o.deleted_at IS NULL
GROUP BY sp.seller_id, r.region_id, DATE_FORMAT(o.placed_at, '%Y-%m')
ORDER BY month, gross_sales DESC;

-- =============================================================================
-- SECTION 8: EXPLAIN ANALYSIS EXAMPLES
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Example: EXPLAIN ANALYZE for order lookup (shows actual row counts)
-- Run this directly in MySQL 8.0.18+
-- ---------------------------------------------------------------------------
EXPLAIN FORMAT=JSON
SELECT o.order_id, o.order_number, o.total_amount, os.status_name
FROM   orders o
JOIN   order_statuses os ON os.status_id = o.status_id
WHERE  o.customer_id = 10
  AND  o.placed_at   >= '2026-01-01'
  AND  o.deleted_at IS NULL
ORDER  BY o.placed_at DESC
LIMIT  20;
-- Expected output:
-- access_type: "index_range_scan" on idx_ord_customer_date
-- rows_examined: ~5 (customer has few orders)
-- filtered: 100% (index covers all WHERE conditions)

-- ---------------------------------------------------------------------------
-- Optimization tip: use EXPLAIN FORMAT=TREE for newer MySQL 8 versions
-- ---------------------------------------------------------------------------
-- EXPLAIN FORMAT=TREE
-- SELECT p.product_name, SUM(oi.quantity) AS units_sold
-- FROM order_items oi
-- JOIN products p ON p.product_id = oi.product_id
-- WHERE oi.created_at >= '2026-04-01'
-- GROUP BY oi.product_id
-- ORDER BY units_sold DESC
-- LIMIT 10;

-- =============================================================================
-- END OF QUERIES & EXPLAIN PLANS
-- =============================================================================
