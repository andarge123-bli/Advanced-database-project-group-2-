-- =============================================================================
-- MYSQL EVENT SCHEDULER JOBS
-- File: 06_events.sql
-- Events:
--   evt_cleanup_old_audit_logs     — Archive/purge audit logs > 12 months
--   evt_cleanup_old_login_attempts — Purge login attempts > 90 days
--   evt_cleanup_expired_sessions   — Remove expired user sessions
--   evt_archive_old_orders         — Soft-archive orders > 2 years
--   evt_refresh_sales_summary      — Populate daily_sales_summary
--   evt_update_customer_ltv        — Recalculate customer LTV segments
--   evt_check_low_stock            — Set low_stock_alert flags
--   evt_expire_coupons             — Deactivate expired coupons
-- =============================================================================

USE eth_ecommerce;

-- Make sure the scheduler is on (execute as DBA):
-- SET GLOBAL event_scheduler = ON;

-- =============================================================================
-- EVENT 1: Cleanup expired user sessions (runs every 15 minutes)
-- =============================================================================
DROP EVENT IF EXISTS evt_cleanup_expired_sessions;
CREATE EVENT evt_cleanup_expired_sessions
    ON SCHEDULE EVERY 15 MINUTE
    STARTS CURRENT_TIMESTAMP
    ON COMPLETION PRESERVE
    ENABLE
    COMMENT 'Remove expired user sessions to keep the sessions table lean'
DO
    DELETE FROM user_sessions
    WHERE expires_at < NOW(3)
       OR (is_active = 0 AND last_active_at < DATE_SUB(NOW(3), INTERVAL 7 DAY));

-- =============================================================================
-- EVENT 2: Cleanup old login attempts (runs daily at 01:00 EAT)
-- =============================================================================
DROP EVENT IF EXISTS evt_cleanup_old_login_attempts;
CREATE EVENT evt_cleanup_old_login_attempts
    ON SCHEDULE EVERY 1 DAY
    STARTS (DATE(NOW()) + INTERVAL 1 DAY + INTERVAL 1 HOUR)
    ON COMPLETION PRESERVE
    ENABLE
    COMMENT 'Delete login attempts older than 90 days'
DO
    DELETE FROM login_attempts
    WHERE attempted_at < DATE_SUB(NOW(3), INTERVAL 90 DAY)
    LIMIT 50000;  -- Batch delete to avoid long-running transaction

-- =============================================================================
-- EVENT 3: Archive old audit logs (runs monthly, 1st of month at 02:00)
-- =============================================================================
DROP EVENT IF EXISTS evt_archive_old_audit_logs;
CREATE EVENT evt_archive_old_audit_logs
    ON SCHEDULE EVERY 1 MONTH
    STARTS '2026-05-01 02:00:00'
    ON COMPLETION PRESERVE
    ENABLE
    COMMENT 'Move audit logs older than 12 months to archive partition'
DO BEGIN
    -- In production, this would INSERT INTO audit_logs_archive SELECT ...
    -- then DELETE. Here we demonstrate the pattern:
    DELETE FROM audit_logs
    WHERE created_at < DATE_SUB(NOW(3), INTERVAL 12 MONTH)
      AND status    != 'FAILURE'  -- Keep failure logs longer
    LIMIT 100000;
END;

-- =============================================================================
-- EVENT 4: Archive old orders (runs monthly at 03:00)
-- =============================================================================
DROP EVENT IF EXISTS evt_archive_old_orders;
CREATE EVENT evt_archive_old_orders
    ON SCHEDULE EVERY 1 MONTH
    STARTS '2026-05-01 03:00:00'
    ON COMPLETION PRESERVE
    ENABLE
    COMMENT 'Soft-archive delivered or cancelled orders older than 2 years'
DO
    UPDATE orders
    SET deleted_at = NOW(3)
    WHERE deleted_at IS NULL
      AND placed_at < DATE_SUB(NOW(3), INTERVAL 2 YEAR)
      AND status_id IN (
          SELECT status_id FROM order_statuses
          WHERE status_code IN ('DELIVERED', 'CANCELLED', 'RETURNED')
      )
    LIMIT 10000;

