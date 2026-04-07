-- =============================================================================
-- ER DIAGRAM & RELATIONAL SCHEMA
-- File: 10_er_diagram_schema.sql
-- Platform: Ethiopia E-Commerce (eth_ecommerce)
-- =============================================================================
-- Contents:
--   PART A — Entity-Relationship Diagram (ASCII / text notation)
--   PART B — Formal Relational Schema (notation with PK/FK markers)
--   PART C — Relationship cardinalities & business rules
--   PART D — Schema integrity constraints summary
-- =============================================================================

-- =============================================================================
-- PART A: ENTITY-RELATIONSHIP DIAGRAM
-- =============================================================================
--
-- Legend:
--   [ENTITY]          = Strong entity (has its own PK)
--   ((ENTITY))        = Weak entity (depends on parent)
--   <RELATIONSHIP>    = Relationship
--   (attr)            = Attribute
--   *attr*            = Primary key attribute
--   #attr             = Foreign key attribute
--   [attr]            = Multi-valued attribute
--   {attr}            = Derived attribute
--   ---1              = Exactly one (mandatory)
--   ---M              = Many (mandatory)
--   ---0..1           = Zero or one (optional)
--   ---0..M           = Zero or many (optional)
-- =============================================================================

/*
══════════════════════════════════════════════════════════════════════════════
                   ETHIOPIA E-COMMERCE ER DIAGRAM
══════════════════════════════════════════════════════════════════════════════

                        ┌─────────────────┐
                        │   [user_roles]   │
                        │  *role_id*       │
                        │   role_code      │
                        │   role_name      │
                        └────────┬────────┘
                                 │ 1
                                 │ classifies
                                 │ M
        ┌──────────────────────────────────────────────┐
        │                   [users]                     │
        │  *user_id*   email   phone_number(enc)        │
        │   password_hash   first_name   last_name      │
        │   #role_id   #region_id   account_status      │
        │   is_email_verified   is_phone_verified       │
        │   failed_login_cnt   lockout_until            │
        │   last_login_at   metadata(JSON)              │
        │   deleted_at   created_at   updated_at        │
        └──────────┬──────────────────────┬────────────┘
                   │                      │
         ┌─────────┴────────┐   ┌─────────┴────────────┐
         │ has (0..M)       │   │ extends (0..1)        │
         │                  │   │                       │
  ┌──────▼──────────┐  ┌────▼───────────────────────────┐
  │ [user_addresses] │  │       [seller_profiles]         │
  │ *address_id*     │  │  *seller_id* (= user_id)        │
  │ #user_id         │  │   business_name   business_tin  │
  │ #region_id       │  │   #region_id   commission_rate  │
  │  label           │  │   bank_account_num(enc)         │
  │  recipient       │  │   telebirr_account(enc)         │
  │  street          │  │   rating   verification_status  │
  │  sub_city        │  └───────────────┬────────────────┘
  │  woreda          │                  │ 1
  │  latitude        │                  │ lists
  │  longitude       │                  │ M
  │  is_default      │      ┌───────────▼───────────────────────────────────┐
  └──────────────────┘      │                  [products]                    │
                             │  *product_id*   #seller_id   #category_id     │
                             │   sku (UNIQUE)   product_name   slug (UNIQUE) │
                             │   base_price   sale_price   currency          │
                             │   weight_grams   brand   description          │
                             │   rating   review_count   is_active           │
                             │   tags(JSON)   metadata(JSON)                 │
                             │   deleted_at   created_at   updated_at        │
                             └───────┬───────────────────┬───────────────────┘
                                     │                   │
                        ┌────────────┘                   └──────────────┐
                        │ 1..M                                  1..M    │
                        ▼                                               ▼
          ┌─────────────────────────┐              ┌──────────────────────────┐
          │    [product_variants]    │              │     [product_images]      │
          │  *variant_id*            │              │  *image_id*               │
          │  #product_id             │              │  #product_id              │
          │   variant_sku (UNIQUE)   │              │  #variant_id (optional)   │
          │   variant_name           │              │   url   alt_text          │
          │   price_delta            │              │   sort_order   is_primary │
          │   is_active              │              └──────────────────────────┘
          │   deleted_at             │
          └──────┬──────────────────┘
                 │ M
                 │ has attributes
                 │ M
  ┌──────────────▼───────────────────────────────────────────────────────────┐
  │                       [variant_attributes]                                │
  │  *variant_id* (FK→product_variants)   *attr_value_id* (FK→attr_values)  │
  └──────────────────────────────────┬───────────────────────────────────────┘
                                     │ M
                                     │ defined by
                                     │ 1
                         ┌───────────▼────────────────────┐
                         │      [attribute_values]          │
                         │  *attr_value_id*                 │
                         │  #attr_type_id                   │
                         │   value_label   value_code       │
                         │   hex_color   sort_order         │
                         └───────────┬────────────────────┘
                                     │ M
                                     │ is type
                                     │ 1
                         ┌───────────▼────────────────────┐
                         │      [attribute_types]           │
                         │  *attr_type_id*                  │
                         │   attr_name   attr_code          │
                         │   display_type                   │
                         └────────────────────────────────┘


══════════════════════════════════════════════════════════════════════════════
                        INVENTORY SUBSYSTEM
══════════════════════════════════════════════════════════════════════════════

  [product_variants] ───M─── <stocked in> ───M─── [warehouses]
          │                                              │
          │                                              │ located in
          │               [inventory]                    │ 1
          │          *inventory_id*                      │
          └─────── #variant_id ─────────────────────────┘
                        #warehouse_id ──────────────────►[regions]
                         quantity_on_hand
                         reserved_quantity
                         reorder_point
                         low_stock_alert
                              │
                              │ 1 generates M
                              ▼
                 ┌────────────────────────────┐
                 │  [inventory_transactions]   │
                 │  *txn_id*                   │
                 │  #inventory_id              │
                 │   variant_id               │
                 │   warehouse_id             │
                 │   txn_type (ENUM)          │
                 │   quantity_delta           │
                 │   quantity_after           │
                 │   reference_type          │
                 │   reference_id            │
                 │   created_at              │
                 └────────────────────────────┘


══════════════════════════════════════════════════════════════════════════════
                        ORDER & PAYMENT SUBSYSTEM
══════════════════════════════════════════════════════════════════════════════

  [users] ──1──── <places> ────M────► [orders]
  (customer)                           │ *order_id*
                                       │  order_number (UNIQUE)
  [users] ──1──── <fulfills> ───M─────►│  #customer_id
  (seller)                             │  #seller_id
                                       │  #shipping_address_id
  [order_statuses] ──1── <has> ─M─────►│  #billing_address_id
                                       │  #warehouse_id
  [payment_method_types] ─1──M────────►│  #region_id
                                       │  #status_id
  [user_addresses] ──1──M─────────────►│  #payment_method_id
                                       │  subtotal   discount_amount
                                       │  shipping_fee   tax_amount
                                       │  total_amount   currency
                                       │  payment_status (ENUM)
                                       │  coupon_code
                                       │  placed_at   confirmed_at
                                       │  shipped_at  delivered_at
                                       │  cancelled_at   deleted_at
                                       └─────────────┬───────────────
                                                     │ 1
                                     ┌───────────────┼────────────────┐
                                     │ M             │ M              │ M
                                     ▼               ▼                ▼
                            [order_items]       [payments]        [refunds]
                            *item_id*           *payment_id*      *refund_id*
                            #order_id           #order_id         #payment_id
                            #product_id         #customer_id      #order_id
                            #variant_id         #method_id        requested_by
                            #warehouse_id       idempotency_key   refund_amount
                             quantity           amount            reason
                             unit_price         status (ENUM)     status (ENUM)
                             discount_pct       gateway_ref
                             line_total         gateway_response
                             status (ENUM)      paid_at
                                                is_flagged


══════════════════════════════════════════════════════════════════════════════
                        CATEGORY HIERARCHY (RECURSIVE)
══════════════════════════════════════════════════════════════════════════════

  [categories]  ────── is parent of ──────► [categories]
   *category_id*                              (self-referential)
    #parent_id ──────────────────────────────► (nullable, NULL = root)
    category_name
    slug (UNIQUE)
    is_active
    deleted_at

  Example tree:
    Electronics (id=1, parent=NULL)
    └── Smartphones (id=10, parent=1)
    └── Laptops (id=11, parent=1)
    └── Power Solutions (id=14, parent=1)
    Fashion (id=2, parent=NULL)
    └── Traditional Wear (id=23, parent=2)


══════════════════════════════════════════════════════════════════════════════
                        REGION HIERARCHY (RECURSIVE)
══════════════════════════════════════════════════════════════════════════════

  [regions] ──────── is parent of ──────► [regions]
   *region_id*                              (self-referential)
    #parent_region_id ───────────────────► (nullable, NULL = top-level)
    region_code (UNIQUE)
    region_name
    latitude / longitude

  Example:
    Addis Ababa (id=1, parent=NULL)
    └── Bole Sub-City (id=9, parent=1)
    └── Kirkos Sub-City (id=10, parent=1)


══════════════════════════════════════════════════════════════════════════════
                        SECURITY & AUDIT SUBSYSTEM
══════════════════════════════════════════════════════════════════════════════

  [users] ──1──M──► [login_attempts]       [users] ──1──M──► [user_sessions]
                     *attempt_id*                              *session_id*
                     #user_id (nullable)                       #user_id
                     ip_address (enc)                          ip_address (enc)
                     user_agent                                device_type
                     status (ENUM)                             expires_at
                     failure_reason                            is_active

  [users] ──1──M──► [audit_logs]
                     *log_id*
                     #user_id (nullable)
                     action   entity_type   entity_id
                     old_values(JSON)   new_values(JSON)
                     status   created_at

  [users] ──1──M──► [fraud_logs]
                     *fraud_id*
                     #user_id (nullable)
                     #order_id (nullable)
                     #payment_id (nullable)
                     fraud_type (ENUM)
                     risk_score (0-100)
                     details(JSON)
                     action_taken (ENUM)


══════════════════════════════════════════════════════════════════════════════
                        ANALYTICS SUBSYSTEM
══════════════════════════════════════════════════════════════════════════════

  [daily_sales_summary]          [product_sales_stats]       [customer_ltv]
  PK(summary_date,               PK(product_id,              PK(customer_id)
     region_id, seller_id)          period_date)              #customer_id
   total_orders                   units_sold                  total_orders
   total_revenue                  revenue                     total_spent
   total_items_sold               returns                     ltv_score
   total_refunds                  views                       segment (ENUM)
   avg_order_value

  All three populated by MySQL Events (evt_refresh_*)
  and queried via VIEWS (vw_sales_summary, vw_top_selling_products, etc.)


══════════════════════════════════════════════════════════════════════════════
                        REVIEWS & NOTIFICATIONS
══════════════════════════════════════════════════════════════════════════════

  [users]    [products]    [orders]             [users]
     │            │            │                   │
     └────────────┴────────────┘                   │ 1
              1..M                                  │ M
              ▼                                     ▼
     [product_reviews]                    [notifications]
      *review_id*                          *notification_id*
      #product_id                          #user_id
      #customer_id                          type   channel (ENUM)
      #order_id (verified purchase)         title   body
       rating (1-5)                         is_read   sent_at
       title   body                         read_at
       is_verified   is_approved


══════════════════════════════════════════════════════════════════════════════
                        COUPONS
══════════════════════════════════════════════════════════════════════════════

  [coupons]
   *coupon_id*
    coupon_code (UNIQUE)
    discount_type (ENUM: PERCENTAGE / FIXED_AMOUNT / FREE_SHIPPING)
    discount_value
    min_order_amt   max_discount
    usage_limit   usage_count   per_user_limit
    valid_from   valid_until
    is_active   #created_by

  Referenced by: orders.coupon_code (loose reference — not FK for flexibility)


══════════════════════════════════════════════════════════════════════════════
                   COMPLETE TABLE COUNT: 30 TABLES
══════════════════════════════════════════════════════════════════════════════
  Lookup/Reference  :  regions, categories, payment_method_types,
                       order_statuses, user_roles                          (5)
  User & Identity   :  users, user_addresses, seller_profiles              (3)
  Product Catalog   :  products, product_variants, product_images,
                       attribute_types, attribute_values, variant_attributes (6)
  Inventory         :  warehouses, inventory, inventory_transactions        (3)
  Orders            :  orders, order_items                                  (2)
  Payments          :  payments, refunds                                    (2)
  Security & Audit  :  login_attempts, audit_logs, fraud_logs,
                       user_sessions                                        (4)
  Analytics         :  daily_sales_summary, product_sales_stats,
                       customer_ltv                                         (3)
  Social & Promo    :  product_reviews, coupons, notifications              (3)
  Shard Routing     :  shard_map                                            (1)
                                                              TOTAL =      32
                                                              (including 2 arch)
*/

