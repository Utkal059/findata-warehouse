-- =============================================================================
-- 90_tests/run_tests.sql
-- Warehouse test suite. Run after scripts/run_all.sql:
--     bash scripts/sqlplus.sh sql/90_tests/run_tests.sql
-- Results go to fd_ops.test_result (one row per test per run) and are printed.
-- Any FAIL makes the script exit non-zero, which fails CI.
--
-- Order matters:
--   T01-T11 read the warehouse as built.
--   T12     replays the most recent batch from STAGE and expects no change.
--   T13-T15 open one extra drill batch (same as-of date as the last batch, so
--           its TRANS window is empty): an injected failure, a refused new
--           batch, then a replay that pushes SYNTHETIC bad rows through CLEAN.
--           Those rows are made up for the test, carry trans_id 'TEST-*' style
--           values and all end in quarantine - none reaches the warehouse.
--   T16-T18 check the audit trigger (rolled back) and the security model.
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF LINESIZE 200 PAGESIZE 200 VERIFY OFF
WHENEVER SQLERROR EXIT FAILURE

DECLARE
  v_run_id   NUMBER;
  v_fails    NUMBER := 0;
  v_n        NUMBER;
  v_m        NUMBER;
  v_txt      VARCHAR2(4000);
  v_k        NUMBER;
  v_last     NUMBER;
  v_drill    NUMBER;
  v_as_of    DATE;
  v_ts       TIMESTAMP;

  TYPE t_counts IS TABLE OF NUMBER INDEX BY VARCHAR2(30);
  v_before   t_counts;
  v_after    t_counts;

  PROCEDURE chk (p_code IN VARCHAR2, p_desc IN VARCHAR2, p_ok IN BOOLEAN, p_detail IN VARCHAR2) IS
    v_status VARCHAR2(4) := CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END;
  BEGIN
    INSERT INTO fd_ops.test_result (run_id, test_code, description, status, detail)
    VALUES (v_run_id, p_code, p_desc, v_status, SUBSTR(p_detail, 1, 4000));
    COMMIT;
    IF NOT p_ok THEN
      v_fails := v_fails + 1;
    END IF;
    DBMS_OUTPUT.PUT_LINE(RPAD(p_code, 6) || RPAD(v_status, 6) || p_desc || ' | ' || p_detail);
  END chk;

  FUNCTION snapshot_counts RETURN t_counts IS
    c t_counts;
  BEGIN
    SELECT COUNT(*) INTO c('stg_trans')     FROM fd_stg.stg_trans;
    SELECT COUNT(*) INTO c('cln_trans')     FROM fd_cln.cln_trans;
    SELECT COUNT(*) INTO c('fact')          FROM fd_dwh.fact_transaction;
    SELECT COUNT(*) INTO c('dim_customer')  FROM fd_dwh.dim_customer;
    SELECT COUNT(*) INTO c('dim_account')   FROM fd_dwh.dim_account;
    SELECT COUNT(*) INTO c('loan_schedule') FROM fd_dwh.loan_schedule;
    SELECT COUNT(*) INTO c('loan_snapshot') FROM fd_dwh.fact_loan_snapshot;
    SELECT COUNT(*) INTO c('fraud_alerts')  FROM fd_dwh.fraud_alerts;
    SELECT NVL(SUM(amount), 0) INTO c('fact_amount') FROM fd_dwh.fact_transaction;
    SELECT NVL(SUM(dpd), 0)    INTO c('sum_dpd')     FROM fd_dwh.fact_loan_snapshot;
    RETURN c;
  END snapshot_counts;

  FUNCTION diff (a IN t_counts, b IN t_counts) RETURN VARCHAR2 IS
    k   VARCHAR2(30) := a.FIRST;
    out VARCHAR2(4000);
  BEGIN
    WHILE k IS NOT NULL LOOP
      IF a(k) <> b(k) THEN
        out := out || k || ' ' || a(k) || '->' || b(k) || '; ';
      END IF;
      k := a.NEXT(k);
    END LOOP;
    RETURN out;
  END diff;

