-- ################################################################################
-- #                                                                              #
-- #    DISTRIBUTED DATABASE DESIGN REPORT  — ADVANCED EDITION                   #
-- #    Ethiopia E-Commerce Platform  (eth_ecommerce)                             #
-- #                                                                              #
-- #    Author   : Principal Database Architect                                   #
-- #    Version  : 2.0  (Advanced)                                                #
-- #    Date     : 2026-04-07                                                     #
-- #    DBMS     : MySQL 8.0.36+  (InnoDB, GTID, XA)                             #
-- #    Scale    : 1 M → 50 M users, 8 Ethiopian cities, 4 shards                #
-- #                                                                              #
-- #    This report covers every layer of a production distributed database:      #
-- #    theory, mathematics, implementation, operations, and failure modes.       #
-- #                                                                              #
-- ################################################################################

-- ================================================================================
-- TABLE OF CONTENTS
-- ================================================================================
--  1.  Executive Summary & Key Metrics
--  2.  System Architecture & Physical Topology
--  3.  Fragmentation Design
--        3.1  Horizontal Fragmentation — Range by Region
--        3.2  Consistent Hashing (Shard Rebalancing)
--        3.3  Vertical Fragmentation
--        3.4  Hybrid Fragmentation
--  4.  Distributed ID Generation (Snowflake IDs)
--  5.  Allocation Strategy
--  6.  Replication Architecture
--        6.1  GTID Topology & ROW-based Replication
--        6.2  Semi-Synchronous Replication
--        6.3  Multi-Source Analytics Replica
--        6.4  Replica Lag & Catch-up Strategy
--  7.  Distributed Transaction Management
--        7.1  Two-Phase Commit (XA)
--        7.2  Saga Pattern & Transactional Outbox
--        7.3  Cross-Shard Foreign Key Enforcement
--  8.  MVCC & InnoDB Concurrency Internals
--  9.  CAP / PACELC Analysis & Consistency Models
--        9.1  Vector Clocks & Causality Tracking
--        9.2  Read-Your-Writes, Monotonic Reads
-- 10.  Concurrency Control & Hotspot Mitigation
--        10.1  Consistent Locking Order
--        10.2  Thundering Herd & Redis Shield
--        10.3  Hotspot Detection & Data Skew
-- 11.  Query Processing & Global Secondary Indexes
--        11.1  Distributed Query Optimizer
--        11.2  Global Secondary Indexes (GSI)
--        11.3  Scatter-Gather & Parallel Execution
-- 12.  Live Schema Migration in Distributed Systems
--        12.1  gh-ost Zero-Downtime Migration
--        12.2  Expand / Contract Pattern
-- 13.  Failure Detection, Recovery & HA
--        13.1  Orchestrator + Raft Consensus
--        13.2  WAL Crash Recovery & InnoDB Internals
--        13.3  Point-in-Time Recovery
--        13.4  Read Repair & Anti-Entropy
-- 14.  Security Architecture
-- 15.  Observability — Metrics, Alerts & SLOs
--        15.1  Prometheus Metrics & Alert Rules
--        15.2  SLO / SLA Definitions
-- 16.  Capacity Planning & Storage Projections
-- 17.  Normalization & Integrity Constraint Proofs
-- 18.  Conclusion, Risk Register & Roadmap
-- ================================================================================

USE eth_ecommerce;

-- ################################################################################
-- SECTION 1: EXECUTIVE SUMMARY & KEY METRICS
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. EXECUTIVE SUMMARY & KEY METRICS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

This report provides a complete, production-grade analysis of the distributed
database design for the Ethiopia E-Commerce Platform. It is written for senior
database architects, site reliability engineers, and technical reviewers who
need deep implementation detail — not surface-level descriptions.

Platform Scope:
  Cities:    Addis Ababa (sub-cities: Bole, Kirkos, Yeka, Nifas Silk, Arada,
             Lideta, Akaki Kality), Adama, Hawassa, Dire Dawa, Mekele,
             Bahir Dar, Jimma, Gondar
  Currency:  Ethiopian Birr (ETB), 15% VAT
  Payments:  Telebirr, CBE Birr, Amole, Bank Transfer, Cash on Delivery, Visa
  Languages: Amharic (primary), English (secondary)

Key System Targets:
  ┌──────────────────────────────────┬──────────────────────────────────────────┐
  │ Metric                           │ Target                                   │
  ├──────────────────────────────────┼──────────────────────────────────────────┤
  │ Availability (SLA)               │ 99.95% (~4.4 hrs downtime/year)          │
  │ Read latency P99 (catalog)       │ < 20 ms (from replica)                   │
  │ Write latency P99 (place order)  │ < 200 ms (including payment lock)        │
  │ Throughput (normal)              │ 12,000 QPS reads / 1,500 TPS writes      │
  │ Throughput (Enkutatash peak)     │ 85,000 QPS reads / 8,000 TPS writes      │
  │ RTO (Primary failure)            │ < 30 seconds (Orchestrator auto-failover)│
  │ RPO (data loss window)           │ < 5 seconds (semi-sync replication)      │
  │ Shards at launch                 │ 4                                        │
  │ Shards at 50M users (5yr target) │ 16                                       │
  │ Replication lag budget           │ < 500 ms (normal), < 5 s (degraded)      │
  └──────────────────────────────────┴──────────────────────────────────────────┘

Critical Design Decisions (with justification):
  ┌──────────────────────────────────┬──────────────────────────────────────────┐
  │ Decision                         │ Why                                      │
  ├──────────────────────────────────┼──────────────────────────────────────────┤
  │ MySQL 8 InnoDB (not Cassandra)   │ Strict ACID needed for Telebirr payments │
  │ Consistent hashing (not MOD)     │ MOD-N resharding moves 75% of data;      │
  │                                  │ consistent hashing moves only 1/N        │
  │ Snowflake IDs (not AUTO_INC)     │ AUTO_INCREMENT cannot be globally unique  │
  │                                  │ across shards without central coordinator │
  │ ROW-format binlog (not STMT)     │ Deterministic across replicas;           │
  │                                  │ STATEMENT fails with non-det. functions  │
  │ Saga (not 2PC) for orders        │ 2PC has O(n) lock time across nodes;     │
  │                                  │ Saga commits locally, compensates async  │
  │ gh-ost for DDL (not ALTER TABLE) │ ALTER TABLE locks the table for minutes; │
  │                                  │ gh-ost uses shadow table + binlog replay │
  └──────────────────────────────────┴──────────────────────────────────────────┘
*/


-- ################################################################################
-- SECTION 2: SYSTEM ARCHITECTURE & PHYSICAL TOPOLOGY
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
2. SYSTEM ARCHITECTURE & PHYSICAL TOPOLOGY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

2.1 Full Stack Topology
────────────────────────

  [Internet / Mobile Clients]
          │  HTTPS/TLS 1.3
          ▼
  ┌──────────────────────────────────────────────────────────────────────┐
  │   CloudFlare CDN + WAF  (DDoS, Bot protection, SSL termination)      │
  └──────────────────────┬───────────────────────────────────────────────┘
                         │
  ┌──────────────────────▼───────────────────────────────────────────────┐
  │   HAProxy / NGINX Load Balancer  (Layer 7, sticky sessions by city)  │
  └──────┬─────────────────────────────────────────────────────┬─────────┘
         │                                                     │
  ┌──────▼──────────────────┐                    ┌────────────▼───────────────┐
  │  API Server Cluster      │                    │  Admin / Analytics Cluster  │
  │  (200 pods, Node.js)     │                    │  (Internal only)           │
  │  Rate: 1,000 req/s each  │                    └────────────┬───────────────┘
  └──────┬──────────────────┘                                 │
         │                                                    │
  ┌──────▼──────────────────────────────────────────────────▼─────────┐
  │                     Redis Cluster (6 nodes)                         │
  │   - Session store (TTL 86400s)                                      │
  │   - Inventory atomic counters (DECRBY for flash sales)              │
  │   - Idempotency key cache (TTL 86400s)                              │
  │   - Rate limiting (sliding window counter per user_id)              │
  │   - Distributed lock (Redlock algorithm, 5 nodes, TTL 5000ms)       │
  └──────┬──────────────────────────────────────────────────────────────┘
         │
  ┌──────▼──────────────────────────────────────────────────────────────┐
  │              ProxySQL Cluster (3 nodes, Keepalived VIP)             │
  │   - Read/Write splitting (regex-based routing rules)                │
  │   - Connection pooling (1000 frontend → 200 MySQL backend)          │
  │   - Query mirroring (shadow 5% traffic to analytics replica)        │
  │   - Health checks every 1 second; node eviction after 3 failures    │
  │   - Failover: re-routes to new Primary within 500ms after ORC event │
  └──────┬────────────────────────────┬────────────────────────┬────────┘
         │                            │                        │
  ┌──────▼──────┐             ┌───────▼───────┐      ┌────────▼──────────┐
  │  AA_SHARD   │             │ CENTRAL_SHARD │      │ EAST / NW SHARDS  │
  │  PRIMARY    │             │ PRIMARY       │      │ PRIMARY nodes      │
  │  (Bole DC)  │             │ (Adama DC)    │      │ (Dire Dawa / BDar) │
  │  + 2 replicas│            │ + 2 replicas  │      │ + 2 replicas each  │
  └─────────────┘             └───────────────┘      └────────────────────┘
         │                            │                        │
  ┌──────▼────────────────────────────▼────────────────────────▼────────┐
  │           ANALYTICS REPLICA  (Multi-source, read-only)              │
  │           Feeds: ClickHouse (OLAP), Grafana, Metabase               │
  └─────────────────────────────────────────────────────────────────────┘
  ┌──────────────────────────────────────────────────────────────────────┐
  │     DELAYED REPLICA  (6-hour lag, Addis DC, never serves traffic)   │
  └──────────────────────────────────────────────────────────────────────┘
  ┌──────────────────────────────────────────────────────────────────────┐
  │  Orchestrator Cluster (3 nodes, Raft consensus — HA topology manager)│
  └──────────────────────────────────────────────────────────────────────┘

2.2 Network Latency Budget
───────────────────────────
  Addis Ababa (intra-DC fiber):    0.1 ms RTT
  Addis → Adama (200km fiber):     3 ms RTT
  Addis → Hawassa (270km fiber):   5 ms RTT
  Addis → Dire Dawa (520km fiber): 8 ms RTT
  Addis → Mekele (780km fiber):    12 ms RTT

  Impact: A cross-shard transaction touching Addis + Mekele adds
  min 12 ms round-trip latency PER network hop. Saga pattern reduces
  inter-node synchronous hops to zero (all steps are local commits).
*/


-- ################################################################################
-- SECTION 3: FRAGMENTATION DESIGN
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
3. FRAGMENTATION DESIGN
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

3.1 Horizontal Fragmentation — Range by Region
────────────────────────────────────────────────
Formal definition (Relational Algebra):
  A horizontal fragment Fᵢ of relation R is defined by:
    Fᵢ = σ(Pᵢ)(R)   where Pᵢ is the predicate for shard i

  Predicates (mutually exclusive, collectively exhaustive):
    P₁ (AA_SHARD)  : region_id ∈ {1,9,10,11,12}   [Addis Ababa + sub-cities]
    P₂ (CENTRAL)   : region_id ∈ {2,3}             [Adama, Hawassa]
    P₃ (EAST)      : region_id ∈ {4,5}             [Dire Dawa, Mekele]
    P₄ (NW)        : region_id ∈ {6,7,8}           [Bahir Dar, Jimma, Gondar]

  Completeness proof:
    {1,9,10,11,12} ∪ {2,3} ∪ {4,5} ∪ {6,7,8} = {1,2,3,4,5,6,7,8,9,10,11,12} ✓
    Pᵢ ∩ Pⱼ = ∅  for all i ≠ j  (disjoint partitions) ✓

  Reconstruction: R = F₁ ∪ F₂ ∪ F₃ ∪ F₄  (UNION ALL across shards) ✓

  Tables fragmented by region_id:
    orders, order_items, payments, refunds, user_addresses,
    inventory (via warehouse→region), audit_logs, fraud_logs,
    user_sessions, notifications, seller_profiles (SELLER_CORE fragment)

  Tables globally replicated (NOT fragmented):
    products, product_variants, product_images, categories,
    attribute_types, attribute_values, user_roles,
    order_statuses, payment_method_types, regions, warehouses

  Rationale for NOT fragmenting products:
    - Products must be browsable from ALL regions without cross-shard joins.
    - A seller in Adama lists a product visible in all 8 cities.
    - Replication lag on product writes is tolerable (< 1 sec).
    - Product write rate is LOW (~50 inserts/min); read rate is VERY HIGH (85% of all QPS).