-- =============================================================================
-- PART B: FORMAL RELATIONAL SCHEMA
-- =============================================================================
-- Notation:
--   PK = Primary Key (underlined in text)
--   FK = Foreign Key (→ target table)
--   AK = Alternate Key / Unique constraint
--   NN = NOT NULL
--   ENC = Encrypted column
--   JSON = JSON column
-- =============================================================================

/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
LOOKUP / REFERENCE TABLES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

user_roles (
    PK role_id         TINYINT UNSIGNED AUTO_INCREMENT,
    AK role_code       VARCHAR(50) NOT NULL UNIQUE,
       role_name       VARCHAR(100) NOT NULL
)

order_statuses (
    PK status_id       TINYINT UNSIGNED AUTO_INCREMENT,
    AK status_code     VARCHAR(50) NOT NULL UNIQUE,
       status_name     VARCHAR(100) NOT NULL,
       is_terminal     TINYINT(1) NOT NULL DEFAULT 0,
       sort_order      TINYINT NOT NULL DEFAULT 0
)

payment_method_types (
    PK method_id       TINYINT UNSIGNED AUTO_INCREMENT,
    AK method_code     VARCHAR(50) NOT NULL UNIQUE,
       method_name     VARCHAR(100) NOT NULL,
       is_digital      TINYINT(1) NOT NULL DEFAULT 1,
       is_active       TINYINT(1) NOT NULL DEFAULT 1
)

