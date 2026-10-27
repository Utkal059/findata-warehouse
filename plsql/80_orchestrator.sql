-- =============================================================================
-- plsql/80_orchestrator.sql
-- One entry point for the nightly run and one for recovery:
--
--   EXEC fd_ops.proc_run_daily_etl(DATE '1998-12-31');
--       RAW_CHECK -> STAGE -> CLEAN -> LOAD_DWH -> RISK -> FRAUD
--       (order comes from fd_ops.etl_step). The first failing step stops the
--       batch: its data is rolled back, the log keeps the error and the batch
--       is marked FAILED.
--
--   EXEC fd_ops.proc_replay_step(p_batch_id => 7, p_step_name => 'CLEAN');
--       re-runs one step of a batch (attempt_no + 1) and, by default, every
--       step after it. Allowed for a FAILED batch or for the most recent batch
--       (an idempotent re-run). Every step is replay-safe: it deletes or
--       merges by batch_id instead of blindly appending.
-- =============================================================================

CREATE OR REPLACE PACKAGE fd_ops.pkg_orchestrator AUTHID DEFINER AS

  FUNCTION run_daily (p_as_of_date IN DATE) RETURN NUMBER;

  PROCEDURE replay_step (p_batch_id  IN NUMBER,
                         p_step_name IN VARCHAR2,
                         p_resume    IN VARCHAR2 DEFAULT 'Y');

END pkg_orchestrator;
/

CREATE OR REPLACE PACKAGE BODY fd_ops.pkg_orchestrator AS

  PROCEDURE exec_step (p_batch_id IN NUMBER, p_step_name IN VARCHAR2) IS
    v_log_id NUMBER;
  BEGIN
    v_log_id := fd_ops.pkg_etl_log.start_step(p_batch_id, p_step_name);
    BEGIN
      fd_ops.pkg_etl_ctl.raise_if_injected(p_step_name);
      CASE p_step_name
        WHEN 'RAW_CHECK' THEN fd_raw.pkg_raw_check.run(p_batch_id, v_log_id);
        WHEN 'STAGE'     THEN fd_stg.pkg_stage.run(p_batch_id, v_log_id);
        WHEN 'CLEAN'     THEN fd_cln.pkg_clean.run(p_batch_id, v_log_id);
        WHEN 'LOAD_DWH'  THEN fd_dwh.pkg_load_dwh.run(p_batch_id, v_log_id);
        WHEN 'RISK'      THEN fd_dwh.pkg_risk.run(p_batch_id, v_log_id);
        WHEN 'FRAUD'     THEN fd_dwh.pkg_fraud.run(p_batch_id, v_log_id);
      END CASE;
      fd_ops.pkg_etl_log.log_step(v_log_id, 'SUCCESS');
    EXCEPTION
      WHEN OTHERS THEN
        ROLLBACK;
        fd_ops.pkg_etl_log.log_step(v_log_id, 'FAILED',
                                    p_error_msg   => SQLERRM,
                                    p_error_stack => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        RAISE;
    END;
  END exec_step;

  PROCEDURE run_steps_from (p_batch_id IN NUMBER, p_from_seq IN NUMBER, p_to_seq IN NUMBER) IS
  BEGIN
    FOR s IN (SELECT step_name FROM fd_ops.etl_step
               WHERE step_seq BETWEEN p_from_seq AND p_to_seq
               ORDER BY step_seq) LOOP
      exec_step(p_batch_id, s.step_name);
    END LOOP;
  END run_steps_from;

  -- A batch is complete when the latest attempt of every step succeeded.
  FUNCTION batch_complete (p_batch_id IN NUMBER) RETURN BOOLEAN IS
    v_missing NUMBER;
  BEGIN
    SELECT COUNT(*) INTO v_missing
      FROM fd_ops.etl_step s
     WHERE NOT EXISTS (
             SELECT 1
               FROM fd_ops.etl_log l
              WHERE l.batch_id = p_batch_id
                AND l.step_name = s.step_name
                AND l.parent_log_id IS NULL
                AND l.status = 'SUCCESS'
                AND l.attempt_no = (SELECT MAX(l2.attempt_no) FROM fd_ops.etl_log l2
                                     WHERE l2.batch_id = p_batch_id
                                       AND l2.step_name = s.step_name
                                       AND l2.parent_log_id IS NULL));
    RETURN v_missing = 0;
  END batch_complete;

  FUNCTION run_daily (p_as_of_date IN DATE) RETURN NUMBER IS
    v_batch_id NUMBER;
  BEGIN
    v_batch_id := fd_ops.pkg_etl_log.start_batch(p_as_of_date);
    BEGIN
      run_steps_from(v_batch_id, 1, 99);
      fd_ops.pkg_etl_log.end_batch(v_batch_id, 'SUCCESS');
    EXCEPTION
      WHEN OTHERS THEN
        fd_ops.pkg_etl_log.end_batch(v_batch_id, 'FAILED', SQLERRM);
        RAISE;
    END;
    RETURN v_batch_id;
  END run_daily;

  PROCEDURE replay_step (p_batch_id  IN NUMBER,
                         p_step_name IN VARCHAR2,
                         p_resume    IN VARCHAR2 DEFAULT 'Y') IS
    v_status  fd_ops.etl_batch.status%TYPE;
    v_latest  NUMBER;
    v_seq     NUMBER;
  BEGIN
    BEGIN
      SELECT status INTO v_status FROM fd_ops.etl_batch WHERE batch_id = p_batch_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20801, 'Batch ' || p_batch_id || ' does not exist');
    END;

    SELECT MAX(batch_id) INTO v_latest FROM fd_ops.etl_batch;
    IF v_status = 'RUNNING' THEN
      RAISE_APPLICATION_ERROR(-20802, 'Batch ' || p_batch_id || ' is still RUNNING');
    ELSIF v_status <> 'FAILED' AND p_batch_id <> v_latest THEN
      RAISE_APPLICATION_ERROR(-20803,
        'Only a FAILED batch or the most recent batch (' || v_latest || ') can be replayed');
    END IF;

    BEGIN
      SELECT step_seq INTO v_seq FROM fd_ops.etl_step WHERE step_name = UPPER(p_step_name);
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20804, 'Unknown step ' || p_step_name);
    END;

    fd_ops.pkg_etl_log.reopen_batch(p_batch_id);
    BEGIN
      run_steps_from(p_batch_id, v_seq, CASE WHEN UPPER(p_resume) = 'Y' THEN 99 ELSE v_seq END);
    EXCEPTION
      WHEN OTHERS THEN
        fd_ops.pkg_etl_log.end_batch(p_batch_id, 'FAILED', SQLERRM);
        RAISE;
    END;

    IF batch_complete(p_batch_id) THEN
      fd_ops.pkg_etl_log.end_batch(p_batch_id, 'SUCCESS');
    ELSE
      fd_ops.pkg_etl_log.end_batch(p_batch_id, 'FAILED',
        'Replayed ' || UPPER(p_step_name) || ' only; later steps still need a run');
    END IF;
  END replay_step;

