-- =============================================================================
-- SAMPLE DATA — Realistic seed data for Ethiopia E-Commerce Platform
-- File: 07_sample_data.sql
-- =============================================================================

USE eth_ecommerce;

-- Disable FK checks during bulk insert (re-enable after)
SET FOREIGN_KEY_CHECKS = 0;
SET UNIQUE_CHECKS = 0;

-- =============================================================================
-- 1. USER ROLES
-- =============================================================================
INSERT INTO user_roles (role_id, role_code, role_name) VALUES
(1, 'admin',    'Platform Administrator'),
(2, 'seller',   'Marketplace Seller'),
(3, 'customer', 'Customer'),
(4, 'support',  'Customer Support Agent'),
(5, 'analyst',  'Business Analyst');

-- =============================================================================
-- 2. REGIONS (Ethiopian Cities)
-- =============================================================================
INSERT INTO regions (region_id, region_code, region_name, parent_region_id, latitude, longitude) VALUES
(1,  'AA',  'Addis Ababa',  NULL,   9.0222,   38.7468),
(2,  'AD',  'Adama',        NULL,   8.5400,   39.2700),
(3,  'HW',  'Hawassa',      NULL,   7.0621,   38.4767),
(4,  'DD',  'Dire Dawa',    NULL,   9.5931,   41.8661),
(5,  'MK',  'Mekele',       NULL,   13.4967,  39.4770),
(6,  'BD',  'Bahir Dar',    NULL,   11.5742,  37.3614),
(7,  'JJ',  'Jimma',        NULL,   7.6667,   36.8333),
(8,  'GD',  'Gondar',       NULL,   12.6030,  37.4521),
-- Sub-cities of Addis Ababa
(9,  'AA-BOL', 'Bole',      1,      8.9806,   38.7578),
(10, 'AA-KIR', 'Kirkos',    1,      9.0100,   38.7500),
(11, 'AA-YEK', 'Yeka',      1,      9.0400,   38.8000),
(12, 'AA-AKA', 'Akaky Kaliti', 1,  8.9000,   38.8000);

-- =============================================================================
-- 3. CATEGORIES (Hierarchical)
-- =============================================================================
INSERT INTO categories (category_id, parent_id, category_name, slug, description, sort_order) VALUES
-- Root categories
(1,  NULL, 'Electronics',          'electronics',           'Consumer electronics and gadgets', 1),
(2,  NULL, 'Fashion',              'fashion',               'Clothing, shoes, and accessories', 2),
(3,  NULL, 'Home & Kitchen',       'home-kitchen',          'Home appliances and kitchenware',  3),
(4,  NULL, 'Food & Grocery',       'food-grocery',          'Fresh and packaged foods',          4),
(5,  NULL, 'Health & Beauty',      'health-beauty',         'Personal care and health products', 5),
(6,  NULL, 'Books & Stationery',   'books-stationery',      'Books, office and school supplies', 6),
(7,  NULL, 'Sports & Outdoors',    'sports-outdoors',       'Sports equipment and outdoor gear', 7),
(8,  NULL, 'Agriculture',          'agriculture',           'Farming tools and agricultural supplies', 8),

-- Electronics sub-categories
(10, 1,    'Smartphones',          'smartphones',           'Mobile phones and accessories', 1),
(11, 1,    'Laptops & Computers',  'laptops-computers',     'Laptops, desktops, and peripherals', 2),
(12, 1,    'TVs & Displays',       'tvs-displays',          'Televisions and monitors', 3),
(13, 1,    'Audio',                'audio',                 'Headphones, speakers, earphones', 4),
(14, 1,    'Power Solutions',      'power-solutions',       'Solar, inverters, batteries', 5),

-- Fashion sub-categories
(20, 2,    'Men\'s Clothing',      'mens-clothing',         'Men\'s apparel', 1),
(21, 2,    'Women\'s Clothing',    'womens-clothing',       'Women\'s apparel', 2),
(22, 2,    'Children\'s Clothing', 'childrens-clothing',    'Kids\' clothes', 3),
(23, 2,    'Traditional Wear',     'traditional-wear',      'Habesha kemis and traditional Ethiopian clothing', 4),
(24, 2,    'Shoes',                'shoes',                 'Footwear for all', 5),

