-- =============================================================================
-- 40_cln/03_validation_views.sql
-- One view per source over STAGING. Each view:
--   1. types every column (fd_cln.to_num / to_yymmdd macros)
--   2. translates Czech codes to English with CASE (unknown -> '#UNKNOWN')
--   3. ranks duplicates with ROW_NUMBER() (first staged row wins)
--   4. lists every broken REJECT rule in reject_codes, e.g. 'R003,R005'
-- pkg_clean loads rows with reject_codes IS NULL and quarantines the rest.
-- Rule catalogue: fd_ops.dq_rule.
-- Inline views are used instead of WITH: Oracle does not expand SQL macros
-- inside a WITH clause (ORA-64630).
-- =============================================================================

-- ------------------------------------------------------------------- district
CREATE OR REPLACE VIEW fd_cln.v_chk_district AS
SELECT t.stg_row_id, t.load_batch_id,
       t.a1, t.a2, t.a3, t.a4, t.a5, t.a6, t.a7, t.a8,
       t.a9, t.a10, t.a11, t.a12, t.a13, t.a14, t.a15, t.a16,
       t.district_id_n            AS district_id,
       TRIM(t.a2)                 AS district_name,
       TRIM(t.a3)                 AS region,
       fd_cln.to_num(t.a4)        AS inhabitants,
       fd_cln.to_num(t.a5)        AS munic_lt_500,
       fd_cln.to_num(t.a6)        AS munic_500_1999,
       fd_cln.to_num(t.a7)        AS munic_2000_9999,
       fd_cln.to_num(t.a8)        AS munic_ge_10000,
       fd_cln.to_num(t.a9)        AS city_cnt,
       fd_cln.to_num(t.a10)       AS urban_ratio_pct,
       fd_cln.to_num(t.a11)       AS avg_salary,
       fd_cln.to_num(t.a12)       AS unemp_rate_95,
       fd_cln.to_num(t.a13)       AS unemp_rate_96,
       fd_cln.to_num(t.a14)       AS entrepreneurs_per_1000,
       fd_cln.to_num(t.a15)       AS crimes_95,
       fd_cln.to_num(t.a16)       AS crimes_96,
       RTRIM(
            CASE WHEN TRIM(t.a1) IS NULL OR TRIM(t.a2) IS NULL OR TRIM(t.a3) IS NULL THEN 'R001,' END
         || CASE WHEN fd_cln.bad_num(t.a1)  + fd_cln.bad_num(t.a4)  + fd_cln.bad_num(t.a5)
                    + fd_cln.bad_num(t.a6)  + fd_cln.bad_num(t.a7)  + fd_cln.bad_num(t.a8)
                    + fd_cln.bad_num(t.a9)  + fd_cln.bad_num(t.a10) + fd_cln.bad_num(t.a11)
                    + fd_cln.bad_num(t.a12) + fd_cln.bad_num(t.a13) + fd_cln.bad_num(t.a14)
                    + fd_cln.bad_num(t.a15) + fd_cln.bad_num(t.a16) > 0 THEN 'R007,' END
         || CASE WHEN t.dup_rn > 1 THEN 'R006,' END
       , ',') AS reject_codes
  FROM (SELECT s.*,
               fd_cln.to_num(s.a1) AS district_id_n,
               ROW_NUMBER() OVER (PARTITION BY TRIM(s.a1) ORDER BY s.stg_row_id) AS dup_rn
          FROM fd_stg.stg_district s) t;

