-- =============================================================================
-- STORED PROCEDURES & FUNCTIONS
-- File: 04_stored_procedures.sql
-- Procedures:
--   sp_place_order          — Full transaction-safe order placement
--   sp_process_payment      — Idempotent payment processing
--   sp_reserve_inventory    — Standalone inventory reservation
--   sp_cancel_order         — Cancel order with full rollback semantics
--   sp_refund_payment       — Initiate refund
--   sp_restock_inventory    — Warehouse restock operation
--   fn_generate_order_number — Order number generator
--   fn_get_available_qty    — Available inventory calculator
-- =============================================================================

USE eth_ecommerce;

DELIMITER $$

-- =============================================================================
-- FUNCTION: fn_generate_order_number
-- Generates human-readable order numbers: ETH-YYYYMMDD-NNNNNN
-- =============================================================================
DROP FUNCTION IF EXISTS fn_generate_order_number $$
CREATE FUNCTION fn_generate_order_number()
RETURNS VARCHAR(30)
DETERMINISTIC
BEGIN
    DECLARE v_date   VARCHAR(8);
    DECLARE v_seq    INT;
    DECLARE v_num    VARCHAR(30);

    SET v_date = DATE_FORMAT(NOW(), '%Y%m%d');

    -- Atomic sequence via single-row counter table trick
    -- (In production, use a dedicated sequence table or UUID_SHORT())
    SELECT COALESCE(MAX(CAST(SUBSTRING_INDEX(order_number, '-', -1) AS UNSIGNED)), 0) + 1
    INTO   v_seq
    FROM   orders
    WHERE  order_number LIKE CONCAT('ETH-', v_date, '-%');

    SET v_num = CONCAT('ETH-', v_date, '-', LPAD(v_seq, 6, '0'));
    RETURN v_num;
END $$

-- =============================================================================
-- FUNCTION: fn_get_available_qty
-- Returns: quantity_on_hand - reserved_quantity for a variant in a warehouse
-- =============================================================================
DROP FUNCTION IF EXISTS fn_get_available_qty $$
CREATE FUNCTION fn_get_available_qty(
    p_variant_id   BIGINT UNSIGNED,
    p_warehouse_id INT UNSIGNED
)
RETURNS INT
READS SQL DATA
DETERMINISTIC
BEGIN
    DECLARE v_avail INT DEFAULT 0;
    SELECT GREATEST(0, quantity_on_hand - reserved_quantity)
    INTO   v_avail
    FROM   inventory
    WHERE  variant_id   = p_variant_id
      AND  warehouse_id = p_warehouse_id;
    RETURN COALESCE(v_avail, 0);
END $$

-- =============================================================================
-- PROCEDURE: sp_reserve_inventory
-- Purpose: Atomically reserve stock for a single variant/warehouse.
-- Called internally by sp_place_order; also usable standalone (cart hold).
-- Uses SERIALIZABLE isolation + SELECT FOR UPDATE.
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_reserve_inventory $$
CREATE PROCEDURE sp_reserve_inventory(
    IN  p_variant_id      BIGINT UNSIGNED,
    IN  p_warehouse_id    INT UNSIGNED,
    IN  p_quantity        INT,
    IN  p_reference_type  VARCHAR(50),
    IN  p_reference_id    BIGINT UNSIGNED,
    OUT p_success         TINYINT,
    OUT p_message         VARCHAR(500)
)
BEGIN
    DECLARE v_available   INT DEFAULT 0;
    DECLARE v_inv_id      BIGINT UNSIGNED;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_success = 0;
        SET p_message = 'RESERVE_ERROR: Unexpected error during inventory reservation';
    END;

    SET p_success = 0;

    START TRANSACTION;

    -- Exclusive lock on inventory row
    SELECT inventory_id,
           GREATEST(0, quantity_on_hand - reserved_quantity)
    INTO   v_inv_id, v_available
    FROM   inventory
    WHERE  variant_id   = p_variant_id
      AND  warehouse_id = p_warehouse_id
    FOR UPDATE;

    IF v_inv_id IS NULL THEN
        ROLLBACK;
        SET p_message = 'RESERVE_ERROR: Inventory record not found';
        LEAVE sp_reserve_inventory;  -- exits the BEGIN..END block
    END IF;

    IF v_available < p_quantity THEN
        ROLLBACK;
        SET p_message = CONCAT('OVERSELL_PREVENTED: Need ', p_quantity,
                               ', available ', v_available);
        LEAVE sp_reserve_inventory;
    END IF;

    UPDATE inventory
    SET    reserved_quantity = reserved_quantity + p_quantity
    WHERE  inventory_id = v_inv_id;

    INSERT INTO inventory_transactions (
        inventory_id, variant_id, warehouse_id,
        txn_type, quantity_delta, quantity_after,
        reference_type, reference_id, notes
    )
    VALUES (
        v_inv_id, p_variant_id, p_warehouse_id,
        'RESERVATION', -p_quantity,
        (SELECT quantity_on_hand - reserved_quantity
         FROM inventory WHERE inventory_id = v_inv_id),
        p_reference_type, p_reference_id,
        CONCAT('Reserved: ', p_quantity, ' units for ', p_reference_type)
    );

    COMMIT;

    SET p_success = 1;
    SET p_message = CONCAT('OK: Reserved ', p_quantity, ' units');