-- Food sub-categories
(30, 4,    'Grains & Pulses',      'grains-pulses',         'Teff, barley, lentils, chickpeas', 1),
(31, 4,    'Coffee & Tea',         'coffee-tea',            'Ethiopian coffee and tea', 2),
(32, 4,    'Spices & Condiments',  'spices-condiments',     'Berbere, mitmita, shiro', 3);

-- =============================================================================
-- 4. PAYMENT METHOD TYPES
-- =============================================================================
INSERT INTO payment_method_types (method_id, method_code, method_name, is_digital) VALUES
(1, 'TELEBIRR',      'Telebirr Mobile Money',  1),
(2, 'CBE_BIRR',      'CBE Birr',               1),
(3, 'AMOLE',         'Amole Digital Wallet',   1),
(4, 'BANK_TRANSFER', 'Bank Transfer',           1),
(5, 'CASH_ON_DEL',   'Cash on Delivery',        0),
(6, 'VISA',          'Visa / Mastercard',       1);

-- =============================================================================
-- 5. ORDER STATUSES
-- =============================================================================
INSERT INTO order_statuses (status_id, status_code, status_name, is_terminal, sort_order) VALUES
(1,  'PENDING',    'Pending',              0, 1),
(2,  'CONFIRMED',  'Confirmed',            0, 2),
(3,  'PROCESSING', 'Processing',           0, 3),
(4,  'SHIPPED',    'Shipped',              0, 4),
(5,  'DELIVERED',  'Delivered',            1, 5),
(6,  'CANCELLED',  'Cancelled',            1, 6),
(7,  'RETURNED',   'Returned',             1, 7);

-- =============================================================================
-- 6. WAREHOUSES
-- =============================================================================
INSERT INTO warehouses (warehouse_id, region_id, warehouse_name, address, latitude, longitude) VALUES
(1, 1,  'Addis Main Fulfillment Center',  'Bole Road, Near Airport, Addis Ababa',           8.9774, 38.7989),
(2, 1,  'Addis North Hub',                'Merkato Area, Addis Ketema, Addis Ababa',          9.0360, 38.7342),
(3, 2,  'Adama Distribution Center',      'East Adama Industrial Zone, Adama',               8.5500, 39.2800),
(4, 3,  'Hawassa Fulfillment Hub',        'Sidama Region, Hawassa Industrial Park, Hawassa', 7.0500, 38.4900),
(5, 4,  'Dire Dawa Logistics Center',     'Dire Dawa Free Trade Zone, Dire Dawa',            9.6000, 41.8700),
(6, 5,  'Mekele North Hub',               'Tigray Region, Mekele Industrial Zone',           13.5000, 39.4800);

-- =============================================================================
-- 7. ATTRIBUTE TYPES & VALUES
-- =============================================================================
INSERT INTO attribute_types (attr_type_id, attr_name, attr_code, display_type) VALUES
(1, 'Color',    'color',    'SWATCH'),
(2, 'Size',     'size',     'DROPDOWN'),
(3, 'Material', 'material', 'DROPDOWN'),
(4, 'Storage',  'storage',  'DROPDOWN');

