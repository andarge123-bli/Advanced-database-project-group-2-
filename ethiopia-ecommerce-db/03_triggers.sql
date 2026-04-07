-- =============================================================================
-- TRIGGERS
-- File: 03_triggers.sql
-- Purpose:
--   - Prevent overselling (inventory guard)
--   - Auto-maintain order totals
--   - Enforce order state-machine transitions
--   - Inventory consistency on order cancellation
--   - Audit trail triggers
--   - Low-stock alert maintenance
-- =============================================================================

USE eth_ecommerce;

DELIMITER $$

-- =============================================================================
-- TRIGGER 1: ORDER ITEM INSERT — Reserve inventory & prevent overselling
-- =============================================================================
-- This is the critical anti-oversell gate. Raises an error if available
-- stock is insufficient BEFORE inserting the order item.
-- Combined with SELECT ... FOR UPDATE in the stored procedure, this creates
-- a two-layer defense against overselling under high concurrency.
-- =============================================================================

DROP TRIGGER IF EXISTS trg_order_item_before_insert $$
CREATE TRIGGER trg_order_item_before_insert
    BEFORE INSERT ON order_items
    FOR EACH ROW
BEGIN
    DECLARE v_available INT DEFAULT 0;
    DECLARE v_qty_hand  INT DEFAULT 0;
    DECLARE v_qty_res   INT DEFAULT 0;

    -- Lock the inventory row to prevent concurrent oversell
    SELECT quantity_on_hand, reserved_quantity
    INTO   v_qty_hand, v_qty_res
    FROM   inventory
    WHERE  variant_id   = NEW.variant_id
      AND  warehouse_id = NEW.warehouse_id
    FOR UPDATE;

    SET v_available = v_qty_hand - v_qty_res;

    IF v_available < NEW.quantity THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'OVERSELL_PREVENTED: Insufficient available inventory',
                MYSQL_ERRNO  = 45001;
    END IF;

    -- Reserve the stock
    UPDATE inventory
    SET    reserved_quantity = reserved_quantity + NEW.quantity
    WHERE  variant_id   = NEW.variant_id
      AND  warehouse_id = NEW.warehouse_id;

    -- Log the reservation
    INSERT INTO inventory_transactions (
        inventory_id, variant_id, warehouse_id,
        txn_type, quantity_delta, quantity_after,
        reference_type, reference_id, notes
    )
    SELECT
        inventory_id, NEW.variant_id, NEW.warehouse_id,
        'RESERVATION', -NEW.quantity,
        (quantity_on_hand - reserved_quantity),
        'order_item', NEW.item_id,
        CONCAT('Reserved for order_item_id=', NEW.item_id)
    FROM inventory
    WHERE variant_id = NEW.variant_id AND warehouse_id = NEW.warehouse_id;
END $$

-- =============================================================================
-- TRIGGER 2: ORDER ITEM INSERT — Recalculate order totals
-- =============================================================================

DROP TRIGGER IF EXISTS trg_order_item_after_insert $$
CREATE TRIGGER trg_order_item_after_insert
    AFTER INSERT ON order_items
    FOR EACH ROW
BEGIN
    UPDATE orders
    SET subtotal     = (SELECT COALESCE(SUM(line_total), 0)
                        FROM order_items
                        WHERE order_id = NEW.order_id AND status = 'ACTIVE'),
        total_amount = (SELECT COALESCE(SUM(line_total), 0) + shipping_fee + tax_amount - discount_amount
                        FROM orders WHERE order_id = NEW.order_id)
    WHERE order_id = NEW.order_id;
END $$

-- =============================================================================
-- TRIGGER 3: ORDER ITEM UPDATE (status change to CANCELLED) — Release stock
-- =============================================================================

DROP TRIGGER IF EXISTS trg_order_item_after_update $$
CREATE TRIGGER trg_order_item_after_update
    AFTER UPDATE ON order_items
    FOR EACH ROW
