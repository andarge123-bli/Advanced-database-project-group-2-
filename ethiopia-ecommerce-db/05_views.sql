-- =============================================================================
-- ANALYTICAL VIEWS
-- File: 05_views.sql
-- Views:
--   vw_sales_summary           — Daily/monthly revenue aggregates
--   vw_top_selling_products    — Best performers by revenue & units
--   vw_customer_lifetime_value — CLV with segmentation
--   vw_inventory_status        — Live stock with low-stock flag
--   vw_seller_performance      — Seller dashboard metrics
--   vw_order_detail            — Denormalized order view for support
--   vw_fraud_risk_users        — High-risk user flag view
--   vw_revenue_by_region       — Geographic revenue breakdown
-- =============================================================================

USE eth_ecommerce;

-- =============================================================================
-- VIEW 1: Sales Summary (daily rollup)
-- =============================================================================
CREATE OR REPLACE VIEW vw_sales_summary AS
SELECT
    DATE(o.placed_at)               AS sale_date,
    r.region_name                   AS region,
    sp.business_name                AS seller_name,
    COUNT(DISTINCT o.order_id)      AS total_orders,
    SUM(o.total_amount)             AS gross_revenue,
    SUM(o.discount_amount)          AS total_discounts,
    SUM(o.tax_amount)               AS total_vat,
    SUM(o.shipping_fee)             AS total_shipping,
    SUM(o.total_amount - o.discount_amount)
                                    AS net_revenue,
    AVG(o.total_amount)             AS avg_order_value,
    COUNT(DISTINCT o.customer_id)   AS unique_customers,
    SUM(oi.quantity)                AS total_units_sold
FROM orders o
JOIN regions        r  ON r.region_id  = o.region_id
JOIN seller_profiles sp ON sp.seller_id = o.seller_id
JOIN order_items oi ON oi.order_id = o.order_id AND oi.status = 'ACTIVE'
JOIN order_statuses os ON os.status_id = o.status_id
WHERE o.deleted_at IS NULL
  AND os.status_code NOT IN ('CANCELLED')
  AND o.payment_status = 'SUCCESS'
GROUP BY DATE(o.placed_at), r.region_id, o.seller_id;

-- =============================================================================
-- VIEW 2: Top Selling Products (all time)
-- =============================================================================
CREATE OR REPLACE VIEW vw_top_selling_products AS
SELECT
    p.product_id,
    p.product_name,
    p.sku,
    c.category_name,
    sp.business_name        AS seller_name,
    r.region_name           AS seller_region,
    SUM(oi.quantity)        AS total_units_sold,
    SUM(oi.line_total)      AS total_revenue,
    COUNT(DISTINCT oi.order_id) AS order_count,
    AVG(oi.unit_price)      AS avg_selling_price,
    p.rating                AS avg_rating,
    p.review_count,
    MIN(o.placed_at)        AS first_sale_date,
    MAX(o.placed_at)        AS last_sale_date
FROM products p
JOIN categories     c   ON c.category_id = p.category_id
JOIN seller_profiles sp ON sp.seller_id  = p.seller_id
JOIN regions        r   ON r.region_id   = sp.region_id
JOIN order_items    oi  ON oi.product_id = p.product_id AND oi.status = 'ACTIVE'
JOIN orders         o   ON o.order_id    = oi.order_id
JOIN order_statuses os  ON os.status_id  = o.status_id
WHERE p.deleted_at IS NULL
  AND os.status_code NOT IN ('CANCELLED')
  AND o.payment_status = 'SUCCESS'
GROUP BY p.product_id, c.category_id, sp.seller_id, r.region_id
ORDER BY total_revenue DESC;

-- =============================================================================
-- VIEW 3: Customer Lifetime Value
-- =============================================================================
CREATE OR REPLACE VIEW vw_customer_lifetime_value AS
SELECT
    u.user_id                                   AS customer_id,
    u.first_name,
    u.last_name,
    u.email,
    r.region_name                               AS home_region,
    COUNT(DISTINCT o.order_id)                  AS total_orders,
    COALESCE(SUM(o.total_amount), 0)            AS total_spent,
    COALESCE(SUM(ref.total_refunded), 0)        AS total_refunded,
    COALESCE(SUM(o.total_amount), 0)
        - COALESCE(SUM(ref.total_refunded), 0)  AS net_spent,
    COALESCE(AVG(o.total_amount), 0)            AS avg_order_value,
    MIN(DATE(o.placed_at))                      AS first_purchase_date,
    MAX(DATE(o.placed_at))                      AS last_purchase_date,
    DATEDIFF(NOW(), MAX(o.placed_at))           AS days_since_last_order,
    CASE
        WHEN COUNT(o.order_id) = 0                        THEN 'NEW'
        WHEN DATEDIFF(NOW(), MAX(o.placed_at)) > 180      THEN 'CHURNED'
        WHEN DATEDIFF(NOW(), MAX(o.placed_at)) > 90       THEN 'AT_RISK'
        WHEN SUM(o.total_amount) >= 10000                 THEN 'VIP'
        ELSE 'ACTIVE'
    END                                         AS customer_segment