regions (
    PK region_id       SMALLINT UNSIGNED AUTO_INCREMENT,
    AK region_code     VARCHAR(10) NOT NULL UNIQUE,
    FK parent_region_id→regions(region_id) NULL  [self-referential, ON UPDATE CASCADE],
       region_name     VARCHAR(100) NOT NULL,
       timezone        VARCHAR(50) NOT NULL DEFAULT 'Africa/Addis_Ababa',
       latitude        DECIMAL(10,7),
       longitude       DECIMAL(10,7),
       is_active       TINYINT(1) NOT NULL DEFAULT 1,
       created_at      DATETIME(3) NOT NULL,
       updated_at      DATETIME(3) NOT NULL
)

categories (
    PK category_id     INT UNSIGNED AUTO_INCREMENT,
    FK parent_id→categories(category_id) NULL  [self-referential, ON UPDATE CASCADE],
    AK slug            VARCHAR(200) NOT NULL UNIQUE,
       category_name   VARCHAR(150) NOT NULL,
       description     TEXT,
       image_url       VARCHAR(500),
       sort_order      SMALLINT NOT NULL DEFAULT 0,
       is_active       TINYINT(1) NOT NULL DEFAULT 1,
       deleted_at      DATETIME(3) [soft delete],
       created_at      DATETIME(3) NOT NULL,
       updated_at      DATETIME(3) NOT NULL,
    FTX ft_category_name (category_name, description)
)

attribute_types (
    PK attr_type_id    INT UNSIGNED AUTO_INCREMENT,
    AK attr_code       VARCHAR(50) NOT NULL UNIQUE,
       attr_name       VARCHAR(100) NOT NULL,
       display_type    ENUM('SWATCH','DROPDOWN','RADIO','TEXT') NOT NULL
)