BEGIN
    -- If item was just cancelled, release reserved stock
    IF OLD.status = 'ACTIVE' AND NEW.status = 'CANCELLED' THEN
        UPDATE inventory
        SET    reserved_quantity = GREATEST(0, reserved_quantity - OLD.quantity)
        WHERE  variant_id   = OLD.variant_id
          AND  warehouse_id = OLD.warehouse_id;

        INSERT INTO inventory_transactions (
            inventory_id, variant_id, warehouse_id,
            txn_type, quantity_delta, quantity_after,
            reference_type, reference_id, notes
        )
        SELECT
            inventory_id, OLD.variant_id, OLD.warehouse_id,
            'RELEASE', OLD.quantity,
            (quantity_on_hand - reserved_quantity),
            'order_item', OLD.item_id,
            CONCAT('Released: order_item cancelled, item_id=', OLD.item_id)
        FROM inventory
        WHERE variant_id = OLD.variant_id AND warehouse_id = OLD.warehouse_id;
    END IF;

    -- If item returned, also release reservation if not already done
    IF OLD.status = 'ACTIVE' AND NEW.status = 'RETURNED' THEN
        UPDATE inventory
        SET    reserved_quantity = GREATEST(0, reserved_quantity - OLD.quantity),
               quantity_on_hand  = quantity_on_hand + OLD.quantity  -- stock restored
        WHERE  variant_id   = OLD.variant_id
          AND  warehouse_id = OLD.warehouse_id;

        INSERT INTO inventory_transactions (
            inventory_id, variant_id, warehouse_id,
            txn_type, quantity_delta, quantity_after,
            reference_type, reference_id, notes
        )
        SELECT
            inventory_id, OLD.variant_id, OLD.warehouse_id,
            'RETURN', OLD.quantity,
            quantity_on_hand,
            'order_item', OLD.item_id,
            CONCAT('Stock restored from return, item_id=', OLD.item_id)
        FROM inventory
        WHERE variant_id = OLD.variant_id AND warehouse_id = OLD.warehouse_id;
    END IF;

    -- Recalculate order totals after any status change
    UPDATE orders
    SET subtotal     = (SELECT COALESCE(SUM(line_total), 0)
                        FROM order_items
                        WHERE order_id = NEW.order_id AND status = 'ACTIVE'),
        total_amount = (SELECT COALESCE(SUM(oi.line_total), 0)
                            + o2.shipping_fee
                            + o2.tax_amount
                            - o2.discount_amount
                        FROM order_items oi
                        JOIN orders o2 ON o2.order_id = oi.order_id
                        WHERE oi.order_id = NEW.order_id
                          AND oi.status   = 'ACTIVE'
                          AND o2.order_id = NEW.order_id
                        GROUP BY o2.order_id)
    WHERE order_id = NEW.order_id;
END $$

-- =============================================================================
-- TRIGGER 4: ORDER UPDATE — Enforce state-machine transitions
-- =============================================================================
-- Valid transitions (simplified):
--   PENDING → CONFIRMED | CANCELLED
--   CONFIRMED → PROCESSING | CANCELLED
--   PROCESSING → SHIPPED | CANCELLED
--   SHIPPED → DELIVERED | RETURNED
--   DELIVERED → RETURNED (partial)
--   CANCELLED, RETURNED → (terminal — no further transitions)
-- =============================================================================

DROP TRIGGER IF EXISTS trg_order_before_update $$
CREATE TRIGGER trg_order_before_update
    BEFORE UPDATE ON orders
    FOR EACH ROW
BEGIN
    DECLARE v_old_code VARCHAR(50);
    DECLARE v_new_code VARCHAR(50);
    DECLARE v_old_terminal TINYINT(1);

    -- Only enforce when status_id changes
    IF NEW.status_id <> OLD.status_id THEN

        SELECT status_code, is_terminal
        INTO   v_old_code, v_old_terminal
        FROM   order_statuses WHERE status_id = OLD.status_id;

        SELECT status_code
        INTO   v_new_code
        FROM   order_statuses WHERE status_id = NEW.status_id;

        -- Block transitions from terminal states
        IF v_old_terminal = 1 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'ORDER_STATE_ERROR: Cannot transition from terminal state',
                    MYSQL_ERRNO  = 45002;
        END IF;

        -- Enforce allowed transitions
        IF NOT (
               (v_old_code = 'PENDING'     AND v_new_code IN ('CONFIRMED', 'CANCELLED'))
            OR (v_old_code = 'CONFIRMED'   AND v_new_code IN ('PROCESSING', 'CANCELLED'))
            OR (v_old_code = 'PROCESSING'  AND v_new_code IN ('SHIPPED', 'CANCELLED'))
            OR (v_old_code = 'SHIPPED'     AND v_new_code IN ('DELIVERED', 'RETURNED'))
            OR (v_old_code = 'DELIVERED'   AND v_new_code IN ('RETURNED'))
            -- Admin override path (any → CANCELLED except terminal)
            OR (v_new_code = 'CANCELLED'   AND v_old_terminal = 0)
        ) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'ORDER_STATE_ERROR: Invalid order status transition',
                    MYSQL_ERRNO  = 45003;
        END IF;

        -- Set timestamps based on new state
        IF v_new_code = 'CONFIRMED'  THEN SET NEW.confirmed_at  = NOW(3); END IF;
        IF v_new_code = 'SHIPPED'    THEN SET NEW.shipped_at    = NOW(3); END IF;
        IF v_new_code = 'DELIVERED'  THEN SET NEW.delivered_at  = NOW(3); END IF;
        IF v_new_code = 'CANCELLED'  THEN SET NEW.cancelled_at  = NOW(3); END IF;
    END IF;
