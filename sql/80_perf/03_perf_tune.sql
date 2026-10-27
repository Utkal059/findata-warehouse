-- =============================================================================
-- 80_perf/03_perf_tune.sql
-- The physical changes measured by the AFTER run:
--   1. LOCAL bitmap indexes on the fact's dimension keys. Low-cardinality
--      keys on a read-mostly fact are the textbook bitmap case, and LOCAL
--      keeps each index partitioned like the fact, so a monthly partition can
--      be maintained without touching the rest.
--   2. A B-tree on fact_loan_snapshot (snapshot_date, sma_class) for the
--      month-end portfolio questions.
--   3. Optimizer statistics for the warehouse schema (DBMS_STATS).
--   4. Star transformation for the session (bitmap AND of dimension filters).
-- =============================================================================

CREATE BITMAP INDEX fd_dwh.fact_txn_branch_bix   ON fd_dwh.fact_transaction (branch_key)   LOCAL;
CREATE BITMAP INDEX fd_dwh.fact_txn_channel_bix  ON fd_dwh.fact_transaction (channel_key)  LOCAL;
CREATE BITMAP INDEX fd_dwh.fact_txn_category_bix ON fd_dwh.fact_transaction (category_key) LOCAL;
CREATE BITMAP INDEX fd_dwh.fact_txn_customer_bix ON fd_dwh.fact_transaction (customer_key) LOCAL;
CREATE BITMAP INDEX fd_dwh.fact_txn_account_bix  ON fd_dwh.fact_transaction (account_key)  LOCAL;

CREATE INDEX fd_dwh.fact_loan_snap_date_ix ON fd_dwh.fact_loan_snapshot (snapshot_date, sma_class);

BEGIN
  DBMS_STATS.GATHER_SCHEMA_STATS(ownname => 'FD_DWH', cascade => TRUE,
                                 estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
                                 method_opt => 'FOR ALL COLUMNS SIZE AUTO');
END;
/

ALTER SESSION SET star_transformation_enabled = TRUE;