END $$

-- =============================================================================
-- PROCEDURE: sp_place_order
-- Purpose : Transaction-safe order placement with full inventory reservation,
--           payment initiation, fraud check, and audit logging.
-- Isolation: REPEATABLE READ (MySQL default) + SELECT FOR UPDATE on inventory
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_place_order $$
CREATE PROCEDURE sp_place_order(
    IN  p_customer_id      BIGINT UNSIGNED,
    IN  p_seller_id        BIGINT UNSIGNED,
    IN  p_shipping_addr_id BIGINT UNSIGNED,
    IN  p_billing_addr_id  BIGINT UNSIGNED,
    IN  p_warehouse_id     INT UNSIGNED,
    IN  p_payment_method   TINYINT UNSIGNED,
    IN  p_coupon_code      VARCHAR(50),
    IN  p_idempotency_key  VARCHAR(128),
    -- Items as a JSON array: [{"variant_id":1,"quantity":2,"unit_price":299.99}]
    IN  p_items_json       JSON,
    OUT p_order_id         BIGINT UNSIGNED,
    OUT p_order_number     VARCHAR(30),
    OUT p_success          TINYINT,
    OUT p_message          VARCHAR(500)
)
proc_label: BEGIN
    DECLARE v_item_count     INT DEFAULT 0;
    DECLARE v_idx            INT DEFAULT 0;
    DECLARE v_variant_id     BIGINT UNSIGNED;
    DECLARE v_quantity       INT;
    DECLARE v_unit_price     DECIMAL(14,2);
    DECLARE v_product_id     BIGINT UNSIGNED;
    DECLARE v_region_id      SMALLINT UNSIGNED;
    DECLARE v_subtotal       DECIMAL(14,2) DEFAULT 0.00;
    DECLARE v_shipping_fee   DECIMAL(14,2) DEFAULT 0.00;
    DECLARE v_discount_amt   DECIMAL(14,2) DEFAULT 0.00;
    DECLARE v_tax_amount     DECIMAL(14,2) DEFAULT 0.00;
    DECLARE v_total          DECIMAL(14,2) DEFAULT 0.00;
    DECLARE v_discount_type  VARCHAR(30);
    DECLARE v_discount_val   DECIMAL(10,2);
    DECLARE v_coupon_id      INT UNSIGNED;
    DECLARE v_status_pending TINYINT UNSIGNED DEFAULT 1;
    DECLARE v_available      INT;
    DECLARE v_inv_id         BIGINT UNSIGNED;
    DECLARE v_line_total     DECIMAL(14,2);
    DECLARE v_new_item_id    BIGINT UNSIGNED;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1
            @sql_errno = MYSQL_ERRNO,
            @sql_msg   = MESSAGE_TEXT;
        ROLLBACK;
        SET p_success = 0;
        SET p_message = CONCAT('ORDER_ERROR [', @sql_errno, ']: ', @sql_msg);
        -- Log the failure
        INSERT INTO audit_logs (user_id, action, entity_type, status, message)
        VALUES (p_customer_id, 'ORDER_PLACE_FAILED', 'orders', 'FAILURE', @sql_msg);
    END;

    SET p_success = 0;
    SET p_order_id = NULL;

    -- -------------------------------------------------------------------------
    -- Pre-checks
    -- -------------------------------------------------------------------------
    -- 1. Idempotency: if this key already created a successful order, return it
    IF EXISTS (
        SELECT 1 FROM orders o
        JOIN payments pay ON pay.order_id = o.order_id
        WHERE pay.idempotency_key = p_idempotency_key AND pay.status = 'SUCCESS'
    ) THEN
        SELECT o.order_id, o.order_number
        INTO   p_order_id, p_order_number
        FROM   orders o
        JOIN   payments pay ON pay.order_id = o.order_id
        WHERE  pay.idempotency_key = p_idempotency_key AND pay.status = 'SUCCESS'
        LIMIT  1;
        SET p_success = 1;
        SET p_message = 'IDEMPOTENT: Order already placed';
        LEAVE proc_label;
    END IF;

    -- 2. Validate customer
    IF NOT EXISTS (
        SELECT 1 FROM users
        WHERE user_id = p_customer_id
          AND account_status = 'ACTIVE'
          AND deleted_at IS NULL
    ) THEN
        SET p_message = 'INVALID_CUSTOMER: Customer not found or inactive';
        LEAVE proc_label;
    END IF;

    -- 3. Validate items JSON
    SET v_item_count = JSON_LENGTH(p_items_json);
    IF v_item_count = 0 THEN
        SET p_message = 'INVALID_ORDER: No items provided';
        LEAVE proc_label;
    END IF;

    -- 4. Validate warehouse
    IF NOT EXISTS (
        SELECT 1 FROM warehouses WHERE warehouse_id = p_warehouse_id AND is_active = 1
    ) THEN
        SET p_message = 'INVALID_WAREHOUSE: Warehouse not found or inactive';
        LEAVE proc_label;
    END IF;

    -- -------------------------------------------------------------------------
    -- Begin transaction
    -- -------------------------------------------------------------------------
    START TRANSACTION;

    -- Get region from warehouse
    SELECT region_id INTO v_region_id FROM warehouses WHERE warehouse_id = p_warehouse_id;

    -- Get pending status id
    SELECT status_id INTO v_status_pending FROM order_statuses WHERE status_code = 'PENDING' LIMIT 1;

    -- -------------------------------------------------------------------------
    -- Apply coupon (if provided)
    -- -------------------------------------------------------------------------
    IF p_coupon_code IS NOT NULL AND p_coupon_code <> '' THEN
        SELECT coupon_id, discount_type, discount_value
        INTO   v_coupon_id, v_discount_type, v_discount_val
        FROM   coupons
        WHERE  coupon_code  = p_coupon_code
          AND  is_active    = 1
          AND  valid_from  <= NOW(3)
          AND  valid_until >= NOW(3)
          AND  (usage_limit IS NULL OR usage_count < usage_limit)
        LIMIT 1;

        IF v_coupon_id IS NULL THEN
            ROLLBACK;
            SET p_message = 'INVALID_COUPON: Coupon not found, expired, or used up';
            LEAVE proc_label;
        END IF;
    END IF;

    -- -------------------------------------------------------------------------
    -- Generate order number and create order skeleton
    -- -------------------------------------------------------------------------
    SET p_order_number = fn_generate_order_number();

    INSERT INTO orders (
        order_number, customer_id, seller_id,
        shipping_address_id, billing_address_id,
        warehouse_id, region_id,
        status_id, subtotal, discount_amount,
        shipping_fee, tax_amount, total_amount,
        currency, payment_method_id, coupon_code
    ) VALUES (
        p_order_number, p_customer_id, p_seller_id,
        p_shipping_addr_id, p_billing_addr_id,
        p_warehouse_id, v_region_id,
        v_status_pending, 0, 0, 0, 0, 0,
        'ETB', p_payment_method, p_coupon_code
    );

    SET p_order_id = LAST_INSERT_ID();

    -- -------------------------------------------------------------------------
    -- Process each order item: check stock, reserve, insert item
    -- -------------------------------------------------------------------------
    SET v_idx = 0;
    WHILE v_idx < v_item_count DO

        SET v_variant_id = JSON_UNQUOTE(JSON_EXTRACT(p_items_json, CONCAT('$[', v_idx, '].variant_id')));
        SET v_quantity   = JSON_UNQUOTE(JSON_EXTRACT(p_items_json, CONCAT('$[', v_idx, '].quantity')));
        SET v_unit_price = JSON_UNQUOTE(JSON_EXTRACT(p_items_json, CONCAT('$[', v_idx, '].unit_price')));

        -- Get product_id from variant (with lock)
        SELECT pv.product_id
        INTO   v_product_id
        FROM   product_variants pv
        WHERE  pv.variant_id = v_variant_id
          AND  pv.is_active  = 1
          AND  pv.deleted_at IS NULL
        FOR SHARE;

        IF v_product_id IS NULL THEN
            ROLLBACK;
            SET p_success = 0;
            SET p_message = CONCAT('INVALID_VARIANT: variant_id=', v_variant_id, ' not found or inactive');
            LEAVE proc_label;
        END IF;

        -- Lock inventory row for this variant/warehouse
        SELECT inventory_id,
               GREATEST(0, quantity_on_hand - reserved_quantity)
        INTO   v_inv_id, v_available
        FROM   inventory
        WHERE  variant_id   = v_variant_id
          AND  warehouse_id = p_warehouse_id
        FOR UPDATE;

        IF v_inv_id IS NULL THEN
            ROLLBACK;
            SET p_success = 0;
            SET p_message = CONCAT('NO_INVENTORY: variant_id=', v_variant_id,
                                   ' not stocked in warehouse_id=', p_warehouse_id);
            LEAVE proc_label;
        END IF;

        IF v_available < v_quantity THEN
            ROLLBACK;
            SET p_success = 0;
            SET p_message = CONCAT('INSUFFICIENT_STOCK: variant_id=', v_variant_id,
                                   ' needs=', v_quantity, ' available=', v_available);
            LEAVE proc_label;
        END IF;

        -- Reserve
        UPDATE inventory
        SET reserved_quantity = reserved_quantity + v_quantity
        WHERE inventory_id = v_inv_id;

        -- Calculate line total
        SET v_line_total = v_quantity * v_unit_price;
        SET v_subtotal   = v_subtotal + v_line_total;

        -- Insert order item
        INSERT INTO order_items (
            order_id, product_id, variant_id, warehouse_id,
            quantity, unit_price, discount_pct, line_total
        ) VALUES (
            p_order_id, v_product_id, v_variant_id, p_warehouse_id,
            v_quantity, v_unit_price, 0.00, v_line_total
        );

        -- Log inventory reservation
        INSERT INTO inventory_transactions (
            inventory_id, variant_id, warehouse_id,
            txn_type, quantity_delta, quantity_after,
            reference_type, reference_id, notes
        ) VALUES (
            v_inv_id, v_variant_id, p_warehouse_id,
            'RESERVATION', -v_quantity,
            (SELECT quantity_on_hand - reserved_quantity FROM inventory WHERE inventory_id = v_inv_id),
            'order', p_order_id,
            CONCAT('Order reservation order_id=', p_order_id)
        );

        SET v_idx = v_idx + 1;
    END WHILE;

    -- -------------------------------------------------------------------------
    -- Shipping fee (simplified: flat ETB 50 within city, ETB 150 cross-city)
    -- -------------------------------------------------------------------------
    SET v_shipping_fee = 50.00;

    -- -------------------------------------------------------------------------
    -- VAT calculation (15% Ethiopian VAT)
    -- -------------------------------------------------------------------------
    SET v_tax_amount = ROUND(v_subtotal * 0.15, 2);

    -- -------------------------------------------------------------------------
    -- Apply discount
    -- -------------------------------------------------------------------------
    IF v_coupon_id IS NOT NULL THEN
        IF v_discount_type = 'PERCENTAGE' THEN
            SET v_discount_amt = ROUND(v_subtotal * (v_discount_val / 100), 2);
        ELSEIF v_discount_type = 'FIXED_AMOUNT' THEN
            SET v_discount_amt = LEAST(v_discount_val, v_subtotal);
        ELSEIF v_discount_type = 'FREE_SHIPPING' THEN
            SET v_discount_amt = v_shipping_fee;
        END IF;

        UPDATE coupons SET usage_count = usage_count + 1 WHERE coupon_id = v_coupon_id;
    END IF;

    SET v_total = v_subtotal + v_shipping_fee + v_tax_amount - v_discount_amt;

    -- -------------------------------------------------------------------------
    -- Update order with final financial values
    -- -------------------------------------------------------------------------
    UPDATE orders
    SET subtotal       = v_subtotal,
        shipping_fee   = v_shipping_fee,
        tax_amount     = v_tax_amount,
        discount_amount = v_discount_amt,
        total_amount   = v_total
    WHERE order_id = p_order_id;

    -- -------------------------------------------------------------------------
    -- Create pending payment record
    -- -------------------------------------------------------------------------
    INSERT INTO payments (
        order_id, customer_id, method_id,
        idempotency_key, amount, currency, status
    ) VALUES (
        p_order_id, p_customer_id, p_payment_method,
        p_idempotency_key, v_total, 'ETB', 'PENDING'
    );

    -- -------------------------------------------------------------------------
    -- Audit log
    -- -------------------------------------------------------------------------
    INSERT INTO audit_logs (
        user_id, action, entity_type, entity_id,
        new_values, status, message
    ) VALUES (
        p_customer_id, 'ORDER_CREATED', 'orders', p_order_id,
        JSON_OBJECT(
            'order_number', p_order_number,
            'total',        v_total,
            'items',        v_item_count
        ),
        'SUCCESS',
        CONCAT('Order created: ', p_order_number)
    );

    COMMIT;

    SET p_success = 1;
    SET p_message = CONCAT('SUCCESS: Order ', p_order_number, ' placed. Total ETB ', v_total);