END $$

-- =============================================================================
-- TRIGGER 5: ORDER DELIVERED — Deduct from inventory_on_hand
-- =============================================================================
-- On delivery confirmation, convert reservation → actual sale

DROP TRIGGER IF EXISTS trg_order_after_update_delivered $$
CREATE TRIGGER trg_order_after_update_delivered
    AFTER UPDATE ON orders
    FOR EACH ROW
BEGIN
    DECLARE v_new_code VARCHAR(50);
    DECLARE v_old_code VARCHAR(50);

    IF NEW.status_id <> OLD.status_id THEN
        SELECT status_code INTO v_new_code FROM order_statuses WHERE status_id = NEW.status_id;
        SELECT status_code INTO v_old_code FROM order_statuses WHERE status_id = OLD.status_id;

        IF v_new_code = 'DELIVERED' AND v_old_code = 'SHIPPED' THEN
            -- Convert reservations to actual deductions
            UPDATE inventory inv
            JOIN order_items oi ON oi.variant_id   = inv.variant_id
                                AND oi.warehouse_id = inv.warehouse_id
            SET inv.quantity_on_hand  = inv.quantity_on_hand  - oi.quantity,
                inv.reserved_quantity = GREATEST(0, inv.reserved_quantity - oi.quantity)
            WHERE oi.order_id = NEW.order_id AND oi.status = 'ACTIVE';

            -- Log sale transactions
            INSERT INTO inventory_transactions (
                inventory_id, variant_id, warehouse_id,
                txn_type, quantity_delta, quantity_after,
                reference_type, reference_id, notes
            )
            SELECT
                inv.inventory_id, oi.variant_id, oi.warehouse_id,
                'SALE', -oi.quantity,
                inv.quantity_on_hand,
                'order', NEW.order_id,
                CONCAT('Sale confirmed on delivery, order_id=', NEW.order_id)
            FROM inventory inv
            JOIN order_items oi ON oi.variant_id   = inv.variant_id
                                AND oi.warehouse_id = inv.warehouse_id
            WHERE oi.order_id = NEW.order_id AND oi.status = 'ACTIVE';

            -- Update low-stock alerts
            UPDATE inventory
            SET low_stock_alert = IF(
                (quantity_on_hand - reserved_quantity) <= reorder_point, 1, 0
            )
            WHERE inventory_id IN (
                SELECT inv2.inventory_id
                FROM order_items oi2
                JOIN inventory inv2
                    ON inv2.variant_id   = oi2.variant_id
                    AND inv2.warehouse_id = oi2.warehouse_id
                WHERE oi2.order_id = NEW.order_id AND oi2.status = 'ACTIVE'
            );
        END IF;

        -- If cancelled: release ALL reservations for remaining active items
        IF v_new_code = 'CANCELLED' THEN
            UPDATE inventory inv
            JOIN order_items oi ON oi.variant_id   = inv.variant_id
                                AND oi.warehouse_id = inv.warehouse_id
                                AND oi.status       = 'ACTIVE'
            SET inv.reserved_quantity = GREATEST(0, inv.reserved_quantity - oi.quantity)
            WHERE oi.order_id = NEW.order_id;

            -- Mark all active items as cancelled
            UPDATE order_items
            SET status = 'CANCELLED'
            WHERE order_id = NEW.order_id AND status = 'ACTIVE';
        END IF;
    END IF;
END $$

-- =============================================================================
-- TRIGGER 6: PAYMENT INSERT — Detect duplicate idempotency key violation
-- =============================================================================
-- Idempotency is primarily enforced by the UNIQUE KEY uq_idempotency_key,
-- but this trigger provides a cleaner error message.

DROP TRIGGER IF EXISTS trg_payment_before_insert $$
CREATE TRIGGER trg_payment_before_insert
    BEFORE INSERT ON payments
    FOR EACH ROW
BEGIN
    DECLARE v_cnt INT;
    SELECT COUNT(*) INTO v_cnt
    FROM payments
    WHERE idempotency_key = NEW.idempotency_key;

    IF v_cnt > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'DUPLICATE_PAYMENT: Idempotency key already used',
                MYSQL_ERRNO  = 45004;
    END IF;
END $$

-- =============================================================================
-- TRIGGER 7: PAYMENT UPDATE — Sync order payment_status
-- =============================================================================