3.2 Consistent Hashing — Shard Rebalancing Without Mass Data Migration
─────────────────────────────────────────────────────────────────────────
Problem with Simple MOD-N Hashing:
  If we use shard = user_id % 4 and add a 5th shard:
    user_id = 100: old shard = 100%4 = 0, new shard = 100%5 = 0  ✓ (lucky)
    user_id = 101: old shard = 101%4 = 1, new shard = 101%5 = 1  ✓ (lucky)
    user_id = 102: old shard = 102%4 = 2, new shard = 102%5 = 2  ✓ (lucky)
    user_id = 103: old shard = 103%4 = 3, new shard = 103%5 = 3  ✓ (lucky)
    user_id = 104: old shard = 104%4 = 0, new shard = 104%5 = 4  ✗ MOVED
  On average: (N-1)/N = 75% of all data must be relocated → massive migration.

Consistent Hashing Solution:
  The keyspace [0, 2³²-1] is arranged as a ring.
  Each shard occupies a range on the ring (a "token range").
  When a shard is added, only the keys in its token range are migrated.
  On average: only 1/N fraction of data moves per shard addition.

  Token Ring Layout (4 shards, initial):
    AA_SHARD   : tokens  [0          →  1,073,741,823]  (0%   → 25%)
    CENTRAL    : tokens  [1,073,741,824 → 2,147,483,647] (25%  → 50%)
    EAST       : tokens  [2,147,483,648 → 3,221,225,471] (50%  → 75%)
    NW         : tokens  [3,221,225,472 → 4,294,967,295] (75%  → 100%)

  shard = HASH(user_id) mapped to ring position
  HASH function: CRC32(CONCAT('usr', user_id)) — stable, fast, uniform

  Adding Shard 5 (future NW split):
    New NW_EAST shard takes [3,758,096,383 → 4,294,967,295] (12.5% of ring)
    Only data in that token range migrates from NW → NW_EAST.
    All other 87.5% of data is untouched. ✓

  Virtual Nodes (vnodes) — 256 per shard:
    Each physical shard owns 256 non-contiguous segments on the ring.
    This ensures even distribution even with unequal shard sizes.
    After adding a new shard, its vnodes are distributed across the ring,
    pulling balanced amounts of data from all existing shards.

3.3 Vertical Fragmentation
──────────────────────────
Applied to: products, users, seller_profiles

  Products vertical split:
    PROD_HOT  (replicated everywhere, memory-optimized):
      product_id, product_name, slug, base_price, sale_price, rating,
      review_count, category_id, seller_id, is_active, is_featured, currency

    PROD_WARM  (replicated everywhere, SSD-tier):
      product_id, sku, short_desc, brand, weight_grams, tags (JSON)

    PROD_COLD  (Primary only, cold storage):
      product_id, description (LONGTEXT), metadata (JSON), cost_price,
      created_at, updated_at, deleted_at

    PROD_ANALYTICS  (ClickHouse cluster, columnar):
      product_id, views, cart_adds, conv_rate, search_impressions

  Users vertical split:
    USER_IDENTITY (Primary only — PII, encrypted, strict RBAC):
      user_id, email, phone_number (ENC), password_hash, date_of_birth,
      gender, failed_login_cnt, lockout_until

    USER_PROFILE (replicated — low sensitivity):
      user_id, first_name, last_name, profile_image, preferred_lang,
      account_status, role_id, region_id, created_at, last_login_at

  Benefit: Product listing page (60% of traffic) reads only PROD_HOT:
    ~150 bytes/row vs ~50,000 bytes/row (full product with LONGTEXT).
    Network I/O reduction: 99.7% for catalog queries. ✓

3.4 Hybrid / Derived Fragmentation
────────────────────────────────────
seller_profiles uses a two-level fragmentation:

  Level 1 — Vertical:
    SELLER_CORE     : seller_id, business_name, region_id, commission_rate,
                      rating, verification_status        [read-heavy, regional]
    SELLER_FINANCE  : seller_id, bank_account_name (ENC), bank_account_num (ENC),
                      telebirr_account (ENC), bank_name  [write-rare, Primary only]

  Level 2 — SELLER_CORE horizontally fragmented by region_id:
    σ(region_id ∈ {1,9..12})(SELLER_CORE) → AA_SHARD
    σ(region_id ∈ {2,3})    (SELLER_CORE) → CENTRAL_SHARD
    σ(region_id ∈ {4,5})    (SELLER_CORE) → EAST_SHARD
    σ(region_id ∈ {6,7,8})  (SELLER_CORE) → NW_SHARD

  SELLER_FINANCE lives exclusively on the Primary (encrypted + audited).
  Cross-join reconstructed in application layer: JOIN on seller_id.

  Derivation correctness:
    R = SELLER_CORE ⋈ SELLER_FINANCE  (natural join on seller_id)
    Each derived fragment Fᵢ = σ(Pᵢ)(SELLER_CORE) ⋈ SELLER_FINANCE ✓
*/

-- Fragmentation distribution verification
SELECT
    r.region_name,
    CASE
        WHEN r.region_id IN (1,9,10,11,12) THEN 'AA_SHARD'
        WHEN r.region_id IN (2,3)          THEN 'CENTRAL_SHARD'
        WHEN r.region_id IN (4,5)          THEN 'EAST_SHARD'
        WHEN r.region_id IN (6,7,8)        THEN 'NW_SHARD'
        ELSE 'UNASSIGNED'
    END                                                    AS target_shard,
    COUNT(o.order_id)                                      AS orders_on_shard,
    ROUND(COUNT(o.order_id) * 100.0 /
          NULLIF(SUM(COUNT(o.order_id)) OVER(), 0), 2)     AS pct_of_total,
    FORMAT(SUM(o.total_amount), 2)                         AS revenue_etb,
    FORMAT(AVG(o.total_amount), 2)                         AS avg_order_etb
FROM orders o
JOIN regions r ON r.region_id = o.region_id
WHERE o.deleted_at IS NULL
GROUP BY r.region_id
ORDER BY orders_on_shard DESC;


-- ################################################################################
-- SECTION 4: DISTRIBUTED ID GENERATION (SNOWFLAKE IDs)
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
4. DISTRIBUTED ID GENERATION — SNOWFLAKE IDS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Problem with AUTO_INCREMENT in a distributed system:
  - Each shard generates its own AUTO_INCREMENT sequence independently.
  - Shard 1 produces user_id = 1, 2, 3...
  - Shard 2 also produces user_id = 1, 2, 3...
  - Cross-shard join: ORDER o JOIN USER u ON o.customer_id = u.user_id
    → Returns WRONG RESULTS because the same ID exists on multiple shards.

Option A: UUID (128-bit) — REJECTED:
  UUIDs are random, causing index fragmentation in InnoDB B-trees.
  INSERT performance degrades 50% at 50M rows due to random page splits.
  Storage: 16 bytes vs 8 bytes (BIGINT) — 2× storage, 2× index size.

Option B: Snowflake ID (64-bit) — ADOPTED:
  Structure of a 64-bit Snowflake ID:
  ┌──────────────────────────────┬─────────────┬──────────────┐
  │  41 bits: millisecond epoch  │ 10b: shard  │ 12b: sequence│
  │  (since 2025-01-01 EAT)      │  node ID    │  counter     │
  └──────────────────────────────┴─────────────┴──────────────┘

  - 41-bit timestamp: supports 2^41 ms = ~69 years of IDs
  - 10-bit node ID:   supports 1,024 distinct nodes (shards/workers)
  - 12-bit sequence:  4,096 unique IDs per millisecond per node
  - Global max: 4,096 × 1,024 = 4,194,304 unique IDs/millisecond globally
  - IDs are monotonically increasing within a node → time-ordered B-tree pages
  - No central coordinator needed

Ethiopian epoch (Jan 1, 2025 00:00:00 EAT = UTC+3):
  EPOCH_MS = 1735686000000  (Unix ms)

ID generation formula (application layer, e.g. Node.js):
  const ts  = Date.now() - EPOCH_MS;             // 41 bits
  const nid = SHARD_NODE_ID & 0x3FF;             // 10 bits (0-1023)
  const seq = (sequence++) & 0xFFF;              // 12 bits (0-4095)
  const id  = BigInt(ts) << 22n | BigInt(nid) << 12n | BigInt(seq);

Decoding a Snowflake ID:
  timestamp_ms = (id >> 22) + EPOCH_MS
  node_id      = (id >> 12) & 0x3FF
  sequence     = id & 0xFFF

Benefits:
  ✓ Globally unique across all 4 (or 16) shards
  ✓ Monotonically increasing → sequential B-tree inserts → no page fragmentation
  ✓ Encodes shard origin → route queries to correct shard without shard_map lookup
  ✓ Sortable by creation time without a separate created_at index
*/

-- Snowflake ID decoder stored function
DELIMITER $$
CREATE FUNCTION IF NOT EXISTS fn_decode_snowflake_id (
    p_id         BIGINT UNSIGNED,
    p_epoch_ms   BIGINT UNSIGNED
)
RETURNS JSON
DETERMINISTIC
COMMENT 'Decodes a Snowflake ID into timestamp, shard_node_id, and sequence'
BEGIN
    DECLARE v_ts_ms   BIGINT UNSIGNED;
    DECLARE v_node_id SMALLINT UNSIGNED;
    DECLARE v_seq     SMALLINT UNSIGNED;
    SET v_ts_ms   = (p_id >> 22) + p_epoch_ms;
    SET v_node_id = (p_id >> 12) & 0x3FF;
    SET v_seq     = p_id & 0xFFF;
    RETURN JSON_OBJECT(
        'snowflake_id',   p_id,
        'created_at_utc', FROM_UNIXTIME(v_ts_ms / 1000.0),
        'shard_node_id',  v_node_id,
        'sequence',       v_seq
    );
END$$
DELIMITER ;

-- Example: decode a known order_id to verify shard origin
-- SELECT fn_decode_snowflake_id(7284729384751104, 1735686000000) AS decoded_id;

-- Cross-shard ID collision check (should return 0 — proves no duplicates)
SELECT COUNT(*) AS duplicate_order_ids
FROM (
    SELECT order_id, COUNT(*) AS cnt
    FROM orders
    GROUP BY order_id
    HAVING cnt > 1
) dupes;


-- ################################################################################
-- SECTION 5: ALLOCATION STRATEGY
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
5. ALLOCATION STRATEGY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

The allocation problem: given fragments F₁..Fₙ and sites S₁..Sₘ, decide
which copies of each fragment to place at which sites to minimize:
  Cost = w₁ × LatencyCost + w₂ × StorageCost + w₃ × NetworkCost

Allocation objectives:
  MIN(communication cost of queries)
  s.t. availability(Fᵢ) ≥ 0.9999 for all financial fragments
       response_time(q) ≤ 50ms for local queries

Fragment Allocation Matrix:
  ┌──────────────────────────┬──────────┬──────────┬──────────┬──────────┐
  │ Fragment                 │ AA_DC    │ CENTRAL  │ EAST_DC  │ NW_DC    │
  ├──────────────────────────┼──────────┼──────────┼──────────┼──────────┤
  │ PROD_HOT (product liting)│ P+R      │ P+R      │ P+R      │ P+R      │
  │ PROD_WARM                │ P+R      │ P+R      │ R        │ R        │
  │ PROD_COLD                │ P        │ —        │ —        │ —        │
  │ orders (AA region)       │ P+R      │ R        │ R        │ R        │
  │ orders (CENTRAL)         │ R        │ P+R      │ R        │ —        │
  │ orders (EAST)            │ R        │ —        │ P+R      │ R        │
  │ orders (NW)              │ R        │ R        │ —        │ P+R      │
  │ USER_PROFILE             │ P+R      │ P+R      │ P+R      │ P+R      │
  │ USER_IDENTITY            │ P        │ —        │ —        │ —        │
  │ SELLER_CORE              │ P+R      │ P+R      │ P+R      │ P+R      │
  │ SELLER_FINANCE           │ P        │ —        │ —        │ —        │
  │ audit_logs               │ P        │ —        │ —        │ —        │
  │ shard_map                │ P+R      │ P+R      │ P+R      │ P+R      │
  │ categories               │ P+R      │ R        │ R        │ R        │
  │ Delayed replica          │ P(6h)    │ —        │ —        │ —        │
  └──────────────────────────┴──────────┴──────────┴──────────┴──────────┘
  P = Primary copy  R = Replica copy  — = Not stored

