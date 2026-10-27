-- =============================================================================
-- 75_mart/01_mart_views.sql
-- Reporting layer. fd_mart owns views only; fd_report (the BI login) can read
-- these views and nothing else.
-- =============================================================================

GRANT SELECT ON fd_dwh.dim_date           TO fd_mart WITH GRANT OPTION;
GRANT SELECT ON fd_dwh.dim_branch         TO fd_mart WITH GRANT OPTION;
GRANT SELECT ON fd_dwh.dim_account        TO fd_mart WITH GRANT OPTION;
GRANT SELECT ON fd_dwh.dim_customer       TO fd_mart WITH GRANT OPTION;
GRANT SELECT ON fd_dwh.dim_channel        TO fd_mart WITH GRANT OPTION;
GRANT SELECT ON fd_dwh.dim_txn_category   TO fd_mart WITH GRANT OPTION;
GRANT SELECT ON fd_dwh.fact_transaction   TO fd_mart WITH GRANT OPTION;
GRANT SELECT ON fd_dwh.fact_loan_snapshot TO fd_mart WITH GRANT OPTION;
GRANT SELECT ON fd_dwh.fraud_alerts       TO fd_mart WITH GRANT OPTION;
GRANT SELECT ON fd_dwh.rule_config        TO fd_mart WITH GRANT OPTION;

-- Month-level cash flow of the whole bank.
CREATE OR REPLACE VIEW fd_mart.v_monthly_txn_trend AS
SELECT d.year_month,
       COUNT(*)                                                    AS txn_cnt,
       SUM(CASE WHEN f.txn_type = 'CREDIT' THEN f.amount ELSE 0 END) AS credit_amount,
       SUM(CASE WHEN f.txn_type = 'DEBIT'  THEN f.amount ELSE 0 END) AS debit_amount,
       SUM(f.signed_amount)                                        AS net_flow,
       COUNT(DISTINCT f.account_key)                               AS active_accounts
  FROM fd_dwh.fact_transaction f
  JOIN fd_dwh.dim_date d ON d.date_key = f.date_key
 GROUP BY d.year_month;

-- Branch (district of the account) by year, with the district's economy.
CREATE OR REPLACE VIEW fd_mart.v_branch_performance AS
SELECT b.region, b.district_name, d.year_num,
       COUNT(DISTINCT f.account_key)                               AS active_accounts,
       COUNT(*)                                                    AS txn_cnt,
       SUM(CASE WHEN f.txn_type = 'CREDIT' THEN f.amount ELSE 0 END) AS credit_amount,
       SUM(CASE WHEN f.txn_type = 'DEBIT'  THEN f.amount ELSE 0 END) AS debit_amount,
       ROUND(AVG(f.amount), 2)                                     AS avg_txn_amount,
       MAX(b.avg_salary)                                           AS district_avg_salary,
       MAX(b.unemp_rate_96)                                        AS district_unemp_rate_96
  FROM fd_dwh.fact_transaction f
  JOIN fd_dwh.dim_branch b ON b.branch_key = f.branch_key
  JOIN fd_dwh.dim_date d   ON d.date_key = f.date_key
 GROUP BY b.region, b.district_name, d.year_num;

-- How money moves: card / cash / transfer / bank-posted, by year.
CREATE OR REPLACE VIEW fd_mart.v_channel_mix AS
SELECT d.year_num, ch.channel_group, ch.channel_name,
       COUNT(*)       AS txn_cnt,
       SUM(f.amount)  AS amount,
       ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (PARTITION BY d.year_num), 2) AS txn_share_pct
  FROM fd_dwh.fact_transaction f
  JOIN fd_dwh.dim_channel ch ON ch.channel_key = f.channel_key
  JOIN fd_dwh.dim_date d     ON d.date_key = f.date_key
 GROUP BY d.year_num, ch.channel_group, ch.channel_name;

