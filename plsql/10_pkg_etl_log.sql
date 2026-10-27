-- =============================================================================
-- plsql/10_pkg_etl_log.sql
-- Logging API used by every ETL step.
-- Every routine runs as an AUTONOMOUS_TRANSACTION: a log row is committed on
-- its own, so it survives when the calling step rolls back its data. This is
-- what lets support staff see *where* and *why* a batch failed.
-- =============================================================================

CREATE OR REPLACE PACKAGE fd_ops.pkg_etl_log AUTHID DEFINER AS

  -- Opens a batch for p_as_of_date and records its TRANS watermark window.
  -- Refuses to start while another batch is RUNNING or FAILED (a failed batch
  -- must be replayed first, otherwise its staged rows would never reach DWH).
  FUNCTION start_batch (p_as_of_date IN DATE) RETURN NUMBER;

  PROCEDURE end_batch (p_batch_id  IN NUMBER,
                       p_status    IN VARCHAR2,
                       p_error_msg IN VARCHAR2 DEFAULT NULL);

  -- Puts a FAILED (or most recent) batch back to RUNNING for a replay.
  PROCEDURE reopen_batch (p_batch_id IN NUMBER);

  -- Inserts a RUNNING row for a step (or sub-task when p_parent_log_id is set)
  -- and returns its log_id. attempt_no increases on every replay.
  FUNCTION start_step (p_batch_id      IN NUMBER,
                       p_step_name     IN VARCHAR2,
                       p_parent_log_id IN NUMBER DEFAULT NULL) RETURN NUMBER;

  -- Closes a step row. When no row counts are passed and the step has
  -- sub-tasks, the counts are summed from them.
  PROCEDURE log_step (p_log_id        IN NUMBER,
                      p_status        IN VARCHAR2,
                      p_rows_read     IN NUMBER   DEFAULT NULL,
                      p_rows_loaded   IN NUMBER   DEFAULT NULL,
                      p_rows_rejected IN NUMBER   DEFAULT NULL,
                      p_error_msg     IN VARCHAR2 DEFAULT NULL,
                      p_error_stack   IN VARCHAR2 DEFAULT NULL);

  -- Single-record error entry (runtime problems). Bulk data-quality rejects
  -- are written set-based by pkg_clean in the same transaction as the
  -- quarantine rows, so the two always agree.
  PROCEDURE log_error (p_batch_id     IN NUMBER,
                       p_log_id       IN NUMBER,
                       p_source_table IN VARCHAR2,
                       p_source_key   IN VARCHAR2,
                       p_rule_code    IN VARCHAR2,
                       p_error_msg    IN VARCHAR2);

END pkg_etl_log;
/

