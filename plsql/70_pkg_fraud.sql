-- =============================================================================
-- plsql/70_pkg_fraud.sql
-- FRAUD step: rule-based transaction monitoring over the facts of one batch.
--
--   F01  large outflow from a newly opened account
--   F02  large debit on an account that was dormant
--   F03  rapid pass-through: most of a large credit leaves within days
--   F04  cash structuring: several same-day cash amounts just under a limit
--   F05  large round-amount cash withdrawal
--
-- Thresholds come from fd_dwh.rule_param; inactive rules (rule_config.is_active
-- = 'N') are skipped. An alert is unique per (txn_key, rule_code), so a replay
-- never duplicates alerts and never reopens one an analyst has closed.
-- =============================================================================

CREATE OR REPLACE PACKAGE fd_dwh.pkg_fraud AUTHID DEFINER AS

  PROCEDURE run (p_batch_id IN NUMBER, p_parent_log_id IN NUMBER);

  -- Analyst action; the status change is audited by trg_fraud_alerts_audit.
  PROCEDURE close_alert (p_alert_id IN NUMBER, p_note IN VARCHAR2);

END pkg_fraud;
/

CREATE OR REPLACE PACKAGE BODY fd_dwh.pkg_fraud AS

  g_batch_id   NUMBER;
  g_parent_id  NUMBER;
  g_log_id     NUMBER;
  g_as_of      DATE;
  g_wm_from    DATE;
  g_scan_from  DATE;     -- first day of this batch's window

  FUNCTION param (p_rule_code IN VARCHAR2, p_name IN VARCHAR2) RETURN NUMBER IS
    v_value NUMBER;
  BEGIN
    SELECT param_value INTO v_value
      FROM fd_dwh.rule_param
     WHERE rule_code = p_rule_code AND param_name = p_name;
    RETURN v_value;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20701, 'Missing rule_param ' || p_rule_code || '.' || p_name);
  END param;

  FUNCTION is_active (p_rule_code IN VARCHAR2) RETURN BOOLEAN IS
    v_flag CHAR(1);
  BEGIN
    SELECT is_active INTO v_flag FROM fd_dwh.rule_config WHERE rule_code = p_rule_code;
    RETURN v_flag = 'Y';
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN FALSE;
  END is_active;

  PROCEDURE begin_task (p_rule_code IN VARCHAR2) IS
  BEGIN
    g_log_id := fd_ops.pkg_etl_log.start_step(g_batch_id, 'FRAUD:' || p_rule_code, g_parent_id);
  END begin_task;

  PROCEDURE end_task (p_alerts IN NUMBER, p_msg IN VARCHAR2) IS
  BEGIN
    fd_ops.pkg_etl_log.log_step(g_log_id, 'SUCCESS', NULL, p_alerts, 0, p_msg);
    g_log_id := NULL;
  END end_task;

  -- --------------------------------------------------------------------- F01
  PROCEDURE scan_f01 IS
    v_days   NUMBER := param('F01', 'MAX_ACCOUNT_AGE_DAYS');
    v_amount NUMBER := param('F01', 'MIN_AMOUNT');
  BEGIN
    begin_task('F01');
    INSERT INTO fd_dwh.fraud_alerts (txn_key, trans_id, account_key, txn_date, rule_code, severity,
                                     alert_reason, batch_id)
    SELECT f.txn_key, f.trans_id, f.account_key, f.txn_date, rc.rule_code, rc.severity,
           ch.channel_name || ' of ' || TO_CHAR(f.amount, 'FM999G999G990D00') || ' CZK '
             || (f.txn_date - a.open_date) || ' day(s) after the account was opened ('
             || TO_CHAR(a.open_date, 'YYYY-MM-DD') || '); rule: >= ' || v_amount
             || ' CZK within ' || v_days || ' days',
           g_batch_id
      FROM fd_dwh.fact_transaction f
      JOIN fd_dwh.dim_account a  ON a.account_key = f.account_key
      JOIN fd_dwh.dim_channel ch ON ch.channel_key = f.channel_key
      JOIN fd_dwh.rule_config rc ON rc.rule_code = 'F01'
     WHERE f.batch_id = g_batch_id
       AND f.txn_type = 'DEBIT'
       AND ch.channel_code IN ('OUTBOUND_TRANSFER', 'CASH_WITHDRAWAL')
       AND f.amount >= v_amount
       AND f.txn_date - a.open_date BETWEEN 0 AND v_days
       AND NOT EXISTS (SELECT 1 FROM fd_dwh.fraud_alerts x
                        WHERE x.txn_key = f.txn_key AND x.rule_code = 'F01');
    end_task(SQL%ROWCOUNT, '>= ' || v_amount || ' CZK out within ' || v_days || ' days of opening');
  END scan_f01;

  -- --------------------------------------------------------------------- F02
  -- Activity = any transaction except bank postings (interest, penalty
  -- interest, statement fees), which arrive whether or not the client acts.
  PROCEDURE scan_f02 IS
    v_days   NUMBER := param('F02', 'MIN_DORMANT_DAYS');
    v_amount NUMBER := param('F02', 'MIN_AMOUNT');
    v_from   DATE;
  BEGIN
    begin_task('F02');
    v_from := g_scan_from - v_days - 1;

    INSERT INTO fd_dwh.fraud_alerts (txn_key, trans_id, account_key, txn_date, rule_code, severity,
                                     alert_reason, batch_id)
    SELECT z.txn_key, z.trans_id, z.account_key, z.txn_date, rc.rule_code, rc.severity,
           'Debit of ' || TO_CHAR(z.amount, 'FM999G999G990D00') || ' CZK after '
             || (z.txn_date - z.last_activity) || ' day(s) without client activity (last: '
             || TO_CHAR(z.last_activity, 'YYYY-MM-DD') || '); rule: >= ' || v_amount
             || ' CZK after >= ' || v_days || ' dormant days',
           g_batch_id
      FROM (SELECT y.*,
                   NVL(y.prev_date, GREATEST(y.open_date, v_from)) AS last_activity
              FROM (SELECT f.txn_key, f.trans_id, f.account_key, f.txn_date, f.txn_type, f.amount,
                           f.batch_id, a.open_date,
                           LAG(f.txn_date) OVER (PARTITION BY f.account_key
                                                 ORDER BY f.txn_date, f.trans_id) AS prev_date
                      FROM fd_dwh.fact_transaction f
                      JOIN fd_dwh.dim_account a      ON a.account_key = f.account_key
                      JOIN fd_dwh.dim_txn_category c ON c.category_key = f.category_key
                     WHERE f.txn_date > v_from
                       AND f.txn_date <= g_as_of
                       AND c.category_code NOT IN ('INTEREST', 'PENALTY_INTEREST', 'STATEMENT')) y) z
      JOIN fd_dwh.rule_config rc ON rc.rule_code = 'F02'
     WHERE z.batch_id = g_batch_id
       AND z.txn_type = 'DEBIT'
       AND z.amount >= v_amount
       AND z.txn_date - z.last_activity >= v_days
       AND NOT EXISTS (SELECT 1 FROM fd_dwh.fraud_alerts x
                        WHERE x.txn_key = z.txn_key AND x.rule_code = 'F02');
    end_task(SQL%ROWCOUNT, '>= ' || v_amount || ' CZK debit after ' || v_days || ' dormant days');
  END scan_f02;

  -- --------------------------------------------------------------------- F03
  PROCEDURE scan_f03 IS
    v_days    NUMBER := param('F03', 'WINDOW_DAYS');
    v_credit  NUMBER := param('F03', 'MIN_CREDIT');
    v_pct     NUMBER := param('F03', 'MIN_OUT_PCT');
  BEGIN
    begin_task('F03');
    INSERT INTO fd_dwh.fraud_alerts (txn_key, trans_id, account_key, txn_date, rule_code, severity,
                                     alert_reason, batch_id)
    SELECT z.txn_key, z.trans_id, z.account_key, z.txn_date, rc.rule_code, rc.severity,
           'Debit of ' || TO_CHAR(z.amount, 'FM999G999G990D00') || ' CZK = '
             || ROUND(100 * z.amount / z.recent_credit) || '% of a '
             || TO_CHAR(z.recent_credit, 'FM999G999G990D00') || ' CZK credit received within '
             || v_days || ' day(s); rule: credit >= ' || v_credit || ' CZK, outflow >= '
             || v_pct || '%',
           g_batch_id
      FROM (SELECT f.txn_key, f.trans_id, f.account_key, f.txn_date, f.txn_type, f.amount, f.batch_id,
                   MAX(CASE WHEN f.txn_type = 'CREDIT'
                             AND c.category_group <> 'INCOME'
                             AND f.amount >= v_credit THEN f.amount END)
                     OVER (PARTITION BY f.account_key ORDER BY f.txn_date
                           RANGE BETWEEN v_days PRECEDING AND CURRENT ROW) AS recent_credit
              FROM fd_dwh.fact_transaction f
              JOIN fd_dwh.dim_txn_category c ON c.category_key = f.category_key
             WHERE f.txn_date > g_scan_from - v_days - 1
               AND f.txn_date <= g_as_of) z
      JOIN fd_dwh.rule_config rc ON rc.rule_code = 'F03'
     WHERE z.batch_id = g_batch_id
       AND z.txn_type = 'DEBIT'
       AND z.recent_credit IS NOT NULL
       AND z.amount >= z.recent_credit * v_pct / 100
       AND NOT EXISTS (SELECT 1 FROM fd_dwh.fraud_alerts x
                        WHERE x.txn_key = z.txn_key AND x.rule_code = 'F03');
    end_task(SQL%ROWCOUNT, '>= ' || v_pct || '% of a >= ' || v_credit || ' CZK credit out within '
                           || v_days || ' days');
  END scan_f03;

  -- --------------------------------------------------------------------- F04
  -- One alert per account-day, attached to the last cash transaction of the day.
  PROCEDURE scan_f04 IS
    v_limit  NUMBER := param('F04', 'REPORTING_LIMIT');
    v_band   NUMBER := param('F04', 'BAND_PCT');
    v_count  NUMBER := param('F04', 'MIN_COUNT');
  BEGIN
    begin_task('F04');
    INSERT INTO fd_dwh.fraud_alerts (txn_key, trans_id, account_key, txn_date, rule_code, severity,
                                     alert_reason, batch_id)
    SELECT z.txn_key, z.trans_id, z.account_key, z.txn_date, rc.rule_code, rc.severity,
           z.n_day || ' cash transactions on one day between '
             || TO_CHAR(v_limit * (1 - v_band / 100), 'FM999G999G990') || ' and '
             || TO_CHAR(v_limit, 'FM999G999G990') || ' CZK (total '
             || TO_CHAR(z.day_total, 'FM999G999G990D00') || ' CZK); rule: >= ' || v_count
             || ' just under the ' || v_limit || ' CZK limit',
           g_batch_id
      FROM (SELECT f.txn_key, f.trans_id, f.account_key, f.txn_date,
                   COUNT(*)      OVER (PARTITION BY f.account_key, f.txn_date) AS n_day,
                   SUM(f.amount) OVER (PARTITION BY f.account_key, f.txn_date) AS day_total,
                   ROW_NUMBER()  OVER (PARTITION BY f.account_key, f.txn_date
                                       ORDER BY f.trans_id DESC) AS rn
              FROM fd_dwh.fact_transaction f
              JOIN fd_dwh.dim_channel ch ON ch.channel_key = f.channel_key
             WHERE f.batch_id = g_batch_id
               AND ch.channel_group = 'CASH'
               AND f.amount >= v_limit * (1 - v_band / 100)
               AND f.amount <  v_limit) z
      JOIN fd_dwh.rule_config rc ON rc.rule_code = 'F04'
     WHERE z.n_day >= v_count
       AND z.rn = 1
       AND NOT EXISTS (SELECT 1 FROM fd_dwh.fraud_alerts x
                        WHERE x.txn_key = z.txn_key AND x.rule_code = 'F04');
    end_task(SQL%ROWCOUNT, '>= ' || v_count || ' same-day cash txns within ' || v_band
                           || '% under ' || v_limit || ' CZK');
  END scan_f04;

  -- --------------------------------------------------------------------- F05
  PROCEDURE scan_f05 IS
    v_amount NUMBER := param('F05', 'MIN_AMOUNT');
    v_round  NUMBER := param('F05', 'ROUND_UNIT');
  BEGIN
    begin_task('F05');
    INSERT INTO fd_dwh.fraud_alerts (txn_key, trans_id, account_key, txn_date, rule_code, severity,
                                     alert_reason, batch_id)
    SELECT f.txn_key, f.trans_id, f.account_key, f.txn_date, rc.rule_code, rc.severity,
           'Cash withdrawal of exactly ' || TO_CHAR(f.amount, 'FM999G999G990') || ' CZK (a multiple of '
             || v_round || '); rule: >= ' || v_amount || ' CZK and round',
           g_batch_id
      FROM fd_dwh.fact_transaction f
      JOIN fd_dwh.dim_channel ch ON ch.channel_key = f.channel_key
      JOIN fd_dwh.rule_config rc ON rc.rule_code = 'F05'
     WHERE f.batch_id = g_batch_id
       AND f.txn_type = 'DEBIT'
       AND ch.channel_code = 'CASH_WITHDRAWAL'
       AND f.amount >= v_amount
       AND MOD(f.amount, v_round) = 0
       AND NOT EXISTS (SELECT 1 FROM fd_dwh.fraud_alerts x
                        WHERE x.txn_key = f.txn_key AND x.rule_code = 'F05');
    end_task(SQL%ROWCOUNT, '>= ' || v_amount || ' CZK cash, multiple of ' || v_round);
  END scan_f05;

  -- ----------------------------------------------------------------------- run
  PROCEDURE run (p_batch_id IN NUMBER, p_parent_log_id IN NUMBER) IS
  BEGIN
    g_batch_id  := p_batch_id;
    g_parent_id := p_parent_log_id;
    g_as_of     := fd_ops.pkg_etl_ctl.batch_as_of(p_batch_id);
    g_wm_from   := fd_ops.pkg_etl_ctl.batch_wm_from(p_batch_id);
    g_scan_from := NVL(g_wm_from + 1, DATE '1900-01-01');

    IF is_active('F01') THEN scan_f01; END IF;
    IF is_active('F02') THEN scan_f02; END IF;
    IF is_active('F03') THEN scan_f03; END IF;
    IF is_active('F04') THEN scan_f04; END IF;
    IF is_active('F05') THEN scan_f05; END IF;

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

  PROCEDURE close_alert (p_alert_id IN NUMBER, p_note IN VARCHAR2) IS
  BEGIN
    UPDATE fd_dwh.fraud_alerts
       SET status          = 'CLOSED',
           closed_ts       = SYSTIMESTAMP,
           closed_by       = SYS_CONTEXT('USERENV', 'SESSION_USER'),
           resolution_note = SUBSTR(p_note, 1, 400)
     WHERE alert_id = p_alert_id
       AND status = 'OPEN';
    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20702, 'Alert ' || p_alert_id || ' does not exist or is not OPEN');
    END IF;
    COMMIT;
  END close_alert;