INSERT INTO attribute_values (attr_value_id, attr_type_id, value_label, value_code, hex_color, sort_order) VALUES
-- Colors
(1,  1, 'Black',  'black',  '#000000', 1),
(2,  1, 'White',  'white',  '#FFFFFF', 2),
(3,  1, 'Red',    'red',    '#FF0000', 3),
(4,  1, 'Blue',   'blue',   '#0000FF', 4),
(5,  1, 'Green',  'green',  '#008000', 5),
(6,  1, 'Gold',   'gold',   '#FFD700', 6),
-- Sizes
(10, 2, 'XS',     'xs',  NULL, 1),
(11, 2, 'S',      's',   NULL, 2),
(12, 2, 'M',      'm',   NULL, 3),
(13, 2, 'L',      'l',   NULL, 4),
(14, 2, 'XL',     'xl',  NULL, 5),
(15, 2, 'XXL',    'xxl', NULL, 6),
-- Storage (for phones/laptops)
(20, 4, '64GB',   '64gb',  NULL, 1),
(21, 4, '128GB',  '128gb', NULL, 2),
(22, 4, '256GB',  '256gb', NULL, 3),
(23, 4, '512GB',  '512gb', NULL, 4),
(24, 4, '1TB',    '1tb',   NULL, 5);

-- =============================================================================
-- 8. USERS
-- NOTE: Passwords are bcrypt hashes. Plain text below (for reference only):
--   admin@eth.com         → Admin@123!
--   customers             → Customer@123!
--   sellers               → Seller@123!
-- =============================================================================

-- Admin user
INSERT INTO users (user_id, role_id, email, phone_number, password_hash, first_name, last_name, region_id, account_status, is_email_verified, is_phone_verified) VALUES
(1, 1, 'admin@ethmarket.com',
 AES_ENCRYPT('+251911000000', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))),
 '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewdBERiPiqiB.1Na',
 'Abebe', 'Kebede', 1, 'ACTIVE', 1, 1);

-- Seller users
INSERT INTO users (user_id, role_id, email, phone_number, password_hash, first_name, last_name, region_id, account_status, is_email_verified, is_phone_verified) VALUES
(2, 2, 'seller1@techstore.com',
 AES_ENCRYPT('+251911100001', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))),
 '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewdBERiPiqiB.1Na',
 'Tigist', 'Haile', 1, 'ACTIVE', 1, 1),

(3, 2, 'seller2@fashionaddis.com',
 AES_ENCRYPT('+251911100002', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))),
 '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewdBERiPiqiB.1Na',
 'Biruk', 'Alemu', 2, 'ACTIVE', 1, 1),

(4, 2, 'seller3@coffeeethiopia.com',
 AES_ENCRYPT('+251911100003', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))),
 '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewdBERiPiqiB.1Na',
 'Hiwot', 'Tadesse', 3, 'ACTIVE', 1, 1);

-- Customer users
INSERT INTO users (user_id, role_id, email, phone_number, password_hash, first_name, last_name, region_id, account_status, is_email_verified, is_phone_verified) VALUES
(10, 3, 'customer1@gmail.com',
 AES_ENCRYPT('+251922200001', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))),
 '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewdBERiPiqiB.1Na',
 'Selam', 'Getachew', 1, 'ACTIVE', 1, 1),

(11, 3, 'customer2@yahoo.com',
 AES_ENCRYPT('+251922200002', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))),
 '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewdBERiPiqiB.1Na',
 'Dawit', 'Mengistu', 2, 'ACTIVE', 1, 1),

(12, 3, 'customer3@eth.et',
 AES_ENCRYPT('+251933300003', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))),
 '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewdBERiPiqiB.1Na',
 'Meron', 'Bekele', 3, 'ACTIVE', 1, 1),

(13, 3, 'customer4@eth.et',
 AES_ENCRYPT('+251944400004', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))),
 '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewdBERiPiqiB.1Na',
 'Yonas', 'Tesfaye', 4, 'ACTIVE', 1, 1),

(14, 3, 'customer5@eth.et',
 AES_ENCRYPT('+251955500005', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))),
 '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewdBERiPiqiB.1Na',
 'Rahel', 'Girma', 5, 'ACTIVE', 1, 1);

