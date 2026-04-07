-- =============================================================================
-- DISTRIBUTED ARCHITECTURE, PARTITIONING & SHARDING
-- File: 09_distributed_arch.sql
-- Topics:
--   1. Range partitioning — orders (by year/month)
--   2. Range partitioning — audit_logs (by month)
--   3. List partitioning — login_attempts (by month)
--   4. Horizontal fragmentation strategy (by region)
--   5. Replication topology
--   6. Connection pooling (ProxySQL)
--   7. Sharding strategy
--   8. CAP theorem trade-offs
--   9. Backup strategy
--  10. Failure recovery & WAL concept
-- =============================================================================

USE eth_ecommerce;

-- =============================================================================
-- PART 1: TABLE PARTITIONING
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1.1  Orders Table — RANGE partitioning by placed_at (YEAR/QUARTER)
-- ---------------------------------------------------------------------------
-- Strategy: Partition by UNIX timestamp of placed_at to allow efficient
-- pruning of historical data and parallel scans per quarter.
--
-- Production note: ALTER TABLE to add partitioning must be done during
-- maintenance window on large tables. For new tables, define at creation.
-- ---------------------------------------------------------------------------

-- Recreate orders with partitioning (template; run after 01_schema_ddl.sql)
-- In practice, use ALTER TABLE orders PARTITION BY RANGE (...)

-- Example partition definition (append to CREATE TABLE orders):
/*
PARTITION BY RANGE (UNIX_TIMESTAMP(placed_at)) (
    PARTITION p_before_2026    VALUES LESS THAN (UNIX_TIMESTAMP('2026-01-01 00:00:00')),
    PARTITION p_2026_q1        VALUES LESS THAN (UNIX_TIMESTAMP('2026-04-01 00:00:00')),
    PARTITION p_2026_q2        VALUES LESS THAN (UNIX_TIMESTAMP('2026-07-01 00:00:00')),
    PARTITION p_2026_q3        VALUES LESS THAN (UNIX_TIMESTAMP('2026-10-01 00:00:00')),
    PARTITION p_2026_q4        VALUES LESS THAN (UNIX_TIMESTAMP('2027-01-01 00:00:00')),
    PARTITION p_2027_q1        VALUES LESS THAN (UNIX_TIMESTAMP('2027-04-01 00:00:00')),
    PARTITION p_future         VALUES LESS THAN MAXVALUE
);
*/

-- Add quarterly partition for next quarter (run in scheduled maintenance):
-- ALTER TABLE orders ADD PARTITION (
--     PARTITION p_2027_q2 VALUES LESS THAN (UNIX_TIMESTAMP('2027-07-01 00:00:00'))
-- );

-- Drop old partitions (archive first!):
-- ALTER TABLE orders DROP PARTITION p_before_2026;

-- ---------------------------------------------------------------------------
-- 1.2  Audit Logs — RANGE partitioning by month
-- ---------------------------------------------------------------------------
/*
PARTITION BY RANGE (YEAR(created_at) * 100 + MONTH(created_at)) (
    PARTITION p_audit_202601  VALUES LESS THAN (202602),
    PARTITION p_audit_202602  VALUES LESS THAN (202603),
    PARTITION p_audit_202603  VALUES LESS THAN (202604),
    PARTITION p_audit_202604  VALUES LESS THAN (202605),
    PARTITION p_audit_202605  VALUES LESS THAN (202606),
    PARTITION p_audit_202606  VALUES LESS THAN (202607),
    PARTITION p_audit_202607  VALUES LESS THAN (202608),
    PARTITION p_audit_202608  VALUES LESS THAN (202609),
    PARTITION p_audit_202609  VALUES LESS THAN (202610),
    PARTITION p_audit_202610  VALUES LESS THAN (202611),
    PARTITION p_audit_202611  VALUES LESS THAN (202612),
    PARTITION p_audit_202612  VALUES LESS THAN (202701),
    PARTITION p_audit_future  VALUES LESS THAN MAXVALUE
);
*/