attribute_values (
    PK attr_value_id   INT UNSIGNED AUTO_INCREMENT,
    FK attr_type_id→attribute_types(attr_type_id) NOT NULL  [ON DELETE CASCADE],
    AK (attr_type_id, value_code),
       value_label     VARCHAR(100) NOT NULL,
       value_code      VARCHAR(100) NOT NULL,
       hex_color       CHAR(7),
       sort_order      TINYINT NOT NULL DEFAULT 0
)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
USER & IDENTITY TABLES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

users (
    PK user_id             BIGINT UNSIGNED AUTO_INCREMENT,
    FK role_id→user_roles(role_id) NOT NULL,
    FK region_id→regions(region_id) NULL,
    AK email               VARCHAR(255) NOT NULL UNIQUE,
       phone_number        VARBINARY(512) NOT NULL  [ENC: AES-256, E.164 format],
       password_hash       VARCHAR(255) NOT NULL    [bcrypt $2b$, cost≥12],
       first_name          VARCHAR(100) NOT NULL,
       last_name           VARCHAR(100) NOT NULL,
       display_name        VARCHAR(150) GENERATED STORED,
       date_of_birth       DATE,
       gender              ENUM('M','F','OTHER','PREFER_NOT'),
       profile_image       VARCHAR(500),
       preferred_lang      CHAR(5) NOT NULL DEFAULT 'am',
       is_email_verified   TINYINT(1) NOT NULL DEFAULT 0,
       is_phone_verified   TINYINT(1) NOT NULL DEFAULT 0,
       account_status      ENUM('ACTIVE','SUSPENDED','BANNED','PENDING_VERIFICATION') NOT NULL,
       last_login_at       DATETIME(3),
       failed_login_cnt    TINYINT UNSIGNED NOT NULL DEFAULT 0,
       lockout_until       DATETIME(3),
       metadata            JSON,
       deleted_at          DATETIME(3)  [soft delete],
       created_at          DATETIME(3) NOT NULL,
       updated_at          DATETIME(3) NOT NULL
)

user_addresses (
    PK address_id      BIGINT UNSIGNED AUTO_INCREMENT,
    FK user_id→users(user_id) NOT NULL  [ON DELETE CASCADE],
    FK region_id→regions(region_id) NOT NULL,
       label           VARCHAR(50) NOT NULL DEFAULT 'Home',
       recipient       VARCHAR(200) NOT NULL,
       phone           VARBINARY(512) NOT NULL  [ENC],
       street          VARCHAR(300) NOT NULL,
       sub_city        VARCHAR(100),
       woreda          VARCHAR(100),
       landmark        VARCHAR(300),
       postal_code     VARCHAR(20),
       latitude        DECIMAL(10,7),
       longitude       DECIMAL(10,7),
       is_default      TINYINT(1) NOT NULL DEFAULT 0,
       deleted_at      DATETIME(3),
       created_at      DATETIME(3) NOT NULL,
       updated_at      DATETIME(3) NOT NULL
)

seller_profiles (
    PK seller_id           BIGINT UNSIGNED,         [same as users.user_id]
    FK seller_id→users(user_id)  [ON DELETE CASCADE],
    FK region_id→regions(region_id) NOT NULL,
       business_name       VARCHAR(200) NOT NULL,
       business_tin        VARCHAR(50),
       business_type       ENUM('INDIVIDUAL','COMPANY','COOPERATIVE') NOT NULL,
       address             VARCHAR(500) NOT NULL,
       bank_account_name   VARBINARY(512)  [ENC],
       bank_account_num    VARBINARY(512)  [ENC],
       bank_name           VARCHAR(100),
       telebirr_account    VARBINARY(512)  [ENC],
       commission_rate     DECIMAL(5,4) NOT NULL DEFAULT 0.0800,
       rating              DECIMAL(3,2) NOT NULL DEFAULT 0.00,
       total_reviews       INT UNSIGNED NOT NULL DEFAULT 0,
       verification_status ENUM('PENDING','VERIFIED','REJECTED','SUSPENDED') NOT NULL,
       verified_at         DATETIME(3),
       metadata            JSON,
       created_at          DATETIME(3) NOT NULL,
       updated_at          DATETIME(3) NOT NULL
)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PRODUCT CATALOG TABLES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

products (
    PK product_id      BIGINT UNSIGNED AUTO_INCREMENT,
    FK seller_id→users(user_id) NOT NULL  [ON DELETE RESTRICT],
    FK category_id→categories(category_id) NOT NULL  [ON DELETE RESTRICT],
    AK sku             VARCHAR(100) NOT NULL UNIQUE,
    AK slug            VARCHAR(350) NOT NULL UNIQUE,
       product_name    VARCHAR(300) NOT NULL,
       short_desc      VARCHAR(500),
       description     LONGTEXT,
       brand           VARCHAR(150),
       base_price      DECIMAL(14,2) NOT NULL  [CHECK ≥ 0],
       sale_price      DECIMAL(14,2)           [CHECK ≥ 0 or NULL],
       cost_price      DECIMAL(14,2),
       currency        CHAR(3) NOT NULL DEFAULT 'ETB',
       weight_grams    INT UNSIGNED,
       is_featured     TINYINT(1) NOT NULL DEFAULT 0,
       is_active       TINYINT(1) NOT NULL DEFAULT 1,
       requires_shipping TINYINT(1) NOT NULL DEFAULT 1,
       tags            JSON,
       metadata        JSON,
       rating          DECIMAL(3,2) NOT NULL DEFAULT 0.00,
       review_count    INT UNSIGNED NOT NULL DEFAULT 0,
       deleted_at      DATETIME(3)  [soft delete],
       created_at      DATETIME(3) NOT NULL,
       updated_at      DATETIME(3) NOT NULL,
    FTX ft_product_search (product_name, short_desc, brand),
    IDX idx_prod_cat_price (category_id, base_price, is_active, deleted_at)  [covering]
)

