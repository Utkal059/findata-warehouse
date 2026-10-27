-- =============================================================================
-- plsql/50_pkg_load_dwh.sql
-- LOAD_DWH step: CLEAN -> star schema.
--   * SCD1 dimensions (branch, account, channel, category): MERGE on the
--     natural key, update only when row_hash changed
--   * dim_customer: SCD2 (close the current version, open a new one)
--   * fact_transaction: insert this batch's clean rows that are not there yet
-- Idempotent: re-running a batch changes nothing and inserts nothing.
-- =============================================================================

CREATE OR REPLACE PACKAGE fd_dwh.pkg_load_dwh AUTHID DEFINER AS

  -- Generates calendar rows (MERGE, so it can be re-run safely).
  PROCEDURE build_dim_date (p_from IN DATE, p_to IN DATE);

  PROCEDURE run (p_batch_id IN NUMBER, p_parent_log_id IN NUMBER);

END pkg_load_dwh;
/

CREATE OR REPLACE PACKAGE BODY fd_dwh.pkg_load_dwh AS

  g_batch_id   NUMBER;
  g_parent_id  NUMBER;
  g_log_id     NUMBER;
  g_as_of      DATE;
  g_wm_from    DATE;

  PROCEDURE begin_task (p_name IN VARCHAR2) IS
  BEGIN
    g_log_id := fd_ops.pkg_etl_log.start_step(g_batch_id, 'LOAD_DWH:' || p_name, g_parent_id);
  END begin_task;

  PROCEDURE end_task (p_read IN NUMBER, p_loaded IN NUMBER, p_msg IN VARCHAR2 DEFAULT NULL) IS
  BEGIN
    fd_ops.pkg_etl_log.log_step(g_log_id, 'SUCCESS', p_read, p_loaded, 0, p_msg);
    g_log_id := NULL;
  END end_task;

  -- ------------------------------------------------------------------ dim_date
  PROCEDURE build_dim_date (p_from IN DATE, p_to IN DATE) IS
  BEGIN
    MERGE INTO fd_dwh.dim_date d
    USING (SELECT TRUNC(p_from) + LEVEL - 1 AS dt
             FROM dual
           CONNECT BY LEVEL <= TRUNC(p_to) - TRUNC(p_from) + 1) s
       ON (d.full_date = s.dt)
    WHEN NOT MATCHED THEN INSERT
         (date_key, full_date, day_of_month, day_of_week, day_name, is_weekend, iso_week,
          month_num, month_name, year_month, quarter_num, year_num, month_end_date, is_month_end)
         VALUES
         (TO_NUMBER(TO_CHAR(s.dt, 'YYYYMMDD')), s.dt, EXTRACT(DAY FROM s.dt),
          TRUNC(s.dt) - TRUNC(s.dt, 'IW') + 1,
          TO_CHAR(s.dt, 'FMDay', 'NLS_DATE_LANGUAGE=ENGLISH'),
          CASE WHEN TRUNC(s.dt) - TRUNC(s.dt, 'IW') >= 5 THEN 'Y' ELSE 'N' END,
          TO_NUMBER(TO_CHAR(s.dt, 'IW')),
          EXTRACT(MONTH FROM s.dt),
          TO_CHAR(s.dt, 'FMMonth', 'NLS_DATE_LANGUAGE=ENGLISH'),
          TO_CHAR(s.dt, 'YYYY-MM'),
          TO_NUMBER(TO_CHAR(s.dt, 'Q')),
          EXTRACT(YEAR FROM s.dt),
          LAST_DAY(s.dt),
          CASE WHEN s.dt = LAST_DAY(s.dt) THEN 'Y' ELSE 'N' END);
    COMMIT;
  END build_dim_date;

  -- ---------------------------------------------------------------- dim_branch
  PROCEDURE load_branch IS
    v_read NUMBER;
  BEGIN
    begin_task('DIM_BRANCH');
    SELECT COUNT(*) INTO v_read FROM fd_cln.cln_district;

    MERGE INTO fd_dwh.dim_branch d
    USING (SELECT c.*,
                  STANDARD_HASH(c.district_name || '|' || c.region || '|' || c.inhabitants || '|' ||
                                c.city_cnt || '|' || c.urban_ratio_pct || '|' || c.avg_salary || '|' ||
                                c.unemp_rate_95 || '|' || c.unemp_rate_96 || '|' ||
                                c.entrepreneurs_per_1000 || '|' || c.crimes_95 || '|' || c.crimes_96,
                                'SHA256') AS row_hash
             FROM fd_cln.cln_district c) s
       ON (d.district_id = s.district_id)
    WHEN MATCHED THEN UPDATE SET
         d.district_name = s.district_name, d.region = s.region, d.inhabitants = s.inhabitants,
         d.city_cnt = s.city_cnt, d.urban_ratio_pct = s.urban_ratio_pct, d.avg_salary = s.avg_salary,
         d.unemp_rate_95 = s.unemp_rate_95, d.unemp_rate_96 = s.unemp_rate_96,
         d.entrepreneurs_per_1000 = s.entrepreneurs_per_1000,
         d.crimes_95 = s.crimes_95, d.crimes_96 = s.crimes_96,
         d.row_hash = s.row_hash, d.updated_batch_id = g_batch_id
       WHERE d.row_hash <> s.row_hash
    WHEN NOT MATCHED THEN INSERT
         (district_id, district_name, region, inhabitants, city_cnt, urban_ratio_pct, avg_salary,
          unemp_rate_95, unemp_rate_96, entrepreneurs_per_1000, crimes_95, crimes_96,
          row_hash, created_batch_id)
         VALUES
         (s.district_id, s.district_name, s.region, s.inhabitants, s.city_cnt, s.urban_ratio_pct,
          s.avg_salary, s.unemp_rate_95, s.unemp_rate_96, s.entrepreneurs_per_1000, s.crimes_95,
          s.crimes_96, s.row_hash, g_batch_id);

    end_task(v_read, SQL%ROWCOUNT, 'rows_loaded = inserted or changed');
  END load_branch;

  -- --------------------------------------------------------------- dim_account
  PROCEDURE load_account IS
    v_read NUMBER;
  BEGIN
    begin_task('DIM_ACCOUNT');
    SELECT COUNT(*) INTO v_read FROM fd_cln.cln_account;

    MERGE INTO fd_dwh.dim_account d
    USING (SELECT a.account_id, a.district_id, a.frequency, a.open_date,
                  o.owner_client_id, NVL(o.disponent_cnt, 0) AS disponent_cnt,
                  STANDARD_HASH(a.district_id || '|' || a.frequency || '|' ||
                                TO_CHAR(a.open_date, 'YYYYMMDD') || '|' || o.owner_client_id || '|' ||
                                NVL(o.disponent_cnt, 0), 'SHA256') AS row_hash
             FROM fd_cln.cln_account a
             LEFT JOIN (SELECT account_id,
                               MIN(CASE WHEN disp_type = 'OWNER' THEN client_id END) AS owner_client_id,
                               COUNT(CASE WHEN disp_type = 'DISPONENT' THEN 1 END) AS disponent_cnt
                          FROM fd_cln.cln_disp
                         GROUP BY account_id) o
               ON o.account_id = a.account_id) s
       ON (d.account_id = s.account_id)
    WHEN MATCHED THEN UPDATE SET
         d.district_id = s.district_id, d.statement_frequency = s.frequency, d.open_date = s.open_date,
         d.owner_client_id = s.owner_client_id, d.disponent_cnt = s.disponent_cnt,
         d.row_hash = s.row_hash, d.updated_batch_id = g_batch_id
       WHERE d.row_hash <> s.row_hash
    WHEN NOT MATCHED THEN INSERT
         (account_id, district_id, statement_frequency, open_date, owner_client_id, disponent_cnt,
          row_hash, created_batch_id)
         VALUES
         (s.account_id, s.district_id, s.frequency, s.open_date, s.owner_client_id, s.disponent_cnt,
          s.row_hash, g_batch_id);

    end_task(v_read, SQL%ROWCOUNT, 'rows_loaded = inserted or changed');
  END load_account;

  -- ------------------------------------------------------ dim_channel/category
  PROCEDURE load_channel IS
  BEGIN
    begin_task('DIM_CHANNEL');
    MERGE INTO fd_dwh.dim_channel d
    USING (SELECT x.*,
                  STANDARD_HASH(x.channel_code || '|' || x.source_operation || '|' ||
                                x.channel_name || '|' || x.channel_group, 'SHA256') AS row_hash
             FROM (SELECT c.code AS channel_code,
                          CASE c.code
                            WHEN 'CARD_WITHDRAWAL'   THEN 'VYBER KARTOU'
                            WHEN 'CASH_CREDIT'       THEN 'VKLAD'
                            WHEN 'INBOUND_TRANSFER'  THEN 'PREVOD Z UCTU'
                            WHEN 'CASH_WITHDRAWAL'   THEN 'VYBER'
                            WHEN 'OUTBOUND_TRANSFER' THEN 'PREVOD NA UCET'
                          END AS source_operation,
                          CASE c.code
                            WHEN 'CARD_WITHDRAWAL'   THEN 'Withdrawal by credit card'
                            WHEN 'CASH_CREDIT'       THEN 'Cash deposit'
                            WHEN 'INBOUND_TRANSFER'  THEN 'Collection from another bank'
                            WHEN 'CASH_WITHDRAWAL'   THEN 'Cash withdrawal'
                            WHEN 'OUTBOUND_TRANSFER' THEN 'Remittance to another bank'
                            WHEN 'NONE'              THEN 'No operation recorded (bank-posted entry)'
                            ELSE c.code
                          END AS channel_name,
                          CASE c.code
                            WHEN 'CARD_WITHDRAWAL'   THEN 'CARD'
                            WHEN 'CASH_CREDIT'       THEN 'CASH'
                            WHEN 'CASH_WITHDRAWAL'   THEN 'CASH'
                            WHEN 'INBOUND_TRANSFER'  THEN 'TRANSFER'
                            WHEN 'OUTBOUND_TRANSFER' THEN 'TRANSFER'
                            WHEN 'NONE'              THEN 'BANK_POSTED'
                            ELSE 'OTHER'
                          END AS channel_group
                     FROM (SELECT DISTINCT NVL(operation, 'NONE') AS code
                             FROM fd_cln.cln_trans
                            WHERE batch_id = g_batch_id) c) x) s
       ON (d.channel_code = s.channel_code)
    WHEN MATCHED THEN UPDATE SET
         d.source_operation = s.source_operation, d.channel_name = s.channel_name,
         d.channel_group = s.channel_group, d.row_hash = s.row_hash
       WHERE d.row_hash <> s.row_hash
    WHEN NOT MATCHED THEN INSERT (channel_code, source_operation, channel_name, channel_group, row_hash)
         VALUES (s.channel_code, s.source_operation, s.channel_name, s.channel_group, s.row_hash);
    end_task(NULL, SQL%ROWCOUNT);

    begin_task('DIM_TXN_CATEGORY');
    MERGE INTO fd_dwh.dim_txn_category d
    USING (SELECT x.*,
                  STANDARD_HASH(x.category_code || '|' || x.source_k_symbol || '|' ||
                                x.category_name || '|' || x.category_group, 'SHA256') AS row_hash
             FROM (SELECT c.code AS category_code,
                          CASE c.code
                            WHEN 'INSURANCE'        THEN 'POJISTNE'
                            WHEN 'STATEMENT'        THEN 'SLUZBY'
                            WHEN 'INTEREST'         THEN 'UROK'
                            WHEN 'PENALTY_INTEREST' THEN 'SANKC. UROK'
                            WHEN 'HOUSEHOLD'        THEN 'SIPO'
                            WHEN 'PENSION'          THEN 'DUCHOD'
                            WHEN 'LOAN_PAYMENT'     THEN 'UVER'
                          END AS source_k_symbol,
                          CASE c.code
                            WHEN 'INSURANCE'        THEN 'Insurance payment'
                            WHEN 'STATEMENT'        THEN 'Payment for statement'
                            WHEN 'INTEREST'         THEN 'Interest credited'
                            WHEN 'PENALTY_INTEREST' THEN 'Sanction interest on negative balance'
                            WHEN 'HOUSEHOLD'        THEN 'Household payment'
                            WHEN 'PENSION'          THEN 'Old-age pension'
                            WHEN 'LOAN_PAYMENT'     THEN 'Loan payment'
                            WHEN 'NONE'             THEN 'No characterisation in source'
                            ELSE c.code
                          END AS category_name,
                          CASE c.code
                            WHEN 'INTEREST'         THEN 'INCOME'
                            WHEN 'PENSION'          THEN 'INCOME'
                            WHEN 'INSURANCE'        THEN 'OBLIGATION'
                            WHEN 'HOUSEHOLD'        THEN 'OBLIGATION'
                            WHEN 'LOAN_PAYMENT'     THEN 'OBLIGATION'
                            WHEN 'STATEMENT'        THEN 'BANK_FEE'
                            WHEN 'PENALTY_INTEREST' THEN 'BANK_FEE'
                            ELSE 'UNSPECIFIED'
                          END AS category_group
                     FROM (SELECT DISTINCT NVL(k_symbol, 'NONE') AS code
                             FROM fd_cln.cln_trans
                            WHERE batch_id = g_batch_id) c) x) s
       ON (d.category_code = s.category_code)
    WHEN MATCHED THEN UPDATE SET
         d.source_k_symbol = s.source_k_symbol, d.category_name = s.category_name,
         d.category_group = s.category_group, d.row_hash = s.row_hash
       WHERE d.row_hash <> s.row_hash
    WHEN NOT MATCHED THEN INSERT (category_code, source_k_symbol, category_name, category_group, row_hash)
         VALUES (s.category_code, s.source_k_symbol, s.category_name, s.category_group, s.row_hash);
    end_task(NULL, SQL%ROWCOUNT);
  END load_channel;

  -- -------------------------------------------------------- dim_customer SCD2
  -- Tracked attributes: gender, birth date, home district/region, card tier
  -- (best card issued on or before the batch date) and has_loan (an owned
  -- account has a loan granted on or before the batch date).
  -- Effective dating: a new version starts on the date of the latest card
  -- issue / loan grant inside this batch's window (business date), or on
  -- the batch date when no such event explains the change.
  PROCEDURE load_customer IS
    v_read      NUMBER;
    v_merged    NUMBER;
    v_versions  NUMBER;
  BEGIN
    begin_task('DIM_CUSTOMER_SCD2');

    DELETE FROM fd_dwh.gtt_customer_src;
    INSERT INTO fd_dwh.gtt_customer_src
           (client_id, gender, birth_date, home_district_id, home_region, card_tier, has_loan,
            eff_date, row_hash)
    SELECT s.client_id, s.gender, s.birth_date, s.district_id, s.region, s.card_tier, s.has_loan,
           s.eff_date,
           STANDARD_HASH(s.gender || '|' || TO_CHAR(s.birth_date, 'YYYYMMDD') || '|' ||
                         s.district_id || '|' || s.region || '|' || s.card_tier || '|' || s.has_loan,
                         'SHA256')
      FROM (SELECT c.client_id, c.gender, c.birth_date, c.district_id, dist.region,
                   CASE cards.tier_rank WHEN 3 THEN 'GOLD' WHEN 2 THEN 'CLASSIC'
                                        WHEN 1 THEN 'JUNIOR' ELSE 'NONE' END AS card_tier,
                   CASE WHEN loans.client_id IS NOT NULL THEN 'Y' ELSE 'N' END AS has_loan,
                   NVL(ev.last_event_date, g_as_of) AS eff_date
              FROM fd_cln.cln_client c
              JOIN fd_cln.cln_district dist ON dist.district_id = c.district_id
              LEFT JOIN (SELECT d.client_id,
                                MAX(CASE k.card_type WHEN 'GOLD' THEN 3 WHEN 'CLASSIC' THEN 2
                                                     WHEN 'JUNIOR' THEN 1 END) AS tier_rank
                           FROM fd_cln.cln_card k
                           JOIN fd_cln.cln_disp d ON d.disp_id = k.disp_id
                          WHERE k.issued_date <= g_as_of
                          GROUP BY d.client_id) cards
                ON cards.client_id = c.client_id
              LEFT JOIN (SELECT DISTINCT d.client_id
                           FROM fd_cln.cln_loan l
                           JOIN fd_cln.cln_disp d ON d.account_id = l.account_id AND d.disp_type = 'OWNER'
                          WHERE l.loan_date <= g_as_of) loans
                ON loans.client_id = c.client_id
              LEFT JOIN (SELECT client_id, MAX(event_date) AS last_event_date
                           FROM (SELECT d.client_id, k.issued_date AS event_date
                                   FROM fd_cln.cln_card k
                                   JOIN fd_cln.cln_disp d ON d.disp_id = k.disp_id
                                  WHERE k.issued_date <= g_as_of
                                    AND (g_wm_from IS NULL OR k.issued_date > g_wm_from)
                                 UNION ALL
                                 SELECT d.client_id, l.loan_date
                                   FROM fd_cln.cln_loan l
                                   JOIN fd_cln.cln_disp d ON d.account_id = l.account_id AND d.disp_type = 'OWNER'
                                  WHERE l.loan_date <= g_as_of
                                    AND (g_wm_from IS NULL OR l.loan_date > g_wm_from))
                          GROUP BY client_id) ev
                ON ev.client_id = c.client_id) s;
    v_read := SQL%ROWCOUNT;

    -- 1. Close the current version of every client whose attributes changed;
    --    first-time clients get their first version (valid from 1900-01-01).
    MERGE INTO fd_dwh.dim_customer d
    USING (SELECT s.*, cur.customer_key AS cur_key
             FROM fd_dwh.gtt_customer_src s
             LEFT JOIN fd_dwh.dim_customer cur
               ON cur.client_id = s.client_id AND cur.is_current = 'Y') s
       ON (d.customer_key = s.cur_key)
    WHEN MATCHED THEN UPDATE SET
         d.valid_to = s.eff_date - 1, d.is_current = 'N', d.updated_batch_id = g_batch_id
       WHERE d.row_hash <> s.row_hash
    WHEN NOT MATCHED THEN INSERT
         (client_id, gender, birth_date, birth_year, home_district_id, home_region, card_tier,
          has_loan, valid_from, valid_to, is_current, row_hash, created_batch_id)
         VALUES
         (s.client_id, s.gender, s.birth_date, EXTRACT(YEAR FROM s.birth_date), s.home_district_id,
          s.home_region, s.card_tier, s.has_loan, DATE '1900-01-01', DATE '9999-12-31', 'Y',
          s.row_hash, g_batch_id);
    v_merged := SQL%ROWCOUNT;              -- closed versions + first versions

    -- 2. Open the new version for every client left without a current row.
    INSERT INTO fd_dwh.dim_customer
           (client_id, gender, birth_date, birth_year, home_district_id, home_region, card_tier,
            has_loan, valid_from, valid_to, is_current, row_hash, created_batch_id)
    SELECT s.client_id, s.gender, s.birth_date, EXTRACT(YEAR FROM s.birth_date), s.home_district_id,
           s.home_region, s.card_tier, s.has_loan, s.eff_date, DATE '9999-12-31', 'Y',
           s.row_hash, g_batch_id
      FROM fd_dwh.gtt_customer_src s
     WHERE NOT EXISTS (SELECT 1 FROM fd_dwh.dim_customer d
                        WHERE d.client_id = s.client_id AND d.is_current = 'Y');
    v_versions := SQL%ROWCOUNT;              -- one per closed version

    end_task(v_read, v_merged,
             (v_merged - v_versions) || ' new client(s), ' || v_versions || ' new SCD2 version(s)');
  END load_customer;

  -- ---------------------------------------------------------- fact_transaction
  PROCEDURE load_fact_transaction IS
    v_read     NUMBER;
    v_loaded   NUMBER;
    v_unknown  NUMBER;
  BEGIN
    begin_task('FACT_TRANSACTION');
    SELECT COUNT(*) INTO v_read FROM fd_cln.cln_trans WHERE batch_id = g_batch_id;

    INSERT INTO fd_dwh.fact_transaction
           (trans_id, txn_date, date_key, account_key, customer_key, branch_key, channel_key,
            category_key, txn_type, amount, signed_amount, balance_after, counterparty_bank,
            counterparty_account, dq_warn_codes, batch_id)
    SELECT t.trans_id, t.trans_date, TO_NUMBER(TO_CHAR(t.trans_date, 'YYYYMMDD')),
           NVL(a.account_key, -1), NVL(c.customer_key, -1), NVL(b.branch_key, -1),
           NVL(ch.channel_key, -1), NVL(cat.category_key, -1),
           t.txn_type, t.amount,
           CASE t.txn_type WHEN 'DEBIT' THEN -t.amount ELSE t.amount END,
           t.balance, t.bank, t.counterparty_account, t.dq_warn_codes, g_batch_id
      FROM fd_cln.cln_trans t
      LEFT JOIN fd_dwh.dim_account a        ON a.account_id = t.account_id
      LEFT JOIN fd_dwh.dim_customer c       ON c.client_id = a.owner_client_id
                                           AND t.trans_date BETWEEN c.valid_from AND c.valid_to
      LEFT JOIN fd_dwh.dim_branch b         ON b.district_id = a.district_id
      LEFT JOIN fd_dwh.dim_channel ch       ON ch.channel_code = NVL(t.operation, 'NONE')
      LEFT JOIN fd_dwh.dim_txn_category cat ON cat.category_code = NVL(t.k_symbol, 'NONE')
     WHERE t.batch_id = g_batch_id
       AND NOT EXISTS (SELECT 1 FROM fd_dwh.fact_transaction f WHERE f.trans_id = t.trans_id);
    v_loaded := SQL%ROWCOUNT;

    -- R008 (WARN): facts parked on an unknown member.
    INSERT INTO fd_ops.etl_error_log (batch_id, log_id, source_table, source_key, rule_code, severity, error_msg)
    SELECT g_batch_id, g_log_id, 'FACT_TRANSACTION', TO_CHAR(f.trans_id), r.rule_code, r.severity, r.description
      FROM fd_dwh.fact_transaction f
      JOIN fd_ops.dq_rule r ON r.rule_code = 'R008'
     WHERE f.batch_id = g_batch_id
       AND -1 IN (f.account_key, f.customer_key, f.branch_key, f.channel_key, f.category_key);
    v_unknown := SQL%ROWCOUNT;

    end_task(v_read, v_loaded, v_unknown || ' row(s) mapped to an unknown member');
  END load_fact_transaction;

  -- ----------------------------------------------------------------------- run
  PROCEDURE run (p_batch_id IN NUMBER, p_parent_log_id IN NUMBER) IS
  BEGIN
    g_batch_id  := p_batch_id;
    g_parent_id := p_parent_log_id;
    g_as_of     := fd_ops.pkg_etl_ctl.batch_as_of(p_batch_id);
    g_wm_from   := fd_ops.pkg_etl_ctl.batch_wm_from(p_batch_id);

    load_branch;
    load_account;
    load_channel;
    load_customer;
    load_fact_transaction;

    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      IF g_log_id IS NOT NULL THEN
        fd_ops.pkg_etl_log.log_step(g_log_id, 'FAILED', p_error_msg => SQLERRM,
                                    p_error_stack => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        g_log_id := NULL;
      END IF;
      RAISE;
  END run;

END pkg_load_dwh;
/
SHOW ERRORS PACKAGE BODY fd_dwh.pkg_load_dwh

-- Only the orchestrator may run this step.
GRANT EXECUTE ON fd_dwh.pkg_load_dwh TO fd_ops;