BEGIN
  SELECT NVL(MAX(run_id), 0) + 1 INTO v_run_id FROM fd_ops.test_result;
  SELECT MAX(batch_id) INTO v_last FROM fd_ops.etl_batch;
  DBMS_OUTPUT.PUT_LINE('Test run ' || v_run_id || ' against batch ' || v_last);

  -- ----------------------------------------------------------------- T01 RAW
  v_txt := NULL;
  FOR r IN (SELECT 'account.asc' f, (SELECT COUNT(*) FROM fd_raw.ext_account) n FROM dual UNION ALL
            SELECT 'card.asc',     (SELECT COUNT(*) FROM fd_raw.ext_card)        FROM dual UNION ALL
            SELECT 'client.asc',   (SELECT COUNT(*) FROM fd_raw.ext_client)      FROM dual UNION ALL
            SELECT 'disp.asc',     (SELECT COUNT(*) FROM fd_raw.ext_disp)        FROM dual UNION ALL
            SELECT 'district.asc', (SELECT COUNT(*) FROM fd_raw.ext_district)    FROM dual UNION ALL
            SELECT 'loan.asc',     (SELECT COUNT(*) FROM fd_raw.ext_loan)        FROM dual UNION ALL
            SELECT 'order.asc',    (SELECT COUNT(*) FROM fd_raw.ext_order)       FROM dual UNION ALL
            SELECT 'trans.asc',    (SELECT COUNT(*) FROM fd_raw.ext_trans)       FROM dual) LOOP
    v_n := fd_raw.pkg_raw_check.file_rows(r.f);
    IF v_n <> r.n THEN
      v_txt := v_txt || r.f || ' file ' || v_n || ' vs table ' || r.n || '; ';
    END IF;
  END LOOP;
  SELECT COUNT(*) INTO v_n FROM fd_raw.ext_trans;
  chk('T01', 'RAW external tables return every data line of every file', v_txt IS NULL,
      NVL(v_txt, '8 files match; trans.asc = ' || v_n || ' rows'));

  -- ------------------------------------------------------ T02 RAW -> STAGING
  SELECT COUNT(*) INTO v_m FROM fd_stg.stg_trans;
  chk('T02', 'Recon RAW -> STAGING: every trans line staged exactly once', v_n = v_m,
      'ext_trans ' || v_n || ' / stg_trans ' || v_m);

  -- ------------------------------------------------ T03 STAGING -> CLEAN + Q
  v_txt := NULL;
  FOR r IN (SELECT 'trans' t,
                   (SELECT COUNT(*) FROM fd_stg.stg_trans) s,
                   (SELECT COUNT(*) FROM fd_cln.cln_trans) c,
                   (SELECT COUNT(*) FROM fd_cln.q_trans)   q FROM dual
            UNION ALL
            SELECT 'account', (SELECT COUNT(*) FROM fd_stg.stg_account),
                   (SELECT COUNT(*) FROM fd_cln.cln_account),
                   (SELECT COUNT(*) FROM fd_cln.q_account WHERE batch_id = v_last) FROM dual
            UNION ALL
            SELECT 'client', (SELECT COUNT(*) FROM fd_stg.stg_client),
                   (SELECT COUNT(*) FROM fd_cln.cln_client),
                   (SELECT COUNT(*) FROM fd_cln.q_client WHERE batch_id = v_last) FROM dual
            UNION ALL
            SELECT 'loan', (SELECT COUNT(*) FROM fd_stg.stg_loan),
                   (SELECT COUNT(*) FROM fd_cln.cln_loan),
                   (SELECT COUNT(*) FROM fd_cln.q_loan WHERE batch_id = v_last) FROM dual) LOOP
    IF r.s <> r.c + r.q THEN
      v_txt := v_txt || r.t || ' stg ' || r.s || ' <> cln ' || r.c || ' + q ' || r.q || '; ';
    END IF;
  END LOOP;
  SELECT COUNT(*) INTO v_n FROM fd_cln.q_trans;
  chk('T03', 'Recon STAGING -> CLEAN: staged = clean + quarantined', v_txt IS NULL,
      NVL(v_txt, 'trans/account/client/loan balance; quarantined trans rows ' || v_n));

  -- ---------------------------------------------------------- T04 CLEAN -> DWH
  SELECT COUNT(*), NVL(SUM(amount), 0) INTO v_n, v_m FROM fd_cln.cln_trans;
  DECLARE
    v_fn NUMBER; v_fa NUMBER; v_bad NUMBER;
  BEGIN
    SELECT COUNT(*), NVL(SUM(amount), 0) INTO v_fn, v_fa FROM fd_dwh.fact_transaction;
    SELECT COUNT(*) INTO v_bad
      FROM (SELECT batch_id, COUNT(*) n FROM fd_cln.cln_trans GROUP BY batch_id) c
      FULL JOIN (SELECT batch_id, COUNT(*) n FROM fd_dwh.fact_transaction GROUP BY batch_id) f
        ON f.batch_id = c.batch_id
     WHERE NVL(c.n, -1) <> NVL(f.n, -1);
    chk('T04', 'Recon CLEAN -> DWH: rows and amount per batch', v_n = v_fn AND v_m = v_fa AND v_bad = 0,
        'cln ' || v_n || ' rows / ' || v_m || ' CZK; fact ' || v_fn || ' rows / ' || v_fa
        || ' CZK; batches differing ' || v_bad);
  END;

  -- -------------------------------------------------------------- T05 orphans
  SELECT (SELECT COUNT(*) FROM fd_dwh.fact_transaction f
           WHERE NOT EXISTS (SELECT 1 FROM fd_dwh.dim_account a WHERE a.account_key = f.account_key)
              OR NOT EXISTS (SELECT 1 FROM fd_dwh.dim_customer c WHERE c.customer_key = f.customer_key)
              OR NOT EXISTS (SELECT 1 FROM fd_dwh.dim_branch b WHERE b.branch_key = f.branch_key)
              OR NOT EXISTS (SELECT 1 FROM fd_dwh.dim_date d WHERE d.date_key = f.date_key))
       + (SELECT COUNT(*) FROM fd_dwh.fraud_alerts x
           WHERE NOT EXISTS (SELECT 1 FROM fd_dwh.fact_transaction f WHERE f.txn_key = x.txn_key))
       + (SELECT COUNT(*) FROM fd_dwh.fact_loan_snapshot s
           WHERE NOT EXISTS (SELECT 1 FROM fd_dwh.dim_customer c WHERE c.customer_key = s.customer_key))
    INTO v_n FROM dual;
  SELECT COUNT(*) INTO v_m FROM fd_dwh.fact_transaction
   WHERE -1 IN (account_key, customer_key, branch_key, channel_key, category_key);
  chk('T05', 'No orphan foreign keys; no fact on an unknown (-1) member', v_n = 0 AND v_m = 0,
      'orphans ' || v_n || ', facts on -1 members ' || v_m);

  -- ----------------------------------------------------------------- T06 SCD2
  SELECT COUNT(*) INTO v_n
    FROM (SELECT client_id FROM fd_dwh.dim_customer WHERE customer_key > 0
           GROUP BY client_id HAVING COUNT(CASE WHEN is_current = 'Y' THEN 1 END) <> 1);
  SELECT COUNT(*), COUNT(DISTINCT client_id) INTO v_m, v_k FROM fd_dwh.dim_customer WHERE customer_key > 0;
  chk('T06', 'SCD2: exactly one current version per client', v_n = 0,
      'clients violating ' || v_n || '; versions ' || v_m || ' for ' || v_k || ' clients');

  SELECT COUNT(*) INTO v_n
    FROM (SELECT client_id, valid_from, valid_to,
                 LEAD(valid_from) OVER (PARTITION BY client_id ORDER BY valid_from) nxt
            FROM fd_dwh.dim_customer WHERE customer_key > 0)
   WHERE nxt IS NOT NULL AND nxt <> valid_to + 1;
  chk('T07', 'SCD2: versions of a client never overlap and leave no gap', v_n = 0,
      'bad version boundaries ' || v_n);

  SELECT COUNT(*) INTO v_n
    FROM fd_dwh.fact_transaction f
    JOIN fd_dwh.dim_customer c ON c.customer_key = f.customer_key
   WHERE f.txn_date NOT BETWEEN c.valid_from AND c.valid_to;
  chk('T08', 'SCD2: each fact points at the customer version valid on its date', v_n = 0,
      'facts outside their version window ' || v_n);

  -- ------------------------------------------------------------ T09 SMA rules
  v_txt := NULL;
  FOR r IN (SELECT 0 d, 'STANDARD' e FROM dual UNION ALL SELECT 1, 'SMA-0' FROM dual UNION ALL
            SELECT 30, 'SMA-0' FROM dual UNION ALL SELECT 31, 'SMA-1' FROM dual UNION ALL
            SELECT 60, 'SMA-1' FROM dual UNION ALL SELECT 61, 'SMA-2' FROM dual UNION ALL
            SELECT 90, 'SMA-2' FROM dual UNION ALL SELECT 91, 'NPA' FROM dual) LOOP
    IF fd_dwh.pkg_risk.classify_dpd(r.d) <> r.e THEN
      v_txt := v_txt || r.d || '->' || fd_dwh.pkg_risk.classify_dpd(r.d) || ' (want ' || r.e || '); ';
    END IF;
  END LOOP;
  chk('T09', 'SMA boundaries 0,1,30,31,60,61,90,91', v_txt IS NULL,
      NVL(v_txt, '0 STANDARD | 1,30 SMA-0 | 31,60 SMA-1 | 61,90 SMA-2 | 91 NPA'));

  -- An installment that falls due on the snapshot date itself is unpaid but
  -- 0 days past due, so "unpaid" and "DPD > 0" are not the same test.
  SELECT COUNT(*) INTO v_n FROM fd_dwh.fact_loan_snapshot
   WHERE sma_class <> fd_dwh.pkg_risk.classify_dpd(dpd)
      OR (installments_paid >= installments_due AND (dpd <> 0 OR first_unpaid_due_date IS NOT NULL))
      OR (installments_paid <  installments_due
          AND (first_unpaid_due_date IS NULL OR dpd <> snapshot_date - first_unpaid_due_date));
  SELECT COUNT(*) INTO v_m FROM fd_dwh.fact_loan_snapshot;
  chk('T10', 'Loan snapshots: DPD = days since oldest unpaid due date; class matches DPD',
      v_n = 0, 'inconsistent rows ' || v_n || ' of ' || v_m);

  -- -------------------------------------------------------- T11 partitioning
  SELECT COUNT(*) INTO v_n FROM dba_tab_partitions
   WHERE table_owner = 'FD_DWH' AND table_name = 'FACT_TRANSACTION' AND partition_name <> 'P_BEFORE_1993';
  SELECT COUNT(DISTINCT TRUNC(txn_date, 'MM')) INTO v_m FROM fd_dwh.fact_transaction;
  chk('T11', 'fact_transaction has one interval partition per loaded month', v_n = v_m,
      'partitions ' || v_n || ', months with data ' || v_m);

  -- ------------------------------------------------------- T12 idempotent rerun
  v_before := snapshot_counts;
  fd_ops.proc_replay_step(v_last, 'STAGE', 'Y');
  v_after := snapshot_counts;
  SELECT COUNT(*) INTO v_n FROM fd_ops.etl_batch WHERE batch_id = v_last AND status = 'SUCCESS';
  v_txt := diff(v_before, v_after);
  chk('T12', 'Idempotency: replaying the last batch STAGE..FRAUD changes nothing',
      v_txt IS NULL AND v_n = 1,
      NVL(v_txt, 'stg/cln/fact/dims/schedule/snapshots/alerts unchanged; batch ' || v_last || ' SUCCESS'));

  -- ------------------------------------------------------- T13 failure drill
  UPDATE fd_ops.etl_config SET param_value = 'CLEAN' WHERE param_name = 'FAIL_AT_STEP';
  COMMIT;
  SELECT as_of_date INTO v_as_of FROM fd_ops.etl_batch WHERE batch_id = v_last;
  BEGIN
    fd_ops.proc_run_daily_etl(v_as_of);      -- same date as the last batch: empty TRANS window
    v_txt := 'no error raised';
  EXCEPTION
    WHEN OTHERS THEN
      v_txt := SQLERRM;
  END;
  UPDATE fd_ops.etl_config SET param_value = NULL WHERE param_name = 'FAIL_AT_STEP';
  COMMIT;
  SELECT MAX(batch_id) INTO v_drill FROM fd_ops.etl_batch;
  SELECT COUNT(*) INTO v_n FROM fd_ops.etl_batch WHERE batch_id = v_drill AND status = 'FAILED';
  SELECT COUNT(*) INTO v_m FROM fd_ops.etl_log
   WHERE batch_id = v_drill AND step_name = 'CLEAN' AND status = 'FAILED' AND error_msg LIKE '%ORA-20990%';
  chk('T13', 'Failure drill: injected CLEAN error fails the batch and is logged',
      v_txt LIKE '%ORA-20990%' AND v_n = 1 AND v_m = 1,
      'batch ' || v_drill || ' FAILED=' || v_n || ', CLEAN log rows FAILED=' || v_m || '; ' || SUBSTR(v_txt, 1, 120));

  BEGIN
    fd_ops.proc_run_daily_etl(DATE '1999-01-31');
    v_txt := 'new batch was allowed';
  EXCEPTION
    WHEN OTHERS THEN
      v_txt := SQLERRM;
  END;
  chk('T14', 'A new batch is refused while a FAILED batch is waiting for replay',
      v_txt LIKE '%ORA-20002%', SUBSTR(v_txt, 1, 200));

  -- SYNTHETIC rows (made up for this test) for the drill batch, one per rule.
  -- They use a real account (except the R003 row) so each row breaks exactly
  -- one rule, whichever data set (full or CI sample) is loaded.
  SELECT TO_CHAR(MIN(account_id)) INTO v_txt FROM fd_cln.cln_account;
  INSERT INTO fd_stg.stg_trans (trans_id, account_id, trans_date, trans_type, operation, amount, balance,
                                k_symbol, bank, account, load_batch_id)
  SELECT NULL,       v_txt,      '981231', 'PRIJEM', 'VKLAD', '100', '100', NULL, NULL, NULL, v_drill FROM dual UNION ALL  -- R001
  SELECT '99000002', v_txt,      '981399', 'PRIJEM', 'VKLAD', '100', '100', NULL, NULL, NULL, v_drill FROM dual UNION ALL  -- R002
  SELECT '99000003', '99999999', '981231', 'PRIJEM', 'VKLAD', '100', '100', NULL, NULL, NULL, v_drill FROM dual UNION ALL  -- R003
  SELECT '99000005', v_txt,      '981231', 'XXXXXX', 'VKLAD', '100', '100', NULL, NULL, NULL, v_drill FROM dual UNION ALL  -- R005
  SELECT (SELECT TO_CHAR(MIN(trans_id)) FROM fd_cln.cln_trans),
                     v_txt,      '981231', 'PRIJEM', 'VKLAD', '100', '100', NULL, NULL, NULL, v_drill FROM dual UNION ALL  -- R006
  SELECT '99000007', v_txt,      '981231', 'PRIJEM', 'VKLAD', '1O0', '100', NULL, NULL, NULL, v_drill FROM dual;           -- R007
  COMMIT;

  v_before := snapshot_counts;
  fd_ops.proc_replay_step(v_drill, 'CLEAN', 'Y');
  v_after := snapshot_counts;

  SELECT COUNT(*) INTO v_n FROM fd_ops.etl_batch WHERE batch_id = v_drill AND status = 'SUCCESS';
  SELECT LISTAGG(reject_codes, ' ') WITHIN GROUP (ORDER BY reject_codes) INTO v_txt
    FROM fd_cln.q_trans WHERE batch_id = v_drill;
  SELECT COUNT(DISTINCT rule_code) INTO v_m FROM fd_ops.etl_error_log
   WHERE batch_id = v_drill AND rule_code IN ('R001', 'R002', 'R003', 'R005', 'R006', 'R007');
  chk('T15', 'Replay of the failed batch succeeds; synthetic bad rows land in quarantine with their rule',
      v_n = 1 AND v_m = 6 AND v_before('fact') = v_after('fact')
        AND v_after('cln_trans') = v_before('cln_trans'),
      'batch ' || v_drill || ' SUCCESS=' || v_n || '; q_trans codes: ' || v_txt
        || '; rules logged ' || v_m || '/6; facts ' || v_before('fact') || '->' || v_after('fact'));

  -- Teardown: the synthetic rows are fixtures, not data. The error log keeps
  -- its entries (tagged with the drill batch) as the audit trail of the drill.
  DELETE FROM fd_cln.q_trans   WHERE batch_id = v_drill;
  DELETE FROM fd_stg.stg_trans WHERE load_batch_id = v_drill;
  COMMIT;

  -- -------------------------------------------------------- T16 audit trigger
  v_ts := SYSTIMESTAMP;
  UPDATE fd_dwh.fraud_alerts
     SET status = 'CLOSED', resolution_note = 'test suite - rolled back'
   WHERE alert_id = (SELECT MIN(alert_id) FROM fd_dwh.fraud_alerts WHERE status = 'OPEN');
  v_m := SQL%ROWCOUNT;
  SELECT COUNT(*) INTO v_n FROM fd_ops.audit_log
   WHERE table_name = 'FD_DWH.FRAUD_ALERTS' AND column_name = 'STATUS'
     AND old_value = 'OPEN' AND new_value = 'CLOSED' AND changed_by IS NOT NULL
     AND changed_ts >= v_ts;
  ROLLBACK;
  chk('T16', 'Closing a fraud alert writes old/new status and user to audit_log',
      v_m = 1 AND v_n = 1,
      'alerts updated ' || v_m || ', STATUS audit rows written ' || v_n || ' (test change rolled back)');

  -- ------------------------------------------------------------- T17 security
  SELECT COUNT(*) INTO v_n FROM dba_users
   WHERE username IN ('FD_OPS', 'FD_RAW', 'FD_STG', 'FD_CLN', 'FD_DWH', 'FD_MART')
     AND authentication_type = 'NONE';
  SELECT COUNT(*) INTO v_m FROM dba_tab_privs
   WHERE grantee = 'FD_REPORT' AND (owner <> 'FD_MART' OR privilege <> 'SELECT');
  chk('T17', 'Least privilege: layer schemas cannot log in; report login reads FD_MART views only',
      v_n = 6 AND v_m = 0, 'schema-only accounts ' || v_n || '/6, other grants to FD_REPORT ' || v_m);

  SELECT COUNT(*) INTO v_n FROM dba_tab_privs
   WHERE grantee = 'FD_ETL' AND owner IN ('FD_RAW', 'FD_STG', 'FD_CLN', 'FD_DWH')
     AND privilege IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE');
  chk('T18', 'Least privilege: ETL login has no direct table access to the layers', v_n = 0,
      'direct table grants to FD_ETL on layer schemas ' || v_n);

  -- ------------------------------------------------------------------ summary
  SELECT COUNT(*) INTO v_n FROM fd_ops.test_result WHERE run_id = v_run_id;
  DBMS_OUTPUT.PUT_LINE('-----');
  DBMS_OUTPUT.PUT_LINE((v_n - v_fails) || ' passed, ' || v_fails || ' failed (run ' || v_run_id || ')');
  IF v_fails > 0 THEN
    RAISE_APPLICATION_ERROR(-20999, v_fails || ' test(s) failed');
  END IF;
END;
/