-- ---------------------------------------------------------------------------
-- 1.3  Login Attempts — RANGE partitioning by month (same pattern)
-- ---------------------------------------------------------------------------
/*
PARTITION BY RANGE (YEAR(attempted_at) * 100 + MONTH(attempted_at)) (
    PARTITION p_login_202601  VALUES LESS THAN (202602),
    PARTITION p_login_202602  VALUES LESS THAN (202603),
    -- ... continue quarterly
    PARTITION p_login_future  VALUES LESS THAN MAXVALUE
);
*/

-- Query with partition pruning — MySQL selects only relevant partitions:
EXPLAIN
SELECT COUNT(*) FROM orders
WHERE placed_at BETWEEN '2026-01-01' AND '2026-03-31 23:59:59';
-- With partitioning: only p_2026_q1 is scanned (partition pruning)
-- Without partitioning: full table scan

-- =============================================================================
-- PART 2: HORIZONTAL FRAGMENTATION (SHARDING) STRATEGY
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Strategy A: Geographic Sharding (by region_id)
-- ---------------------------------------------------------------------------
-- Shard 1 (AA_SHARD):   region_id IN (1, 9, 10, 11, 12) — Addis Ababa
-- Shard 2 (CENTRAL):    region_id IN (2, 3)              — Adama, Hawassa
-- Shard 3 (EAST):       region_id IN (4, 5)              — Dire Dawa, Mekele
-- Shard 4 (NORTH_WEST): region_id IN (6, 7, 8)           — Bahir Dar, Jimma, Gondar
--
-- Routing logic (application layer / ProxySQL):
-- SELECT shard_id FROM shard_map WHERE region_id = ?
--
-- Benefits:
--   - Data locality: Addis orders stay in Addis shard → lower latency
--   - Compliance: regional data residency requirements
--   - Hot spot management: Addis (~70% of traffic) gets dedicated larger shard
--
-- Drawbacks:
--   - Cross-shard queries (e.g., nationwide reports) require scatter-gather
--   - Uneven growth if one city explodes in traffic

-- ---------------------------------------------------------------------------
-- Strategy B: User-ID Range Sharding (simpler for global operations)
-- ---------------------------------------------------------------------------
-- Shard 1: user_id 1 - 10,000,000
-- Shard 2: user_id 10,000,001 - 20,000,000
-- Shard 3: user_id 20,000,001 - 30,000,000
-- Shard 4: user_id 30,000,001+
--
-- Benefits:
--   - Uniform distribution (assuming sequential IDs with Snowflake/UUID)
--   - Simple routing: shard = FLOOR(user_id / 10_000_000)
--
-- Drawbacks:
--   - Hot shard: newest shard gets all writes
--   - Solution: use hash sharding → shard = user_id % num_shards

-- ---------------------------------------------------------------------------
-- Strategy C (Recommended): Consistent Hash Sharding
-- ---------------------------------------------------------------------------
-- shard = CONSISTENT_HASH(user_id) % num_shards
-- Virtual nodes allow rebalancing without full resharding
-- ProxySQL + Vitess or PlanetScale support this natively

-- =============================================================================
-- PART 3: REPLICATION TOPOLOGY
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 3.1  Production Replication Setup
-- ---------------------------------------------------------------------------
-- PRIMARY (Write master) → located in Addis Ababa DC
-- REPLICA 1 (Read replica, async) → Addis Ababa (hot standby, failover)
-- REPLICA 2 (Read replica, async) → Hawassa DC (regional reads for South)
-- REPLICA 3 (Read replica, async) → Adama DC (regional reads for Central)
-- REPLICA 4 (Delayed replica, 6h) → for accidental data recovery
--
-- Replication type: GTID-based (MySQL 8 default)
-- binlog_format: ROW (required for full consistency)

-- Setup commands (run on Primary as root):
-- CHANGE REPLICATION SOURCE TO
--     SOURCE_HOST='primary.db.ethmarket.internal',
--     SOURCE_USER='eth_replicator',
--     SOURCE_PASSWORD='<<REPLICATION_STRONG_PASSWORD>>',
--     SOURCE_AUTO_POSITION=1;
-- START REPLICA;