-- Point-in-time segmentation: each transaction is attributed to the customer
-- version (card tier, loan holder) that was valid on the transaction date.
CREATE OR REPLACE VIEW fd_mart.v_customer_segment AS
SELECT d.year_num,
       c.gender,
       CASE WHEN d.year_num - c.birth_year < 25 THEN '<25'
            WHEN d.year_num - c.birth_year < 40 THEN '25-39'
            WHEN d.year_num - c.birth_year < 60 THEN '40-59'
            ELSE '60+' END                                         AS age_band,
       c.card_tier,
       c.has_loan,
       COUNT(DISTINCT c.client_id)                                 AS clients,
       COUNT(*)                                                    AS txn_cnt,
       SUM(CASE WHEN f.txn_type = 'CREDIT' THEN f.amount ELSE 0 END) AS credit_amount,
       SUM(CASE WHEN f.txn_type = 'DEBIT'  THEN f.amount ELSE 0 END) AS debit_amount
  FROM fd_dwh.fact_transaction f
  JOIN fd_dwh.dim_customer c ON c.customer_key = f.customer_key
  JOIN fd_dwh.dim_date d     ON d.date_key = f.date_key
 WHERE c.customer_key > 0
 GROUP BY d.year_num, c.gender,
          CASE WHEN d.year_num - c.birth_year < 25 THEN '<25'
               WHEN d.year_num - c.birth_year < 40 THEN '25-39'
               WHEN d.year_num - c.birth_year < 60 THEN '40-59'
               ELSE '60+' END,
          c.card_tier, c.has_loan;

-- Early-warning portfolio view at every month-end.
CREATE OR REPLACE VIEW fd_mart.v_loan_portfolio_quality AS
SELECT s.snapshot_date, s.sma_class,
       COUNT(*)                   AS loans,
       SUM(s.outstanding_amount)  AS outstanding_amount,
       SUM(s.overdue_amount)      AS overdue_amount,
       ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (PARTITION BY s.snapshot_date), 2) AS loan_share_pct
  FROM fd_dwh.fact_loan_snapshot s
 GROUP BY s.snapshot_date, s.sma_class;

-- Honest check of the DERIVED classification against the status the source
-- delivered: worst SMA class a loan ever reached vs loan.status.
CREATE OR REPLACE VIEW fd_mart.v_loan_status_vs_sma AS
SELECT source_status_code, source_status, worst_sma_class, COUNT(*) AS loans
  FROM (SELECT s.loan_id, s.source_status_code, s.source_status,
               CASE MAX(CASE s.sma_class WHEN 'STANDARD' THEN 0 WHEN 'SMA-0' THEN 1
                                         WHEN 'SMA-1' THEN 2 WHEN 'SMA-2' THEN 3 WHEN 'NPA' THEN 4 END)
                 WHEN 0 THEN 'STANDARD' WHEN 1 THEN 'SMA-0' WHEN 2 THEN 'SMA-1'
                 WHEN 3 THEN 'SMA-2' WHEN 4 THEN 'NPA' END AS worst_sma_class
          FROM fd_dwh.fact_loan_snapshot s
         GROUP BY s.loan_id, s.source_status_code, s.source_status)
 GROUP BY source_status_code, source_status, worst_sma_class;

-- Alert workload by rule.
CREATE OR REPLACE VIEW fd_mart.v_fraud_alert_summary AS
SELECT r.rule_code, r.rule_name, r.severity, a.status,
       COUNT(*)                       AS alerts,
       COUNT(DISTINCT a.account_key)  AS accounts,
       SUM(f.amount)                  AS amount_flagged
  FROM fd_dwh.fraud_alerts a
  JOIN fd_dwh.rule_config r      ON r.rule_code = a.rule_code
  JOIN fd_dwh.fact_transaction f ON f.txn_key = a.txn_key
 GROUP BY r.rule_code, r.rule_name, r.severity, a.status;

GRANT SELECT ON fd_mart.v_monthly_txn_trend      TO fd_report;
GRANT SELECT ON fd_mart.v_branch_performance     TO fd_report;
GRANT SELECT ON fd_mart.v_channel_mix            TO fd_report;
GRANT SELECT ON fd_mart.v_customer_segment       TO fd_report;
GRANT SELECT ON fd_mart.v_loan_portfolio_quality TO fd_report;
GRANT SELECT ON fd_mart.v_loan_status_vs_sma     TO fd_report;
GRANT SELECT ON fd_mart.v_fraud_alert_summary    TO fd_report;