product_variants (
    PK variant_id      BIGINT UNSIGNED AUTO_INCREMENT,
    FK product_id→products(product_id) NOT NULL  [ON DELETE CASCADE],
    AK variant_sku     VARCHAR(150) NOT NULL UNIQUE,
       variant_name    VARCHAR(200),
       price_delta     DECIMAL(10,2) NOT NULL DEFAULT 0.00,
       weight_grams    INT UNSIGNED,
       is_active       TINYINT(1) NOT NULL DEFAULT 1,
       deleted_at      DATETIME(3),
       created_at      DATETIME(3) NOT NULL,
       updated_at      DATETIME(3) NOT NULL
)

product_images (
    PK image_id        BIGINT UNSIGNED AUTO_INCREMENT,
    FK product_id→products(product_id) NOT NULL  [ON DELETE CASCADE],
    FK variant_id→product_variants(variant_id) NULL,
       url             VARCHAR(500) NOT NULL,
       alt_text        VARCHAR(300),
       sort_order      TINYINT UNSIGNED NOT NULL DEFAULT 0,
       is_primary      TINYINT(1) NOT NULL DEFAULT 0
)

variant_attributes (
    PK,FK variant_id→product_variants(variant_id)  [ON DELETE CASCADE],
    PK,FK attr_value_id→attribute_values(attr_value_id)  [ON DELETE RESTRICT],
    COMPOSITE PK (variant_id, attr_value_id)
)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
INVENTORY TABLES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

warehouses (
    PK warehouse_id    INT UNSIGNED AUTO_INCREMENT,
    FK region_id→regions(region_id) NOT NULL,
       warehouse_name  VARCHAR(150) NOT NULL,
       address         VARCHAR(500) NOT NULL,
       latitude        DECIMAL(10,7),
       longitude       DECIMAL(10,7),
       is_active       TINYINT(1) NOT NULL DEFAULT 1,
       created_at      DATETIME(3) NOT NULL
)

inventory (
    PK inventory_id        BIGINT UNSIGNED AUTO_INCREMENT,
    FK variant_id→product_variants(variant_id) NOT NULL  [ON DELETE CASCADE],
    FK warehouse_id→warehouses(warehouse_id) NOT NULL,
    AK (variant_id, warehouse_id) UNIQUE,
       quantity_on_hand    INT NOT NULL DEFAULT 0  [CHECK ≥ 0],
       reserved_quantity   INT NOT NULL DEFAULT 0  [CHECK ≥ 0],
       reorder_point       INT NOT NULL DEFAULT 10,
       reorder_quantity    INT NOT NULL DEFAULT 50,
       low_stock_alert     TINYINT(1) NOT NULL DEFAULT 0,
       last_restocked_at   DATETIME(3),
       updated_at          DATETIME(3) NOT NULL,
    CHECK: quantity_on_hand ≥ reserved_quantity  [available ≥ 0]
)

inventory_transactions (
    PK txn_id              BIGINT UNSIGNED AUTO_INCREMENT,
    FK inventory_id→inventory(inventory_id) NOT NULL  [ON DELETE RESTRICT],
       variant_id          BIGINT UNSIGNED NOT NULL,
       warehouse_id        INT UNSIGNED NOT NULL,
       txn_type            ENUM('RESTOCK','SALE','RESERVATION','RELEASE',
                                'CANCELLATION','ADJUSTMENT','RETURN','TRANSFER') NOT NULL,
       quantity_delta      INT NOT NULL,
       quantity_after      INT NOT NULL,
       reference_type      VARCHAR(50),
       reference_id        BIGINT UNSIGNED,
       notes               VARCHAR(500),
       created_by          BIGINT UNSIGNED,
       created_at          DATETIME(3) NOT NULL  [append-only, no UPDATE/DELETE]
)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ORDER TABLES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

orders (
    PK order_id            BIGINT UNSIGNED AUTO_INCREMENT,
    AK order_number        VARCHAR(30) NOT NULL UNIQUE,
    FK customer_id→users(user_id) NOT NULL  [ON DELETE RESTRICT],
    FK seller_id→users(user_id) NOT NULL    [ON DELETE RESTRICT],
    FK shipping_address_id→user_addresses(address_id) NULL  [ON DELETE SET NULL],
    FK billing_address_id→user_addresses(address_id) NULL   [ON DELETE SET NULL],
    FK warehouse_id→warehouses(warehouse_id) NULL            [ON DELETE SET NULL],
    FK region_id→regions(region_id) NULL                     [ON DELETE SET NULL],
    FK status_id→order_statuses(status_id) NOT NULL          [ON DELETE RESTRICT],
    FK payment_method_id→payment_method_types(method_id),
       subtotal            DECIMAL(14,2) NOT NULL DEFAULT 0.00,
       discount_amount     DECIMAL(14,2) NOT NULL DEFAULT 0.00,
       shipping_fee        DECIMAL(14,2) NOT NULL DEFAULT 0.00,
       tax_amount          DECIMAL(14,2) NOT NULL DEFAULT 0.00,
       total_amount        DECIMAL(14,2) NOT NULL DEFAULT 0.00  [CHECK ≥ 0],
       currency            CHAR(3) NOT NULL DEFAULT 'ETB',
       payment_status      ENUM('PENDING','AUTHORIZED','CAPTURED',
                                'PARTIALLY_REFUNDED','REFUNDED',
                                'FAILED','CANCELLED') NOT NULL,
       coupon_code         VARCHAR(50),
       notes               TEXT,
       placed_at           DATETIME(3) NOT NULL,
       confirmed_at        DATETIME(3),
       shipped_at          DATETIME(3),
       delivered_at        DATETIME(3),
       cancelled_at        DATETIME(3),
       deleted_at          DATETIME(3)  [soft archive],
       updated_at          DATETIME(3) NOT NULL,
    IDX idx_ord_customer_date (customer_id, placed_at),
    IDX idx_ord_seller_date   (seller_id,   placed_at),
    IDX idx_ord_status        (status_id,   placed_at)
)