-- =============================================================================
-- EVENT 5: Refresh daily_sales_summary (runs daily at 00:05 EAT)
-- Populates yesterday's summary row
-- =============================================================================
DROP EVENT IF EXISTS evt_refresh_sales_summary;
CREATE EVENT evt_refresh_sales_summary
    ON SCHEDULE EVERY 1 DAY
    STARTS (DATE(NOW()) + INTERVAL 1 DAY + INTERVAL 5 MINUTE)
    ON COMPLETION PRESERVE
    ENABLE
    COMMENT 'Populate daily_sales_summary for the previous day'
DO BEGIN
    DECLARE v_yesterday DATE DEFAULT DATE_SUB(CURDATE(), INTERVAL 1 DAY);

    -- Delete existing rows for yesterday (idempotent)
    DELETE FROM daily_sales_summary WHERE summary_date = v_yesterday;

    -- Insert fresh aggregates
    INSERT INTO daily_sales_summary (
        summary_date, region_id, seller_id,
        total_orders, total_revenue, total_items_sold,
        total_refunds, avg_order_value
    )
    SELECT
        v_yesterday,
        o.region_id,
        o.seller_id,
        COUNT(DISTINCT o.order_id),
        COALESCE(SUM(o.total_amount), 0),
        COALESCE(SUM(oi.quantity), 0),
        COALESCE(SUM(ref.refund_amount), 0),
        COALESCE(AVG(o.total_amount), 0)
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id AND oi.status = 'ACTIVE'
    LEFT JOIN (
        SELECT pay.order_id, SUM(r2.refund_amount) AS refund_amount
        FROM   refunds r2
        JOIN   payments pay ON pay.payment_id = r2.payment_id
        WHERE  r2.status = 'PROCESSED'
        GROUP  BY pay.order_id
    ) ref ON ref.order_id = o.order_id
    WHERE DATE(o.placed_at) = v_yesterday
      AND o.payment_status  = 'SUCCESS'
      AND o.deleted_at IS NULL
    GROUP BY o.region_id, o.seller_id;
END;

-- =============================================================================
-- EVENT 6: Update customer LTV segments (runs daily at 00:30)
-- =============================================================================
DROP EVENT IF EXISTS evt_update_customer_ltv;
CREATE EVENT evt_update_customer_ltv
    ON SCHEDULE EVERY 1 DAY
    STARTS (DATE(NOW()) + INTERVAL 1 DAY + INTERVAL 30 MINUTE)
    ON COMPLETION PRESERVE
    ENABLE
    COMMENT 'Refresh customer_ltv table with current metrics and segments'
DO BEGIN
    -- Upsert LTV data
    INSERT INTO customer_ltv (
        customer_id, first_order_date, last_order_date,
        total_orders, total_spent, total_refunds,
        avg_order_value, ltv_score, segment
    )
    SELECT
        u.user_id,
        MIN(DATE(o.placed_at)),
        MAX(DATE(o.placed_at)),
        COUNT(DISTINCT o.order_id),
        COALESCE(SUM(o.total_amount), 0),
        COALESCE(SUM(ref.total_refunded), 0),
        COALESCE(AVG(o.total_amount), 0),
        -- Simple LTV score: net_spent * recency_factor
        COALESCE(SUM(o.total_amount), 0)
            * EXP(-0.005 * GREATEST(0, DATEDIFF(NOW(), MAX(o.placed_at)))),
        CASE
            WHEN COUNT(o.order_id) = 0                       THEN 'NEW'
            WHEN DATEDIFF(NOW(), MAX(o.placed_at)) > 180     THEN 'CHURNED'
            WHEN DATEDIFF(NOW(), MAX(o.placed_at)) > 90      THEN 'AT_RISK'
            WHEN SUM(o.total_amount) >= 10000                THEN 'VIP'
            ELSE 'ACTIVE'
        END
    FROM users u
    LEFT JOIN orders o ON o.customer_id   = u.user_id
                       AND o.payment_status = 'SUCCESS'
                       AND o.deleted_at IS NULL
    LEFT JOIN (
        SELECT pay.order_id, SUM(r2.refund_amount) AS total_refunded
        FROM   refunds r2
        JOIN   payments pay ON pay.payment_id = r2.payment_id
        WHERE  r2.status = 'PROCESSED'
        GROUP  BY pay.order_id
    ) ref ON ref.order_id = o.order_id
    WHERE u.deleted_at IS NULL
      AND u.role_id = (SELECT role_id FROM user_roles WHERE role_code = 'customer')
    GROUP BY u.user_id
    ON DUPLICATE KEY UPDATE
        first_order_date  = VALUES(first_order_date),
        last_order_date   = VALUES(last_order_date),
        total_orders      = VALUES(total_orders),
        total_spent       = VALUES(total_spent),
        total_refunds     = VALUES(total_refunds),
        avg_order_value   = VALUES(avg_order_value),
        ltv_score         = VALUES(ltv_score),
        segment           = VALUES(segment),
        updated_at        = NOW(3);