-- =============================================================================
-- 9. USER ADDRESSES
-- =============================================================================
INSERT INTO user_addresses (address_id, user_id, region_id, label, recipient, phone, street, sub_city, woreda, is_default) VALUES
(1, 10, 9,  'Home',   'Selam Getachew',  AES_ENCRYPT('+251922200001', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))), 'Bole Road, House #24',     'Bole',    '3',  1),
(2, 10, 10, 'Office', 'Selam Getachew',  AES_ENCRYPT('+251922200001', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))), 'Kirkos, Near Stadium',     'Kirkos',  '5',  0),
(3, 11, 2,  'Home',   'Dawit Mengistu',  AES_ENCRYPT('+251922200002', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))), 'Adama, Kebele 03, H# 12',  NULL,      NULL, 1),
(4, 12, 3,  'Home',   'Meron Bekele',    AES_ENCRYPT('+251933300003', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))), 'Hawassa, Kebele 05, H# 7', NULL,      NULL, 1),
(5, 13, 4,  'Home',   'Yonas Tesfaye',   AES_ENCRYPT('+251944400004', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))), 'Dire Dawa, Ganda H# 18',   NULL,      NULL, 1),
(6, 14, 5,  'Home',   'Rahel Girma',     AES_ENCRYPT('+251955500005', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))), 'Mekele, Ayder Sub-City',   'Ayder',   NULL, 1);

-- =============================================================================
-- 10. SELLER PROFILES
-- =============================================================================
INSERT INTO seller_profiles (seller_id, business_name, business_type, region_id, address, commission_rate, rating, total_reviews, verification_status, verified_at) VALUES
(2, 'EthTech Store',      'COMPANY',     1, 'Bole Sub-City, Addis Ababa',  0.08, 4.72, 1842, 'VERIFIED', '2025-01-15 09:00:00'),
(3, 'Fashion Addis',      'INDIVIDUAL',  2, 'Adama City, Main Market',     0.10, 4.45, 634,  'VERIFIED', '2025-03-20 11:00:00'),
(4, 'Yirgacheffe Coffee', 'COOPERATIVE', 3, 'Hawassa, Coffee Cooperative', 0.07, 4.90, 2311, 'VERIFIED', '2024-11-01 08:00:00');

-- =============================================================================
-- 11. PRODUCTS
-- =============================================================================
INSERT INTO products (product_id, seller_id, category_id, sku, product_name, slug, short_desc, description, brand, base_price, sale_price, currency, weight_grams, is_featured, is_active, rating, review_count) VALUES
-- Tech products
(1, 2, 10, 'ETH-SMPH-001', 'Samsung Galaxy A54 5G',
 'samsung-galaxy-a54-5g',
 'High-performance 5G smartphone with 50MP camera',
 'The Samsung Galaxy A54 5G features a 6.4" Super AMOLED display, triple camera system with 50MP main sensor, 5000mAh battery, and 5G connectivity. Perfect for Ethiopian consumers with reliable network coverage.',
 'Samsung', 18500.00, 16999.00, 'ETB', 202, 1, 1, 4.65, 523),

(2, 2, 11, 'ETH-LAPT-001', 'HP Pavilion 15 Laptop',
 'hp-pavilion-15-laptop',
 'Intel Core i5, 8GB RAM, 512GB SSD',
 'HP Pavilion 15 with 15.6" Full HD display, Intel Core i5-1235U, 8GB DDR4 RAM, 512GB NVMe SSD, Windows 11. Excellent for students, professionals, and businesses across Ethiopia.',
 'HP', 45000.00, 42000.00, 'ETB', 1780, 1, 1, 4.50, 287),

(3, 2, 14, 'ETH-SOLR-001', 'Felicity 200W Solar Panel Kit',
 'felicity-200w-solar-panel-kit',
 'Complete off-grid solar solution for homes',
 'Complete solar system kit: 200W monocrystalline panel, 100Ah AGM battery, 20A MPPT charge controller, 1000W inverter. Perfect for Ethiopian rural homes and businesses facing power challenges.',
 'Felicity', 32000.00, NULL, 'ETB', 15000, 1, 1, 4.80, 1021),