-- -------------------------------------------------------------------- account
CREATE OR REPLACE VIEW fd_cln.v_chk_account AS
SELECT t.stg_row_id, t.load_batch_id,
       t.account_id, t.district_id, t.frequency, t.acct_date,
       t.account_id_n, t.district_id_n, t.open_date, t.frequency_std,
       RTRIM(
            CASE WHEN t.account_id_n IS NULL OR t.district_id_n IS NULL OR t.frequency_std IS NULL THEN 'R001,' END
         || CASE WHEN t.open_date IS NULL THEN 'R002,' END
         || CASE WHEN t.district_id_n IS NOT NULL AND d.district_id IS NULL THEN 'R003,' END
         || CASE WHEN t.frequency_std = '#UNKNOWN' THEN 'R005,' END
         || CASE WHEN t.dup_rn > 1 THEN 'R006,' END
         || CASE WHEN fd_cln.bad_num(t.account_id) + fd_cln.bad_num(t.district_id) > 0 THEN 'R007,' END
       , ',') AS reject_codes
  FROM (SELECT s.*,
               fd_cln.to_num(s.account_id)   AS account_id_n,
               fd_cln.to_num(s.district_id)  AS district_id_n,
               fd_cln.to_yymmdd(s.acct_date) AS open_date,
               CASE TRIM(s.frequency)
                 WHEN 'POPLATEK MESICNE'   THEN 'MONTHLY'
                 WHEN 'POPLATEK TYDNE'     THEN 'WEEKLY'
                 WHEN 'POPLATEK PO OBRATU' THEN 'ON_TRANSACTION'
                 ELSE NVL2(TRIM(s.frequency), '#UNKNOWN', NULL)
               END AS frequency_std,
               ROW_NUMBER() OVER (PARTITION BY TRIM(s.account_id) ORDER BY s.stg_row_id) AS dup_rn
          FROM fd_stg.stg_account s) t
  LEFT JOIN fd_cln.cln_district d ON d.district_id = t.district_id_n;

-- --------------------------------------------------------------------- client
-- birth_number is YYMMDD; for women the month is stored + 50.
CREATE OR REPLACE VIEW fd_cln.v_chk_client AS
SELECT d.stg_row_id, d.load_batch_id,
       d.client_id, d.birth_number, d.district_id,
       d.client_id_n, d.district_id_n, d.bn, d.gender, d.birth_date,
       RTRIM(
            CASE WHEN d.client_id_n IS NULL OR d.district_id_n IS NULL THEN 'R001,' END
         || CASE WHEN d.birth_date IS NULL THEN 'R002,' END
         || CASE WHEN d.district_id_n IS NOT NULL AND dist.district_id IS NULL THEN 'R003,' END
         || CASE WHEN d.dup_rn > 1 THEN 'R006,' END
         || CASE WHEN fd_cln.bad_num(d.client_id) + fd_cln.bad_num(d.district_id) > 0 THEN 'R007,' END
       , ',') AS reject_codes
  FROM (SELECT t.*,
               CASE WHEN t.bn IS NOT NULL
                    THEN CASE WHEN TO_NUMBER(SUBSTR(t.bn, 3, 2)) > 50 THEN 'F' ELSE 'M' END
               END AS gender,
               CASE WHEN t.bn IS NOT NULL
                    THEN TO_DATE('19' || SUBSTR(t.bn, 1, 2)
                                 || LPAD(TO_CHAR(MOD(TO_NUMBER(SUBSTR(t.bn, 3, 2)), 50)), 2, '0')
                                 || SUBSTR(t.bn, 5, 2) DEFAULT NULL ON CONVERSION ERROR, 'YYYYMMDD')
               END AS birth_date
          FROM (SELECT s.*,
                       fd_cln.to_num(s.client_id)   AS client_id_n,
                       fd_cln.to_num(s.district_id) AS district_id_n,
                       CASE WHEN REGEXP_LIKE(TRIM(s.birth_number), '^[0-9]{6}$')
                            THEN TRIM(s.birth_number) END AS bn,
                       ROW_NUMBER() OVER (PARTITION BY TRIM(s.client_id) ORDER BY s.stg_row_id) AS dup_rn
                  FROM fd_stg.stg_client s) t) d
  LEFT JOIN fd_cln.cln_district dist ON dist.district_id = d.district_id_n;