Availability formula for replicated fragment (n copies, p = probability each up):
  availability = 1 - (1-p)ⁿ
  With p = 0.999 (each node), n = 4 replicas:
  availability = 1 - (0.001)⁴ = 1 - 0.000000000001 = 99.9999999999% ✓

Allocation cost model (per fragment, per query):
  C(q, Fᵢ, Sⱼ) = data_size × bandwidth_cost + latency_ms × query_frequency
  Example — product listing (PROD_HOT fragment, AA_SHARD, Addis customer):
    C = 150 bytes × 0.001 ETB/MB + 2ms × 10,000/min = negligible ✓
  Example — product listing from Mekele customer hitting AA_SHARD replica:
    C = 150 bytes × 0.001 ETB/MB + 12ms × 5,000/min = higher → justify local copy
    Solution: Replicate PROD_HOT to EAST_DC ✓ (already in matrix above)
*/

-- Allocation health check — verify shard_map is consistent
SELECT
    sm.shard_name,
    sm.dsn_primary,
    sm.dsn_replica,
    JSON_LENGTH(sm.region_ids)  AS region_count,
    sm.region_ids               AS covered_regions,
    sm.is_active
FROM shard_map sm
ORDER BY sm.shard_id;


-- ################################################################################
-- SECTION 6: REPLICATION ARCHITECTURE
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
6. REPLICATION ARCHITECTURE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

6.1 GTID Replication & ROW-format Binary Log
──────────────────────────────────────────────
Global Transaction Identifiers (GTID):
  Format: source_uuid:transaction_id
  Example: 3E11FA47-71CA-11E1-9E33-C80AA9429562:1-1000

  Guarantees: each transaction is replicated exactly once, in the correct order.
  After failover, new Primary can calculate exactly which transactions were
  missed using GTID sets, and request only those from binlog.

ROW vs STATEMENT format (why ROW is mandatory for distributed systems):
  STATEMENT: replicates the SQL text.
    Problem: UPDATE orders SET updated_at = NOW() WHERE ...
    → NOW() returns different values on primary vs replica → DIVERGENCE ✗

  ROW: replicates the exact before/after values of each row.
    → Same bytes written on every replica. → IDENTICAL DATA ✓
    → Larger binlog volume (a DELETE of 1M rows = 1M row events)
    → Mitigated by: binlog_row_image=MINIMAL (only changed columns)

  Required MySQL settings on ALL nodes:
    binlog_format         = ROW
    binlog_row_image      = MINIMAL
    gtid_mode             = ON
    enforce_gtid_consistency = ON
    log_replica_updates   = ON   [replicas also write binlog for chain replication]
    relay_log_purge       = ON
    slave_parallel_type   = LOGICAL_CLOCK
    slave_parallel_workers = 8   [parallel apply per commit group]

6.2 Semi-Synchronous Replication for Financial Durability
───────────────────────────────────────────────────────────
Normal async replication risk:
  t=0: Primary commits payment of ETB 45,000 (in-memory + binlog flushed)
  t=1: Binlog sent to replica (in-flight)
  t=2: PRIMARY CRASHES before replica receives event
  t=3: Replica promoted to Primary — transaction LOST forever ✗

Semi-sync solution:
  Primary waits for at least 1 replica to write the event to its relay log
  before returning SUCCESS to the client.
  t=0: Primary commits + binlog flushed
  t=1: Primary sends binlog event; WAITS for ACK (timeout: 1000ms)
  t=2: Replica writes to relay log → sends ACK
  t=3: Primary receives ACK → returns SUCCESS to application
  t=4: PRIMARY CRASHES — replica has the event → no data loss ✓

  Degradation: if replica doesn't ACK within 1000ms, Primary falls back
  to async automatically. Alert fires. SRE investigates.

  Configuration:
    [PRIMARY]
    rpl_semi_sync_source_enabled                = 1
    rpl_semi_sync_source_wait_for_replica_count = 1
    rpl_semi_sync_source_timeout                = 1000
    rpl_semi_sync_source_wait_no_replica        = ON  ← if 0 replicas, BLOCK writes

    [REPLICA 1 — hot standby]
    rpl_semi_sync_replica_enabled = 1

6.3 Multi-Source Replication (Analytics Replica)
──────────────────────────────────────────────────
  ANALYTICS_REPLICA receives from 4 channels simultaneously:
    CHANNEL aa_ch     ← AA_SHARD PRIMARY       (replicate all tables)
    CHANNEL central_ch ← CENTRAL_SHARD PRIMARY  (replicate all tables)
    CHANNEL east_ch   ← EAST_SHARD PRIMARY      (replicate all tables)
    CHANNEL nw_ch     ← NW_SHARD PRIMARY        (replicate all tables)

  Conflict resolution (same PK from two channels):
    Not possible for partitioned tables (each PK belongs to exactly one shard).
    For global tables (products, categories): replicated from AA_SHARD only.
    Other shards use IGNORE_SERVER_IDS to skip duplicates.

6.4 Replica Lag & Catch-up Strategy
──────────────────────────────────────
When a replica falls behind (e.g., after 2 hours of network outage):
  Symptom: Seconds_Behind_Source = 7200

  Catch-up strategy — LOGICAL_CLOCK parallel apply:
    slave_parallel_workers = 16   (temporarily increase)
    Transactions in the same binlog commit group apply in parallel.
    Lag shrinks at N× rate where N = number of parallel workers.

  Application behavior during high lag:
    ProxySQL routes reads to PRIMARY for any user whose last write was < lag_seconds ago.
    This prevents "read-your-own-write" violations during replica catch-up.
    Implemented via: session variable @last_write_ts compared to replica lag.

  Replication stop on critical error:
    sql_replica_skip_counter is FORBIDDEN (skipping events causes divergence).
    Instead: STOP REPLICA; fix data manually; set gtid_executed correctly; START REPLICA;
    Or: pt-table-checksum + pt-table-sync to reconcile diverged replica.
*/

-- Replication health monitoring
SELECT
    'Replication Health Check'         AS check_name,
    NOW(3)                             AS run_at;

-- Estimated replication lag via audit log timestamp delta
SELECT
    TIMESTAMPDIFF(MICROSECOND,
        (SELECT MAX(created_at) FROM audit_logs),
        NOW(3)
    ) / 1000.0                         AS estimated_lag_ms,
    (SELECT COUNT(*) FROM outbox_events WHERE is_published = 0)
                                       AS unpublished_outbox_events,
    (SELECT COUNT(*) FROM saga_log WHERE status = 'IN_PROGRESS'
        AND created_at < DATE_SUB(NOW(), INTERVAL 5 MINUTE))
                                       AS stale_sagas_5min;

-- Binlog size growth rate (proxy metric — tracks write activity)
SELECT
    DATE_FORMAT(created_at, '%Y-%m-%d %H:%i') AS minute_bucket,
    COUNT(*)                                  AS write_events,
    SUM(JSON_LENGTH(new_values))              AS approx_bytes
FROM audit_logs
WHERE created_at >= DATE_SUB(NOW(), INTERVAL 60 MINUTE)
GROUP BY minute_bucket
ORDER BY minute_bucket;


-- ################################################################################
-- SECTION 7: DISTRIBUTED TRANSACTION MANAGEMENT
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
7. DISTRIBUTED TRANSACTION MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

7.1 Two-Phase Commit (XA) — Cross-Shard Seller Payouts
────────────────────────────────────────────────────────
XA protocol guarantees atomicity across multiple resource managers.

  Phase 1 — PREPARE:
    Coordinator sends XA PREPARE to all participants.
    Each participant:
      1. Completes all local work.
      2. Writes PREPARE record to its redo log (durable even if it crashes now).
      3. Responds VOTE-COMMIT or VOTE-ABORT.

  Phase 2 — COMMIT or ROLLBACK:
    If all votes = COMMIT: Coordinator sends XA COMMIT to all.
    If any vote = ABORT: Coordinator sends XA ROLLBACK to all.
    Participants apply the decision and release locks.

  Failure handling matrix:
    ┌─────────────────────────────────┬────────────────────────────────────────┐
    │ Failure Point                   │ Recovery                               │
    ├─────────────────────────────────┼────────────────────────────────────────┤
    │ Coordinator crashes before PREP │ No participants wrote anything → ABORT  │
    │ Participant crashes after PREP  │ On restart: InnoDB restores PREPARE     │
    │                                 │ state from redo log; awaits coordinator │
    │ Coordinator crashes after PREP  │ On restart: reads coordinator WAL;      │
    │ but before COMMIT               │ reissues XA COMMIT to all participants  │
    │ Participant crashes after COMMIT│ On restart: InnoDB applies commit from  │
    │                                 │ redo log; idempotent                   │
    └─────────────────────────────────┴────────────────────────────────────────┘

  In-doubt XA transactions (recovery query):
*/
XA RECOVER;
/*
  Performance note: 2PC holds locks across all participants for the duration
  of both phases. With inter-city latency of 12ms (Addis→Mekele), a 3-shard
  2PC transaction locks rows for minimum 24ms (2 round trips).
  At 1,200 TPS this creates unacceptable contention.
  → USE 2PC only for low-frequency batch operations (seller payouts run nightly).
  → Use Saga for all OLTP operations (orders, payments).

7.2 Saga Pattern with Transactional Outbox
────────────────────────────────────────────
The Saga splits a distributed transaction into local transactions connected
by domain events. Each step has a compensating transaction for rollback.

ORDER PLACEMENT SAGA — Full Step Specification:

  Step 1: CREATE_ORDER
    Local TX on customer's shard:
      INSERT INTO orders (..., status='PENDING', payment_status='PENDING')
      INSERT INTO outbox_events (event_type='ORDER_CREATED', topic='orders')
    Compensating TX: UPDATE orders SET status='CANCELLED', cancelled_at=NOW(3)
    Idempotency: order_number is UNIQUE → duplicate saga restarts are safe

  Step 2: RESERVE_INVENTORY
    Local TX on warehouse's shard:
      UPDATE inventory SET reserved_quantity = reserved_quantity + qty
             WHERE variant_id = X AND warehouse_id = Y
             AND (quantity_on_hand - reserved_quantity) >= qty
      INSERT INTO inventory_transactions (txn_type='RESERVATION', ...)
      INSERT INTO outbox_events (event_type='INVENTORY_RESERVED', ...)
    Compensating TX: UPDATE inventory SET reserved_quantity = reserved_quantity - qty
    Guard: quantity_on_hand - reserved_quantity >= qty (enforced by CHECK + FOR UPDATE)

  Step 3: PROCESS_PAYMENT
    Local TX on customer's shard:
      INSERT INTO payments (status='PROCESSING', idempotency_key=...)
      [Call Telebirr/CBE API — external I/O outside transaction]
      UPDATE payments SET status='SUCCESS', paid_at=NOW(3) WHERE payment_id=...
      UPDATE orders SET payment_status='CAPTURED'
      INSERT INTO outbox_events (event_type='PAYMENT_CONFIRMED', ...)
    Compensating TX:
      UPDATE payments SET status='FAILED'
      Compensate Step 2: release inventory reservation
      Compensate Step 1: cancel order

  Step 4: DEDUCT_INVENTORY
    Local TX: UPDATE inventory SET quantity_on_hand = quantity_on_hand - qty,
                                   reserved_quantity = reserved_quantity - qty
    INSERT INTO inventory_transactions (txn_type='SALE', ...)
    No compensation needed (delivery fails → refund triggers restock)

  Step 5: NOTIFY_CUSTOMER
    Insert into notifications (or publish to SNS)
    Idempotent: duplicate notifications are filtered by idempotency_key
    No compensation needed

  Saga Recovery:
    A background job runs every 30 seconds:
    SELECT * FROM saga_log WHERE status='IN_PROGRESS' AND updated_at < NOW()-60
    For each stale saga: resume from last completed step OR start compensation

7.3 Cross-Shard Foreign Key Enforcement
─────────────────────────────────────────
MySQL InnoDB enforces FOREIGN KEY constraints only within a single node.
In a sharded system, a payment.order_id might reference an order on a
different shard. MySQL cannot enforce this FK at the database level.

Strategy: Application-layer FK enforcement

  Before INSERT INTO payments (order_id = X):
    1. Decode shard from Snowflake ID X → identify correct shard
    2. Query that shard: SELECT order_id FROM orders WHERE order_id = X
    3. If NOT FOUND: raise application error "Order not found"
    4. If FOUND: proceed with INSERT

  Cross-shard referential integrity for analytics:
    A nightly job runs on the analytics replica:
      SELECT p.payment_id, p.order_id
      FROM payments p
      LEFT JOIN orders o ON o.order_id = p.order_id
      WHERE o.order_id IS NULL          ← orphaned payment (FK violation)
    Violations are logged to audit_logs with action='CROSS_SHARD_FK_VIOLATION'
    and escalated to DBA on-call.
*/