FROM users u
LEFT JOIN regions r ON r.region_id = u.region_id
LEFT JOIN orders o ON o.customer_id = u.user_id
    AND o.deleted_at IS NULL
    AND o.payment_status = 'SUCCESS'
LEFT JOIN (
    SELECT pay.order_id, SUM(ref2.refund_amount) AS total_refunded
    FROM refunds ref2
    JOIN payments pay ON pay.payment_id = ref2.payment_id
    WHERE ref2.status = 'PROCESSED'
    GROUP BY pay.order_id
) ref ON ref.order_id = o.order_id
WHERE u.deleted_at IS NULL
  AND u.role_id = (SELECT role_id FROM user_roles WHERE role_code = 'customer')
GROUP BY u.user_id, r.region_id;

-- =============================================================================
-- VIEW 4: Inventory Status (with availability & low-stock alert)
-- =============================================================================
CREATE OR REPLACE VIEW vw_inventory_status AS
SELECT
    inv.inventory_id,
    p.product_id,
    p.product_name,
    p.sku                               AS product_sku,
    pv.variant_id,
    pv.variant_sku,
    pv.variant_name,
    w.warehouse_name,
    r.region_name                       AS warehouse_region,
    inv.quantity_on_hand,
    inv.reserved_quantity,
    GREATEST(0, inv.quantity_on_hand - inv.reserved_quantity) AS available_qty,
    inv.reorder_point,
    inv.reorder_quantity,
    inv.low_stock_alert,
    inv.last_restocked_at,
    sp.business_name                    AS seller_name,
    CASE
        WHEN inv.quantity_on_hand = 0   THEN 'OUT_OF_STOCK'
        WHEN (inv.quantity_on_hand - inv.reserved_quantity) <= 0
                                        THEN 'FULLY_RESERVED'
        WHEN inv.low_stock_alert = 1    THEN 'LOW_STOCK'
        ELSE 'IN_STOCK'
    END                                 AS stock_status
FROM inventory inv
JOIN product_variants pv ON pv.variant_id   = inv.variant_id
JOIN products         p  ON p.product_id    = pv.product_id
JOIN warehouses       w  ON w.warehouse_id  = inv.warehouse_id
JOIN regions          r  ON r.region_id     = w.region_id
JOIN seller_profiles  sp ON sp.seller_id    = p.seller_id
WHERE pv.deleted_at IS NULL AND p.deleted_at IS NULL;

-- =============================================================================
-- VIEW 5: Seller Performance Dashboard
-- =============================================================================
CREATE OR REPLACE VIEW vw_seller_performance AS
SELECT
    sp.seller_id,
    sp.business_name,
    r.region_name                               AS seller_region,
    sp.verification_status,
    sp.commission_rate,
    sp.rating                                   AS seller_rating,
    sp.total_reviews,
    COUNT(DISTINCT p.product_id)                AS total_products,
    COUNT(DISTINCT p.product_id)
        FILTER (WHERE p.is_active = 1 AND p.deleted_at IS NULL)
                                                AS active_products,
    COUNT(DISTINCT o.order_id)                  AS total_orders,
    COALESCE(SUM(o.total_amount), 0)            AS gross_revenue,
    COALESCE(SUM(o.total_amount * sp.commission_rate), 0)
                                                AS platform_commission,
    COALESCE(SUM(o.total_amount * (1 - sp.commission_rate)), 0)
                                                AS seller_net_revenue,
    COALESCE(AVG(o.total_amount), 0)            AS avg_order_value,
    COUNT(DISTINCT o.customer_id)               AS unique_customers
FROM seller_profiles sp
JOIN regions r ON r.region_id = sp.region_id
LEFT JOIN products p ON p.seller_id = sp.seller_id
LEFT JOIN orders o ON o.seller_id = sp.seller_id
    AND o.deleted_at IS NULL
    AND o.payment_status = 'SUCCESS'
GROUP BY sp.seller_id, r.region_id;

-- =============================================================================
-- VIEW 6: Order Detail (denormalized for support/admin)
-- =============================================================================
CREATE OR REPLACE VIEW vw_order_detail AS
SELECT
    o.order_id,
    o.order_number,
    CONCAT(cu.first_name, ' ', cu.last_name)    AS customer_name,
    cu.email                                    AS customer_email,
    sp.business_name                            AS seller_name,
    os.status_name                              AS order_status,
    pmt.method_name                             AS payment_method,
    o.payment_status,
    o.subtotal,
    o.discount_amount,
    o.shipping_fee,
    o.tax_amount,
    o.total_amount,
    o.currency,
    o.coupon_code,
    r.region_name                               AS fulfillment_region,
    w.warehouse_name                            AS warehouse,
    o.placed_at,
    o.confirmed_at,
    o.shipped_at,
    o.delivered_at,
    o.cancelled_at,
    o.notes,
    -- Shipping address
    CONCAT(ua.street, ', ', ua.sub_city, ', ', r_addr.region_name)
                                                AS shipping_address,
    -- Item summary (JSON)
    (
        SELECT JSON_ARRAYAGG(
            JSON_OBJECT(
                'product',   p.product_name,
                'variant',   pv.variant_name,
                'qty',       oi.quantity,
                'unit_price', oi.unit_price,
                'line_total', oi.line_total,
                'status',    oi.status
            )
        )
        FROM order_items oi
        JOIN products       p  ON p.product_id  = oi.product_id
        JOIN product_variants pv ON pv.variant_id = oi.variant_id
        WHERE oi.order_id = o.order_id
    )                                           AS items_json