-- Fashion products
(4, 3, 23, 'ETH-HABT-001', 'Habesha Kemis — Traditional Ethiopian Dress',
 'habesha-kemis-traditional-dress',
 'Handwoven cotton Habesha kemis for women',
 'Authentic Ethiopian traditional dress handwoven from 100% cotton in Addis Ababa. Features traditional border patterns (tikil) in gold and silver thread. Available in multiple sizes. Perfect for festivals, weddings, and daily wear.',
 'Addis Weavers', 2800.00, 2400.00, 'ETB', 400, 1, 1, 4.88, 892),

(5, 3, 20, 'ETH-MENS-001', 'Ethiopian Traditional Shirt (Kemis for Men)',
 'ethiopian-traditional-shirt-mens',
 'Handcrafted Ethiopian men\'s traditional shirt',
 'Traditional Ethiopian men\'s shirt with collar embroidery. 100% cotton, machine washable. Available in white and cream.',
 'Addis Weavers', 1500.00, NULL, 'ETB', 300, 0, 1, 4.70, 341),

-- Coffee products
(6, 4, 31, 'ETH-COFF-001', 'Yirgacheffe Grade 1 — Washed Arabica Coffee (1kg)',
 'yirgacheffe-grade1-washed-arabica-1kg',
 'World-famous Ethiopian Yirgacheffe single-origin coffee',
 'Grade 1 Yirgacheffe washed Arabica coffee beans. Tasting notes: jasmine, bergamot, lemon, peach. 100% sun-dried and naturally processed at altitude 1700-2200m. Exported to 40+ countries. Fresh roasted weekly.',
 'Yirgacheffe Coffee', 750.00, 680.00, 'ETB', 1100, 1, 1, 4.95, 3210),

(7, 4, 32, 'ETH-SPIC-001', 'Ethiopian Berbere Spice Mix (500g)',
 'ethiopian-berbere-spice-mix-500g',
 'Authentic hand-ground Ethiopian berbere spice',
 'Traditional Ethiopian berbere — a complex blend of chili, garlic, ginger, coriander, fenugreek, and 12+ other spices. Stone-ground in Hawassa. Essential for Doro Wat, Tibs, and all Ethiopian cuisine.',
 'Hawassa Spices', 350.00, NULL, 'ETB', 550, 0, 1, 4.92, 1876);

-- =============================================================================
-- 12. PRODUCT VARIANTS
-- =============================================================================
INSERT INTO product_variants (variant_id, product_id, variant_sku, variant_name, price_delta, is_active) VALUES
-- Galaxy A54 variants (color + storage)
(1,  1, 'ETH-SMPH-001-BLK-128', 'Black / 128GB',  0.00,     1),
(2,  1, 'ETH-SMPH-001-WHT-128', 'White / 128GB',  0.00,     1),
(3,  1, 'ETH-SMPH-001-BLK-256', 'Black / 256GB',  2500.00,  1),

-- HP Laptop variants (RAM/storage)
(4,  2, 'ETH-LAPT-001-8-512',  'Core i5 / 8GB / 512GB',   0.00,     1),
(5,  2, 'ETH-LAPT-001-16-512', 'Core i5 / 16GB / 512GB',  4500.00,  1),
(6,  2, 'ETH-LAPT-001-16-1T',  'Core i5 / 16GB / 1TB',    9000.00,  1),

-- Solar panel (one variant)
(7,  3, 'ETH-SOLR-001-STD',    'Standard Kit',    0.00,     1),

-- Habesha Kemis variants (size + color)
(8,  4, 'ETH-HABT-001-S-WHT',  'S / White',       0.00,     1),
(9,  4, 'ETH-HABT-001-M-WHT',  'M / White',       0.00,     1),
(10, 4, 'ETH-HABT-001-L-WHT',  'L / White',       0.00,     1),
(11, 4, 'ETH-HABT-001-XL-WHT', 'XL / White',      100.00,   1),

-- Men's shirt variants
(12, 5, 'ETH-MENS-001-S',      'S',               0.00,     1),
(13, 5, 'ETH-MENS-001-M',      'M',               0.00,     1),
(14, 5, 'ETH-MENS-001-L',      'L',               0.00,     1),