-- Orphan payment detection (cross-shard FK violation check)
SELECT
    p.payment_id,
    p.order_id,
    p.amount,
    p.status,
    p.created_at,
    'ORPHANED_PAYMENT'              AS anomaly_type
FROM payments p
LEFT JOIN orders o ON o.order_id = p.order_id AND o.deleted_at IS NULL
WHERE o.order_id IS NULL
  AND p.status NOT IN ('CANCELLED')
  AND p.created_at > DATE_SUB(NOW(), INTERVAL 24 HOUR);

-- Saga stale detection
SELECT
    saga_id,
    saga_type,
    current_step,
    status,
    last_error,
    created_at,
    TIMESTAMPDIFF(SECOND, updated_at, NOW(3)) AS seconds_stuck
FROM saga_log
WHERE status IN ('IN_PROGRESS', 'COMPENSATING')
  AND updated_at < DATE_SUB(NOW(3), INTERVAL 5 MINUTE)
ORDER BY seconds_stuck DESC;


-- ################################################################################
-- SECTION 8: MVCC & INNODB CONCURRENCY INTERNALS
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
8. MVCC & INNODB CONCURRENCY INTERNALS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

8.1 Multi-Version Concurrency Control (MVCC)
──────────────────────────────────────────────
InnoDB implements MVCC to allow readers to see a consistent snapshot of data
WITHOUT acquiring shared locks. This is fundamental to avoiding read/write
contention on a high-traffic e-commerce platform.

How InnoDB stores versions:
  Each InnoDB row has two hidden system columns:
    DB_TRX_ID  : transaction ID that last inserted/updated this row
    DB_ROLL_PTR: pointer into the undo log (previous version of the row)

  The undo log is a linked list of row versions (the "version chain").
  When a transaction reads a row, it checks:
    IF DB_TRX_ID <= read_view.low_watermark THEN use this version
    ELSE follow DB_ROLL_PTR → check next version
    REPEAT until a version visible to this read_view is found

Read View (Snapshot):
  Created at the START of a transaction (REPEATABLE READ) or per-statement (READ COMMITTED).
  Defines:
    low_watermark  : min active TRX_ID at snapshot time (all older TXs are committed)
    high_watermark : next available TRX_ID (all newer TXs are invisible)
    active_trxs    : set of TRX_IDs that were active at snapshot time (excluded)

Visibility rule:
  A row version V with TRX_ID = T is visible if:
    T <= low_watermark                              (committed before snapshot) ✓
    OR T > high_watermark                           (created after → invisible) ✗
    OR T ∈ active_trxs                              (in-flight at snapshot → invisible) ✗

Impact on our system:
  1. A customer browsing products (REPEATABLE READ) sees a consistent price
     snapshot even if a seller updates the price mid-transaction. ✓
  2. sp_place_order uses SELECT ... FOR UPDATE — this BYPASSES MVCC for that row,
     acquiring a physical row lock. Required to prevent overselling. ✓
  3. Long-running transactions accumulate undo log entries (version chains grow).
     → Monitor: SELECT * FROM information_schema.INNODB_TRX WHERE trx_started < NOW()-60;
     → Kill if > 5 minutes: KILL trx_mysql_thread_id;

8.2 Gap Locks & Next-Key Locks (Phantom Prevention)
─────────────────────────────────────────────────────
Under REPEATABLE READ, InnoDB uses next-key locks (row lock + gap lock before the row)
to prevent phantom reads in range queries.

  Example: SELECT * FROM orders WHERE placed_at BETWEEN '2026-04-01' AND '2026-04-07' FOR UPDATE;
  InnoDB locks:
    All rows in the range (row locks)
    All gaps between those rows (gap locks)
    Gap after the last row (prevents INSERT of new rows in range)
  → No phantom rows can be inserted by concurrent transactions.

  Impact: Gap locks can cause unexpected lock waits.
  Mitigation: Prefer equality conditions (WHERE order_id = X FOR UPDATE) over range
              for locking queries. Range locks only in serializable isolation.

8.3 InnoDB Redo Log (Write-Ahead Log)
──────────────────────────────────────
All changes are recorded in the redo log BEFORE being applied to data pages.
This is the WAL (Write-Ahead Logging) protocol:

  LSN: Log Sequence Number — monotonically increasing 8-byte counter.
  Each redo log record has an LSN.
  Each data page header stores the last-flushed LSN.

  During CRASH RECOVERY:
    Step 1: Find last checkpoint LSN (stored in ibdata1 header).
    Step 2: Read all redo records with LSN > checkpoint LSN.
    Step 3: Re-apply those records to data pages (REDO phase).
    Step 4: Roll back uncommitted transactions using undo logs (UNDO phase).
    Step 5: Database is consistent. Open for connections.

  innodb_redo_log_capacity = 8G   (MySQL 8.0.30+ unified redo log)
  This controls how many seconds of changes can buffer before a checkpoint.
  Larger = faster throughput, longer crash recovery time.
  At 1,500 TPS write rate: 8GB allows ~4 minutes of activity between checkpoints.

8.4 Buffer Pool & Page Lifecycle
──────────────────────────────────
  Buffer pool (200GB on Primary): caches data pages and index pages in memory.
  Page lifecycle:
    LOAD: page read from disk → placed in buffer pool (LRU)
    DIRTY: page modified → marked dirty (not yet flushed to disk)
    FLUSH: dirty page written to disk by background page cleaner thread
    EVICT: cold page evicted from LRU if buffer pool is full

  innodb_buffer_pool_instances = 16   (reduces mutex contention)
  innodb_page_cleaners          = 8   (parallel flush threads)

  Critical metric: Buffer pool hit ratio = (read_requests - disk_reads) / read_requests
  Target: > 99%.  If < 95% → buffer pool too small → OOM or disk I/O bottleneck.
*/

-- MVCC: detect long-running transactions that bloat undo logs
SELECT
    trx_id,
    trx_state,
    trx_started,
    TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS seconds_running,
    trx_rows_locked,
    trx_rows_modified,
    LEFT(trx_query, 200)                       AS current_query
FROM information_schema.INNODB_TRX
WHERE trx_started < DATE_SUB(NOW(), INTERVAL 30 SECOND)
ORDER BY trx_started;

-- Buffer pool effectiveness
SELECT
    ROUND((1 - Innodb_buffer_pool_reads / Innodb_buffer_pool_read_requests) * 100, 4)
                               AS buffer_pool_hit_pct,
    Innodb_buffer_pool_reads   AS physical_disk_reads,
    Innodb_buffer_pool_read_requests AS logical_reads,
    Innodb_pages_written        AS dirty_pages_flushed
FROM (
    SELECT
        SUM(IF(VARIABLE_NAME='Innodb_buffer_pool_reads', VARIABLE_VALUE, 0))            AS Innodb_buffer_pool_reads,
        SUM(IF(VARIABLE_NAME='Innodb_buffer_pool_read_requests', VARIABLE_VALUE, 0))    AS Innodb_buffer_pool_read_requests,
        SUM(IF(VARIABLE_NAME='Innodb_pages_written', VARIABLE_VALUE, 0))                AS Innodb_pages_written
    FROM performance_schema.global_status
    WHERE VARIABLE_NAME IN ('Innodb_buffer_pool_reads',
                            'Innodb_buffer_pool_read_requests',
                            'Innodb_pages_written')
) s;


-- ################################################################################
-- SECTION 9: CAP / PACELC ANALYSIS & CONSISTENCY MODELS
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
9. CAP / PACELC ANALYSIS & CONSISTENCY MODELS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

9.1 CAP Theorem Formal Statement
──────────────────────────────────
Brewer's theorem (2000): A distributed system can guarantee at most 2 of:
  C — Consistency:         All nodes see the same data at the same time.
  A — Availability:        Every request receives a (non-error) response.
  P — Partition Tolerance: The system operates despite network partitions.

Since P is mandatory (Ethiopian inter-city fiber links WILL fail), we choose
between C and A on a per-subsystem basis:

  ┌─────────────────────┬──────┬──────────────────────────────────────────────┐
  │ Subsystem           │ CAP  │ Consequence & Implementation                 │
  ├─────────────────────┼──────┼──────────────────────────────────────────────┤
  │ Payment processing  │  CP  │ If Primary unreachable: ABORT (return error) │
  │                     │      │ Never serve stale payment data from replica  │
  ├─────────────────────┼──────┼──────────────────────────────────────────────┤
  │ Order placement     │  CP  │ Overselling is worse than unavailability.    │
  │                     │      │ Fail the request; customer retries.          │
  ├─────────────────────┼──────┼──────────────────────────────────────────────┤
  │ Inventory reads     │  AP  │ Show potentially stale stock count on UI.    │
  │                     │      │ "Only 2 left!" may be 10 seconds stale. OK. │
  ├─────────────────────┼──────┼──────────────────────────────────────────────┤
  │ Product catalog     │  AP  │ Serve from replica even if 500ms behind.    │
  │                     │      │ Stale price displayed, confirmed at checkout.│
  ├─────────────────────┼──────┼──────────────────────────────────────────────┤
  │ Search / Browse     │  AP  │ ElasticSearch index may lag 5s. Acceptable. │
  ├─────────────────────┼──────┼──────────────────────────────────────────────┤
  │ Analytics/Reporting │  AP  │ Pre-aggregated tables refreshed hourly.     │
  │                     │      │ Dashboard shows data up to 1hr old. Fine.   │
  └─────────────────────┴──────┴──────────────────────────────────────────────┘

9.2 PACELC Extension
─────────────────────
PACELC (Abadi, 2012) adds: during normal operation (no partition, E),
choose between Latency (L) and Consistency (C):

  P → A : During partition, favor Availability (catalog, search)
  P → C : During partition, favor Consistency (payments, orders)
  E → L : Normally, favor Latency (catalog reads from replica)
  E → C : Normally, favor Consistency (payment writes to Primary)

  Our system is: Payments = PC/EC, Catalog = PA/EL, Analytics = PA/EL

9.3 Vector Clocks — Causality Tracking
────────────────────────────────────────
Problem: In an eventually consistent system, without causality tracking,
events can be applied out of order.

Example without vector clocks:
  t=0: Customer updates shipping address to "Bole" (on AA replica)
  t=1: Order placed — uses shipping address (on Primary)
  t=2: Address update replicates to Primary
  t=3: Address now shows "Bole" but order was created with old address ✗

Vector clock solution:
  Each node maintains a vector clock V = [AA:n₁, CENTRAL:n₂, EAST:n₃, NW:n₄]
  Every write increments the writer's component.
  Reads include the client's seen vector clock.
  The system ensures: if event A caused event B, then B is only visible
  after A is visible (causality preserved).

Implementation in our system:
  The sessions table stores a client_vector_clock JSON column.
  On each write, the application updates the clock.
  On reads, the routing layer checks: replica.current_clock >= client.clock
  If not: route read to Primary (fall back to strong consistency for this client).

  This gives READ-YOUR-WRITES consistency without always hitting Primary.

9.4 Read-Your-Writes Implementation (ProxySQL Session Tracking)
────────────────────────────────────────────────────────────────
  Problem: Customer places an order → reads order list from replica → doesn't see own order.
  Solution:
    After any write, application sets:
      SET @last_write_ts = NOW(3);
    ProxySQL intercepts all subsequent SELECTs within the session.
    If SHOW REPLICA STATUS shows Seconds_Behind_Source > 0:
      AND (NOW(3) - @last_write_ts) < replication_lag_seconds:
      → Route SELECT to PRIMARY
    After lag seconds pass: back to replica routing.
    Implemented via ProxySQL mysql_query_rules.multiplex=0 for post-write sessions.
*/

-- Causality violation detection: orders created before the address update was replicated
SELECT
    o.order_id,
    o.customer_id,
    o.placed_at,
    ua.updated_at                AS address_last_updated,
    TIMESTAMPDIFF(MILLISECOND, o.placed_at, ua.updated_at) AS ms_address_updated_after_order
FROM orders o
JOIN user_addresses ua ON ua.address_id = o.shipping_address_id
WHERE ua.updated_at > o.placed_at   -- address updated AFTER order placed (potential causality issue)
  AND TIMESTAMPDIFF(SECOND, o.placed_at, ua.updated_at) < 10  -- within 10 sec window
ORDER BY o.placed_at DESC
LIMIT 50;