-- ----------------------------------------------------------------------- disp
CREATE OR REPLACE VIEW fd_cln.v_chk_disp AS
SELECT t.stg_row_id, t.load_batch_id,
       t.disp_id, t.client_id, t.account_id, t.disp_type,
       t.disp_id_n, t.client_id_n, t.account_id_n, t.disp_type_std,
       RTRIM(
            CASE WHEN t.disp_id_n IS NULL OR t.client_id_n IS NULL OR t.account_id_n IS NULL
                   OR t.disp_type_std IS NULL THEN 'R001,' END
         || CASE WHEN (t.client_id_n IS NOT NULL AND c.client_id IS NULL)
                   OR (t.account_id_n IS NOT NULL AND a.account_id IS NULL) THEN 'R003,' END
         || CASE WHEN t.disp_type_std = '#UNKNOWN' THEN 'R005,' END
         || CASE WHEN t.dup_rn > 1 THEN 'R006,' END
         || CASE WHEN fd_cln.bad_num(t.disp_id) + fd_cln.bad_num(t.client_id)
                    + fd_cln.bad_num(t.account_id) > 0 THEN 'R007,' END
       , ',') AS reject_codes
  FROM (SELECT s.*,
               fd_cln.to_num(s.disp_id)    AS disp_id_n,
               fd_cln.to_num(s.client_id)  AS client_id_n,
               fd_cln.to_num(s.account_id) AS account_id_n,
               CASE TRIM(s.disp_type)
                 WHEN 'OWNER'     THEN 'OWNER'
                 WHEN 'DISPONENT' THEN 'DISPONENT'
                 ELSE NVL2(TRIM(s.disp_type), '#UNKNOWN', NULL)
               END AS disp_type_std,
               ROW_NUMBER() OVER (PARTITION BY TRIM(s.disp_id) ORDER BY s.stg_row_id) AS dup_rn
          FROM fd_stg.stg_disp s) t
  LEFT JOIN fd_cln.cln_client  c ON c.client_id  = t.client_id_n
  LEFT JOIN fd_cln.cln_account a ON a.account_id = t.account_id_n;

-- ----------------------------------------------------------------------- card
CREATE OR REPLACE VIEW fd_cln.v_chk_card AS
SELECT t.stg_row_id, t.load_batch_id,
       t.card_id, t.disp_id, t.card_type, t.issued,
       t.card_id_n, t.disp_id_n, t.issued_date, t.card_type_std,
       RTRIM(
            CASE WHEN t.card_id_n IS NULL OR t.disp_id_n IS NULL OR t.card_type_std IS NULL THEN 'R001,' END
         || CASE WHEN t.issued_date IS NULL THEN 'R002,' END
         || CASE WHEN t.disp_id_n IS NOT NULL AND d.disp_id IS NULL THEN 'R003,' END
         || CASE WHEN t.card_type_std = '#UNKNOWN' THEN 'R005,' END
         || CASE WHEN t.dup_rn > 1 THEN 'R006,' END
         || CASE WHEN fd_cln.bad_num(t.card_id) + fd_cln.bad_num(t.disp_id) > 0 THEN 'R007,' END
       , ',') AS reject_codes
  FROM (SELECT s.*,
               fd_cln.to_num(s.card_id)   AS card_id_n,
               fd_cln.to_num(s.disp_id)   AS disp_id_n,
               fd_cln.to_yymmdd(s.issued) AS issued_date,
               CASE LOWER(TRIM(s.card_type))
                 WHEN 'junior'  THEN 'JUNIOR'
                 WHEN 'classic' THEN 'CLASSIC'
                 WHEN 'gold'    THEN 'GOLD'
                 ELSE NVL2(TRIM(s.card_type), '#UNKNOWN', NULL)
               END AS card_type_std,
               ROW_NUMBER() OVER (PARTITION BY TRIM(s.card_id) ORDER BY s.stg_row_id) AS dup_rn
          FROM fd_stg.stg_card s) t
  LEFT JOIN fd_cln.cln_disp d ON d.disp_id = t.disp_id_n;