-- Coffee (single variant)
(15, 6, 'ETH-COFF-001-1KG',    '1kg Bag',         0.00,     1),
(16, 6, 'ETH-COFF-001-5KG',    '5kg Bag',         3000.00,  1),

-- Berbere spice (single variant)
(17, 7, 'ETH-SPIC-001-500G',   '500g Pack',       0.00,     1),
(18, 7, 'ETH-SPIC-001-1KG',    '1kg Pack',        280.00,   1);

-- =============================================================================
-- 13. VARIANT ATTRIBUTES
-- =============================================================================
INSERT INTO variant_attributes (variant_id, attr_value_id) VALUES
-- Galaxy A54 Black 128GB
(1, 1), (1, 21),   -- Black, 128GB
-- Galaxy A54 White 128GB
(2, 2), (2, 21),   -- White, 128GB
-- Galaxy A54 Black 256GB
(3, 1), (3, 22),   -- Black, 256GB

-- Habesha Kemis sizes
(8,  11), (8,  2),  -- S, White
(9,  12), (9,  2),  -- M, White
(10, 13), (10, 2),  -- L, White
(11, 14), (11, 2),  -- XL, White

-- Mens shirt sizes
(12, 11),   -- S
(13, 12),   -- M
(14, 13);   -- L

-- =============================================================================
-- 14. INVENTORY
-- =============================================================================
INSERT INTO inventory (inventory_id, variant_id, warehouse_id, quantity_on_hand, reserved_quantity, reorder_point, reorder_quantity, last_restocked_at) VALUES
-- Galaxy A54 @ Addis Main
(1,  1,  1, 500, 0, 50, 200, '2026-03-01 08:00:00'),
(2,  2,  1, 350, 0, 30, 150, '2026-03-01 08:00:00'),
(3,  3,  1, 200, 0, 20, 100, '2026-03-01 08:00:00'),
-- Galaxy A54 @ Adama
(4,  1,  3, 150, 0, 20, 100, '2026-03-05 09:00:00'),

-- HP Laptop @ Addis Main
(5,  4,  1, 80,  0, 10, 50,  '2026-02-15 08:00:00'),
(6,  5,  1, 60,  0, 10, 40,  '2026-02-15 08:00:00'),
(7,  6,  1, 40,  0, 5,  30,  '2026-02-15 08:00:00'),

-- Solar Panel @ Addis Main
(8,  7,  1, 200, 0, 20, 100, '2026-01-20 08:00:00'),
-- Solar Panel @ Hawassa
(9,  7,  4, 80,  0, 10, 50,  '2026-02-01 09:00:00'),

-- Habesha Kemis @ Addis Main
(10, 8,  1, 300, 0, 30, 100, '2026-03-10 08:00:00'),
(11, 9,  1, 400, 0, 40, 150, '2026-03-10 08:00:00'),
(12, 10, 1, 350, 0, 35, 120, '2026-03-10 08:00:00'),
(13, 11, 1, 200, 0, 20, 80,  '2026-03-10 08:00:00'),

-- Men's shirts @ Addis North
(14, 12, 2, 200, 0, 25, 100, '2026-03-12 08:00:00'),
(15, 13, 2, 250, 0, 30, 100, '2026-03-12 08:00:00'),
(16, 14, 2, 180, 0, 20, 80,  '2026-03-12 08:00:00'),

-- Coffee @ Hawassa
(17, 15, 4, 2000, 0, 200, 1000, '2026-04-01 07:00:00'),
(18, 16, 4, 500,  0, 50,  200,  '2026-04-01 07:00:00'),

-- Berbere spice @ Hawassa
(19, 17, 4, 3000, 0, 300, 1500, '2026-04-01 07:00:00'),
(20, 18, 4, 1000, 0, 100, 500,  '2026-04-01 07:00:00');

