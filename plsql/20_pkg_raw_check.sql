-- =============================================================================
-- plsql/20_pkg_raw_check.sql
-- RAW_CHECK step: for every source file, rows visible through the external
-- table must equal the file's line count minus the header. A difference means
-- lines were rejected to the BADFILE (fd_log_dir:ext_<name>.bad).
-- =============================================================================

CREATE OR REPLACE PACKAGE fd_raw.pkg_raw_check AUTHID DEFINER AS

  PROCEDURE run (p_batch_id IN NUMBER, p_parent_log_id IN NUMBER);

  -- Data lines in a source file (total lines - 1 header line).
  FUNCTION file_rows (p_file_name IN VARCHAR2) RETURN NUMBER;

END pkg_raw_check;
/

CREATE OR REPLACE PACKAGE BODY fd_raw.pkg_raw_check AS

  TYPE t_source IS RECORD (ext_table VARCHAR2(30), file_name VARCHAR2(30), label VARCHAR2(20));
  TYPE t_sources IS TABLE OF t_source;

  FUNCTION sources RETURN t_sources IS
  BEGIN
    RETURN t_sources(
      t_source('EXT_ACCOUNT',  'account.asc',  'ACCOUNT'),
      t_source('EXT_CARD',     'card.asc',     'CARD'),
      t_source('EXT_CLIENT',   'client.asc',   'CLIENT'),
      t_source('EXT_DISP',     'disp.asc',     'DISP'),
      t_source('EXT_DISTRICT', 'district.asc', 'DISTRICT'),
      t_source('EXT_LOAN',     'loan.asc',     'LOAN'),
      t_source('EXT_ORDER',    'order.asc',    'ORDER'),
      t_source('EXT_TRANS',    'trans.asc',    'TRANS'));
  END sources;

  FUNCTION file_rows (p_file_name IN VARCHAR2) RETURN NUMBER IS
    v_lines NUMBER;
    v_known BOOLEAN := FALSE;
    v_src   t_sources := sources;
  BEGIN
    -- Only the eight registered file names can reach the dynamic SQL below.
    FOR i IN 1 .. v_src.COUNT LOOP
      v_known := v_known OR v_src(i).file_name = p_file_name;
    END LOOP;
    IF NOT v_known THEN
      RAISE_APPLICATION_ERROR(-20100, 'Unregistered source file: ' || p_file_name);
    END IF;

    EXECUTE IMMEDIATE
      'SELECT COUNT(*) FROM fd_raw.ext_file_lines EXTERNAL MODIFY (LOCATION (''' ||
      p_file_name || '''))'
      INTO v_lines;
    RETURN GREATEST(v_lines - 1, 0);
  END file_rows;

  PROCEDURE run (p_batch_id IN NUMBER, p_parent_log_id IN NUMBER) IS
    v_src       t_sources := sources;
    v_log_id    NUMBER;
    v_expected  NUMBER;
    v_visible   NUMBER;
    v_tolerance NUMBER := NVL(TO_NUMBER(fd_ops.pkg_etl_ctl.get_param('RAW_REJECT_TOLERANCE')), 0);
    v_failures  VARCHAR2(4000);
  BEGIN
    FOR i IN 1 .. v_src.COUNT LOOP
      v_log_id := fd_ops.pkg_etl_log.start_step(p_batch_id, 'RAW_CHECK:' || v_src(i).label, p_parent_log_id);

      v_expected := file_rows(v_src(i).file_name);
      EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM fd_raw.' ||
                        DBMS_ASSERT.SIMPLE_SQL_NAME(v_src(i).ext_table)
        INTO v_visible;

      IF v_expected - v_visible > v_tolerance THEN
        fd_ops.pkg_etl_log.log_step(v_log_id, 'FAILED', v_expected, v_visible, v_expected - v_visible,
          (v_expected - v_visible) || ' line(s) rejected; see fd_log_dir:' ||
          LOWER(v_src(i).ext_table) || '.bad');
        v_failures := v_failures || v_src(i).label || ' ';
      ELSE
        fd_ops.pkg_etl_log.log_step(v_log_id, 'SUCCESS', v_expected, v_visible, v_expected - v_visible);
      END IF;
      v_log_id := NULL;
    END LOOP;

    IF v_failures IS NOT NULL THEN
      RAISE_APPLICATION_ERROR(-20101, 'RAW_CHECK row-count mismatch for: ' || TRIM(v_failures));
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      IF v_log_id IS NOT NULL THEN
        fd_ops.pkg_etl_log.log_step(v_log_id, 'FAILED', p_error_msg => SQLERRM,
                                    p_error_stack => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      END IF;
      RAISE;
  END run;

END pkg_raw_check;
/
SHOW ERRORS PACKAGE BODY fd_raw.pkg_raw_check

-- Only the orchestrator may run this step.
GRANT EXECUTE ON fd_raw.pkg_raw_check TO fd_ops;