-- ----------------------------------------------------------------------- loan
CREATE OR REPLACE VIEW fd_cln.v_chk_loan AS
SELECT t.stg_row_id, t.load_batch_id,
       t.loan_id, t.account_id, t.loan_date, t.amount, t.duration, t.payments, t.status,
       t.loan_id_n, t.account_id_n, t.loan_date_d, t.amount_n, t.duration_n, t.payments_n,
       TRIM(t.status) AS status_code, t.loan_status,
       RTRIM(
            CASE WHEN t.loan_id_n IS NULL OR t.account_id_n IS NULL OR TRIM(t.amount) IS NULL
                   OR TRIM(t.duration) IS NULL OR TRIM(t.payments) IS NULL
                   OR t.loan_status IS NULL THEN 'R001,' END
         || CASE WHEN t.loan_date_d IS NULL THEN 'R002,' END
         || CASE WHEN t.account_id_n IS NOT NULL AND a.account_id IS NULL THEN 'R003,' END
         || CASE WHEN t.loan_status = '#UNKNOWN' THEN 'R005,' END
         || CASE WHEN t.dup_rn > 1 THEN 'R006,' END
         || CASE WHEN fd_cln.bad_num(t.loan_id) + fd_cln.bad_num(t.account_id) + fd_cln.bad_num(t.amount)
                    + fd_cln.bad_num(t.duration) + fd_cln.bad_num(t.payments) > 0
                   OR t.duration_n <= 0 OR t.payments_n <= 0 THEN 'R007,' END
       , ',') AS reject_codes
  FROM (SELECT s.*,
               fd_cln.to_num(s.loan_id)      AS loan_id_n,
               fd_cln.to_num(s.account_id)   AS account_id_n,
               fd_cln.to_yymmdd(s.loan_date) AS loan_date_d,
               fd_cln.to_num(s.amount)       AS amount_n,
               fd_cln.to_num(s.duration)     AS duration_n,
               fd_cln.to_num(s.payments)     AS payments_n,
               CASE TRIM(s.status)
                 WHEN 'A' THEN 'FINISHED_OK'
                 WHEN 'B' THEN 'FINISHED_DEFAULT'
                 WHEN 'C' THEN 'RUNNING_OK'
                 WHEN 'D' THEN 'RUNNING_DEBT'
                 ELSE NVL2(TRIM(s.status), '#UNKNOWN', NULL)
               END AS loan_status,
               ROW_NUMBER() OVER (PARTITION BY TRIM(s.loan_id) ORDER BY s.stg_row_id) AS dup_rn
          FROM fd_stg.stg_loan s) t
  LEFT JOIN fd_cln.cln_account a ON a.account_id = t.account_id_n;

-- ---------------------------------------------------------------------- order
-- 'LEASING' is not in the original mapping brief but occurs 341 times in
-- order.asc; it is kept as LEASING rather than rejected.
CREATE OR REPLACE VIEW fd_cln.v_chk_order AS
SELECT t.stg_row_id, t.load_batch_id,
       t.order_id, t.account_id, t.bank_to, t.account_to, t.amount, t.k_symbol,
       t.order_id_n, t.account_id_n, t.amount_n, t.k_symbol_std,
       TRIM(t.bank_to) AS bank_to_std, TRIM(t.account_to) AS account_to_std,
       RTRIM(
            CASE WHEN t.order_id_n IS NULL OR t.account_id_n IS NULL OR TRIM(t.amount) IS NULL THEN 'R001,' END
         || CASE WHEN t.account_id_n IS NOT NULL AND a.account_id IS NULL THEN 'R003,' END
         || CASE WHEN t.k_symbol_std = '#UNKNOWN' THEN 'R005,' END
         || CASE WHEN t.dup_rn > 1 THEN 'R006,' END
         || CASE WHEN fd_cln.bad_num(t.order_id) + fd_cln.bad_num(t.account_id)
                    + fd_cln.bad_num(t.amount) > 0 THEN 'R007,' END
       , ',') AS reject_codes
  FROM (SELECT s.*,
               fd_cln.to_num(s.order_id)   AS order_id_n,
               fd_cln.to_num(s.account_id) AS account_id_n,
               fd_cln.to_num(s.amount)     AS amount_n,
               CASE TRIM(s.k_symbol)
                 WHEN 'POJISTNE' THEN 'INSURANCE'
                 WHEN 'SIPO'     THEN 'HOUSEHOLD'
                 WHEN 'UVER'     THEN 'LOAN_PAYMENT'
                 WHEN 'LEASING'  THEN 'LEASING'
                 ELSE NVL2(TRIM(s.k_symbol), '#UNKNOWN', NULL)
               END AS k_symbol_std,
               ROW_NUMBER() OVER (PARTITION BY TRIM(s.order_id) ORDER BY s.stg_row_id) AS dup_rn
          FROM fd_stg.stg_order s) t
  LEFT JOIN fd_cln.cln_account a ON a.account_id = t.account_id_n;

