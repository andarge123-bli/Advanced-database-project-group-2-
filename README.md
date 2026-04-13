<div align="center">

# 🛒 Ethiopian E-Commerce Platform
### Advanced Database Systems — Group 2 Project

<p align="center">
  <img src="https://img.shields.io/badge/Database-Mysql_8+-336791?style=for-the-badge&logo=mysql&logoColor=white"/>
  
  <img src="https://img.shields.io/badge/Normalization-3NF%20%2F%20BCNF-1a7a6e?style=for-the-badge"/>
  <img src="https://img.shields.io/badge/Tables-32%20Entities-1a4a7a?style=for-the-badge"/>
  <img src="https://img.shields.io/badge/Architecture-Distributed-c8860a?style=for-the-badge"/>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Course-Advanced%20Database%20Systems-0d2137?style=for-the-badge"/>
  <img src="https://img.shields.io/badge/Year-2nd%20Year%20Software%20Engineering-145214?style=for-the-badge"/>
  <img src="https://img.shields.io/badge/Group-2-7a1a1a?style=for-the-badge"/>
</p>

<br/>

> **A fully-normalized, enterprise-grade distributed relational database designed for a multi-city Ethiopian e-commerce marketplace — covering Addis Ababa, Adama, and Hawassa.**

</div>

---

## 📋 Table of Contents