-- ---------------------------------------------------------------------------
-- 3.2  Semi-synchronous Replication (for financial tables)
-- ---------------------------------------------------------------------------
-- For payments and orders tables, use semi-sync to prevent data loss:
-- SET GLOBAL rpl_semi_sync_source_enabled = 1;
-- SET GLOBAL rpl_semi_sync_replica_enabled = 1;
-- SET GLOBAL rpl_semi_sync_source_wait_for_replica_count = 1;
-- SET GLOBAL rpl_semi_sync_source_timeout = 1000; -- 1 second timeout

-- ---------------------------------------------------------------------------
-- 3.3  Read-Write Splitting via ProxySQL
-- ---------------------------------------------------------------------------
-- ProxySQL routes:
--   - SELECT queries         → Read replicas (round-robin)
--   - INSERT/UPDATE/DELETE   → Primary
--   - Transactions           → Primary (pinned for session duration)
--   - Critical reads (FOR UPDATE) → Primary
--
-- ProxySQL config excerpt:
-- mysql_query_rules:
--   - rule_id: 1
--     active: 1
--     match_pattern: "^SELECT .* FOR UPDATE"
--     destination_hostgroup: 1  # Primary
--   - rule_id: 2
--     active: 1
--     match_pattern: "^SELECT"
--     destination_hostgroup: 2  # Replica pool

-- =============================================================================
-- PART 4: CONNECTION POOLING (ProxySQL)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- ProxySQL Configuration Summary
-- ---------------------------------------------------------------------------
-- ProxySQL sits between the application and MySQL nodes.
-- It provides:
--   - Connection multiplexing: 1000 app connections → 100 MySQL connections
--   - Query routing (read/write split)
--   - Query caching for repeated SELECTs
--   - Automatic failover detection
--   - Query mirroring (traffic replay for testing)
--   - Query rewrite rules
--
-- Recommended pool sizes per tier:
--   Primary:            max_connections = 500
--   Each Read Replica:  max_connections = 300
--   ProxySQL:           max_connections = 5000 (app-facing)
--
-- Backend pool settings:
-- INSERT INTO mysql_servers (hostgroup_id, hostname, port, max_connections, weight) VALUES
-- (1, 'primary.db.ethmarket.internal',  3306, 500, 1000),  -- Primary
-- (2, 'replica1.db.ethmarket.internal', 3306, 300, 500),   -- Replica 1 (hot)
-- (2, 'replica2.db.ethmarket.internal', 3306, 300, 400),   -- Replica 2 (Hawassa)
-- (2, 'replica3.db.ethmarket.internal', 3306, 300, 400);   -- Replica 3 (Adama)

-- =============================================================================
-- PART 5: CAP THEOREM TRADE-OFFS
-- =============================================================================

/*
Ethiopia E-Commerce Platform CAP Position:
==========================================

For OLTP operations (orders, payments, inventory):
  CP — Consistency + Partition Tolerance
  Trade-off: Availability suffers during network partitions.
  Justification: Financial transactions MUST be consistent.
                 Double-charging a customer is unacceptable.
                 Short-term unavailability is preferable to inconsistency.

For read-heavy operations (product catalog, reviews, analytics):
  AP — Availability + Partition Tolerance
  Trade-off: Slight stale reads acceptable (read replicas lag 100ms-2s).
  Justification: A customer seeing a slightly outdated product price
                 for 2 seconds is acceptable; the site being down is not.

Consistency Models Used:
  - Orders/Payments:   SERIALIZABLE or REPEATABLE READ + FOR UPDATE
  - Product Catalog:   READ COMMITTED (read replicas)
  - Analytics:         EVENTUAL CONSISTENCY (pre-aggregated tables, 24h lag)
  - Inventory:         REPEATABLE READ + FOR UPDATE (anti-oversell)
  - Sessions:          EVENTUAL CONSISTENCY (session table, READ COMMITTED)

Replication Lag Management:
  - Telebirr payment confirmations: Always read from Primary (critical path)
  - Product search: Read from replica (slight staleness acceptable)
  - Order status: Read from Primary for customer-facing, replica for dashboards
*/

-- =============================================================================
-- PART 6: WRITE-AHEAD LOGGING (WAL) & CRASH RECOVERY
-- =============================================================================