FROM orders o
JOIN users           cu  ON cu.user_id       = o.customer_id
JOIN seller_profiles sp  ON sp.seller_id     = o.seller_id
JOIN order_statuses  os  ON os.status_id     = o.status_id
JOIN payment_method_types pmt ON pmt.method_id = o.payment_method_id
LEFT JOIN regions    r   ON r.region_id      = o.region_id
LEFT JOIN warehouses w   ON w.warehouse_id   = o.warehouse_id
LEFT JOIN user_addresses ua ON ua.address_id = o.shipping_address_id
LEFT JOIN regions r_addr ON r_addr.region_id = ua.region_id
WHERE o.deleted_at IS NULL;

-- =============================================================================
-- VIEW 7: Fraud Risk Users
-- =============================================================================
CREATE OR REPLACE VIEW vw_fraud_risk_users AS
SELECT
    u.user_id,
    CONCAT(u.first_name, ' ', u.last_name)      AS full_name,
    u.email,
    u.account_status,
    u.failed_login_cnt,
    u.lockout_until,
    COUNT(fl.fraud_id)                          AS fraud_event_count,
    MAX(fl.risk_score)                          AS max_risk_score,
    AVG(fl.risk_score)                          AS avg_risk_score,
    GROUP_CONCAT(DISTINCT fl.fraud_type)        AS fraud_types,
    MAX(fl.created_at)                          AS last_fraud_event
FROM users u
JOIN fraud_logs fl ON fl.user_id = u.user_id
WHERE u.deleted_at IS NULL
GROUP BY u.user_id
HAVING fraud_event_count > 0
ORDER BY max_risk_score DESC, fraud_event_count DESC;

-- =============================================================================
-- VIEW 8: Revenue by Region
-- =============================================================================
CREATE OR REPLACE VIEW vw_revenue_by_region AS
SELECT
    r.region_id,
    r.region_name,
    r.region_code,
    COUNT(DISTINCT o.order_id)                  AS total_orders,
    COUNT(DISTINCT o.customer_id)               AS unique_customers,
    COUNT(DISTINCT o.seller_id)                 AS active_sellers,
    COALESCE(SUM(o.total_amount), 0)            AS total_revenue,
    COALESCE(AVG(o.total_amount), 0)            AS avg_order_value,
    COALESCE(SUM(o.tax_amount), 0)              AS total_vat_collected,
    COALESCE(SUM(oi.quantity), 0)               AS total_units_sold
FROM regions r
LEFT JOIN orders o ON o.region_id = r.region_id
    AND o.deleted_at IS NULL
    AND o.payment_status = 'SUCCESS'
LEFT JOIN order_items oi ON oi.order_id = o.order_id AND oi.status = 'ACTIVE'
WHERE r.is_active = 1
GROUP BY r.region_id
ORDER BY total_revenue DESC;

-- =============================================================================
-- VIEW 9: Low Stock Alert Dashboard
-- =============================================================================
CREATE OR REPLACE VIEW vw_low_stock_alerts AS
SELECT
    p.product_id,
    p.product_name,
    pv.variant_id,
    pv.variant_sku,
    pv.variant_name,
    sp.business_name    AS seller,
    w.warehouse_name,
    r.region_name       AS region,
    inv.quantity_on_hand,
    inv.reserved_quantity,
    GREATEST(0, inv.quantity_on_hand - inv.reserved_quantity) AS available_qty,
    inv.reorder_point,
    inv.reorder_quantity,
    CASE
        WHEN inv.quantity_on_hand = 0 THEN 'OUT_OF_STOCK'
        ELSE 'LOW_STOCK'
    END AS alert_type
FROM inventory inv
JOIN product_variants pv ON pv.variant_id   = inv.variant_id
JOIN products         p  ON p.product_id    = pv.product_id
JOIN warehouses       w  ON w.warehouse_id  = inv.warehouse_id
JOIN regions          r  ON r.region_id     = w.region_id
JOIN seller_profiles  sp ON sp.seller_id    = p.seller_id
WHERE inv.low_stock_alert = 1
  AND pv.deleted_at IS NULL
  AND p.deleted_at IS NULL
  AND p.is_active = 1
ORDER BY inv.quantity_on_hand ASC;

-- =============================================================================
-- END OF VIEWS
-- =============================================================================