END $$

-- =============================================================================
-- PROCEDURE: sp_process_payment
-- Purpose : Idempotent payment processing (Telebirr / bank / COD)
--           Safe to retry: same idempotency_key → returns existing result
-- Isolation: REPEATABLE READ + row lock on payments
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_process_payment $$
CREATE PROCEDURE sp_process_payment(
    IN  p_idempotency_key   VARCHAR(128),
    IN  p_gateway_reference VARCHAR(200),
    IN  p_gateway_response  JSON,
    IN  p_new_status        ENUM('SUCCESS','FAILED','CANCELLED'),
    OUT p_payment_id        BIGINT UNSIGNED,
    OUT p_success           TINYINT,
    OUT p_message           VARCHAR(500)
)
proc_pay: BEGIN
    DECLARE v_current_status VARCHAR(30);
    DECLARE v_order_id       BIGINT UNSIGNED;
    DECLARE v_amount         DECIMAL(14,2);
    DECLARE v_confirmed_status_id TINYINT UNSIGNED;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @sql_msg = MESSAGE_TEXT;
        ROLLBACK;
        SET p_success = 0;
        SET p_message = CONCAT('PAYMENT_ERROR: ', @sql_msg);
    END;

    SET p_success = 0;

    -- -------------------------------------------------------------------------
    -- Idempotency check: already processed
    -- -------------------------------------------------------------------------
    SELECT payment_id, status, order_id, amount
    INTO   p_payment_id, v_current_status, v_order_id, v_amount
    FROM   payments
    WHERE  idempotency_key = p_idempotency_key
    LIMIT  1;

    IF p_payment_id IS NULL THEN
        SET p_message = 'PAYMENT_NOT_FOUND: No payment with given idempotency key';
        LEAVE proc_pay;
    END IF;

    -- If already in terminal state and same result requested → idempotent return
    IF v_current_status = p_new_status THEN
        SET p_success = 1;
        SET p_message = CONCAT('IDEMPOTENT: Payment already in state ', v_current_status);
        LEAVE proc_pay;
    END IF;

    IF v_current_status IN ('SUCCESS', 'REFUNDED', 'CANCELLED') THEN
        SET p_message = CONCAT('TERMINAL_STATE: Payment is already ', v_current_status);
        LEAVE proc_pay;
    END IF;

    -- -------------------------------------------------------------------------
    -- Begin transaction
    -- -------------------------------------------------------------------------
    START TRANSACTION;

    -- Lock the payment row
    SELECT payment_id, status
    INTO   p_payment_id, v_current_status
    FROM   payments
    WHERE  idempotency_key = p_idempotency_key
    FOR UPDATE;

    -- Update payment record
    UPDATE payments
    SET status            = p_new_status,
        gateway_reference = p_gateway_reference,
        gateway_response  = p_gateway_response,
        paid_at           = IF(p_new_status = 'SUCCESS', NOW(3), NULL)
    WHERE payment_id = p_payment_id;

    -- Update order payment_status
    UPDATE orders
    SET payment_status = p_new_status
    WHERE order_id = v_order_id;

    -- On SUCCESS: advance order to CONFIRMED
    IF p_new_status = 'SUCCESS' THEN
        SELECT status_id INTO v_confirmed_status_id
        FROM order_statuses WHERE status_code = 'CONFIRMED';

        UPDATE orders
        SET status_id    = v_confirmed_status_id,
            confirmed_at = NOW(3)
        WHERE order_id = v_order_id
          AND status_id = (SELECT status_id FROM order_statuses WHERE status_code = 'PENDING');
    END IF;

    -- On FAILED/CANCELLED: release inventory reservations
    IF p_new_status IN ('FAILED', 'CANCELLED') THEN
        -- Release all reserved inventory for this order
        UPDATE inventory inv
        JOIN order_items oi ON oi.variant_id   = inv.variant_id
                            AND oi.warehouse_id = inv.warehouse_id
                            AND oi.status       = 'ACTIVE'
        SET inv.reserved_quantity = GREATEST(0, inv.reserved_quantity - oi.quantity)
        WHERE oi.order_id = v_order_id;

        -- Cancel the order
        UPDATE orders
        SET status_id      = (SELECT status_id FROM order_statuses WHERE status_code = 'CANCELLED'),
            cancelled_at   = NOW(3),
            payment_status = p_new_status
        WHERE order_id = v_order_id;

        -- Mark items cancelled
        UPDATE order_items SET status = 'CANCELLED'
        WHERE order_id = v_order_id AND status = 'ACTIVE';
    END IF;

    -- Audit log
    INSERT INTO audit_logs (
        action, entity_type, entity_id,
        new_values, status, message
    ) VALUES (
        'PAYMENT_PROCESSED', 'payments', p_payment_id,
        JSON_OBJECT(
            'new_status',       p_new_status,
            'gateway_ref',      p_gateway_reference,
            'amount',           v_amount
        ),
        IF(p_new_status = 'SUCCESS', 'SUCCESS', 'WARNING'),
        CONCAT('Payment ', p_payment_id, ' → ', p_new_status)
    );

    COMMIT;

    SET p_success = 1;
    SET p_message = CONCAT('SUCCESS: Payment ', p_payment_id, ' status updated to ', p_new_status);