CREATE OR REPLACE PACKAGE BODY fd_ops.pkg_etl_log AS

  FUNCTION start_batch (p_as_of_date IN DATE) RETURN NUMBER IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    v_batch_id  NUMBER;
    v_open_id   NUMBER;
    v_open_st   VARCHAR2(10);
    v_wm        DATE;
  BEGIN
    IF p_as_of_date IS NULL THEN
      RAISE_APPLICATION_ERROR(-20001, 'as_of_date is required');
    END IF;

    BEGIN
      SELECT batch_id, status INTO v_open_id, v_open_st
        FROM fd_ops.etl_batch
       WHERE status IN ('RUNNING', 'FAILED')
       ORDER BY batch_id
       FETCH FIRST 1 ROW ONLY;
      RAISE_APPLICATION_ERROR(-20002,
        'Batch ' || v_open_id || ' is ' || v_open_st ||
        '. Replay it with fd_ops.proc_replay_step (see RUNBOOK) before starting a new batch.');
    EXCEPTION
      WHEN NO_DATA_FOUND THEN NULL;
    END;

    SELECT last_loaded_value INTO v_wm
      FROM fd_ops.etl_watermark
     WHERE table_name = 'TRANS';

    IF v_wm IS NOT NULL AND TRUNC(p_as_of_date) < v_wm THEN
      RAISE_APPLICATION_ERROR(-20003,
        'as_of_date ' || TO_CHAR(p_as_of_date, 'YYYY-MM-DD') ||
        ' is before the TRANS watermark ' || TO_CHAR(v_wm, 'YYYY-MM-DD') ||
        '; back-dated loads are not supported.');
    END IF;

    INSERT INTO fd_ops.etl_batch (as_of_date, wm_from, wm_to, status)
    VALUES (TRUNC(p_as_of_date), v_wm, TRUNC(p_as_of_date), 'RUNNING')
    RETURNING batch_id INTO v_batch_id;
    COMMIT;
    RETURN v_batch_id;
  END start_batch;

  PROCEDURE end_batch (p_batch_id  IN NUMBER,
                       p_status    IN VARCHAR2,
                       p_error_msg IN VARCHAR2 DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    UPDATE fd_ops.etl_batch
       SET status    = p_status,
           end_ts    = SYSTIMESTAMP,
           error_msg = SUBSTR(p_error_msg, 1, 4000)
     WHERE batch_id = p_batch_id;
    COMMIT;
  END end_batch;

  PROCEDURE reopen_batch (p_batch_id IN NUMBER) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    UPDATE fd_ops.etl_batch
       SET status = 'RUNNING', end_ts = NULL, error_msg = NULL
     WHERE batch_id = p_batch_id;
    COMMIT;
  END reopen_batch;

  FUNCTION start_step (p_batch_id      IN NUMBER,
                       p_step_name     IN VARCHAR2,
                       p_parent_log_id IN NUMBER DEFAULT NULL) RETURN NUMBER IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    v_log_id  NUMBER;
    v_attempt NUMBER;
  BEGIN
    SELECT COUNT(*) + 1 INTO v_attempt
      FROM fd_ops.etl_log
     WHERE batch_id = p_batch_id
       AND step_name = p_step_name;

    INSERT INTO fd_ops.etl_log (batch_id, parent_log_id, step_name, attempt_no, status)
    VALUES (p_batch_id, p_parent_log_id, p_step_name, v_attempt, 'RUNNING')
    RETURNING log_id INTO v_log_id;
    COMMIT;
    RETURN v_log_id;
  END start_step;

  PROCEDURE log_step (p_log_id        IN NUMBER,
                      p_status        IN VARCHAR2,
                      p_rows_read     IN NUMBER   DEFAULT NULL,
                      p_rows_loaded   IN NUMBER   DEFAULT NULL,
                      p_rows_rejected IN NUMBER   DEFAULT NULL,
                      p_error_msg     IN VARCHAR2 DEFAULT NULL,
                      p_error_stack   IN VARCHAR2 DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    v_read     NUMBER := p_rows_read;
    v_loaded   NUMBER := p_rows_loaded;
    v_rejected NUMBER := p_rows_rejected;
  BEGIN
    IF v_read IS NULL AND v_loaded IS NULL AND v_rejected IS NULL THEN
      SELECT SUM(rows_read), SUM(rows_loaded), SUM(rows_rejected)
        INTO v_read, v_loaded, v_rejected
        FROM fd_ops.etl_log
       WHERE parent_log_id = p_log_id;
    END IF;

    UPDATE fd_ops.etl_log
       SET status        = p_status,
           end_ts        = SYSTIMESTAMP,
           rows_read     = v_read,
           rows_loaded   = v_loaded,
           rows_rejected = v_rejected,
           error_msg     = SUBSTR(p_error_msg, 1, 4000),
           error_stack   = SUBSTR(p_error_stack, 1, 4000)
     WHERE log_id = p_log_id;
    COMMIT;
  END log_step;

  PROCEDURE log_error (p_batch_id     IN NUMBER,
                       p_log_id       IN NUMBER,
                       p_source_table IN VARCHAR2,
                       p_source_key   IN VARCHAR2,
                       p_rule_code    IN VARCHAR2,
                       p_error_msg    IN VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO fd_ops.etl_error_log
           (batch_id, log_id, source_table, source_key, rule_code, severity, error_msg)
    SELECT p_batch_id, p_log_id, p_source_table, SUBSTR(p_source_key, 1, 200), p_rule_code,
           (SELECT severity FROM fd_ops.dq_rule WHERE rule_code = p_rule_code),
           SUBSTR(p_error_msg, 1, 4000)
      FROM dual;
    COMMIT;
  END log_error;

END pkg_etl_log;
/
SHOW ERRORS PACKAGE BODY fd_ops.pkg_etl_log

GRANT EXECUTE ON fd_ops.pkg_etl_log TO fd_raw, fd_stg, fd_cln, fd_dwh;