/*
MySQL InnoDB WAL (ib_logfile0, ib_logfile1):
============================================

InnoDB implements WAL through the REDO log:
  1. Every transaction writes REDO records to the in-memory log buffer first.
  2. On COMMIT: log buffer is flushed to ib_logfile* on disk (durable).
  3. Actual data pages may still be "dirty" in the buffer pool.
  4. Background thread (page cleaner) writes dirty pages to tablespace files.

Crash Recovery Scenario:
  - Server crashes after COMMIT but before dirty pages are flushed to disk.
  - On restart: InnoDB reads REDO log → replays all committed transactions.
  - Data is fully recovered. No data loss for committed transactions.

Key MySQL Settings for Durability:
  innodb_flush_log_at_trx_commit = 1   -- Flush log on every COMMIT (gold standard)
  sync_binlog = 1                      -- Sync binary log on every COMMIT
  innodb_doublewrite = ON              -- Prevent torn page writes
  innodb_log_file_size = 2G           -- Larger = less frequent checkpointing

Checkpointing:
  - MySQL automatically checkpoints (flushes dirty pages) to bound recovery time.
  - innodb_log_file_size controls max recovery time: larger file = slower recovery
    but fewer I/O operations during normal operation.
  - Target: recovery in < 60 seconds → tune log file size accordingly.

WAL in Distributed Setup:
  - Binary log (binlog) acts as a distributed WAL.
  - Replicas replay binlog events = distributed log replay.
  - GTID ensures each transaction is applied exactly once.
*/

-- Check current WAL/InnoDB status:
-- SHOW ENGINE INNODB STATUS\G
-- SHOW GLOBAL VARIABLES LIKE 'innodb_flush_log_at_trx_commit';
-- SHOW GLOBAL VARIABLES LIKE 'innodb_log_file_size';

-- =============================================================================
-- PART 7: BACKUP STRATEGY
-- =============================================================================

/*
Backup Plan for Ethiopia E-Commerce Platform:
=============================================

1. FULL BACKUP (Weekly — Sunday 00:00 EAT):
   Tool: MySQL Enterprise Backup (mysqlbackup) or Percona XtraBackup
   Command:
     xtrabackup --backup \
       --host=primary.db.ethmarket.internal \
       --user=eth_backup --password=<<BACKUP_PASSWORD>> \
       --target-dir=/backup/full/$(date +%Y%m%d)
   Retention: 4 weeks
   Storage: Replicated to secondary data center (Hawassa DC)

2. INCREMENTAL BACKUP (Every 6 hours):
   Command:
     xtrabackup --backup --incremental \
       --incremental-basedir=/backup/full/latest \
       --target-dir=/backup/incr/$(date +%Y%m%d_%H%M)
   Retention: 7 days

3. BINARY LOG BACKUP (Continuous — Point-in-Time Recovery):
   mysqlbinlog --read-from-remote-server \
     --host=primary.db.ethmarket.internal \
     --raw --stop-never \
     binlog.000001 > /backup/binlogs/
   This enables recovery to any point in time (PITR).
   Retention: 14 days

4. LOGICAL BACKUP (Monthly — for portability):
   mysqldump --single-transaction --master-data=2 \
     --routines --triggers --events \
     eth_ecommerce > /backup/logical/eth_ecommerce_$(date +%Y%m).sql
   Compressed: gzip -9

Recovery Time Objectives (RTO/RPO):
  RTO: < 15 minutes (with replica promotion)
  RPO: < 5 minutes (semi-sync replication + continuous binlog backup)

RESTORE PROCEDURE:
  Step 1: Promote replica to primary (if primary is down):
    SET GLOBAL read_only = OFF;
    STOP REPLICA;
  Step 2: Restore from latest incremental backup (if replica not available):
    xtrabackup --prepare --apply-log-only --target-dir=/backup/full/latest
    xtrabackup --prepare --target-dir=/backup/full/latest \
      --incremental-dir=/backup/incr/latest
    xtrabackup --copy-back --target-dir=/backup/full/latest
    chown -R mysql:mysql /var/lib/mysql
    systemctl start mysql
  Step 3: Apply binary logs for PITR:
    mysqlbinlog /backup/binlogs/binlog.* | mysql -u root -p eth_ecommerce
*/

