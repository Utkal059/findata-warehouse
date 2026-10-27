-- =============================================================================
-- plsql/40_pkg_clean.sql
-- CLEAN step: STAGING -> CLEAN + QUARANTINE.
--   * reads the fd_cln.v_chk_* views (typing, translation, dedup, rules)
--   * reject_codes IS NULL     -> MERGE (masters) / INSERT (trans) into cln_*
--   * reject_codes IS NOT NULL -> q_* quarantine + one etl_error_log row per rule
--   * R004 (running balance) is a WARN rule: row kept, flagged, logged
-- Parents are cleaned before children so orphan checks see this batch's keys.
-- The whole step is one transaction: it commits at the end or rolls back.
-- =============================================================================

CREATE OR REPLACE PACKAGE fd_cln.pkg_clean AUTHID DEFINER AS
  PROCEDURE run (p_batch_id IN NUMBER, p_parent_log_id IN NUMBER);
END pkg_clean;
/

CREATE OR REPLACE PACKAGE BODY fd_cln.pkg_clean AS

  g_batch_id   NUMBER;
  g_parent_id  NUMBER;
  g_log_id     NUMBER;

  PROCEDURE begin_task (p_name IN VARCHAR2) IS
  BEGIN
    g_log_id := fd_ops.pkg_etl_log.start_step(g_batch_id, 'CLEAN:' || p_name, g_parent_id);
  END begin_task;

  PROCEDURE end_task (p_read IN NUMBER, p_rejected IN NUMBER) IS
  BEGIN
    fd_ops.pkg_etl_log.log_step(g_log_id, 'SUCCESS', p_read, p_read - p_rejected, p_rejected);
    g_log_id := NULL;
  END end_task;

  -- One etl_error_log row per (quarantined row, broken rule), same transaction.
  PROCEDURE log_rejects (p_source IN VARCHAR2, p_q_table IN VARCHAR2, p_key_col IN VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE
      'INSERT INTO fd_ops.etl_error_log
              (batch_id, log_id, source_table, source_key, rule_code, severity, error_msg)
       SELECT q.batch_id, :log_id, :src, q.' || DBMS_ASSERT.SIMPLE_SQL_NAME(p_key_col) || ',
              r.rule_code, r.severity, r.description
         FROM fd_cln.' || DBMS_ASSERT.SIMPLE_SQL_NAME(p_q_table) || ' q
         JOIN fd_ops.dq_rule r
           ON INSTR('','' || q.reject_codes || '','', '','' || r.rule_code || '','') > 0
        WHERE q.batch_id = :b'
      USING g_log_id, p_source, g_batch_id;
  END log_rejects;

  -- ------------------------------------------------------------------ masters
  PROCEDURE clean_district IS
    v_read NUMBER; v_bad NUMBER;
  BEGIN
    begin_task('DISTRICT');
    SELECT COUNT(*) INTO v_read FROM fd_cln.v_chk_district;

    DELETE FROM fd_cln.q_district WHERE batch_id = g_batch_id;
    INSERT INTO fd_cln.q_district (stg_row_id, batch_id, reject_codes,
           a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16)
    SELECT stg_row_id, g_batch_id, reject_codes,
           a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16
      FROM fd_cln.v_chk_district
     WHERE reject_codes IS NOT NULL;
    v_bad := SQL%ROWCOUNT;

    MERGE INTO fd_cln.cln_district c
    USING (SELECT * FROM fd_cln.v_chk_district WHERE reject_codes IS NULL) s
       ON (c.district_id = s.district_id)
    WHEN MATCHED THEN UPDATE SET
         c.district_name = s.district_name, c.region = s.region, c.inhabitants = s.inhabitants,
         c.munic_lt_500 = s.munic_lt_500, c.munic_500_1999 = s.munic_500_1999,
         c.munic_2000_9999 = s.munic_2000_9999, c.munic_ge_10000 = s.munic_ge_10000,
         c.city_cnt = s.city_cnt, c.urban_ratio_pct = s.urban_ratio_pct, c.avg_salary = s.avg_salary,
         c.unemp_rate_95 = s.unemp_rate_95, c.unemp_rate_96 = s.unemp_rate_96,
         c.entrepreneurs_per_1000 = s.entrepreneurs_per_1000,
         c.crimes_95 = s.crimes_95, c.crimes_96 = s.crimes_96,
         c.batch_id = g_batch_id, c.updated_ts = SYSTIMESTAMP
       WHERE DECODE(c.district_name, s.district_name, 0, 1) + DECODE(c.region, s.region, 0, 1)
           + DECODE(c.inhabitants, s.inhabitants, 0, 1) + DECODE(c.avg_salary, s.avg_salary, 0, 1)
           + DECODE(c.urban_ratio_pct, s.urban_ratio_pct, 0, 1) + DECODE(c.city_cnt, s.city_cnt, 0, 1)
           + DECODE(c.unemp_rate_95, s.unemp_rate_95, 0, 1) + DECODE(c.unemp_rate_96, s.unemp_rate_96, 0, 1)
           + DECODE(c.crimes_95, s.crimes_95, 0, 1) + DECODE(c.crimes_96, s.crimes_96, 0, 1)
           + DECODE(c.entrepreneurs_per_1000, s.entrepreneurs_per_1000, 0, 1)
           + DECODE(c.munic_lt_500, s.munic_lt_500, 0, 1) + DECODE(c.munic_500_1999, s.munic_500_1999, 0, 1)
           + DECODE(c.munic_2000_9999, s.munic_2000_9999, 0, 1) + DECODE(c.munic_ge_10000, s.munic_ge_10000, 0, 1) > 0
    WHEN NOT MATCHED THEN INSERT
         (district_id, district_name, region, inhabitants, munic_lt_500, munic_500_1999,
          munic_2000_9999, munic_ge_10000, city_cnt, urban_ratio_pct, avg_salary,
          unemp_rate_95, unemp_rate_96, entrepreneurs_per_1000, crimes_95, crimes_96, batch_id)
         VALUES
         (s.district_id, s.district_name, s.region, s.inhabitants, s.munic_lt_500, s.munic_500_1999,
          s.munic_2000_9999, s.munic_ge_10000, s.city_cnt, s.urban_ratio_pct, s.avg_salary,
          s.unemp_rate_95, s.unemp_rate_96, s.entrepreneurs_per_1000, s.crimes_95, s.crimes_96, g_batch_id);

    log_rejects('DISTRICT', 'Q_DISTRICT', 'A1');
    end_task(v_read, v_bad);
  END clean_district;

  PROCEDURE clean_account IS
    v_read NUMBER; v_bad NUMBER;
  BEGIN
    begin_task('ACCOUNT');
    SELECT COUNT(*) INTO v_read FROM fd_cln.v_chk_account;

    DELETE FROM fd_cln.q_account WHERE batch_id = g_batch_id;
    INSERT INTO fd_cln.q_account (stg_row_id, batch_id, reject_codes, account_id, district_id, frequency, acct_date)
    SELECT stg_row_id, g_batch_id, reject_codes, account_id, district_id, frequency, acct_date
      FROM fd_cln.v_chk_account
     WHERE reject_codes IS NOT NULL;
    v_bad := SQL%ROWCOUNT;

    MERGE INTO fd_cln.cln_account c
    USING (SELECT account_id_n, district_id_n, frequency_std, open_date
             FROM fd_cln.v_chk_account WHERE reject_codes IS NULL) s
       ON (c.account_id = s.account_id_n)
    WHEN MATCHED THEN UPDATE SET
         c.district_id = s.district_id_n, c.frequency = s.frequency_std, c.open_date = s.open_date,
         c.batch_id = g_batch_id, c.updated_ts = SYSTIMESTAMP
       WHERE DECODE(c.district_id, s.district_id_n, 0, 1) + DECODE(c.frequency, s.frequency_std, 0, 1)
           + DECODE(c.open_date, s.open_date, 0, 1) > 0
    WHEN NOT MATCHED THEN INSERT (account_id, district_id, frequency, open_date, batch_id)
         VALUES (s.account_id_n, s.district_id_n, s.frequency_std, s.open_date, g_batch_id);

    log_rejects('ACCOUNT', 'Q_ACCOUNT', 'ACCOUNT_ID');
    end_task(v_read, v_bad);
  END clean_account;

  PROCEDURE clean_client IS
    v_read NUMBER; v_bad NUMBER;
  BEGIN
    begin_task('CLIENT');
    SELECT COUNT(*) INTO v_read FROM fd_cln.v_chk_client;

    DELETE FROM fd_cln.q_client WHERE batch_id = g_batch_id;
    INSERT INTO fd_cln.q_client (stg_row_id, batch_id, reject_codes, client_id, birth_number, district_id)
    SELECT stg_row_id, g_batch_id, reject_codes, client_id, birth_number, district_id
      FROM fd_cln.v_chk_client
     WHERE reject_codes IS NOT NULL;
    v_bad := SQL%ROWCOUNT;

    MERGE INTO fd_cln.cln_client c
    USING (SELECT client_id_n, bn, gender, birth_date, district_id_n
             FROM fd_cln.v_chk_client WHERE reject_codes IS NULL) s
       ON (c.client_id = s.client_id_n)
    WHEN MATCHED THEN UPDATE SET
         c.birth_number = s.bn, c.gender = s.gender, c.birth_date = s.birth_date,
         c.district_id = s.district_id_n, c.batch_id = g_batch_id, c.updated_ts = SYSTIMESTAMP
       WHERE DECODE(c.birth_number, s.bn, 0, 1) + DECODE(c.district_id, s.district_id_n, 0, 1) > 0
    WHEN NOT MATCHED THEN INSERT (client_id, birth_number, gender, birth_date, district_id, batch_id)
         VALUES (s.client_id_n, s.bn, s.gender, s.birth_date, s.district_id_n, g_batch_id);

    log_rejects('CLIENT', 'Q_CLIENT', 'CLIENT_ID');
    end_task(v_read, v_bad);
  END clean_client;

  PROCEDURE clean_disp IS
    v_read NUMBER; v_bad NUMBER;
  BEGIN
    begin_task('DISP');
    SELECT COUNT(*) INTO v_read FROM fd_cln.v_chk_disp;

    DELETE FROM fd_cln.q_disp WHERE batch_id = g_batch_id;
    INSERT INTO fd_cln.q_disp (stg_row_id, batch_id, reject_codes, disp_id, client_id, account_id, disp_type)
    SELECT stg_row_id, g_batch_id, reject_codes, disp_id, client_id, account_id, disp_type
      FROM fd_cln.v_chk_disp
     WHERE reject_codes IS NOT NULL;
    v_bad := SQL%ROWCOUNT;

    MERGE INTO fd_cln.cln_disp c
    USING (SELECT disp_id_n, client_id_n, account_id_n, disp_type_std
             FROM fd_cln.v_chk_disp WHERE reject_codes IS NULL) s
       ON (c.disp_id = s.disp_id_n)
    WHEN MATCHED THEN UPDATE SET
         c.client_id = s.client_id_n, c.account_id = s.account_id_n, c.disp_type = s.disp_type_std,
         c.batch_id = g_batch_id, c.updated_ts = SYSTIMESTAMP
       WHERE DECODE(c.client_id, s.client_id_n, 0, 1) + DECODE(c.account_id, s.account_id_n, 0, 1)
           + DECODE(c.disp_type, s.disp_type_std, 0, 1) > 0
    WHEN NOT MATCHED THEN INSERT (disp_id, client_id, account_id, disp_type, batch_id)
         VALUES (s.disp_id_n, s.client_id_n, s.account_id_n, s.disp_type_std, g_batch_id);

    log_rejects('DISP', 'Q_DISP', 'DISP_ID');
    end_task(v_read, v_bad);
  END clean_disp;

  PROCEDURE clean_card IS
    v_read NUMBER; v_bad NUMBER;
  BEGIN
    begin_task('CARD');
    SELECT COUNT(*) INTO v_read FROM fd_cln.v_chk_card;

    DELETE FROM fd_cln.q_card WHERE batch_id = g_batch_id;
    INSERT INTO fd_cln.q_card (stg_row_id, batch_id, reject_codes, card_id, disp_id, card_type, issued)
    SELECT stg_row_id, g_batch_id, reject_codes, card_id, disp_id, card_type, issued
      FROM fd_cln.v_chk_card
     WHERE reject_codes IS NOT NULL;
    v_bad := SQL%ROWCOUNT;

    MERGE INTO fd_cln.cln_card c
    USING (SELECT card_id_n, disp_id_n, card_type_std, issued_date
             FROM fd_cln.v_chk_card WHERE reject_codes IS NULL) s
       ON (c.card_id = s.card_id_n)
    WHEN MATCHED THEN UPDATE SET
         c.disp_id = s.disp_id_n, c.card_type = s.card_type_std, c.issued_date = s.issued_date,
         c.batch_id = g_batch_id, c.updated_ts = SYSTIMESTAMP
       WHERE DECODE(c.disp_id, s.disp_id_n, 0, 1) + DECODE(c.card_type, s.card_type_std, 0, 1)
           + DECODE(c.issued_date, s.issued_date, 0, 1) > 0
    WHEN NOT MATCHED THEN INSERT (card_id, disp_id, card_type, issued_date, batch_id)
         VALUES (s.card_id_n, s.disp_id_n, s.card_type_std, s.issued_date, g_batch_id);

    log_rejects('CARD', 'Q_CARD', 'CARD_ID');
    end_task(v_read, v_bad);
  END clean_card;

  PROCEDURE clean_loan IS
    v_read NUMBER; v_bad NUMBER;
  BEGIN
    begin_task('LOAN');
    SELECT COUNT(*) INTO v_read FROM fd_cln.v_chk_loan;

    DELETE FROM fd_cln.q_loan WHERE batch_id = g_batch_id;
    INSERT INTO fd_cln.q_loan (stg_row_id, batch_id, reject_codes, loan_id, account_id, loan_date,
                               amount, duration, payments, status)
    SELECT stg_row_id, g_batch_id, reject_codes, loan_id, account_id, loan_date,
           amount, duration, payments, status
      FROM fd_cln.v_chk_loan
     WHERE reject_codes IS NOT NULL;
    v_bad := SQL%ROWCOUNT;

    MERGE INTO fd_cln.cln_loan c
    USING (SELECT loan_id_n, account_id_n, loan_date_d, amount_n, duration_n, payments_n,
                  status_code, loan_status
             FROM fd_cln.v_chk_loan WHERE reject_codes IS NULL) s
       ON (c.loan_id = s.loan_id_n)
    WHEN MATCHED THEN UPDATE SET
         c.account_id = s.account_id_n, c.loan_date = s.loan_date_d, c.amount = s.amount_n,
         c.duration_months = s.duration_n, c.monthly_payment = s.payments_n,
         c.status_code = s.status_code, c.loan_status = s.loan_status,
         c.batch_id = g_batch_id, c.updated_ts = SYSTIMESTAMP
       WHERE DECODE(c.account_id, s.account_id_n, 0, 1) + DECODE(c.loan_date, s.loan_date_d, 0, 1)
           + DECODE(c.amount, s.amount_n, 0, 1) + DECODE(c.duration_months, s.duration_n, 0, 1)
           + DECODE(c.monthly_payment, s.payments_n, 0, 1) + DECODE(c.status_code, s.status_code, 0, 1) > 0
    WHEN NOT MATCHED THEN INSERT
         (loan_id, account_id, loan_date, amount, duration_months, monthly_payment,
          status_code, loan_status, batch_id)
         VALUES
         (s.loan_id_n, s.account_id_n, s.loan_date_d, s.amount_n, s.duration_n, s.payments_n,
          s.status_code, s.loan_status, g_batch_id);

    log_rejects('LOAN', 'Q_LOAN', 'LOAN_ID');
    end_task(v_read, v_bad);
  END clean_loan;

  PROCEDURE clean_order IS
    v_read NUMBER; v_bad NUMBER;
  BEGIN
    begin_task('ORDER');
    SELECT COUNT(*) INTO v_read FROM fd_cln.v_chk_order;

    DELETE FROM fd_cln.q_order WHERE batch_id = g_batch_id;
    INSERT INTO fd_cln.q_order (stg_row_id, batch_id, reject_codes, order_id, account_id, bank_to,
                                account_to, amount, k_symbol)
    SELECT stg_row_id, g_batch_id, reject_codes, order_id, account_id, bank_to,
           account_to, amount, k_symbol
      FROM fd_cln.v_chk_order
     WHERE reject_codes IS NOT NULL;
    v_bad := SQL%ROWCOUNT;

    MERGE INTO fd_cln.cln_order c
    USING (SELECT order_id_n, account_id_n, bank_to_std, account_to_std, amount_n, k_symbol_std
             FROM fd_cln.v_chk_order WHERE reject_codes IS NULL) s
       ON (c.order_id = s.order_id_n)
    WHEN MATCHED THEN UPDATE SET
         c.account_id = s.account_id_n, c.bank_to = s.bank_to_std, c.account_to = s.account_to_std,
         c.amount = s.amount_n, c.k_symbol = s.k_symbol_std,
         c.batch_id = g_batch_id, c.updated_ts = SYSTIMESTAMP
       WHERE DECODE(c.account_id, s.account_id_n, 0, 1) + DECODE(c.bank_to, s.bank_to_std, 0, 1)
           + DECODE(c.account_to, s.account_to_std, 0, 1) + DECODE(c.amount, s.amount_n, 0, 1)
           + DECODE(c.k_symbol, s.k_symbol_std, 0, 1) > 0
    WHEN NOT MATCHED THEN INSERT (order_id, account_id, bank_to, account_to, amount, k_symbol, batch_id)
         VALUES (s.order_id_n, s.account_id_n, s.bank_to_std, s.account_to_std, s.amount_n,
                 s.k_symbol_std, g_batch_id);

    log_rejects('ORDER', 'Q_ORDER', 'ORDER_ID');
    end_task(v_read, v_bad);
  END clean_order;

  -- -------------------------------------------------------------------- trans
  PROCEDURE clean_trans IS
    v_read NUMBER; v_bad NUMBER;
  BEGIN
    begin_task('TRANS');

    -- Replay-safe: remove anything an earlier attempt of this batch produced.
    DELETE FROM fd_cln.cln_trans WHERE batch_id = g_batch_id;
    DELETE FROM fd_cln.q_trans   WHERE batch_id = g_batch_id;

    SELECT COUNT(*) INTO v_read FROM fd_stg.stg_trans WHERE load_batch_id = g_batch_id;

    -- One pass over the batch: good rows to CLEAN, the rest to QUARANTINE.
    INSERT FIRST
      WHEN reject_codes IS NULL THEN
        INTO fd_cln.cln_trans (trans_id, account_id, trans_date, txn_type, operation, amount, balance,
                               k_symbol, bank, counterparty_account, batch_id)
        VALUES (trans_id_n, account_id_n, trans_date_d, txn_type, operation_std, amount_n, balance_n,
                k_symbol_std, bank_std, counterparty_account_std, g_batch_id)
      ELSE
        INTO fd_cln.q_trans (stg_row_id, batch_id, reject_codes, trans_id, account_id, trans_date,
                             trans_type, operation, amount, balance, k_symbol, bank, account)
        VALUES (stg_row_id, g_batch_id, reject_codes, trans_id, account_id, trans_date,
                trans_type, operation, amount, balance, k_symbol, bank, account)
    SELECT * FROM fd_cln.v_chk_trans WHERE load_batch_id = g_batch_id;

    SELECT COUNT(*) INTO v_bad FROM fd_cln.q_trans WHERE batch_id = g_batch_id;
    log_rejects('TRANS', 'Q_TRANS', 'TRANS_ID');
    end_task(v_read, v_bad);
  END clean_trans;

  -- R004 (WARN): the balance before a transaction (balance -/+ amount) must be
  -- a balance that existed just before it. The source has dates but no
  -- times, and same-day order does not follow trans_id (e.g. month-end
  -- interest is credited before the statement fee), so a strict LAG() check
  -- raises false alarms on 48% of rows. Order-independent version: the
  -- opening balance must equal some balance on the same or the previous
  -- active day of the account. Remaining hits are real source differences
  -- (e.g. interest postings off by 0.10 CZK), so R004 warns, not rejects.
  PROCEDURE check_balances IS
    v_hits    NUMBER;
    v_checked NUMBER;
  BEGIN
    begin_task('TRANS_R004');

    MERGE INTO fd_cln.cln_trans c
    USING (
      WITH x AS (
        SELECT t.trans_id, t.account_id, t.batch_id,
               ROUND(t.balance, 2) AS bal,
               ROUND(t.balance - CASE t.txn_type WHEN 'DEBIT' THEN -t.amount ELSE t.amount END, 2) AS pre_bal,
               DENSE_RANK() OVER (PARTITION BY t.account_id ORDER BY t.trans_date) AS day_no
          FROM fd_cln.cln_trans t
         WHERE t.account_id IN (SELECT account_id FROM fd_cln.cln_trans WHERE batch_id = g_batch_id)
      ), candidates AS (                       -- balances seen on the same day ...
        SELECT account_id, day_no, bal, trans_id FROM x
        UNION ALL                              -- ... or on the previous active day
        SELECT account_id, day_no + 1, bal, trans_id FROM x
      )
      SELECT x.trans_id
        FROM x
       WHERE x.batch_id = g_batch_id
         AND x.day_no > 1
         AND NOT EXISTS (SELECT 1
                           FROM candidates c
                          WHERE c.account_id = x.account_id
                            AND c.day_no     = x.day_no
                            AND c.bal        = x.pre_bal
                            AND c.trans_id  <> x.trans_id)
    ) s
    ON (c.trans_id = s.trans_id)
    WHEN MATCHED THEN UPDATE SET c.dq_warn_codes = 'R004';
    v_hits := SQL%ROWCOUNT;

    INSERT INTO fd_ops.etl_error_log (batch_id, log_id, source_table, source_key, rule_code, severity, error_msg)
    SELECT g_batch_id, g_log_id, 'TRANS', TO_CHAR(c.trans_id), r.rule_code, r.severity, r.description
      FROM fd_cln.cln_trans c
      JOIN fd_ops.dq_rule r ON r.rule_code = 'R004'
     WHERE c.batch_id = g_batch_id
       AND c.dq_warn_codes = 'R004';

    -- rows_read = rows checked, rows_rejected = 0 (warnings do not reject)
    SELECT COUNT(*) INTO v_checked FROM fd_cln.cln_trans WHERE batch_id = g_batch_id;
    fd_ops.pkg_etl_log.log_step(g_log_id, 'SUCCESS', v_checked, NULL, 0,
                                v_hits || ' row(s) flagged R004 (WARN)');
    g_log_id := NULL;
  END check_balances;

  -- ----------------------------------------------------------------------- run
  PROCEDURE run (p_batch_id IN NUMBER, p_parent_log_id IN NUMBER) IS
  BEGIN
    g_batch_id  := p_batch_id;
    g_parent_id := p_parent_log_id;

    clean_district;
    clean_account;
    clean_client;
    clean_disp;
    clean_card;
    clean_loan;
    clean_order;
    clean_trans;
    check_balances;

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

END pkg_clean;
/
SHOW ERRORS PACKAGE BODY fd_cln.pkg_clean

-- Only the orchestrator may run this step.
GRANT EXECUTE ON fd_cln.pkg_clean TO fd_ops;