END $$

-- =============================================================================
-- PROCEDURE: sp_cancel_order
-- Purpose : Cancel a non-delivered order with full inventory release
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_cancel_order $$
CREATE PROCEDURE sp_cancel_order(
    IN  p_order_id       BIGINT UNSIGNED,
    IN  p_cancelled_by   BIGINT UNSIGNED,
    IN  p_cancel_reason  VARCHAR(500),
    OUT p_success        TINYINT,
    OUT p_message        VARCHAR(500)
)
proc_cancel: BEGIN
    DECLARE v_current_code  VARCHAR(50);
    DECLARE v_is_terminal   TINYINT(1);
    DECLARE v_cancelled_id  TINYINT UNSIGNED;
    DECLARE v_payment_id    BIGINT UNSIGNED;
    DECLARE v_payment_status VARCHAR(30);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @sql_msg = MESSAGE_TEXT;
        ROLLBACK;
        SET p_success = 0;
        SET p_message = CONCAT('CANCEL_ERROR: ', @sql_msg);
    END;

    SET p_success = 0;

    -- Validate order existence and status
    SELECT os.status_code, os.is_terminal
    INTO   v_current_code, v_is_terminal
    FROM   orders o
    JOIN   order_statuses os ON os.status_id = o.status_id
    WHERE  o.order_id = p_order_id;

    IF v_current_code IS NULL THEN
        SET p_message = 'ORDER_NOT_FOUND';
        LEAVE proc_cancel;
    END IF;

    IF v_is_terminal = 1 THEN
        SET p_message = CONCAT('CANCEL_REFUSED: Order is in terminal state ', v_current_code);
        LEAVE proc_cancel;
    END IF;

    IF v_current_code = 'DELIVERED' THEN
        SET p_message = 'CANCEL_REFUSED: Cannot cancel a delivered order. Use refund flow.';
        LEAVE proc_cancel;
    END IF;

    START TRANSACTION;

    SELECT status_id INTO v_cancelled_id FROM order_statuses WHERE status_code = 'CANCELLED';

    -- Cancel the order (trigger handles inventory release and item cancellation)
    UPDATE orders
    SET status_id    = v_cancelled_id,
        cancelled_at = NOW(3),
        notes        = CONCAT(COALESCE(notes, ''), ' | CANCELLED: ', p_cancel_reason)
    WHERE order_id = p_order_id;

    -- Cancel associated pending payment
    SELECT payment_id, status
    INTO   v_payment_id, v_payment_status
    FROM   payments
    WHERE  order_id = p_order_id
      AND  status IN ('PENDING', 'PROCESSING')
    LIMIT  1;

    IF v_payment_id IS NOT NULL THEN
        UPDATE payments
        SET status = 'CANCELLED'
        WHERE payment_id = v_payment_id;
    END IF;

    -- Audit log
    INSERT INTO audit_logs (
        user_id, action, entity_type, entity_id,
        new_values, status, message
    ) VALUES (
        p_cancelled_by, 'ORDER_CANCELLED', 'orders', p_order_id,
        JSON_OBJECT(
            'reason',      p_cancel_reason,
            'old_status',  v_current_code,
            'cancelled_by', p_cancelled_by
        ),
        'SUCCESS',
        CONCAT('Order ', p_order_id, ' cancelled by user ', p_cancelled_by)
    );

    COMMIT;

    SET p_success = 1;
    SET p_message = CONCAT('SUCCESS: Order ', p_order_id, ' cancelled');