order_items (
    PK item_id         BIGINT UNSIGNED AUTO_INCREMENT,
    FK order_id→orders(order_id) NOT NULL          [ON DELETE CASCADE],
    FK product_id→products(product_id) NOT NULL    [ON DELETE RESTRICT],
    FK variant_id→product_variants(variant_id) NOT NULL  [ON DELETE RESTRICT],
    FK warehouse_id→warehouses(warehouse_id) NOT NULL    [ON DELETE RESTRICT],
       quantity        INT UNSIGNED NOT NULL  [CHECK > 0],
       unit_price      DECIMAL(14,2) NOT NULL  [snapshot price at purchase time],
       discount_pct    DECIMAL(5,2) NOT NULL DEFAULT 0.00,
       line_total      DECIMAL(14,2) NOT NULL,
       status          ENUM('ACTIVE','CANCELLED','RETURNED') NOT NULL,
       created_at      DATETIME(3) NOT NULL,
       updated_at      DATETIME(3) NOT NULL
)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PAYMENT TABLES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

payments (
    PK payment_id          BIGINT UNSIGNED AUTO_INCREMENT,
    FK order_id→orders(order_id) NOT NULL          [ON DELETE RESTRICT],
    FK customer_id→users(user_id) NOT NULL         [ON DELETE RESTRICT],
    FK method_id→payment_method_types(method_id) NOT NULL,
    AK idempotency_key     VARCHAR(128) NOT NULL UNIQUE,
       amount              DECIMAL(14,2) NOT NULL  [CHECK > 0],
       currency            CHAR(3) NOT NULL DEFAULT 'ETB',
       status              ENUM('PENDING','PROCESSING','SUCCESS','FAILED',
                                'CANCELLED','REFUNDED','PARTIALLY_REFUNDED') NOT NULL,
       gateway_reference   VARCHAR(200),
       gateway_response    JSON,
       paid_at             DATETIME(3),
       refunded_amount     DECIMAL(14,2) NOT NULL DEFAULT 0.00,
       failure_reason      VARCHAR(500),
       ip_address          VARBINARY(64)  [ENC],
       device_fingerprint  VARCHAR(255),
       is_flagged          TINYINT(1) NOT NULL DEFAULT 0,
       created_at          DATETIME(3) NOT NULL,
       updated_at          DATETIME(3) NOT NULL,
    CHECK: refunded_amount ≥ 0 AND refunded_amount ≤ amount
)

refunds (
    PK refund_id       BIGINT UNSIGNED AUTO_INCREMENT,
    FK payment_id→payments(payment_id) NOT NULL,
    FK order_id→orders(order_id) NOT NULL,
    FK requested_by→users(user_id),
    FK approved_by→users(user_id) NULL,
       refund_amount   DECIMAL(14,2) NOT NULL  [CHECK > 0],
       reason          VARCHAR(500) NOT NULL,
       status          ENUM('PENDING','APPROVED','PROCESSED','REJECTED','FAILED') NOT NULL,
       gateway_ref     VARCHAR(200),
       notes           TEXT,
       created_at      DATETIME(3) NOT NULL,
       updated_at      DATETIME(3) NOT NULL
)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SECURITY & AUDIT TABLES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

login_attempts (
    PK attempt_id      BIGINT UNSIGNED AUTO_INCREMENT,
    FK user_id→users(user_id) NULL  [NULL if unknown user],
       email           VARCHAR(255),
       ip_address      VARBINARY(64) NOT NULL  [ENC],
       user_agent      VARCHAR(500),
       status          ENUM('SUCCESS','FAILED','BLOCKED') NOT NULL,
       failure_reason  VARCHAR(200),
       attempted_at    DATETIME(3) NOT NULL  [append-only]
)

audit_logs (
    PK log_id          BIGINT UNSIGNED AUTO_INCREMENT,
    FK user_id→users(user_id) NULL,
       session_id      VARCHAR(128),
       action          VARCHAR(100) NOT NULL,
       entity_type     VARCHAR(50) NOT NULL,
       entity_id       BIGINT UNSIGNED,
       old_values      JSON,
       new_values      JSON,
       ip_address      VARBINARY(64),
       user_agent      VARCHAR(500),
       status          ENUM('SUCCESS','FAILURE','WARNING') NOT NULL,
       message         VARCHAR(1000),
       created_at      DATETIME(3) NOT NULL  [append-only, never UPDATE/DELETE]
)