-- ---------------------------------------------------------------------- trans
-- Partitioning the duplicate window by load_batch_id lets a
-- "WHERE load_batch_id = :b" predicate reach the staging partition.
-- A trans_id already loaded by an earlier batch is a duplicate too (R006).
CREATE OR REPLACE VIEW fd_cln.v_chk_trans AS
SELECT t.stg_row_id, t.load_batch_id,
       t.trans_id, t.account_id, t.trans_date, t.trans_type, t.operation, t.amount, t.balance,
       t.k_symbol, t.bank, t.account,
       t.trans_id_n, t.account_id_n, t.trans_date_d, t.amount_n, t.balance_n,
       t.txn_type, t.operation_std, t.k_symbol_std,
       TRIM(t.bank)    AS bank_std,
       TRIM(t.account) AS counterparty_account_std,
       RTRIM(
            CASE WHEN t.trans_id_n IS NULL OR t.account_id_n IS NULL OR TRIM(t.amount) IS NULL
                   OR t.txn_type IS NULL THEN 'R001,' END
         || CASE WHEN t.trans_date_d IS NULL THEN 'R002,' END
         || CASE WHEN t.account_id_n IS NOT NULL AND a.account_id IS NULL THEN 'R003,' END
         || CASE WHEN '#UNKNOWN' IN (t.txn_type, t.operation_std, t.k_symbol_std) THEN 'R005,' END
         || CASE WHEN t.dup_rn > 1 OR prev.trans_id IS NOT NULL THEN 'R006,' END
         || CASE WHEN fd_cln.bad_num(t.trans_id) + fd_cln.bad_num(t.account_id)
                    + fd_cln.bad_num(t.amount) + fd_cln.bad_num(t.balance) > 0
                   OR t.amount_n < 0 THEN 'R007,' END
       , ',') AS reject_codes
  FROM (SELECT s.*,
               fd_cln.to_num(s.trans_id)      AS trans_id_n,
               fd_cln.to_num(s.account_id)    AS account_id_n,
               fd_cln.to_yymmdd(s.trans_date) AS trans_date_d,
               fd_cln.to_num(s.amount)        AS amount_n,
               fd_cln.to_num(s.balance)       AS balance_n,
               CASE TRIM(s.trans_type)
                 WHEN 'PRIJEM' THEN 'CREDIT'
                 WHEN 'VYDAJ'  THEN 'DEBIT'
                 WHEN 'VYBER'  THEN 'DEBIT'      -- cash withdrawal recorded with its own type code
                 ELSE NVL2(TRIM(s.trans_type), '#UNKNOWN', NULL)
               END AS txn_type,
               CASE TRIM(s.operation)
                 WHEN 'VYBER KARTOU'   THEN 'CARD_WITHDRAWAL'
                 WHEN 'VKLAD'          THEN 'CASH_CREDIT'
                 WHEN 'PREVOD Z UCTU'  THEN 'INBOUND_TRANSFER'
                 WHEN 'VYBER'          THEN 'CASH_WITHDRAWAL'
                 WHEN 'PREVOD NA UCET' THEN 'OUTBOUND_TRANSFER'
                 ELSE NVL2(TRIM(s.operation), '#UNKNOWN', NULL)
               END AS operation_std,
               CASE TRIM(s.k_symbol)
                 WHEN 'POJISTNE'    THEN 'INSURANCE'
                 WHEN 'SLUZBY'      THEN 'STATEMENT'
                 WHEN 'UROK'        THEN 'INTEREST'
                 WHEN 'SANKC. UROK' THEN 'PENALTY_INTEREST'
                 WHEN 'SIPO'        THEN 'HOUSEHOLD'
                 WHEN 'DUCHOD'      THEN 'PENSION'
                 WHEN 'UVER'        THEN 'LOAN_PAYMENT'
                 ELSE NVL2(TRIM(s.k_symbol), '#UNKNOWN', NULL)
               END AS k_symbol_std,
               ROW_NUMBER() OVER (PARTITION BY s.load_batch_id, TRIM(s.trans_id)
                                  ORDER BY s.stg_row_id) AS dup_rn
          FROM fd_stg.stg_trans s) t
  LEFT JOIN fd_cln.cln_account a  ON a.account_id = t.account_id_n
  LEFT JOIN fd_cln.cln_trans prev ON prev.trans_id = t.trans_id_n
                                 AND prev.batch_id <> t.load_batch_id;