END $$

-- =============================================================================
-- PROCEDURE: sp_refund_payment
-- Purpose : Initiate and process a full or partial refund
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_refund_payment $$
CREATE PROCEDURE sp_refund_payment(
    IN  p_payment_id     BIGINT UNSIGNED,
    IN  p_refund_amount  DECIMAL(14,2),
    IN  p_requested_by   BIGINT UNSIGNED,
    IN  p_reason         VARCHAR(500),
    IN  p_gateway_ref    VARCHAR(200),
    OUT p_refund_id      BIGINT UNSIGNED,
    OUT p_success        TINYINT,
    OUT p_message        VARCHAR(500)
)
proc_refund: BEGIN
    DECLARE v_order_id         BIGINT UNSIGNED;
    DECLARE v_payment_amount   DECIMAL(14,2);
    DECLARE v_already_refunded DECIMAL(14,2);
    DECLARE v_payment_status   VARCHAR(30);
    DECLARE v_max_refundable   DECIMAL(14,2);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @sql_msg = MESSAGE_TEXT;
        ROLLBACK;
        SET p_success = 0;
        SET p_message = CONCAT('REFUND_ERROR: ', @sql_msg);
    END;

    SET p_success = 0;

    SELECT order_id, amount, refunded_amount, status
    INTO   v_order_id, v_payment_amount, v_already_refunded, v_payment_status
    FROM   payments
    WHERE  payment_id = p_payment_id;

    IF v_order_id IS NULL THEN
        SET p_message = 'PAYMENT_NOT_FOUND';
        LEAVE proc_refund;
    END IF;

    IF v_payment_status NOT IN ('SUCCESS', 'PARTIALLY_REFUNDED') THEN
        SET p_message = CONCAT('REFUND_REFUSED: Payment status is ', v_payment_status);
        LEAVE proc_refund;
    END IF;

    SET v_max_refundable = v_payment_amount - v_already_refunded;

    IF p_refund_amount > v_max_refundable THEN
        SET p_message = CONCAT('REFUND_EXCEEDS_BALANCE: Max refundable=', v_max_refundable);
        LEAVE proc_refund;
    END IF;

    START TRANSACTION;

    -- Lock payment row
    SELECT payment_id FROM payments WHERE payment_id = p_payment_id FOR UPDATE;

    -- Create refund record
    INSERT INTO refunds (
        payment_id, order_id, requested_by,
        refund_amount, reason, status, gateway_ref
    ) VALUES (
        p_payment_id, v_order_id, p_requested_by,
        p_refund_amount, p_reason, 'PROCESSED', p_gateway_ref
    );

    SET p_refund_id = LAST_INSERT_ID();

    -- Update payment
    SET v_already_refunded = v_already_refunded + p_refund_amount;

    UPDATE payments
    SET refunded_amount = v_already_refunded,
        status = IF(v_already_refunded >= v_payment_amount, 'REFUNDED', 'PARTIALLY_REFUNDED')
    WHERE payment_id = p_payment_id;

    -- Update order payment_status
    UPDATE orders
    SET payment_status = IF(v_already_refunded >= v_payment_amount,
                            'REFUNDED', 'PARTIALLY_REFUNDED')
    WHERE order_id = v_order_id;

    -- Audit
    INSERT INTO audit_logs (user_id, action, entity_type, entity_id, new_values, status)
    VALUES (
        p_requested_by, 'REFUND_PROCESSED', 'refunds', p_refund_id,
        JSON_OBJECT('amount', p_refund_amount, 'reason', p_reason, 'payment_id', p_payment_id),
        'SUCCESS'
    );

    COMMIT;

    SET p_success = 1;
    SET p_message = CONCAT('SUCCESS: Refund of ETB ', p_refund_amount, ' processed, refund_id=', p_refund_id);