-- =============================================================================
-- PART 8: SCALING STRATEGY FOR MILLIONS OF USERS
-- =============================================================================

/*
Scaling Roadmap — Ethiopia E-Commerce Platform:
===============================================

PHASE 1 (0 → 100K users):
  - Single Primary + 2 Read Replicas
  - ProxySQL for connection pooling
  - Redis for session cache and rate limiting
  - CDN for product images (e.g., Cloudflare or AWS CloudFront)
  - Vertical scaling: Primary on 32-core, 256GB RAM machine

PHASE 2 (100K → 1M users):
  - Add partitioned orders and audit_logs tables
  - Implement read-through caching layer (Redis) for product catalog
  - Pre-compute analytics in daily_sales_summary (event-driven)
  - Add Elasticsearch for advanced product search (replace MySQL FULLTEXT)
  - Separate product catalog service (read-heavy) from order service (write-heavy)
  - Geographic sharding: Addis shard + Regional shard

PHASE 3 (1M → 10M users):
  - Microservices extraction: Inventory Service, Payment Service, Catalog Service
  - Each service owns its own database (database-per-service pattern)
  - Kafka for event streaming (order placed → inventory reserved → payment → notification)
  - Distributed tracing (Jaeger/Tempo)
  - Feature flags for gradual rollouts

PHASE 4 (10M+ users):
  - Vitess for MySQL horizontal sharding (transparent to application)
  - Multi-region active-active with CockroachDB or TiDB for global consistency
  - CQRS: separate command (write) and query (read) databases
  - Event sourcing for financial transactions (immutable event log)

Key Bottlenecks to Address:
  - Hot inventory rows (popular products): Use application-level batching + Redis
  - Order number generation: Replace fn_generate_order_number with Snowflake IDs
  - Session table: Move to Redis (sub-millisecond reads, TTL support)
  - Audit logs: Stream to Apache Kafka → long-term storage in ClickHouse

Caching Strategy:
  L1: Application-level in-memory (product metadata, 30s TTL)
  L2: Redis cluster (session, cart, popular products, 5min TTL)
  L3: MySQL read replicas (slow queries, 1-2s replication lag)

Connection Limits at Scale:
  - MySQL Primary: max_connections=2000 (HW limit: ~256GB RAM)
  - ProxySQL: handles 50,000 app connections → 2000 MySQL connections
  - Application pods: each pod maintains 10 ProxySQL connections
  - At 1M RPS peak: 50K concurrent connections → ProxySQL handles this
*/

-- =============================================================================
-- PART 9: SHARD ROUTING HELPER TABLE
-- =============================================================================

-- Shard configuration table (used by application / ProxySQL routing)
CREATE TABLE IF NOT EXISTS shard_map (
    shard_id       TINYINT UNSIGNED PRIMARY KEY,
    shard_name     VARCHAR(50)  NOT NULL,
    dsn_primary    VARCHAR(200) NOT NULL COMMENT 'hostname:port of Primary',
    dsn_replica    VARCHAR(200) NOT NULL COMMENT 'hostname:port of Read Replica',
    region_ids     JSON         NOT NULL COMMENT 'Array of region_ids served by this shard',
    is_active      TINYINT(1)   NOT NULL DEFAULT 1,
    max_user_id    BIGINT UNSIGNED NULL  COMMENT 'For user-ID sharding',
    min_user_id    BIGINT UNSIGNED NULL
) ENGINE=InnoDB COMMENT='Application-layer shard routing map';

INSERT INTO shard_map (shard_id, shard_name, dsn_primary, dsn_replica, region_ids, min_user_id, max_user_id) VALUES
(1, 'AA_SHARD',    'aa-primary.db.ethmarket.internal:3306',  'aa-replica.db.ethmarket.internal:3306',  '[1,9,10,11,12]', 1,         10000000),
(2, 'CENTRAL',     'ct-primary.db.ethmarket.internal:3306',  'ct-replica.db.ethmarket.internal:3306',  '[2,3]',          10000001,  20000000),
(3, 'EAST',        'ea-primary.db.ethmarket.internal:3306',  'ea-replica.db.ethmarket.internal:3306',  '[4,5]',          20000001,  30000000),
(4, 'NORTH_WEST',  'nw-primary.db.ethmarket.internal:3306',  'nw-replica.db.ethmarket.internal:3306',  '[6,7,8]',        30000001,  NULL);