fraud_logs (
    PK fraud_id        BIGINT UNSIGNED AUTO_INCREMENT,
    FK user_id→users(user_id) NULL,
    FK order_id→orders(order_id) NULL,
    FK payment_id→payments(payment_id) NULL,
       fraud_type      ENUM('VELOCITY_ABUSE','PAYMENT_FAILURE','ACCOUNT_TAKEOVER',
                            'MULTIPLE_ACCOUNTS','SUSPICIOUS_IP','CHARGEBACK',
                            'REVIEW_FRAUD','COUPON_ABUSE','OTHER') NOT NULL,
       risk_score      TINYINT UNSIGNED NOT NULL  [0-100],
       details         JSON NOT NULL,
       action_taken    ENUM('FLAGGED','BLOCKED','SUSPENDED','ESCALATED','DISMISSED') NOT NULL,
       reviewed_by     BIGINT UNSIGNED,
       reviewed_at     DATETIME(3),
       created_at      DATETIME(3) NOT NULL
)

user_sessions (
    PK session_id      VARCHAR(128),
    FK user_id→users(user_id) NOT NULL  [ON DELETE CASCADE],
       ip_address      VARBINARY(64) NOT NULL  [ENC],
       user_agent      VARCHAR(500),
       device_type     ENUM('MOBILE','TABLET','DESKTOP','OTHER') NOT NULL,
       is_active       TINYINT(1) NOT NULL DEFAULT 1,
       expires_at      DATETIME(3) NOT NULL,
       created_at      DATETIME(3) NOT NULL,
       last_active_at  DATETIME(3) NOT NULL
)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ANALYTICS TABLES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

daily_sales_summary (
    PK (summary_date DATE, region_id SMALLINT UNSIGNED, seller_id BIGINT UNSIGNED),
       total_orders       INT UNSIGNED NOT NULL DEFAULT 0,
       total_revenue      DECIMAL(18,2) NOT NULL DEFAULT 0.00,
       total_items_sold   INT UNSIGNED NOT NULL DEFAULT 0,
       total_refunds      DECIMAL(18,2) NOT NULL DEFAULT 0.00,
       avg_order_value    DECIMAL(14,2) NOT NULL DEFAULT 0.00,
       updated_at         DATETIME(3) NOT NULL
)

product_sales_stats (
    PK (product_id BIGINT UNSIGNED, period_date DATE),
    FK product_id→products(product_id)  [ON DELETE CASCADE],
       units_sold         INT UNSIGNED NOT NULL DEFAULT 0,
       revenue            DECIMAL(14,2) NOT NULL DEFAULT 0.00,
       returns            INT UNSIGNED NOT NULL DEFAULT 0,
       views              INT UNSIGNED NOT NULL DEFAULT 0,
       updated_at         DATETIME(3) NOT NULL
)

customer_ltv (
    PK,FK customer_id→users(user_id)  [ON DELETE CASCADE],
       first_order_date   DATE,
       last_order_date    DATE,
       total_orders       INT UNSIGNED NOT NULL DEFAULT 0,
       total_spent        DECIMAL(18,2) NOT NULL DEFAULT 0.00,
       total_refunds      DECIMAL(18,2) NOT NULL DEFAULT 0.00,
       avg_order_value    DECIMAL(14,2) NOT NULL DEFAULT 0.00,
       ltv_score          DECIMAL(10,2) NOT NULL DEFAULT 0.00,
       segment            ENUM('NEW','ACTIVE','VIP','AT_RISK','CHURNED') NOT NULL,
       updated_at         DATETIME(3) NOT NULL
)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SOCIAL & PROMOTIONAL TABLES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

product_reviews (
    PK review_id       BIGINT UNSIGNED AUTO_INCREMENT,
    FK product_id→products(product_id) NOT NULL   [ON DELETE CASCADE],
    FK customer_id→users(user_id) NOT NULL         [ON DELETE CASCADE],
    FK order_id→orders(order_id) NOT NULL          [ON DELETE CASCADE, verified purchase],
    AK (order_id, product_id) UNIQUE  [one review per purchase],
       rating          TINYINT UNSIGNED NOT NULL  [CHECK 1-5],
       title           VARCHAR(200),
       body            TEXT,
       is_verified     TINYINT(1) NOT NULL DEFAULT 1,
       is_approved     TINYINT(1) NOT NULL DEFAULT 0,
       helpful_votes   INT UNSIGNED NOT NULL DEFAULT 0,
       deleted_at      DATETIME(3),
       created_at      DATETIME(3) NOT NULL,
    FTX ft_review_body (title, body)
)

coupons (
    PK coupon_id       INT UNSIGNED AUTO_INCREMENT,
    AK coupon_code     VARCHAR(50) NOT NULL UNIQUE,
    FK created_by→users(user_id) NOT NULL,
       description     VARCHAR(300),
       discount_type   ENUM('PERCENTAGE','FIXED_AMOUNT','FREE_SHIPPING') NOT NULL,
       discount_value  DECIMAL(10,2) NOT NULL,
       min_order_amt   DECIMAL(10,2) NOT NULL DEFAULT 0.00,
       max_discount    DECIMAL(10,2),
       usage_limit     INT UNSIGNED,
       usage_count     INT UNSIGNED NOT NULL DEFAULT 0,
       per_user_limit  INT UNSIGNED NOT NULL DEFAULT 1,
       valid_from      DATETIME(3) NOT NULL,
       valid_until     DATETIME(3) NOT NULL,
       is_active       TINYINT(1) NOT NULL DEFAULT 1,
       created_at      DATETIME(3) NOT NULL
)