-- ################################################################################
-- SECTION 10: CONCURRENCY CONTROL & HOTSPOT MITIGATION
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
10. CONCURRENCY CONTROL & HOTSPOT MITIGATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

10.1 Consistent Locking Order (Deadlock Prevention)
─────────────────────────────────────────────────────
A deadlock occurs when TX₁ holds lock A and waits for B, while
TX₂ holds lock B and waits for A (circular wait).

Prevention rule: All transactions must acquire locks in a GLOBAL CANONICAL ORDER:
  Order: inventory → orders → order_items → payments → audit_logs
  NEVER reverse this order in any stored procedure or application code.

Implementation in sp_place_order:
  Step 1: SELECT ... FOR UPDATE on inventory rows (always lock variant_id ASC)
  Step 2: INSERT INTO orders
  Step 3: INSERT INTO order_items
  Step 4: (Payment processed asynchronously — no concurrent lock with order)

InnoDB deadlock detection:
  If deadlock occurs despite precautions: InnoDB detects within 50ms
  and rolls back the transaction with the smallest undo log (cheapest rollback).
  Application retries with exponential backoff: 100ms, 200ms, 400ms, 800ms.
  Max retries: 5. After 5 failures: return 503 to client.

  innodb_lock_wait_timeout = 5  (seconds before lock wait timeout)
  innodb_deadlock_detect    = ON (waiter graph cycle detection)

10.2 Thundering Herd & Redis Inventory Shield
──────────────────────────────────────────────
Scenario: Enkutatash flash sale — Samsung Galaxy S25 (500 units) at 50% off.
  200,000 concurrent buyers attempt to purchase simultaneously at 00:00.
  All 200,000 hit: SELECT ... FOR UPDATE on inventory WHERE variant_id = X.
  MySQL can only process ~100 FOR UPDATE/sec on one row (lock serialization).
  Result: 199,900 transactions queue → timeout cascade → database crash. ✗

Thundering Herd Solution — Redis Inventory Shield:
  STEP 1 (Redis, atomic DECRBY, < 1ms per operation):
    SCRIPT:
      local qty = redis.call('DECRBY', key, requested_qty)
      if qty < 0 then
        redis.call('INCRBY', key, requested_qty)  -- rollback
        return 0  -- SOLD_OUT
      end
      return 1  -- RESERVED

    At 200,000 concurrent requests: Redis processes all in < 200ms (single thread,
    100,000+ DECRBY/sec capacity with Lua scripting).
    Only the first 500 units succeed. The rest get SOLD_OUT immediately.
    0 MySQL lock contention for 199,500 losing requests. ✓

  STEP 2 (MySQL, async, only for the 500 winners):
    Queue worker processes 500 reservations into MySQL inventory table.
    No lock contention because only 500 concurrent writes (vs 200,000). ✓

  STEP 3 (Reconciliation — every 60 seconds):
    SELECT
        r.redis_qty,
        m.mysql_available,
        (r.redis_qty - m.mysql_available) AS drift
    FROM redis_inventory_snapshot r
    JOIN (SELECT variant_id, quantity_on_hand - reserved_quantity AS mysql_available
          FROM inventory WHERE variant_id = X) m USING (variant_id)
    HAVING ABS(drift) > 2;  -- alert if drift > 2 units

10.3 Hotspot Detection & Data Skew
─────────────────────────────────────
Data skew: one shard receives disproportionately more traffic than others.
  Example: All Ethiopian New Year orders concentrated on AA_SHARD (62% of users = Addis)
  while NW_SHARD sits idle. AA_SHARD becomes the bottleneck.

Detection queries (run nightly on each shard):
*/

-- Hotspot detection: identify high-contention inventory rows
SELECT
    i.inventory_id,
    p.product_name,
    pv.variant_name,
    w.warehouse_name,
    i.quantity_on_hand,
    i.reserved_quantity,
    COUNT(it.txn_id)                                    AS txns_last_hour,
    ROUND(COUNT(it.txn_id) / 60.0, 1)                  AS txns_per_minute,
    ROUND(i.reserved_quantity * 100.0 /
          NULLIF(i.quantity_on_hand, 0), 1)             AS reservation_rate_pct
FROM inventory i
JOIN product_variants pv ON pv.variant_id = i.variant_id
JOIN products          p  ON p.product_id  = pv.product_id
JOIN warehouses        w  ON w.warehouse_id = i.warehouse_id
LEFT JOIN inventory_transactions it
    ON it.inventory_id = i.inventory_id
   AND it.created_at  >= DATE_SUB(NOW(), INTERVAL 1 HOUR)
GROUP BY i.inventory_id
HAVING txns_per_minute > 10   -- more than 10 reservations/minute = hot row
ORDER BY txns_per_minute DESC
LIMIT 20;

-- Data skew detection: order volume per shard
SELECT
    CASE
        WHEN r.region_id IN (1,9,10,11,12) THEN 'AA_SHARD'
        WHEN r.region_id IN (2,3)          THEN 'CENTRAL_SHARD'
        WHEN r.region_id IN (4,5)          THEN 'EAST_SHARD'
        WHEN r.region_id IN (6,7,8)        THEN 'NW_SHARD'
    END                                                  AS shard,
    COUNT(o.order_id)                                    AS order_count,
    ROUND(COUNT(o.order_id) * 100.0 /
          SUM(COUNT(o.order_id)) OVER(), 2)              AS pct_of_total,
    FORMAT(SUM(o.total_amount), 2)                       AS total_revenue_etb,
    FORMAT(AVG(o.total_amount), 2)                       AS avg_order_etb,
    MIN(o.placed_at)                                     AS first_order,
    MAX(o.placed_at)                                     AS last_order
FROM orders o
JOIN regions r ON r.region_id = o.region_id
WHERE o.deleted_at IS NULL
  AND o.placed_at  >= DATE_SUB(NOW(), INTERVAL 7 DAY)
GROUP BY shard
ORDER BY order_count DESC;


-- ################################################################################
-- SECTION 11: QUERY PROCESSING & GLOBAL SECONDARY INDEXES
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
11. QUERY PROCESSING & GLOBAL SECONDARY INDEXES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

11.1 Query Classification
──────────────────────────
  Type 1 — Local Query: all data on one shard.
    WHERE clause includes the shard key (region_id, user_id).
    Execution: route to one shard; standard MySQL query plan.

  Type 2 — Fan-out (Scatter-Gather): data on multiple shards.
    No shard key in WHERE; requires parallel scan of all shards.
    Execution: ProxySQL / Vitess fan-out to all shards; merge results.
    Cost: O(n_shards × cost_per_shard). Minimize via pre-aggregation.

  Type 3 — Cross-shard join: entities on different shards need to be joined.
    The most expensive distributed query type.
    Solution: Denormalize by copying the needed attributes to the query shard.

11.2 Global Secondary Indexes (GSI)
────────────────────────────────────
Problem: Seller views all their orders across ALL regions.
  SELECT * FROM orders WHERE seller_id = 5;
  This is a Type 2 fan-out — seller 5's orders are spread across all 4 shards
  because orders are sharded by region, not seller.
  Without GSI: query hits 4 shards in parallel → 4× read amplification.

GSI Solution: Maintain a seller_orders_index table on each shard,
  mapping seller_id → (order_id, shard, region_id, placed_at, total_amount).
  This GSI is itself partitioned by seller_id (hash-based).
  When a seller queries their orders: hit their GSI shard → get list of
  (order_id, target_shard) → fetch full order from target shard.
  Result: 1 GSI lookup + N targeted fetches (N = number of orders, not shards).
*/

-- Global Secondary Index table for seller→orders
CREATE TABLE IF NOT EXISTS gsi_seller_orders (
    seller_id       BIGINT UNSIGNED  NOT NULL,
    order_id        BIGINT UNSIGNED  NOT NULL,
    source_shard    VARCHAR(20)      NOT NULL   COMMENT 'Which shard holds the full order',
    region_id       SMALLINT UNSIGNED NOT NULL,
    placed_at       DATETIME(3)      NOT NULL,
    total_amount    DECIMAL(14,2)    NOT NULL,
    order_status    VARCHAR(50)      NOT NULL,
    payment_status  VARCHAR(50)      NOT NULL,

    PRIMARY KEY (seller_id, order_id),
    KEY idx_gsi_seller_date (seller_id, placed_at),
    KEY idx_gsi_seller_status (seller_id, order_status)
) ENGINE=InnoDB
  COMMENT='GSI: seller_id → orders (maintained by trigger/event on each shard)'
  PARTITION BY HASH(seller_id) PARTITIONS 8;

-- GSI population from current shard (run on each shard node)
INSERT INTO gsi_seller_orders
    (seller_id, order_id, source_shard, region_id, placed_at, total_amount,
     order_status, payment_status)
SELECT
    o.seller_id,
    o.order_id,
    CASE
        WHEN o.region_id IN (1,9,10,11,12) THEN 'AA_SHARD'
        WHEN o.region_id IN (2,3)          THEN 'CENTRAL_SHARD'
        WHEN o.region_id IN (4,5)          THEN 'EAST_SHARD'
        WHEN o.region_id IN (6,7,8)        THEN 'NW_SHARD'
    END,
    o.region_id,
    o.placed_at,
    o.total_amount,
    os.status_code,
    o.payment_status
FROM orders o
JOIN order_statuses os ON os.status_id = o.status_id
WHERE o.deleted_at IS NULL
ON DUPLICATE KEY UPDATE
    order_status   = VALUES(order_status),
    payment_status = VALUES(payment_status),
    total_amount   = VALUES(total_amount);

/*
11.3 Query Optimizer Hints (Forcing Optimal Plans)
────────────────────────────────────────────────────
MySQL's cost-based optimizer can choose sub-optimal plans on the first run
(stale statistics). Hints override the optimizer when needed.
*/

-- Force covering index for product listing (override optimizer if it chooses full scan)
SELECT /*+ INDEX(p idx_prod_cat_rating) */
    p.product_id,
    p.product_name,
    p.base_price,
    p.sale_price,
    p.rating,
    p.review_count
FROM   products p
WHERE  p.category_id = 10
  AND  p.is_active   = 1
  AND  p.deleted_at IS NULL
ORDER BY p.rating DESC
LIMIT  24;

-- Force hash join for large aggregation (avoid nested loop on big tables)
SELECT /*+ HASH_JOIN(o, os) */
    os.status_name,
    COUNT(o.order_id)                  AS order_count,
    FORMAT(SUM(o.total_amount), 2)     AS total_revenue_etb
FROM orders         o
JOIN order_statuses os ON os.status_id = o.status_id
WHERE o.deleted_at IS NULL
  AND o.placed_at >= DATE_SUB(NOW(), INTERVAL 30 DAY)
GROUP BY os.status_id
ORDER BY order_count DESC;

-- EXPLAIN with optimizer trace (detailed cost model output)
EXPLAIN FORMAT=TREE
SELECT p.product_id, p.product_name, p.base_price, p.rating
FROM   products p
WHERE  p.category_id = 10 AND p.is_active = 1 AND p.deleted_at IS NULL
ORDER BY p.rating DESC LIMIT 24;


-- ################################################################################
-- SECTION 12: LIVE SCHEMA MIGRATION IN DISTRIBUTED SYSTEMS
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
12. LIVE SCHEMA MIGRATION IN DISTRIBUTED SYSTEMS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Problem: ALTER TABLE on a production MySQL table with 100M rows LOCKS THE TABLE.
  ALTER TABLE orders ADD COLUMN delivery_sla_hours TINYINT UNSIGNED NULL;
  → Table locked for WRITES for ~20 minutes on 100M row table.
  → During that time: 0 new orders possible. ✗

12.1 gh-ost: Zero-Downtime Online Schema Changes
─────────────────────────────────────────────────
gh-ost (GitHub Online Schema change) avoids table locking entirely.
It uses the binary log as a change stream, not triggers.

gh-ost migration flow for ADD COLUMN on orders:
  STEP 1: Create shadow table:
          CREATE TABLE _orders_gho LIKE orders;
          ALTER TABLE _orders_gho ADD COLUMN delivery_sla_hours TINYINT UNSIGNED NULL;

  STEP 2: Chunk-copy existing data (background, rate-limited):
          INSERT INTO _orders_gho SELECT * FROM orders WHERE order_id BETWEEN X AND Y;
          (Runs in 1,000-row chunks; sleeps between chunks to avoid overload)

  STEP 3: Apply concurrent changes via binlog:
          gh-ost connects as a replica to the binary log.
          For each INSERT/UPDATE/DELETE on orders during copy:
            → Apply equivalent change to _orders_gho immediately.
          This ensures _orders_gho stays perfectly in sync with orders.

  STEP 4: Final cutover (lock window: ~1 second):
          LOCK TABLES orders WRITE;
          Apply remaining binlog events to _orders_gho;
          RENAME TABLE orders TO _orders_del, _orders_gho TO orders;
          UNLOCK TABLES;

  STEP 5: Verify, then DROP TABLE _orders_del; (after 48-hour observation period)

  Total lock time: < 1 second (vs 20+ minutes for ALTER TABLE). ✓
  Zero downtime for reads during entire migration.
  Writes blocked for < 1 second during cutover.