END;

-- =============================================================================
-- EVENT 7: Check and set low-stock alerts (runs every 2 hours)
-- =============================================================================
DROP EVENT IF EXISTS evt_check_low_stock;
CREATE EVENT evt_check_low_stock
    ON SCHEDULE EVERY 2 HOUR
    STARTS CURRENT_TIMESTAMP
    ON COMPLETION PRESERVE
    ENABLE
    COMMENT 'Update low_stock_alert flag based on current stock vs reorder_point'
DO
    UPDATE inventory
    SET low_stock_alert = IF(
        (quantity_on_hand - reserved_quantity) <= reorder_point,
        1, 0
    );

-- =============================================================================
-- EVENT 8: Expire coupons (runs daily at 00:10)
-- =============================================================================
DROP EVENT IF EXISTS evt_expire_coupons;
CREATE EVENT evt_expire_coupons
    ON SCHEDULE EVERY 1 DAY
    STARTS (DATE(NOW()) + INTERVAL 1 DAY + INTERVAL 10 MINUTE)
    ON COMPLETION PRESERVE
    ENABLE
    COMMENT 'Deactivate expired coupons'
DO
    UPDATE coupons
    SET is_active = 0
    WHERE valid_until < NOW(3) AND is_active = 1;

-- =============================================================================
-- EVENT 9: Refresh product sales stats (runs daily at 01:00)
-- =============================================================================
DROP EVENT IF EXISTS evt_refresh_product_stats;
CREATE EVENT evt_refresh_product_stats
    ON SCHEDULE EVERY 1 DAY
    STARTS (DATE(NOW()) + INTERVAL 1 DAY + INTERVAL 1 HOUR)
    ON COMPLETION PRESERVE
    ENABLE
    COMMENT 'Refresh product_sales_stats for the previous day'
DO BEGIN
    DECLARE v_yesterday DATE DEFAULT DATE_SUB(CURDATE(), INTERVAL 1 DAY);

    DELETE FROM product_sales_stats WHERE period_date = v_yesterday;

    INSERT INTO product_sales_stats (product_id, period_date, units_sold, revenue, returns)
    SELECT
        oi.product_id,
        v_yesterday,
        SUM(CASE WHEN oi.status = 'ACTIVE'   THEN oi.quantity ELSE 0 END),
        SUM(CASE WHEN oi.status = 'ACTIVE'   THEN oi.line_total ELSE 0 END),
        SUM(CASE WHEN oi.status = 'RETURNED' THEN oi.quantity ELSE 0 END)
    FROM order_items oi
    JOIN orders o ON o.order_id = oi.order_id
    WHERE DATE(o.placed_at) = v_yesterday
      AND o.payment_status  = 'SUCCESS'
      AND o.deleted_at IS NULL
    GROUP BY oi.product_id
    ON DUPLICATE KEY UPDATE
        units_sold = VALUES(units_sold),
        revenue    = VALUES(revenue),
        returns    = VALUES(returns),
        updated_at = NOW(3);
END;

-- =============================================================================
-- END OF EVENTS
-- =============================================================================