END pkg_orchestrator;
/
SHOW ERRORS PACKAGE BODY fd_ops.pkg_orchestrator

CREATE OR REPLACE PROCEDURE fd_ops.proc_run_daily_etl (p_as_of_date IN DATE) AUTHID DEFINER AS
  v_batch_id NUMBER;
BEGIN
  v_batch_id := fd_ops.pkg_orchestrator.run_daily(p_as_of_date);
  DBMS_OUTPUT.PUT_LINE('batch ' || v_batch_id || ' as of ' ||
                       TO_CHAR(p_as_of_date, 'YYYY-MM-DD') || ': SUCCESS');
END proc_run_daily_etl;
/

CREATE OR REPLACE PROCEDURE fd_ops.proc_replay_step (p_batch_id  IN NUMBER,
                                                     p_step_name IN VARCHAR2,
                                                     p_resume    IN VARCHAR2 DEFAULT 'Y')
  AUTHID DEFINER AS
BEGIN
  fd_ops.pkg_orchestrator.replay_step(p_batch_id, p_step_name, p_resume);
  DBMS_OUTPUT.PUT_LINE('batch ' || p_batch_id || ' replayed from ' || UPPER(p_step_name));
END proc_replay_step;
/

-- The application login runs and recovers batches and reads the run logs;
-- it owns no tables and cannot touch the layers directly.
GRANT EXECUTE ON fd_ops.proc_run_daily_etl TO fd_etl;
GRANT EXECUTE ON fd_ops.proc_replay_step   TO fd_etl;
GRANT SELECT  ON fd_ops.etl_batch          TO fd_etl;
GRANT SELECT  ON fd_ops.etl_log            TO fd_etl;
GRANT SELECT  ON fd_ops.etl_error_log      TO fd_etl;
GRANT SELECT, UPDATE ON fd_ops.etl_config  TO fd_etl;