- [Project Overview](#-project-overview)
- [Database Architecture](#-database-architecture)
- [Schema Subsystems](#-schema-subsystems)
  - [Lookup & Reference Tables](#1--lookup--reference-tables)
  - [User & Identity](#2--user--identity)
  - [Product Catalog](#3--product-catalog)
  - [Inventory Management](#4--inventory-management)
  - [Orders](#5--orders)
  - [Payments & Refunds](#6--payments--refunds)
  - [Security & Audit](#7--security--audit)
  - [Analytics](#8--analytics)
  - [Social & Promotions](#9--social--promotions)
- [ER Diagram](#-er-diagram)
- [Normalization](#-normalization)
- [Security Implementation](#-security-implementation)
- [Distributed Design](#-distributed-design)
- [Query Optimization](#-query-optimization)
- [Project Deliverables](#-project-deliverables)
- [Setup & Installation](#-setup--installation)
- [Team — Group 2](#-team--group-2)

---

## 🌍 Project Overview

This project implements a **production-quality relational database** for an Ethiopian multi-vendor e-commerce platform. The platform serves sellers and buyers across three major Ethiopian cities and is designed to handle real-world challenges including encrypted PII storage, distributed horizontal sharding, row-level security, fraud detection, and full audit trails.

| Property | Value |
|---|---|
| **Platform Name** | Ethiopia E-Commerce (`eth_ecommerce`) |
| **Database Engine** | PostgreSQL 15+ / MySQL 8+ compatible |
| **Total Tables** | 32 entities |
| **Normalization Form** | 3NF & BCNF throughout |
| **Covered Cities** | Addis Ababa · Adama · Hawassa |
| **Supported Currencies** | ETB (Ethiopian Birr) |
| **Payment Methods** | Telebirr, CBE Birr, Bank Transfer, Cash on Delivery |
| **Architecture** | Horizontally sharded distributed database |
| **Encryption** | AES-256-GCM for PII · bcrypt (cost ≥ 12) for passwords |

---

## 🏗 Database Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                  eth_ecommerce  (Logical Schema)                  │
│                                                                   │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────────┐  │
│  │  Reference  │  │   Identity   │  │    Product Catalog     │  │
│  │  5 tables   │  │   3 tables   │  │       6 tables         │  │
│  └─────────────┘  └──────────────┘  └────────────────────────┘  │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────────┐  │
│  │  Inventory  │  │    Orders    │  │  Payments & Refunds    │  │
│  │  3 tables   │  │   2 tables   │  │       2 tables         │  │
│  └─────────────┘  └──────────────┘  └────────────────────────┘  │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────────┐  │
│  │  Security   │  │  Analytics   │  │  Social & Promo        │  │
│  │  4 tables   │  │   3 tables   │  │       3 tables         │  │
│  └─────────────┘  └──────────────┘  └────────────────────────┘  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │              Distributed Routing — 1 table                  │  │
│  │   Shard 1: Addis Ababa │ Shard 2: Adama │ Shard 3: Hawassa│  │
│  └────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 📦 Schema Subsystems

### 1 · Lookup & Reference Tables
> Small, stable tables that anchor the rest of the schema.

| Table | PK Type | Purpose |
|---|---|---|
| `user_roles` | `TINYINT` | Customer, Seller, Admin role definitions |
| `order_statuses` | `TINYINT` | Lifecycle states: PENDING → DELIVERED → CANCELLED |
| `payment_method_types` | `TINYINT` | Telebirr, CBEBirr, Bank Transfer, COD |
| `regions` | `SMALLINT` | Self-referential hierarchy: Country → City → Sub-City → Woreda |
| `categories` | `INT` | Self-referential product category tree |

---

### 2 · User & Identity

| Table | Key Columns | Notes |
|---|---|---|
| `users` | `user_id PK`, `role_id FK`, `region_id FK` | Central entity; phone stored AES-256 encrypted |
| `user_addresses` | `address_id PK`, `user_id FK`, `region_id FK` | Shipping & billing addresses with GPS coords |
| `seller_profiles` | `seller_id PK` (= `user_id`) | 1:1 extension of users; bank/Telebirr accounts encrypted |

**Key design decisions:**
- `seller_profiles.seller_id` shares the same value as `users.user_id` (1:1 identity relationship)
- `phone_number` stored as `VARBINARY(512)` with AES-256-GCM encryption
- `display_name` is a **generated stored column** (first_name + last_name)
- Account lockout implemented via `failed_login_cnt` + `lockout_until`

---

### 3 · Product Catalog

| Table | Purpose |
|---|---|
| `products` | Master product listing with pricing, SEO slug, full-text search index |
| `product_variants` | SKU-level variants (size, color, etc.) with price delta |
| `product_images` | Multiple images per product or variant with sort order |
| `attribute_types` | Dimension definitions: Size, Color, Material, etc. |
| `attribute_values` | Concrete values: Red (#FF0000), XL, Cotton |
| `variant_attributes` | **Junction table** (M:N) linking variants to their attribute values |

```
products ──1:N──► product_variants ──M:N──► attribute_values
                                   (via variant_attributes)
                                         │
                              attribute_types ──1:N──► attribute_values
```

---

### 4 · Inventory Management

| Table | Purpose |
|---|---|
| `warehouses` | Physical warehouse locations per region |
| `inventory` | Stock levels per variant per warehouse (UNIQUE on variant+warehouse) |
| `inventory_transactions` | **Append-only** immutable ledger of all stock movements |

**CHECK constraint:** `quantity_on_hand ≥ reserved_quantity` (available stock is always ≥ 0)

**Transaction types:** `RESTOCK · SALE · RESERVATION · RELEASE · CANCELLATION · ADJUSTMENT · RETURN · TRANSFER`

---

### 5 · Orders

| Table | Key FKs | Notes |
|---|---|---|
| `orders` | `customer_id`, `seller_id`, `status_id`, `warehouse_id`, `shipping_address_id` | Full lifecycle timestamps; soft-delete archive |
| `order_items` | `order_id`, `product_id`, `variant_id`, `warehouse_id` | `unit_price` is a snapshot (never changes after order) |

**Indexes on `orders`:**
```sql
idx_ord_customer_date  (customer_id, placed_at)
idx_ord_seller_date    (seller_id,   placed_at)
idx_ord_status         (status_id,   placed_at)
```

---

### 6 · Payments & Refunds

| Table | Key Design |
|---|---|
| `payments` | `idempotency_key` (UNIQUE) prevents duplicate charges; `ip_address` encrypted; fraud flag |
| `refunds` | Full audit chain: `payment_id → order_id → requested_by → approved_by` |

**Payment statuses:** `PENDING · PROCESSING · SUCCESS · FAILED · CANCELLED · REFUNDED · PARTIALLY_REFUNDED`

---

### 7 · Security & Audit

| Table | Append-Only | Purpose |
|---|---|---|
| `login_attempts` | ✅ Yes | Rate limiting & lockout detection |
| `audit_logs` | ✅ Yes | Immutable record of every state change |
| `fraud_logs` | ✅ Yes | Risk scoring (0–100), fraud type classification, action taken |
| `user_sessions` | No | Active session tracking with device & IP |

---

### 8 · Analytics

| Table | Composite PK | Populated By |
|---|---|---|
| `daily_sales_summary` | `(summary_date, region_id, seller_id)` | MySQL/PostgreSQL scheduled event |
| `product_sales_stats` | `(product_id, period_date)` | Scheduled event |
| `customer_ltv` | `customer_id` | Scheduled event |

**Customer LTV Segments:** `NEW · ACTIVE · VIP · AT_RISK · CHURNED`

---

### 9 · Social & Promotions

| Table | Notable Constraint |
|---|---|
| `product_reviews` | UNIQUE `(order_id, product_id)` — one review per verified purchase |
| `coupons` | Supports `PERCENTAGE`, `FIXED_AMOUNT`, `FREE_SHIPPING`; usage rate-limited |
| `notifications` | Multi-channel: `EMAIL · SMS · PUSH · IN_APP` |

---

## 📊 ER Diagram

The full Entity-Relationship diagram is included as a **multi-page professional PDF** in this repository.

```
ER_Diagram_Ethiopian_Ecommerce.pdf
├── Page 1 — Cover & Architecture Overview
├── Page 2 — Lookup, Reference, User & Identity
├── Page 3 — Product Catalog Subsystem
├── Page 4 — Inventory Subsystem
├── Page 5 — Orders Subsystem
├── Page 6 — Payments Subsystem
├── Page 7 — Security & Audit Subsystem
└── Page 8 — Analytics, Social & Distributed Routing
```

**32-table relationship summary:**

```
user_roles      ──1:N──► users ──1:1──► seller_profiles
regions         ──1:N──► users, user_addresses, seller_profiles, warehouses, orders
categories      ──1:N──► products (self-referential hierarchy)
users(seller)   ──1:N──► products ──1:N──► product_variants ──M:N──► attribute_values
product_variants──1:N──► inventory ──1:N──► inventory_transactions
users(customer) ──1:N──► orders    ──1:N──► order_items
orders          ──1:N──► payments  ──1:N──► refunds
users           ──1:N──► login_attempts, user_sessions, audit_logs, fraud_logs
products        ──1:N──► product_reviews (verified by orders)
```

---

## ✅ Normalization

The schema strictly adheres to **Third Normal Form (3NF)** and **Boyce-Codd Normal Form (BCNF)**:

| Rule | How it's enforced |
|---|---|
| **1NF** | All columns are atomic; no repeating groups; JSON columns used only for unstructured metadata |
| **2NF** | Every non-key attribute depends on the whole primary key; composite PKs in junction/analytics tables have no partial dependencies |
| **3NF** | No transitive dependencies; `display_name` is a generated column, not a stored redundancy |
| **BCNF** | Every determinant is a candidate key; `variant_attributes` junction resolves the M:N between variants and attribute values |
| **Soft Deletes** | `deleted_at` columns preserve referential history without cascading hard deletes |

---

## 🔐 Security Implementation

### Encryption
```
PII fields (phone_number, ip_address, bank_account_num, telebirr_account)
  └─ Storage:  VARBINARY columns
  └─ Cipher:   AES-256-GCM with per-record IV
  └─ Keys:     Managed externally via KMS (never stored in DB)

Password fields
  └─ Algorithm: bcrypt with cost factor ≥ 12
  └─ Format:    $2b$ prefix enforced
```

### Role-Based Access Control (RBAC)
```sql
-- Roles: admin, seller, customer, readonly_analyst, system_service
-- Principle of least privilege applied to every DB user
```

### Row-Level Security (RLS)
- Customers see only their own orders and addresses
- Sellers see only their own products and order fulfillments
- Analysts have read-only access to aggregated views

### Fraud & Abuse Prevention
- `login_attempts` enables IP-rate-limiting and account lockout
- `fraud_logs` with `risk_score` (0–100) and automated actions: `FLAGGED · BLOCKED · SUSPENDED · ESCALATED`
- `payments.idempotency_key` prevents duplicate charge race conditions
- `payments.is_flagged` integrates with fraud detection pipeline

---

## 🌐 Distributed Design

The platform uses **horizontal fragmentation** (sharding) by geographic region:

```
┌─────────────────┬──────────────────┬───────────────────────────┐
│  Shard          │  Region          │  Strategy                  │
├─────────────────┼──────────────────┼───────────────────────────┤
│  Shard 1        │  Addis Ababa     │  Primary hub, largest shard│
│  Shard 2        │  Adama           │  Regional replica          │
│  Shard 3        │  Hawassa         │  Regional replica          │
└─────────────────┴──────────────────┴───────────────────────────┘
```

**`shard_map` table** stores:
- `dsn_primary` / `dsn_replica` — connection strings per shard
- `region_ids` (JSON) — mapping of regions to shards
- `min_user_id` / `max_user_id` — range-based user routing

**Replication:** Each shard runs Primary → Replica streaming replication for read scaling and failover.

**Lookup tables** (`user_roles`, `order_statuses`, `payment_method_types`, `regions`, `categories`) are **replicated to all shards** for local joins.

---

## ⚡ Query Optimization

### Indexes Applied
```sql
-- Covering index for category browsing
idx_prod_cat_price (category_id, base_price, is_active, deleted_at)

-- Temporal range scans on orders
idx_ord_customer_date (customer_id, placed_at)
idx_ord_seller_date   (seller_id,   placed_at)
idx_ord_status        (status_id,   placed_at)

-- Full-Text Search
ft_product_search     (product_name, short_desc, brand)
ft_category_name      (category_name, description)
ft_review_body        (title, body)
```

### Concurrency Patterns
- `SELECT ... FOR UPDATE SKIP LOCKED` for queue-style order processing
- Optimistic locking via `updated_at` timestamps for inventory updates
- `inventory_transactions` is append-only — eliminates UPDATE contention on stock
- `SERIALIZABLE` isolation for payment capture to prevent double-charge

---

## 📁 Project Deliverables

| File | Description |
|---|---|
| `ER_Diagram_Ethiopian_Ecommerce.pdf` | 8-page professional ER diagram PDF |
| `SQL_Scripts_DDL_DML_Queries.sql` | Complete DDL (CREATE), DML (INSERT), indexes, triggers, RBAC, RLS |
| `Query_Optimization_Concurrency_Report.docx` | Index strategy & concurrency analysis |
| `Security_Implementation_Report.docx` | Encryption, RBAC, RLS, fraud detection design |
| `Distributed_Database_Design_Report.docx` | Sharding strategy, replication, CAP theorem analysis |
| `Group2_Presentation.pptx` | Final project presentation slides |

---

## 🚀 Setup & Installation

### Prerequisites
- PostgreSQL 15+ (or MySQL 8+)
- psql CLI or pgAdmin

### Database Setup
```bash
# 1. Create the database
createdb eth_ecommerce

# 2. Run the full schema + seed script
psql -U postgres -d eth_ecommerce -f SQL_Scripts_DDL_DML_Queries.sql

# 3. Verify tables were created
psql -U postgres -d eth_ecommerce -c "\dt"
```

### Verify the Schema
```sql
-- Check table count
SELECT COUNT(*) FROM information_schema.tables
WHERE table_schema = 'public';
-- Expected: 32

-- Confirm all foreign key constraints
SELECT tc.table_name, tc.constraint_name, kcu.column_name,
       ccu.table_name AS foreign_table
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.constraint_column_usage ccu
  ON ccu.constraint_name = tc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
ORDER BY tc.table_name;
```

---

## 👨‍💻 Team — Group 2

<div align="center">

| # | Role |
|---|---|
| 1 | Database Architect |
| 2 | Schema Designer |
| 3 | Security Implementation |
| 4 | Query Optimization |
| 5 | Distributed Design |
| 6 | Documentation & Presentation |

**Second Year Software Engineering Students**
**Advanced Database Systems Course — 2025/2026**

</div>

---

## 📚 Academic Context

This project was developed as part of the **Advanced Database Systems** course curriculum. It demonstrates practical application of:

- Relational database theory (3NF / BCNF normalization)
- Entity-Relationship modeling
- SQL DDL/DML and complex query writing
- Database security (encryption, RBAC, RLS)
- Query optimization and indexing strategies
- Distributed database architecture and sharding
- Concurrency control and transaction isolation

---

<div align="center">

**Ethiopian E-Commerce Platform · Advanced Database Systems · Group 2**

*Second Year Software Engineering — 2025/2026*

</div>