END pkg_fraud;
/
SHOW ERRORS PACKAGE BODY fd_dwh.pkg_fraud

-- Every status / note change on an alert lands in fd_ops.audit_log
-- (old value, new value, database user, OS user, time).
CREATE OR REPLACE TRIGGER fd_dwh.trg_fraud_alerts_audit
AFTER UPDATE OF status, resolution_note ON fd_dwh.fraud_alerts
FOR EACH ROW
BEGIN
  IF NVL(:OLD.status, '~') <> NVL(:NEW.status, '~') THEN
    INSERT INTO fd_ops.audit_log (table_name, record_key, column_name, old_value, new_value,
                                  changed_by, os_user)
    VALUES ('FD_DWH.FRAUD_ALERTS', TO_CHAR(:NEW.alert_id), 'STATUS', :OLD.status, :NEW.status,
            SYS_CONTEXT('USERENV', 'SESSION_USER'), SYS_CONTEXT('USERENV', 'OS_USER'));
  END IF;
  IF NVL(:OLD.resolution_note, '~') <> NVL(:NEW.resolution_note, '~') THEN
    INSERT INTO fd_ops.audit_log (table_name, record_key, column_name, old_value, new_value,
                                  changed_by, os_user)
    VALUES ('FD_DWH.FRAUD_ALERTS', TO_CHAR(:NEW.alert_id), 'RESOLUTION_NOTE',
            :OLD.resolution_note, :NEW.resolution_note,
            SYS_CONTEXT('USERENV', 'SESSION_USER'), SYS_CONTEXT('USERENV', 'OS_USER'));
  END IF;
END;
/
SHOW ERRORS TRIGGER fd_dwh.trg_fraud_alerts_audit

GRANT EXECUTE ON fd_dwh.pkg_fraud TO fd_ops;

-- Analysts close alerts through the application login, never by direct DML.
CREATE OR REPLACE PROCEDURE fd_dwh.close_fraud_alert (p_alert_id IN NUMBER, p_note IN VARCHAR2)
  AUTHID DEFINER AS
BEGIN
  fd_dwh.pkg_fraud.close_alert(p_alert_id, p_note);
END close_fraud_alert;
/
GRANT EXECUTE ON fd_dwh.close_fraud_alert TO fd_etl;