gh-ost command:
  gh-ost \
    --host=primary.db.ethmarket.internal \
    --port=3306 \
    --database=eth_ecommerce \
    --table=orders \
    --alter="ADD COLUMN delivery_sla_hours TINYINT UNSIGNED NULL AFTER cancelled_at" \
    --chunk-size=1000 \
    --max-load=Threads_running=50 \
    --critical-load=Threads_running=100 \
    --switch-to-rbr \
    --allow-master-master \
    --cut-over=default \
    --exact-rowcount \
    --concurrent-rowcount \
    --default-retries=120 \
    --execute

12.2 Expand / Contract Pattern — Backward-Compatible Schema Changes
────────────────────────────────────────────────────────────────────
Multi-step deployment for column renames/type changes without downtime:

  Phase 1 — EXPAND (add new column, both columns active):
    ALTER TABLE orders ADD COLUMN payment_gateway VARCHAR(50) NULL;
    Deploy v2 app: writes to BOTH old (payment_method_id) and new (payment_gateway).
    Reads from old column only.

  Phase 2 — MIGRATE DATA (background job):
    UPDATE orders SET payment_gateway = pmt.method_code
    FROM payment_method_types pmt WHERE pmt.method_id = orders.payment_method_id
    WHERE payment_gateway IS NULL
    LIMIT 10000;   -- batch to avoid lock overload

  Phase 3 — SWITCH READS:
    Deploy v3 app: reads from NEW column; writes to both.
    Monitor for errors.

  Phase 4 — CONTRACT (remove old column):
    Deploy v4 app: writes to NEW column only.
    DROP COLUMN payment_method_id; (using gh-ost)

  This pattern ensures zero downtime and instant rollback at any phase.

12.3 Distributed DDL — All Shards Must Migrate Together
─────────────────────────────────────────────────────────
  Problem: If AA_SHARD migrates but CENTRAL_SHARD does not, the application
  sends queries with the new column name to CENTRAL → SQL error.

  Solution: Use a migration coordinator (Flyway / Liquibase) with shard awareness.
    1. Run gh-ost on AA_SHARD → wait for completion.
    2. Run gh-ost on CENTRAL_SHARD → wait.
    3. Run gh-ost on EAST_SHARD → wait.
    4. Run gh-ost on NW_SHARD → wait.
    5. Deploy new application version (it can safely use new schema now).

  Schema version tracking table (exists on all shards):
*/

CREATE TABLE IF NOT EXISTS schema_migrations (
    migration_id   VARCHAR(100)    PRIMARY KEY,
    applied_at     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    description    VARCHAR(300)    NOT NULL,
    checksum       CHAR(64)        NOT NULL COMMENT 'SHA256 of migration SQL',
    execution_ms   INT UNSIGNED    NOT NULL,
    shard_name     VARCHAR(30)     NOT NULL COMMENT 'Which shard this record is from'
) ENGINE=InnoDB COMMENT='Schema version tracking for distributed migration coordination';


-- ################################################################################
-- SECTION 13: FAILURE DETECTION, RECOVERY & HA
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
13. FAILURE DETECTION, RECOVERY & HIGH AVAILABILITY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

13.1 Orchestrator + Raft Consensus (Split-Brain Prevention)
─────────────────────────────────────────────────────────────
Orchestrator is the MySQL topology manager. It runs on 3 nodes using the
Raft consensus algorithm to prevent split-brain:

  Raft guarantee: a leader is elected only when a QUORUM (2 of 3) of
  Orchestrator nodes agree. A leader cannot be elected during a network partition
  that isolates a minority (1 of 3 nodes).

  Failover decision process:
    t=0:  Primary missed heartbeat.
    t=3:  Three consecutive heartbeat misses → Orchestrator suspects failure.
    t=4:  Orchestrator node 1 broadcasts SUSPECT_FAILURE to nodes 2 and 3.
    t=5:  Nodes 2 and 3 independently verify: can they reach the Primary?
    t=6:  Both confirm they cannot → QUORUM agrees Primary is down.
    t=7:  Leader (node 1) initiates failover: SELECT best replica.
    t=8:  Best replica = Replica 1 (semi-sync, most advanced GTID set).
    t=10: Orchestrator issues: STOP REPLICA; RESET REPLICA ALL; on Replica 1.
    t=11: Replica 1 promoted to Primary: SET GLOBAL read_only = OFF;
    t=12: ProxySQL updated via Orchestrator HTTP API → routes writes to new Primary.
    t=15: DNS updated: db-primary.ethmarket.internal → Replica 1 IP.
    t=20: Replica 2 and 3 repointed to new Primary. Replication resumed.
    t=30: System fully operational. PagerDuty alert fired.

  Anti-split-brain: old Primary cannot promote itself (it was isolated).
  Fencing: Orchestrator sends SIGTERM + fence token change to old Primary.
  If old Primary comes back: it sees it's not the leader (GTID mismatch) → stays replica.

13.2 WAL Crash Recovery — Formal Proof
────────────────────────────────────────
InnoDB redo log guarantees durability for committed transactions.
With innodb_flush_log_at_trx_commit=1 + sync_binlog=1:

  PROOF: Let T be a committed transaction with LSN L.
    Claim: T survives any crash after its COMMIT.

    By flush_log_at_trx_commit=1:
      ∀ COMMIT: the redo log is flushed to OS buffer AND fsync() called.
      → T's redo records are durably on disk before COMMIT returns. □

    By sync_binlog=1:
      ∀ COMMIT: binlog is fsync()'d before COMMIT returns.
      → T's binlog event is durably on disk. □

    On restart, InnoDB:
      1. Reads checkpoint LSN C from ibdata1.
      2. Replays all redo records with LSN > C (including L).
      3. T is fully re-applied. □

    QED: No committed transaction is lost on crash. □

13.3 Read Repair & Anti-Entropy
────────────────────────────────
Read Repair (for eventual consistency subsystems):
  When a read is served from a replica and the result is compared against
  the Primary (e.g., during a consistency audit), any divergence triggers
  an automatic repair:
    1. Read request goes to replica: returns product.base_price = 15,000
    2. Background thread reads same row from Primary: returns 14,000
    3. Divergence detected → replica row is stale (replica lag issue)
    4. Repair: UPDATE replica row with Primary value (via replication or direct write)
    5. Log divergence to audit_logs for SRE review.

Anti-Entropy (proactive synchronization):
  Nightly job (evt_anti_entropy_check):
    1. pt-table-checksum computes CRC32 of every table on Primary and all replicas.
    2. Any CRC mismatch → pt-table-sync repairs the replica (safe, idempotent).
    3. Mismatches logged → if > 100 rows diverged, PagerDuty alert.
    4. Root cause investigated (usually: skipped replication events, clock skew).

13.4 Backup Strategy — Complete Recovery Matrix
────────────────────────────────────────────────
  ┌───────────────────┬────────────────┬───────────┬──────────────────────────┐
  │ Backup Type       │ Frequency      │ Retention │ Tool & Notes             │
  ├───────────────────┼────────────────┼───────────┼──────────────────────────┤
  │ Full backup       │ Weekly Sun 01h │ 4 weeks   │ Percona XtraBackup 8.0   │
  │                   │                │           │ Hot backup, no lock      │
  │ Incremental       │ Every 6 hours  │ 7 days    │ XtraBackup --incremental │
  │                   │                │           │ based on LSN             │
  │ Binary log stream │ Continuous     │ 14 days   │ mysqlbinlog --read-from-  │
  │                   │                │           │ remote-server            │
  │ Logical dump      │ Monthly        │ 6 months  │ mysqldump --single-trans  │
  │                   │                │           │ + gzip → S3              │
  │ Delayed replica   │ Continuous 6h  │ Ongoing   │ SOURCE_DELAY=21600       │
  │                   │ lag            │           │ For accidental DDL undo  │
  └───────────────────┴────────────────┴───────────┴──────────────────────────┘

  Recovery Time Objectives:
    Full restore from snapshot: ~10 min (500 GB, 10 GbE transfer)
    PITR from checkpoint + binlog: ~15 min per hour of data
    Delayed replica promote: < 5 min (just stop replica, promote, redirect)
*/

-- Backup freshness verification (proxy: check last inventory restock time)
SELECT
    'Full backup freshness'             AS check_type,
    MAX(last_restocked_at)             AS last_write_event,
    TIMESTAMPDIFF(HOUR, MAX(last_restocked_at), NOW(3)) AS hours_since_last_write
FROM inventory
UNION ALL
SELECT
    'Oldest active session',
    MIN(created_at),
    TIMESTAMPDIFF(HOUR, MIN(created_at), NOW(3))
FROM user_sessions WHERE is_active = 1;

-- InnoDB redo log status
SHOW GLOBAL STATUS LIKE 'Innodb_redo_log%';
SHOW GLOBAL VARIABLES LIKE 'innodb_redo_log_capacity';


-- ################################################################################
-- SECTION 14: SECURITY ARCHITECTURE
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
14. SECURITY ARCHITECTURE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

14.1 Defence in Depth — 6 Layers
──────────────────────────────────
  Layer 1 — Perimeter:  CloudFlare WAF, DDoS protection, TLS termination.
  Layer 2 — Network:    Private VPC; MySQL not reachable from internet.
                        Security groups: port 3306 open only to ProxySQL IPs.
  Layer 3 — Transport:  TLS 1.3 on all MySQL connections (require_secure_transport=ON).
                        mTLS between application pods and ProxySQL.
  Layer 4 — Application: MySQL 8 native RBAC (5 roles: admin, seller, customer, analyst, support).
                         Stored procedures enforce business rules; direct table DML denied.
  Layer 5 — Data:       AES-256 column encryption for PII (phone, bank account, IP).
                        InnoDB Transparent Data Encryption for full tablespace.
                        Encryption keys in HashiCorp Vault; rotated every 90 days.
  Layer 6 — Audit:      Append-only audit_logs; fraud_logs; login_attempts.
                        Every schema change logged via MySQL Enterprise Audit Plugin.
                        SIEM integration (Splunk / ELK) via audit log streaming.

14.2 Privilege Escalation Prevention
──────────────────────────────────────
  MySQL 8 ROLE system prevents horizontal and vertical privilege escalation:

  eth_customer ROLE:
    EXECUTE on sp_place_order, sp_process_payment, sp_cancel_order
    SELECT on vw_order_detail (own orders only — row-level via WHERE customer_id = CURRENT_USER_ID())
    No direct SELECT/INSERT/UPDATE on base tables.

  eth_seller ROLE:
    EXECUTE on sp_restock_inventory, sp_cancel_order
    SELECT on vw_seller_performance, vw_low_stock_alert
    SELECT on products WHERE seller_id = OWN_SELLER_ID (enforced by app layer)

  eth_analyst ROLE:
    SELECT ONLY on all vw_* views and analytics tables.
    NO access to users, payments, user_addresses (PII tables).

  eth_admin ROLE:
    ALL PRIVILEGES but NO GRANT OPTION.
    Admin actions require MFA verification.
    All admin queries logged to audit_logs with action='ADMIN_QUERY'.

  Super account (root) disabled on all replicas; only accessible at primary via
  physical console or VPN jump host with hardware token authentication.

14.3 SQL Injection Prevention
───────────────────────────────
  All application queries use parameterized statements (prepared statements).
  Stored procedures receive typed parameters (no dynamic SQL).
  The only dynamic SQL in the system is in sp_place_order for optional coupon
  validation — this uses a whitelist regex: ^[A-Z0-9_-]{4,20}$.

14.4 Encryption Key Architecture
──────────────────────────────────
  Key hierarchy:
    Master Key (MK)       : Stored in HashiCorp Vault (never in application code)
    Data Encryption Keys  : Derived per-table using HKDF(MK, table_name, "v1")
    Column Keys           : Derived per-column: HKDF(DEK, column_name, user_id)

  Usage in SQL (conceptual):
    -- Encrypt phone number on write:
    AES_ENCRYPT(phone_number, UNHEX(SHA2(CONCAT(vault_key, user_id), 256)))
    -- Decrypt on read (only available to eth_admin and eth_support):
    AES_DECRYPT(phone_number, UNHEX(SHA2(CONCAT(vault_key, user_id), 256)))

  Key rotation (zero-downtime):
    UPDATE users SET phone_number =
        AES_ENCRYPT(
            AES_DECRYPT(phone_number, old_key_bytes),
            new_key_bytes
        )
    WHERE user_id BETWEEN @batch_start AND @batch_end;
    -- Runs in 10,000-row batches; entire rotation completes in < 2 hours for 10M users.