notifications (
    PK notification_id BIGINT UNSIGNED AUTO_INCREMENT,
    FK user_id→users(user_id) NOT NULL  [ON DELETE CASCADE],
       type            VARCHAR(100) NOT NULL,
       channel         ENUM('EMAIL','SMS','PUSH','IN_APP') NOT NULL,
       title           VARCHAR(200) NOT NULL,
       body            TEXT NOT NULL,
       data            JSON,
       is_read         TINYINT(1) NOT NULL DEFAULT 0,
       sent_at         DATETIME(3),
       read_at         DATETIME(3),
       created_at      DATETIME(3) NOT NULL
)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DISTRIBUTED / OPERATIONAL TABLE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

shard_map (
    PK shard_id        TINYINT UNSIGNED,
       shard_name      VARCHAR(50) NOT NULL,
       dsn_primary     VARCHAR(200) NOT NULL,
       dsn_replica     VARCHAR(200) NOT NULL,
       region_ids      JSON NOT NULL,
       is_active       TINYINT(1) NOT NULL DEFAULT 1,
       max_user_id     BIGINT UNSIGNED,
       min_user_id     BIGINT UNSIGNED
)
*/

-- =============================================================================
-- PART C: RELATIONSHIP CARDINALITIES & BUSINESS RULES
-- =============================================================================

/*
TABLE              RELATIONSHIP            TABLE                   CARDINALITY  MANDATORY
──────────────────────────────────────────────────────────────────────────────────────────
user_roles         classifies              users                   1 : M        both
regions            locates                 users                   1 : M        users opt.
regions            locates                 user_addresses          1 : M        both
regions            locates                 seller_profiles         1 : M        both
regions            locates                 warehouses              1 : M        both
regions            locates                 orders                  1 : M        orders opt.
regions            is parent of            regions (self)          1 : M        parent opt.

users (seller)     lists                   products                1 : M        both
users (customer)   places                  orders                  1 : M        both
users              has                     user_addresses          1 : M        addr mandatory
users              has                     user_sessions           1 : M        sessions opt.
users              generates               login_attempts          1 : M        attempts opt.
users              triggers                audit_logs              1 : M        user opt.
users              triggers                fraud_logs              1 : M        user opt.
users              receives                notifications           1 : M        both
users (seller)     extends to              seller_profiles         1 : 1        both

categories         organizes               products                1 : M        both
categories         is parent of            categories (self)       1 : M        parent opt.

products           has                     product_variants        1 : M        both
products           has                     product_images          1 : M        images opt.
products           has                     product_sales_stats     1 : M        stats opt.
products           receives                product_reviews         1 : M        reviews opt.

product_variants   has attributes via      variant_attributes      M : M        —
attribute_types    defines                 attribute_values        1 : M        both
attribute_values   maps to variants via    variant_attributes      M : M        —

product_variants   stocked in              inventory               1 : M        inv mandatory
warehouses         hosts                   inventory               1 : M        inv mandatory
inventory          records                 inventory_transactions  1 : M        both

orders             contains               order_items              1 : M        both
orders             has                    payments                 1 : M        payments opt.
orders             has                    refunds                  1 : M        refunds opt.
orders             has status             order_statuses           M : 1        both
orders             uses                   payment_method_types     M : 1        meth opt.
orders             ships to               user_addresses           M : 1        addr opt.

payments           generates              refunds                  1 : M        refunds opt.

product_reviews    verified by            orders                   M : 1        both

coupons            applied to             orders                   1 : M        loose ref.
*/

-- =============================================================================
-- PART D: SCHEMA INTEGRITY CONSTRAINT SUMMARY
-- =============================================================================

SELECT
    tc.TABLE_NAME,
    tc.CONSTRAINT_NAME,
    tc.CONSTRAINT_TYPE,
    kcu.COLUMN_NAME,
    kcu.REFERENCED_TABLE_NAME,
    kcu.REFERENCED_COLUMN_NAME,
    rc.UPDATE_RULE,
    rc.DELETE_RULE
FROM information_schema.TABLE_CONSTRAINTS  tc
JOIN information_schema.KEY_COLUMN_USAGE   kcu
    ON kcu.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
   AND kcu.CONSTRAINT_NAME   = tc.CONSTRAINT_NAME
   AND kcu.TABLE_NAME        = tc.TABLE_NAME
LEFT JOIN information_schema.REFERENTIAL_CONSTRAINTS rc
    ON rc.CONSTRAINT_SCHEMA   = tc.CONSTRAINT_SCHEMA
   AND rc.CONSTRAINT_NAME     = tc.CONSTRAINT_NAME
WHERE tc.CONSTRAINT_SCHEMA = 'eth_ecommerce'
  AND tc.CONSTRAINT_TYPE   IN ('PRIMARY KEY','UNIQUE','FOREIGN KEY')
ORDER BY tc.TABLE_NAME, tc.CONSTRAINT_TYPE, tc.CONSTRAINT_NAME;

-- Index inventory for the schema
SELECT
    TABLE_NAME,
    INDEX_NAME,
    GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS columns,
    INDEX_TYPE,
    NON_UNIQUE
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = 'eth_ecommerce'
GROUP BY TABLE_NAME, INDEX_NAME, INDEX_TYPE, NON_UNIQUE
ORDER BY TABLE_NAME, NON_UNIQUE, INDEX_NAME;

-- =============================================================================
-- END OF ER DIAGRAM & RELATIONAL SCHEMA
-- =============================================================================