DROP TRIGGER IF EXISTS trg_payment_after_update $$
CREATE TRIGGER trg_payment_after_update
    AFTER UPDATE ON payments
    FOR EACH ROW
BEGIN
    IF NEW.status <> OLD.status THEN
        UPDATE orders
        SET payment_status = NEW.status
        WHERE order_id = NEW.order_id;
    END IF;
END $$

-- =============================================================================
-- TRIGGER 8: PRODUCT DELETE (soft) — Deactivate variants too
-- =============================================================================

DROP TRIGGER IF EXISTS trg_product_before_soft_delete $$
CREATE TRIGGER trg_product_before_soft_delete
    BEFORE UPDATE ON products
    FOR EACH ROW
BEGIN
    IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
        -- Soft-delete all variants
        UPDATE product_variants
        SET deleted_at = NEW.deleted_at,
            is_active  = 0
        WHERE product_id = OLD.product_id AND deleted_at IS NULL;

        SET NEW.is_active = 0;
    END IF;
END $$

-- =============================================================================
-- TRIGGER 9: PRODUCT REVIEW INSERT — Update product aggregate rating
-- =============================================================================

DROP TRIGGER IF EXISTS trg_review_after_insert $$
CREATE TRIGGER trg_review_after_insert
    AFTER INSERT ON product_reviews
    FOR EACH ROW
BEGIN
    IF NEW.is_approved = 1 THEN
        UPDATE products
        SET rating       = (SELECT AVG(rating)  FROM product_reviews
                            WHERE product_id = NEW.product_id AND is_approved = 1 AND deleted_at IS NULL),
            review_count = (SELECT COUNT(*)     FROM product_reviews
                            WHERE product_id = NEW.product_id AND is_approved = 1 AND deleted_at IS NULL)
        WHERE product_id = NEW.product_id;
    END IF;
END $$

-- =============================================================================
-- TRIGGER 10: REVIEW APPROVAL — Update aggregate when approved
-- =============================================================================

DROP TRIGGER IF EXISTS trg_review_after_update $$
CREATE TRIGGER trg_review_after_update
    AFTER UPDATE ON product_reviews
    FOR EACH ROW
BEGIN
    IF NEW.is_approved <> OLD.is_approved THEN
        UPDATE products
        SET rating       = (SELECT COALESCE(AVG(rating), 0)
                            FROM product_reviews
                            WHERE product_id = NEW.product_id AND is_approved = 1 AND deleted_at IS NULL),
            review_count = (SELECT COUNT(*)
                            FROM product_reviews
                            WHERE product_id = NEW.product_id AND is_approved = 1 AND deleted_at IS NULL)
        WHERE product_id = NEW.product_id;
    END IF;
END $$

-- =============================================================================
-- TRIGGER 11: LOGIN ATTEMPT — Lockout enforcement
-- =============================================================================

DROP TRIGGER IF EXISTS trg_login_attempt_after_insert $$
CREATE TRIGGER trg_login_attempt_after_insert
    AFTER INSERT ON login_attempts
    FOR EACH ROW
BEGIN
    DECLARE v_fail_count TINYINT UNSIGNED;

    IF NEW.status = 'FAILED' AND NEW.user_id IS NOT NULL THEN
        SELECT failed_login_cnt INTO v_fail_count
        FROM users WHERE user_id = NEW.user_id;

        SET v_fail_count = v_fail_count + 1;

        IF v_fail_count >= 5 THEN
            -- Lockout for 30 minutes after 5 consecutive failures
            UPDATE users
            SET failed_login_cnt = v_fail_count,
                lockout_until    = DATE_ADD(NOW(3), INTERVAL 30 MINUTE)
            WHERE user_id = NEW.user_id;

            -- Log fraud event
            INSERT INTO fraud_logs (user_id, fraud_type, risk_score, details, action_taken)
            VALUES (
                NEW.user_id,
                'ACCOUNT_TAKEOVER',
                75,
                JSON_OBJECT(
                    'reason',       'Repeated failed logins',
                    'fail_count',   v_fail_count,
                    'ip_address',   HEX(NEW.ip_address),
                    'user_agent',   NEW.user_agent
                ),
                'BLOCKED'
            );
        ELSE
            UPDATE users SET failed_login_cnt = v_fail_count WHERE user_id = NEW.user_id;
        END IF;

    ELSEIF NEW.status = 'SUCCESS' AND NEW.user_id IS NOT NULL THEN
        -- Reset on successful login
        UPDATE users
        SET failed_login_cnt = 0,
            lockout_until    = NULL,
            last_login_at    = NOW(3)
        WHERE user_id = NEW.user_id;
    END IF;
END $$

DELIMITER ;

-- =============================================================================
-- END OF TRIGGERS
-- =============================================================================