*/

-- Security audit: accounts with privilege anomalies
SELECT
    u.email,
    ur.role_code,
    u.account_status,
    u.failed_login_cnt,
    u.lockout_until,
    COUNT(la.attempt_id) AS failed_logins_7d
FROM users u
JOIN user_roles ur ON ur.role_id = u.role_id
LEFT JOIN login_attempts la
    ON la.user_id = u.user_id
   AND la.status  = 'FAILED'
   AND la.attempted_at >= DATE_SUB(NOW(), INTERVAL 7 DAY)
WHERE u.deleted_at IS NULL
  AND u.account_status != 'SUSPENDED'
GROUP BY u.user_id
HAVING failed_logins_7d >= 5
ORDER BY failed_logins_7d DESC;

-- Encrypted column verification (all VARBINARY columns = encrypted)
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'eth_ecommerce'
  AND DATA_TYPE = 'varbinary'
ORDER BY TABLE_NAME, COLUMN_NAME;


-- ################################################################################
-- SECTION 15: OBSERVABILITY — METRICS, ALERTS & SLOs
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
15. OBSERVABILITY — METRICS, ALERTS & SLOs
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

15.1 Key Prometheus Metrics (collected via mysqld_exporter)
────────────────────────────────────────────────────────────
  mysql_global_status_threads_running            [gauge]   Active query threads
  mysql_global_status_innodb_row_lock_waits_total [counter] Lock contention rate
  mysql_global_status_innodb_deadlocks_total      [counter] Deadlock frequency
  mysql_global_status_slow_queries_total          [counter] Slow query rate
  mysql_slave_status_seconds_behind_master        [gauge]   Replication lag (s)
  mysql_global_status_innodb_buffer_pool_read_requests [counter] Cache reads
  mysql_global_status_innodb_buffer_pool_reads    [counter] Disk reads (cache miss)
  mysql_global_status_connections                 [counter] Total connections
  mysql_global_status_queries                     [counter] QPS
  mysql_global_status_com_select                  [counter] SELECT rate
  mysql_global_status_com_insert                  [counter] INSERT rate
  mysql_global_status_com_update                  [counter] UPDATE rate
  mysql_global_status_com_delete                  [counter] DELETE rate

15.2 Alert Rules (Prometheus Alertmanager)
────────────────────────────────────────────
  CRITICAL Alerts (PagerDuty page, immediate response):
  ┌────────────────────────────────────┬──────────────────────────────────────┐
  │ Alert                              │ Condition                            │
  ├────────────────────────────────────┼──────────────────────────────────────┤
  │ PrimaryDown                        │ mysql_up == 0 for Primary node       │
  │ ReplicationLagCritical             │ seconds_behind_master > 300 (5 min)  │
  │ SemiSyncFallback                   │ rpl_semi_sync_master_status == OFF   │
  │ BufferPoolHitRateLow               │ hit_rate < 95% for 5 minutes         │
  │ DeadlockRateHigh                   │ deadlocks > 10 per minute            │
  │ XATransactionStuck                 │ XA RECOVER returns rows > 5 minutes  │
  │ SagaStuck                          │ saga_log.status=IN_PROGRESS > 10 min │
  └────────────────────────────────────┴──────────────────────────────────────┘

  WARNING Alerts (Slack notification, investigate within 1 hour):
  ┌────────────────────────────────────┬──────────────────────────────────────┐
  │ Alert                              │ Condition                            │
  ├────────────────────────────────────┼──────────────────────────────────────┤
  │ ReplicationLagWarning              │ seconds_behind_master > 60 (1 min)   │
  │ SlowQueryRateHigh                  │ slow_queries > 100 per minute        │
  │ ConnectionPoolNearLimit            │ connections > 80% of max_connections │
  │ LockWaitRateHigh                   │ lock_waits > 50 per minute           │
  │ InventoryHotspot                   │ single inventory row > 100 txns/min  │
  │ FraudRateSpiking                   │ fraud_logs inserts > 50 per minute   │
  │ OutboxEventBacklog                 │ unpublished outbox_events > 1,000    │
  └────────────────────────────────────┴──────────────────────────────────────┘

15.3 SLO / SLA Definitions
────────────────────────────
  Service Level Objectives (what we promise internally to engineering):

  SLO 1 — Availability:
    target: 99.95% uptime per month
    error budget: 0.05% = 21.9 minutes/month
    measurement: (total_minutes - downtime_minutes) / total_minutes × 100

  SLO 2 — Payment Latency:
    target: 99th percentile of sp_process_payment < 200ms
    measurement: histogram_quantile(0.99, mysql_statement_duration_seconds)

  SLO 3 — Order Success Rate:
    target: > 99.5% of sp_place_order calls succeed (no error returned)
    error budget: 0.5% = 5 failures per 1,000 attempts
    measurement: (successful_orders / attempted_orders) × 100

  SLO 4 — Replication Freshness:
    target: 99.9% of read queries see data no older than 1 second
    measurement: % of reads where replica_lag < 1s

  Service Level Agreement (contractual with business):
    SLA: 99.9% uptime (43.8 min downtime/month)  [public commitment]
    SLO: 99.95% uptime                           [internal target; buffer for SLA]
    Penalty: if SLA breached → automatic credit to seller partners per contract.
*/

-- SLO dashboard query — order success rate last 24 hours
SELECT
    HOUR(o.placed_at)                            AS hour_of_day,
    COUNT(o.order_id)                            AS total_attempts,
    SUM(IF(o.payment_status = 'CAPTURED', 1, 0)) AS successful_orders,
    SUM(IF(o.payment_status = 'FAILED',   1, 0)) AS failed_orders,
    ROUND(SUM(IF(o.payment_status = 'CAPTURED', 1, 0)) * 100.0 /
          NULLIF(COUNT(o.order_id), 0), 3)       AS success_rate_pct,
    ROUND(AVG(TIMESTAMPDIFF(MILLISECOND, o.placed_at, o.confirmed_at)), 1)
                                                 AS avg_confirm_ms
FROM orders o
WHERE o.placed_at >= DATE_SUB(NOW(), INTERVAL 24 HOUR)
  AND o.deleted_at IS NULL
GROUP BY HOUR(o.placed_at)
ORDER BY HOUR(o.placed_at);

-- Replication freshness proxy: audit log insert recency
SELECT
    COUNT(*)                                          AS audit_events_last_min,
    MAX(created_at)                                   AS last_audit_event,
    TIMESTAMPDIFF(MILLISECOND, MAX(created_at), NOW(3)) AS ms_since_last_write,
    IF(TIMESTAMPDIFF(SECOND, MAX(created_at), NOW(3)) > 60,
        'ALERT: No writes in 60 seconds', 'OK')       AS status
FROM audit_logs
WHERE created_at >= DATE_SUB(NOW(), INTERVAL 1 MINUTE);


-- ################################################################################
-- SECTION 16: CAPACITY PLANNING & STORAGE PROJECTIONS
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
16. CAPACITY PLANNING & STORAGE PROJECTIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

16.1 Hardware Sizing — Per Shard Node
──────────────────────────────────────
  Primary Node (write-optimized):
    CPU:  32 cores, AMD EPYC 7543 or AWS r6g.8xlarge
    RAM:  256 GB   (innodb_buffer_pool_size = 200 GB)
    Disk: 4× 3.84 TB Samsung PM9A3 NVMe in RAID 10 → 7.68 TB usable
          Random read: 800K IOPS, Write: 200K IOPS
    NIC:  25 GbE   (replication bandwidth headroom: 5 GB/s)

  Replica Nodes (read-optimized):
    CPU:  16 cores
    RAM:  128 GB   (buffer pool: 96 GB)
    Disk: 2× 3.84 TB NVMe SSD
    NIC:  10 GbE

  innodb_io_capacity         = 2000   (SSD IOPS budget for background flush)
  innodb_io_capacity_max     = 8000   (burst IOPS for catch-up)
  innodb_read_io_threads     = 8
  innodb_write_io_threads    = 8
  innodb_flush_neighbors     = 0      (SSD: no benefit from flushing neighbors)
  innodb_log_file_size       = 2G     (per redo log file; 2 files = 4GB total)

16.2 Storage Growth Model (Mathematical)
──────────────────────────────────────────
  Variables:
    U  = monthly active users
    OPU = orders per user per month = 2.5 (average)
    IPI = items per order = 2.8 (average)
    RPO = order row size = 350 bytes
    RPI = order_item row size = 220 bytes

  Orders per month M:  N(M) = U × OPU
  Storage per month S: S(M) = N(M) × (RPO + IPI × RPI) × IndexMultiplier(1.6)

  Year-by-year projection:
  ┌──────┬────────────┬──────────────┬─────────────┬─────────────┬───────────────┐
  │ Year │ MAU        │ Orders/month │ Orders Table│ All Tables  │ Action        │
  ├──────┼────────────┼──────────────┼─────────────┼─────────────┼───────────────┤
  │  1   │ 1,000,000  │   2,500,000  │   14 GB/yr  │   250 GB/yr │ 4 shards OK   │
  │  2   │ 4,000,000  │  10,000,000  │   55 GB/yr  │   900 GB/yr │ Add replicas  │
  │  3   │ 10,000,000 │  25,000,000  │  140 GB/yr  │  2.2 TB/yr  │ 8 shards      │
  │  4   │ 20,000,000 │  50,000,000  │  280 GB/yr  │  4.4 TB/yr  │ 12 shards     │
  │  5   │ 50,000,000 │ 125,000,000  │  700 GB/yr  │ 11.0 TB/yr  │ 16 shards+arch│
  └──────┴────────────┴──────────────┴─────────────┴─────────────┴───────────────┘

  Action trigger: add new shards when any shard exceeds 2 TB data size.
  Archive trigger: orders older than 2 years archived to cold storage (S3 Glacier).

16.3 Connection Pool Sizing (Little's Law)
───────────────────────────────────────────
  Little's Law: L = λ × W
    L = average number of requests in the system (connections needed)
    λ = arrival rate (QPS)
    W = average time a request holds a connection

  At normal load:
    λ = 12,000 QPS, W = 10ms average (reads: 5ms, writes: 30ms weighted)
    L = 12,000 × 0.010 = 120 active connections needed
    With 20% headroom: pool size = 150 connections to MySQL

  At Enkutatash peak:
    λ = 85,000 QPS, W = 15ms (higher write ratio during sale)
    L = 85,000 × 0.015 = 1,275 connections needed
    → ProxySQL multiplexing: 4,000 frontend ↔ 1,300 MySQL backend connections
    → MySQL max_connections = 1,500 (includes replication threads, monitoring)
*/

-- Capacity: current table sizes
SELECT
    TABLE_NAME                                            AS tbl,
    FORMAT(TABLE_ROWS, 0)                                 AS est_rows,
    ROUND(DATA_LENGTH    / 1024 / 1024 / 1024, 3)        AS data_gb,
    ROUND(INDEX_LENGTH   / 1024 / 1024 / 1024, 3)        AS index_gb,
    ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024 / 1024, 3) AS total_gb,
    ROUND(INDEX_LENGTH * 100.0 /
          NULLIF(DATA_LENGTH + INDEX_LENGTH, 0), 1)       AS index_overhead_pct
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'eth_ecommerce'
ORDER BY (DATA_LENGTH + INDEX_LENGTH) DESC;

-- Connection pool utilization
SELECT
    VARIABLE_NAME,
    VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME IN (
    'Threads_connected',
    'Threads_running',
    'Max_used_connections',
    'Connection_errors_max_connections',
    'Aborted_connects'
);


-- ################################################################################
-- SECTION 17: NORMALIZATION & INTEGRITY CONSTRAINT PROOFS
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
17. NORMALIZATION & INTEGRITY CONSTRAINT PROOFS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

17.1 Normalization Proof — orders Table
─────────────────────────────────────────
Attributes: {order_id, order_number, customer_id, seller_id, shipping_address_id,
             billing_address_id, warehouse_id, region_id, status_id, payment_method_id,
             subtotal, discount_amount, shipping_fee, tax_amount, total_amount,
             currency, payment_status, coupon_code, notes, placed_at, confirmed_at,
             shipped_at, delivered_at, cancelled_at, deleted_at, updated_at}