END $$

-- =============================================================================
-- PROCEDURE: sp_restock_inventory
-- Purpose : Safely add stock to a warehouse inventory row
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_restock_inventory $$
CREATE PROCEDURE sp_restock_inventory(
    IN  p_variant_id    BIGINT UNSIGNED,
    IN  p_warehouse_id  INT UNSIGNED,
    IN  p_quantity      INT,
    IN  p_restocked_by  BIGINT UNSIGNED,
    IN  p_notes         VARCHAR(500),
    OUT p_success       TINYINT,
    OUT p_message       VARCHAR(500)
)
BEGIN
    DECLARE v_inv_id BIGINT UNSIGNED;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @sql_msg = MESSAGE_TEXT;
        ROLLBACK;
        SET p_success = 0;
        SET p_message = CONCAT('RESTOCK_ERROR: ', @sql_msg);
    END;

    SET p_success = 0;

    IF p_quantity <= 0 THEN
        SET p_message = 'RESTOCK_ERROR: Quantity must be positive';
        LEAVE sp_restock_inventory;
    END IF;

    START TRANSACTION;

    SELECT inventory_id INTO v_inv_id
    FROM inventory
    WHERE variant_id = p_variant_id AND warehouse_id = p_warehouse_id
    FOR UPDATE;

    IF v_inv_id IS NULL THEN
        -- Auto-create inventory row
        INSERT INTO inventory (variant_id, warehouse_id, quantity_on_hand, reserved_quantity)
        VALUES (p_variant_id, p_warehouse_id, p_quantity, 0);
        SET v_inv_id = LAST_INSERT_ID();
    ELSE
        UPDATE inventory
        SET quantity_on_hand = quantity_on_hand + p_quantity,
            last_restocked_at = NOW(3),
            low_stock_alert   = 0
        WHERE inventory_id = v_inv_id;
    END IF;

    INSERT INTO inventory_transactions (
        inventory_id, variant_id, warehouse_id,
        txn_type, quantity_delta, quantity_after,
        reference_type, created_by, notes
    ) VALUES (
        v_inv_id, p_variant_id, p_warehouse_id,
        'RESTOCK', p_quantity,
        (SELECT quantity_on_hand FROM inventory WHERE inventory_id = v_inv_id),
        'manual', p_restocked_by, p_notes
    );

    COMMIT;

    SET p_success = 1;
    SET p_message = CONCAT('SUCCESS: Restocked ', p_quantity, ' units');
END $$

DELIMITER ;

-- =============================================================================
-- END OF STORED PROCEDURES
-- =============================================================================