-- Application routing function (conceptual):
-- SELECT dsn_primary FROM shard_map WHERE JSON_CONTAINS(region_ids, CAST(? AS JSON))

-- =============================================================================
-- PART 10: SELF-REVIEW — PRINCIPAL ENGINEER ASSESSMENT
-- =============================================================================

/*
SELF-REVIEW: Weaknesses, Improvements & Scaling Bottlenecks
=============================================================

IDENTIFIED WEAKNESSES:
1. Order number generation (fn_generate_order_number):
   - Current: MAX()+1 query — not safe at high concurrency (race condition).
   - Fix: Use a dedicated atomic sequence table with FOR UPDATE, or Snowflake IDs
     (64-bit timestamp + machine ID + sequence) for guaranteed uniqueness.

2. Inventory table lacks a separate "cart reservation" TTL:
   - If a customer adds to cart but never checks out, reserved_quantity stays locked.
   - Fix: Add reserved_until DATETIME + background job to release expired reservations.

3. Phone number encryption uses a hardcoded key reference:
   - The ETH_MASTER_KEY_PLACEHOLDER must be rotated regularly.
   - Fix: Implement MySQL Keyring Plugin + envelope encryption with key versioning.

4. No outbox pattern for notifications:
   - If the DB commits but the notification service crashes, users miss emails/SMS.
   - Fix: Implement the Transactional Outbox Pattern:
     Write to notifications table in same TX, poll and publish to Kafka separately.

5. JSON columns for items_json in views:
   - Aggregating JSON in a VIEW is expensive. For high traffic, materialize this.
   - Fix: Pre-compute order_summary at insert time; store in a denormalized column.

6. daily_sales_summary uses runner event at midnight:
   - If the event fails, the next day's analytics are stale.
   - Fix: Add retry logic and alerting via sys.schema_events monitoring.

7. No read-your-writes guarantee for replicas:
   - After placing an order, the customer's confirmation page might read from
     a stale replica (replication lag of 100-500ms).
   - Fix: For order confirmation, always route the immediate subsequent read
     to Primary (sticky session to Primary for 2 seconds after write).

8. Soft deletes without index on deleted_at:
   - All queries filtering "deleted_at IS NULL" scan the index; as rows accumulate,
     this becomes inefficient.
   - Fix: Use partial indexes where supported, or a separate archive table pattern.

SCALING BOTTLENECKS:
1. Inventory hot rows: Popular product variants (e.g., iPhone on sale day) will have
   thousands of concurrent FOR UPDATE locks. Use Redis atomic DECR as the primary
   reservation mechanism; write to MySQL async.

2. ORDER writes: At 10K orders/second peak, single Primary becomes bottleneck.
   Solution: Vitess sharding by customer_id.

3. Audit log writes: At scale, audit_logs receive millions of inserts/day.
   Solution: Batch-write to Kafka first; consumer writes to ClickHouse (columnar)
   for analytics, MySQL for operational queries.

4. Full-text search: MySQL FULLTEXT is not horizontally scalable.
   Solution: Sync product data to Elasticsearch/OpenSearch for production search.

RECOMMENDED IMPROVEMENTS (Priority Order):
P1. Replace fn_generate_order_number with Snowflake ID library
P1. Add cart reservation TTL + cleanup job
P1. Implement Redis for session storage (remove user_sessions from MySQL)
P2. Add Elasticsearch sync for product search
P2. Implement Kafka outbox for all external events (notifications, webhooks)
P3. Migrate to Vitess for transparent sharding at 5M+ users
P3. Add ClickHouse for analytics workloads (separate from OLTP)
P3. Implement database-per-service when extracting microservices

SECURITY IMPROVEMENTS:
- Add IP rate limiting at ProxySQL level (not just application layer)
- Implement database activity monitoring (DAM) via MySQL audit plugin
- Rotate encryption keys quarterly via key versioning table
- Add column-level encryption for bank account numbers using application-layer KMS
*/

-- =============================================================================
-- END OF DISTRIBUTED ARCHITECTURE
-- =============================================================================