Candidate Keys: {order_id}, {order_number}
Primary Key: order_id

FIRST NORMAL FORM (1NF):
  ✓ All attributes are atomic (no repeating groups, no multi-valued attributes).
  ✓ coupon_code is a scalar VARCHAR, not a multi-valued field.
  ✓ No arrays — order_items are in a separate table.

SECOND NORMAL FORM (2NF):
  Requirement: No non-key attribute is partially dependent on any candidate key.
  PK is single-column (order_id) → partial dependency impossible for 1-col PK.
  ✓ 2NF satisfied trivially.

THIRD NORMAL FORM (3NF):
  Requirement: No non-key attribute is transitively dependent on the PK via
               another non-key attribute.
  Check: total_amount = subtotal - discount_amount + shipping_fee + tax_amount
  → total_amount is DERIVED from other attributes. Is this a violation?
  → No: total_amount is a STORED DERIVED attribute for performance and audit purposes.
    It is set ONCE at order creation and never recomputed from components.
    This is an intentional denormalization for financial auditability.
    Alternative: compute total at read time → aggregate overhead on every read.
    Decision: store total_amount (denormalized) ✓, document the rationale.

  Check: Does any non-key attribute determine another?
  shipping_fee depends on (warehouse_id, shipping_address_id, order weight)
  → shipping_fee is set at order time as a snapshot; not computed from FKs.
  → No transitive dependency exists at the schema level. ✓
  3NF: SATISFIED ✓

BOYCE-CODD NORMAL FORM (BCNF):
  Requirement: For every non-trivial FD X → Y, X must be a superkey.
  Candidate keys: {order_id}, {order_number}
  All FDs in the table are of the form: order_id → attribute or order_number → attribute.
  Both order_id and order_number are candidate keys (superkeys). ✓
  BCNF: SATISFIED ✓

17.2 Normalization — variant_attributes (Junction Table)
─────────────────────────────────────────────────────────
Relation: variant_attributes(variant_id, attr_value_id)
  This is a pure M:N junction table.
  PK: (variant_id, attr_value_id)
  FDs: only the trivial FD (variant_id, attr_value_id) → {}
  BCNF: Trivially satisfied. ✓

17.3 Integrity Constraints Summary
────────────────────────────────────
  Entity Integrity:
    Every table has a PRIMARY KEY (declared NOT NULL).
    AUTO_INCREMENT on numeric PKs ensures uniqueness without application coordination.
    PKs on Snowflake-generated IDs are application-enforced unique globally.

  Referential Integrity:
    All FOREIGN KEY constraints declared with explicit ON DELETE and ON UPDATE actions.
    Critical FKs use ON DELETE RESTRICT (prevent orphan deletion).
    Cascade deletes used only where orphans have no independent meaning (product_images).
    Cross-shard FKs enforced at application layer (Section 7.3).

  Domain Constraints:
    CHECK (base_price >= 0) on products.
    CHECK (quantity_on_hand >= 0) on inventory.
    CHECK (quantity_on_hand >= reserved_quantity) on inventory.
    CHECK (rating BETWEEN 1 AND 5) on product_reviews.
    CHECK (risk_score BETWEEN 0 AND 100) on fraud_logs.
    ENUM types enforce domain for status columns.

  Business Rule Constraints:
    Trigger trg_order_state_machine: enforces legal order state transitions.
    Trigger trg_inventory_anti_oversell: prevents reserved_quantity > quantity_on_hand.
    Trigger trg_payment_idempotency: enforced by UNIQUE(idempotency_key) on payments.
    Trigger trg_review_one_per_purchase: UNIQUE(order_id, product_id) on product_reviews.
*/

-- Normalization verification: detect any multi-valued columns (should return 0)
SELECT
    TABLE_NAME,
    COLUMN_NAME,
    DATA_TYPE
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'eth_ecommerce'
  AND DATA_TYPE IN ('SET')   -- SET type allows multi-valued → would violate 1NF
ORDER BY TABLE_NAME;          -- Should return 0 rows ✓

-- Check constraint verification
SELECT
    tc.TABLE_NAME,
    tc.CONSTRAINT_NAME,
    cc.CHECK_CLAUSE
FROM information_schema.TABLE_CONSTRAINTS tc
JOIN information_schema.CHECK_CONSTRAINTS cc
    ON cc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
   AND cc.CONSTRAINT_NAME   = tc.CONSTRAINT_NAME
WHERE tc.TABLE_SCHEMA    = 'eth_ecommerce'
  AND tc.CONSTRAINT_TYPE = 'CHECK'
ORDER BY tc.TABLE_NAME;

-- Foreign key action verification
SELECT
    kcu.TABLE_NAME,
    kcu.COLUMN_NAME,
    kcu.REFERENCED_TABLE_NAME,
    kcu.REFERENCED_COLUMN_NAME,
    rc.DELETE_RULE,
    rc.UPDATE_RULE
FROM information_schema.KEY_COLUMN_USAGE kcu
JOIN information_schema.REFERENTIAL_CONSTRAINTS rc
    ON rc.CONSTRAINT_NAME   = kcu.CONSTRAINT_NAME
   AND rc.CONSTRAINT_SCHEMA = kcu.CONSTRAINT_SCHEMA
WHERE kcu.TABLE_SCHEMA          = 'eth_ecommerce'
  AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
ORDER BY kcu.TABLE_NAME, kcu.COLUMN_NAME;


-- ################################################################################
-- SECTION 18: CONCLUSION, RISK REGISTER & ROADMAP
-- ################################################################################
/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
18. CONCLUSION, RISK REGISTER & ROADMAP
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

18.1 Architecture Summary — Five Core Principles
──────────────────────────────────────────────────
  1. DATA LOCALITY: Geographic sharding (RANGE by region_id) ensures 95%+ of
     OLTP queries are local to one shard. Consistent hashing enables resharding
     with minimal data movement (O(1/N) per added shard).

  2. FINANCIAL INTEGRITY: Every money-touching operation uses:
     - Snowflake IDs (globally unique across shards)
     - Idempotency keys (UNIQUE constraint prevents double-charge)
     - SELECT ... FOR UPDATE (prevents overselling)
     - Semi-synchronous replication (data on 2 nodes before ACK)
     - ACID stored procedures with explicit ROLLBACK on every error path

  3. GRACEFUL DEGRADATION: CP for money, AP for catalog.
     The system fails safely: if a shard is unavailable, reads degrade to
     stale replica data; writes fail with a clear error message rather
     than silently accepting inconsistent state.

  4. ZERO-DOWNTIME OPERATIONS: gh-ost for schema migrations (< 1s lock),
     Orchestrator for failover (< 30s), Saga for cross-shard transactions
     (no global locks), consistent hashing for resharding (no downtime).

  5. OBSERVABLE BY DESIGN: Every stored procedure records an audit_log entry.
     Every distributed operation records a saga_log entry. Every unpublished
     event has an outbox_events row. No silent failures.

18.2 Risk Register
───────────────────
  ┌──────────────────────────────┬────────┬────────┬───────────────────────────────┐
  │ Risk                         │ Prob.  │ Impact │ Mitigation                    │
  ├──────────────────────────────┼────────┼────────┼───────────────────────────────┤
  │ Inter-city fiber cut         │ HIGH   │ HIGH   │ Regional shard independence;   │
  │                              │        │        │ local replica serves reads     │
  ├──────────────────────────────┼────────┼────────┼───────────────────────────────┤
  │ Flash sale thundering herd   │ HIGH   │ HIGH   │ Redis atomic DECRBY shield;   │
  │ (inventory hot row)          │        │        │ load shedding at ProxySQL     │
  ├──────────────────────────────┼────────┼────────┼───────────────────────────────┤
  │ Replication lag spike        │ MEDIUM │ MEDIUM │ Semi-sync for payments;       │
  │ (replica far behind)         │        │        │ sticky primary reads after    │
  │                              │        │        │ write for 2× lag seconds      │
  ├──────────────────────────────┼────────┼────────┼───────────────────────────────┤
  │ Accidental DROP TABLE        │ MEDIUM │ HIGH   │ Delayed replica 6h lag; PITR  │
  │                              │        │        │ < 15 min recovery; daily drill│
  ├──────────────────────────────┼────────┼────────┼───────────────────────────────┤
  │ Snowflake clock skew         │ MEDIUM │ MEDIUM │ NTP sync < 10ms; ID monoton.  │
  │ (duplicate IDs if clock back)│        │        │ enforced; sequence always inc.│
  ├──────────────────────────────┼────────┼────────┼───────────────────────────────┤
  │ Consistent hashing skew      │ LOW    │ MEDIUM │ 256 vnodes per shard evens    │
  │ (uneven token ring)          │        │        │ distribution; monitor monthly │
  ├──────────────────────────────┼────────┼────────┼───────────────────────────────┤
  │ Encryption key compromise    │ LOW    │ HIGH   │ Vault; rotation 90d; split-   │
  │                              │        │        │ key custody for MK            │
  ├──────────────────────────────┼────────┼────────┼───────────────────────────────┤
  │ Saga stuck (orphan TX)       │ LOW    │ MEDIUM │ 5-min watchdog; auto-         │
  │                              │        │        │ compensate; PagerDuty alert   │
  └──────────────────────────────┴────────┴────────┴───────────────────────────────┘

18.3 Scaling Roadmap
─────────────────────
  Phase 1 — Launch (0–1M users, 4 shards):
    ✓ MySQL Primary + 3 replicas per shard
    ✓ ProxySQL R/W splitting
    ✓ Snowflake IDs, Saga, outbox pattern
    ✓ gh-ost for DDL migrations
    → Target: 12,000 QPS / 1,500 TPS

  Phase 2 — Growth (1M–10M users, 4–8 shards):
    → Redis Cluster for inventory shield (flash sales)
    → Elasticsearch for product search (replace MySQL FULLTEXT)
    → ClickHouse analytics cluster (multi-source from all shards)
    → Read replica per shard increased to 3
    → Consistent hashing resharding: 4 → 8 shards
    → Target: 50,000 QPS / 6,000 TPS

  Phase 3 — Scale (10M–25M users, 8–16 shards):
    → Vitess: transparent MySQL sharding middleware
    → CQRS: separate read models for analytics and search
    → Event sourcing for order state machine
    → Kafka event bus replaces direct outbox polling
    → Target: 200,000 QPS / 20,000 TPS

  Phase 4 — Enterprise (25M–50M+ users, 16+ shards):
    → Database-per-microservice where bounded contexts allow
    → NewSQL (TiDB / CockroachDB) evaluation for global consistency
    → Active-active multi-region replication (conflict-free)
    → Aurora Limitless or Spanner for global financial ledger
    → Target: 1,000,000 QPS / 100,000 TPS

18.4 Final Self-Review — Known Weaknesses & Honest Limitations
──────────────────────────────────────────────────────────────
  1. Cross-shard queries are expensive. The GSI partially mitigates this,
     but a seller with orders in all regions still requires fan-out for
     unindexed queries. Long-term fix: Vitess global tables.

  2. Saga eventual consistency means a customer CAN see a placed order
     before inventory is confirmed deducted (window: < 100ms typically,
     < 2s under load). Acceptable but must be surfaced to users clearly.

  3. Semi-sync fallback to async (on replica timeout) reduces RPO from
     < 5 seconds to "potentially minutes" during the async window.
     Mitigation: alert fires immediately; SRE can pause writes if needed.

  4. Consistent hashing resharding still requires data migration (just less
     of it than MOD-N). During resharding, the moved token range's data is
     in dual-write mode → 2× write amplification temporarily.

  5. MySQL is not natively designed for global distributed transactions.
     As the platform reaches 25M+ users, a purpose-built distributed SQL
     system (TiDB, CockroachDB, Spanner) should be seriously evaluated.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
END OF ADVANCED DISTRIBUTED DATABASE DESIGN REPORT
Ethiopia E-Commerce Platform — Version 2.0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
*/

-- Final system health snapshot
SELECT
    'DISTRIBUTED SYSTEM HEALTH — ADVANCED REPORT'  AS title,
    NOW(3)                                          AS generated_at,
    @@hostname                                      AS this_node,
    @@server_id                                     AS mysql_server_id,
    @@gtid_mode                                     AS gtid_mode,
    @@binlog_format                                 AS binlog_format,
    @@innodb_buffer_pool_size / 1024/1024/1024      AS buffer_pool_gb,
    @@max_connections                               AS max_connections;

-- ################################################################################
-- END OF FILE: 11_distributed_db_design_report.sql
-- ################################################################################