-- =============================================================================
-- 15. COUPONS
-- =============================================================================
INSERT INTO coupons (coupon_id, coupon_code, description, discount_type, discount_value, min_order_amt, max_discount, usage_limit, per_user_limit, valid_from, valid_until, is_active, created_by) VALUES
(1, 'NEWUSER20',  '20% off for new customers',    'PERCENTAGE',   20.00, 500.00,  2000.00, 1000, 1, '2026-01-01', '2026-12-31', 1, 1),
(2, 'FASTHAWK',   'ETB 500 off on ETB 3000+',     'FIXED_AMOUNT', 500.00, 3000.00, NULL,   500,  2, '2026-03-01', '2026-06-30', 1, 1),
(3, 'FREESHIP',   'Free shipping any order',       'FREE_SHIPPING', 50.00, 0.00,   NULL,   NULL, 3, '2026-04-01', '2026-04-30', 1, 1),
(4, 'COFFEE10',   '10% off coffee orders',         'PERCENTAGE',   10.00, 300.00,  500.00, 2000, 5, '2026-01-01', '2026-12-31', 1, 4);

-- =============================================================================
-- 16. SAMPLE ORDERS (manually inserted to bypass trigger for seed purposes)
-- =============================================================================
SET FOREIGN_KEY_CHECKS = 0;  -- bypass triggers for seed data

INSERT INTO orders (order_id, order_number, customer_id, seller_id, shipping_address_id, billing_address_id, warehouse_id, region_id, status_id, subtotal, discount_amount, shipping_fee, tax_amount, total_amount, currency, payment_method_id, payment_status, placed_at, confirmed_at, shipped_at, delivered_at) VALUES
(1001, 'ETH-20260101-000001', 10, 2, 1, 1, 1, 9, 5, 16999.00, 0.00, 50.00, 2549.85, 19598.85, 'ETB', 1, 'SUCCESS', '2026-01-15 10:30:00', '2026-01-15 11:00:00', '2026-01-16 09:00:00', '2026-01-17 14:00:00'),
(1002, 'ETH-20260201-000001', 11, 4, 3, 3, 4, 2, 5, 2040.00,  408.00, 50.00, 255.30, 1937.30, 'ETB', 1, 'SUCCESS', '2026-02-10 09:15:00', '2026-02-10 10:00:00', '2026-02-11 08:00:00', '2026-02-12 15:00:00'),
(1003, 'ETH-20260301-000001', 12, 3, 4, 4, 1, 3, 2, 7200.00,  0.00,  50.00, 1080.00, 8330.00, 'ETB', 5, 'PENDING', '2026-03-22 14:00:00', '2026-03-22 14:30:00', NULL, NULL),
(1004, 'ETH-20260401-000001', 13, 2, 5, 5, 1, 4, 5, 42000.00, 0.00,  50.00, 6300.00, 48350.00, 'ETB', 4, 'SUCCESS', '2026-04-01 08:00:00', '2026-04-01 09:00:00', '2026-04-02 07:00:00', '2026-04-03 16:00:00'),
(1005, 'ETH-20260407-000001', 14, 4, 6, 6, 4, 5, 1, 3400.00,  340.00, 50.00, 459.00, 3569.00, 'ETB', 1, 'PENDING', '2026-04-07 08:30:00', NULL, NULL, NULL);

INSERT INTO order_items (item_id, order_id, product_id, variant_id, warehouse_id, quantity, unit_price, discount_pct, line_total, status) VALUES
(1, 1001, 1, 1, 1, 1, 16999.00, 0.00, 16999.00, 'ACTIVE'),
(2, 1002, 6, 15, 4, 3, 680.00, 0.00, 2040.00, 'ACTIVE'),
(3, 1003, 4, 9, 1, 3, 2400.00, 0.00, 7200.00, 'ACTIVE'),
(4, 1004, 2, 4, 1, 1, 42000.00, 0.00, 42000.00, 'ACTIVE'),
(5, 1005, 6, 15, 4, 2, 680.00, 0.00, 1360.00, 'ACTIVE'),
(6, 1005, 7, 17, 4, 6, 350.00, 0.00, 2100.00, 'ACTIVE');

