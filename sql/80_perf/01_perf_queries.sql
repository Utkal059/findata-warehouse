-- =============================================================================
-- 80_perf/01_perf_queries.sql
-- Five business questions used for the BEFORE / AFTER tuning comparison.
-- The SQL text is identical in both runs; only the physical design changes.
-- =============================================================================

CREATE TABLE fd_ops.perf_query (
  query_id     VARCHAR2(10)   NOT NULL,
  description  VARCHAR2(200)  NOT NULL,
  sql_text     CLOB           NOT NULL,
  CONSTRAINT perf_query_pk PRIMARY KEY (query_id)
);

INSERT INTO fd_ops.perf_query VALUES ('Q1',
'Monthly credits vs debits for one region (south Moravia), 1997',
q'[SELECT d.year_month,
       SUM(CASE WHEN f.txn_type = 'CREDIT' THEN f.amount END) AS credits,
       SUM(CASE WHEN f.txn_type = 'DEBIT'  THEN f.amount END) AS debits
  FROM fd_dwh.fact_transaction f
  JOIN fd_dwh.dim_branch b ON b.branch_key = f.branch_key
  JOIN fd_dwh.dim_date d   ON d.date_key = f.date_key
 WHERE b.region = 'south Moravia'
   AND f.txn_date BETWEEN DATE '1997-01-01' AND DATE '1997-12-31'
 GROUP BY d.year_month
 ORDER BY d.year_month]');

INSERT INTO fd_ops.perf_query VALUES ('Q2',
'Card withdrawals by region, Q4 1998',
q'[SELECT b.region, COUNT(*) AS withdrawals, SUM(f.amount) AS amount
  FROM fd_dwh.fact_transaction f
  JOIN fd_dwh.dim_channel ch ON ch.channel_key = f.channel_key
  JOIN fd_dwh.dim_branch b   ON b.branch_key = f.branch_key
 WHERE ch.channel_code = 'CARD_WITHDRAWAL'
   AND f.txn_date BETWEEN DATE '1998-10-01' AND DATE '1998-12-31'
 GROUP BY b.region
 ORDER BY amount DESC]');

INSERT INTO fd_ops.perf_query VALUES ('Q3',
'Top 10 accounts by household (SIPO) payments, 1998',
q'[SELECT a.account_id, b.district_name, SUM(f.amount) AS household_paid, COUNT(*) AS payments
  FROM fd_dwh.fact_transaction f
  JOIN fd_dwh.dim_txn_category c ON c.category_key = f.category_key
  JOIN fd_dwh.dim_account a      ON a.account_key = f.account_key
  JOIN fd_dwh.dim_branch b       ON b.branch_key = f.branch_key
 WHERE c.category_code = 'HOUSEHOLD'
   AND f.txn_date BETWEEN DATE '1998-01-01' AND DATE '1998-12-31'
 GROUP BY a.account_id, b.district_name
 ORDER BY household_paid DESC
 FETCH FIRST 10 ROWS ONLY]');

INSERT INTO fd_ops.perf_query VALUES ('Q4',
'Gold-card holders: credits and debits by month (point-in-time SCD2), 1996',
q'[SELECT d.year_month, COUNT(DISTINCT c.client_id) AS clients,
       SUM(CASE WHEN f.txn_type = 'CREDIT' THEN f.amount END) AS credits,
       SUM(CASE WHEN f.txn_type = 'DEBIT'  THEN f.amount END) AS debits
  FROM fd_dwh.fact_transaction f
  JOIN fd_dwh.dim_customer c ON c.customer_key = f.customer_key
  JOIN fd_dwh.dim_date d     ON d.date_key = f.date_key
 WHERE c.card_tier = 'GOLD'
   AND f.txn_date BETWEEN DATE '1996-01-01' AND DATE '1996-12-31'
 GROUP BY d.year_month
 ORDER BY d.year_month]');

INSERT INTO fd_ops.perf_query VALUES ('Q5',
'Last 90 days of account activity for loans classed NPA at 1998-12-31',
q'[SELECT s.loan_id, s.dpd, COUNT(f.txn_key) AS txns,
       SUM(CASE WHEN f.txn_type = 'CREDIT' THEN f.amount END) AS credits_90d
  FROM fd_dwh.fact_loan_snapshot s
  LEFT JOIN fd_dwh.fact_transaction f
    ON f.account_key = s.account_key
   AND f.txn_date BETWEEN DATE '1998-10-03' AND DATE '1998-12-31'
 WHERE s.snapshot_date = DATE '1998-12-31'
   AND s.sma_class = 'NPA'
 GROUP BY s.loan_id, s.dpd
 ORDER BY s.dpd DESC]');

COMMIT;
