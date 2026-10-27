-- =============================================================================
-- plsql/30_pkg_stage.sql
-- STAGE step: RAW -> STAGING, no transformation.
--   * master files (account, card, client, disp, district, loan, order):
--     full snapshot every batch, previous copy replaced
--   * trans: only rows with watermark < trans.date <= as_of_date
-- The TRANS watermark moves in the same transaction as the staged rows.
-- =============================================================================

CREATE OR REPLACE PACKAGE fd_stg.pkg_stage AUTHID DEFINER AS
  PROCEDURE run (p_batch_id IN NUMBER, p_parent_log_id IN NUMBER);
END pkg_stage;
/

CREATE OR REPLACE PACKAGE BODY fd_stg.pkg_stage AS

  PROCEDURE run (p_batch_id IN NUMBER, p_parent_log_id IN NUMBER) IS
    v_log_id  NUMBER;
    v_rows    NUMBER;
    v_as_of   DATE := fd_ops.pkg_etl_ctl.batch_as_of(p_batch_id);
    v_wm_from DATE := fd_ops.pkg_etl_ctl.batch_wm_from(p_batch_id);

    PROCEDURE begin_task (p_name IN VARCHAR2) IS
    BEGIN
      v_log_id := fd_ops.pkg_etl_log.start_step(p_batch_id, 'STAGE:' || p_name, p_parent_log_id);
    END begin_task;

    PROCEDURE end_task (p_rows IN NUMBER) IS
    BEGIN
      fd_ops.pkg_etl_log.log_step(v_log_id, 'SUCCESS', p_rows, p_rows, 0);
      v_log_id := NULL;
    END end_task;
  BEGIN
    -- ---------------------------------------------------------------- masters
    begin_task('DISTRICT');
    DELETE FROM fd_stg.stg_district;
    INSERT INTO fd_stg.stg_district
           (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, load_batch_id)
    SELECT a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, p_batch_id
      FROM fd_raw.ext_district;
    end_task(SQL%ROWCOUNT);

    begin_task('ACCOUNT');
    DELETE FROM fd_stg.stg_account;
    INSERT INTO fd_stg.stg_account (account_id, district_id, frequency, acct_date, load_batch_id)
    SELECT account_id, district_id, frequency, acct_date, p_batch_id
      FROM fd_raw.ext_account;
    end_task(SQL%ROWCOUNT);

    begin_task('CLIENT');
    DELETE FROM fd_stg.stg_client;
    INSERT INTO fd_stg.stg_client (client_id, birth_number, district_id, load_batch_id)
    SELECT client_id, birth_number, district_id, p_batch_id
      FROM fd_raw.ext_client;
    end_task(SQL%ROWCOUNT);

    begin_task('DISP');
    DELETE FROM fd_stg.stg_disp;
    INSERT INTO fd_stg.stg_disp (disp_id, client_id, account_id, disp_type, load_batch_id)
    SELECT disp_id, client_id, account_id, disp_type, p_batch_id
      FROM fd_raw.ext_disp;
    end_task(SQL%ROWCOUNT);

    begin_task('CARD');
    DELETE FROM fd_stg.stg_card;
    INSERT INTO fd_stg.stg_card (card_id, disp_id, card_type, issued, load_batch_id)
    SELECT card_id, disp_id, card_type, issued, p_batch_id
      FROM fd_raw.ext_card;
    end_task(SQL%ROWCOUNT);

    begin_task('LOAN');
    DELETE FROM fd_stg.stg_loan;
    INSERT INTO fd_stg.stg_loan
           (loan_id, account_id, loan_date, amount, duration, payments, status, load_batch_id)
    SELECT loan_id, account_id, loan_date, amount, duration, payments, status, p_batch_id
      FROM fd_raw.ext_loan;
    end_task(SQL%ROWCOUNT);

    begin_task('ORDER');
    DELETE FROM fd_stg.stg_order;
    INSERT INTO fd_stg.stg_order
           (order_id, account_id, bank_to, account_to, amount, k_symbol, load_batch_id)
    SELECT order_id, account_id, bank_to, account_to, amount, k_symbol, p_batch_id
      FROM fd_raw.ext_order;
    end_task(SQL%ROWCOUNT);

    -- ------------------------------------------------------ trans (incremental)
    begin_task('TRANS');
    DELETE FROM fd_stg.stg_trans WHERE load_batch_id = p_batch_id;     -- replay-safe

    INSERT INTO fd_stg.stg_trans
           (trans_id, account_id, trans_date, trans_type, operation, amount, balance,
            k_symbol, bank, account, load_batch_id)
    SELECT e.trans_id, e.account_id, e.trans_date, e.trans_type, e.operation, e.amount, e.balance,
           e.k_symbol, e.bank, e.account, p_batch_id
      FROM (SELECT x.*,
                   CASE WHEN REGEXP_LIKE(TRIM(x.trans_date), '^[0-9]{6}$')
                        THEN TO_DATE('19' || TRIM(x.trans_date) DEFAULT NULL ON CONVERSION ERROR, 'YYYYMMDD')
                   END AS parsed_date
              FROM fd_raw.ext_trans x) e
     WHERE (    e.parsed_date <= v_as_of
            AND (v_wm_from IS NULL OR e.parsed_date > v_wm_from))
        -- Rows whose date cannot be parsed would never match a watermark
        -- window; stage them once so CLEAN can quarantine them (rule R002).
        OR (    e.parsed_date IS NULL
            AND NOT EXISTS (SELECT 1 FROM fd_stg.stg_trans s WHERE s.trans_id = e.trans_id));
    v_rows := SQL%ROWCOUNT;

    fd_ops.pkg_etl_ctl.set_watermark('TRANS', v_as_of, p_batch_id);
    end_task(v_rows);

    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      IF v_log_id IS NOT NULL THEN
        fd_ops.pkg_etl_log.log_step(v_log_id, 'FAILED', p_error_msg => SQLERRM,
                                    p_error_stack => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      END IF;
      RAISE;
  END run;

END pkg_stage;
/
SHOW ERRORS PACKAGE BODY fd_stg.pkg_stage

-- Only the orchestrator may run this step.
GRANT EXECUTE ON fd_stg.pkg_stage TO fd_ops;