-- =============================================================================
-- 17. SAMPLE PAYMENTS
-- =============================================================================
INSERT INTO payments (payment_id, order_id, customer_id, method_id, idempotency_key, amount, currency, status, gateway_reference, paid_at) VALUES
(1, 1001, 10, 1, 'idem-1001-aa-20260115', 19598.85, 'ETB', 'SUCCESS', 'TBR-2026011500001', '2026-01-15 10:35:00'),
(2, 1002, 11, 1, 'idem-1002-ad-20260210', 1937.30,  'ETB', 'SUCCESS', 'TBR-2026021000001', '2026-02-10 09:20:00'),
(3, 1003, 12, 5, 'idem-1003-hw-20260322', 8330.00,  'ETB', 'PENDING', NULL,                NULL),
(4, 1004, 13, 4, 'idem-1004-dd-20260401', 48350.00, 'ETB', 'SUCCESS', 'CBE-BANK-20260401-0001', '2026-04-01 08:10:00'),
(5, 1005, 14, 1, 'idem-1005-mk-20260407', 3569.00,  'ETB', 'PENDING', NULL, NULL);

-- =============================================================================
-- 18. SAMPLE AUDIT LOGS
-- =============================================================================
INSERT INTO audit_logs (user_id, action, entity_type, entity_id, new_values, status, message) VALUES
(10, 'ORDER_CREATED',      'orders',   1001, JSON_OBJECT('order_number', 'ETH-20260115-000001', 'total', 19598.85), 'SUCCESS', 'Order placed via mobile app'),
(10, 'PAYMENT_PROCESSED',  'payments', 1,    JSON_OBJECT('gateway_ref', 'TBR-2026011500001', 'status', 'SUCCESS'),  'SUCCESS', 'Telebirr payment confirmed'),
(11, 'ORDER_CREATED',      'orders',   1002, JSON_OBJECT('order_number', 'ETH-20260201-000001', 'total', 1937.30),  'SUCCESS', 'Order placed via web'),
(1,  'USER_SUSPENDED',     'users',    99,   JSON_OBJECT('reason', 'Suspicious activity'),                          'SUCCESS', 'Admin action: account suspended');

-- =============================================================================
-- 19. SAMPLE LOGIN ATTEMPTS
-- =============================================================================
INSERT INTO login_attempts (user_id, email, ip_address, user_agent, status, attempted_at) VALUES
(10, 'customer1@gmail.com', AES_ENCRYPT('196.188.45.12', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))), 'Mozilla/5.0 (Android 13)', 'SUCCESS', '2026-04-07 07:45:00'),
(10, 'customer1@gmail.com', AES_ENCRYPT('196.188.45.12', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))), 'Mozilla/5.0 (Android 13)', 'SUCCESS', '2026-04-06 18:20:00'),
(NULL, 'unknown@hacker.com', AES_ENCRYPT('5.34.22.11', UNHEX(SHA2('ETH_MASTER_KEY_PLACEHOLDER', 256))),  'Python-requests/2.31', 'FAILED', '2026-04-06 03:15:00');

-- =============================================================================
-- 20. DAILY SALES SUMMARY (pre-populated example)
-- =============================================================================
INSERT INTO daily_sales_summary (summary_date, region_id, seller_id, total_orders, total_revenue, total_items_sold, total_refunds, avg_order_value) VALUES
('2026-01-15', 9, 2, 1, 19598.85, 1, 0.00, 19598.85),
('2026-02-10', 2, 4, 1, 1937.30,  3, 0.00, 1937.30),
('2026-04-01', 4, 2, 1, 48350.00, 1, 0.00, 48350.00);

SET FOREIGN_KEY_CHECKS = 1;
SET UNIQUE_CHECKS = 1;

-- =============================================================================
-- END OF SAMPLE DATA
-- =============================================================================
