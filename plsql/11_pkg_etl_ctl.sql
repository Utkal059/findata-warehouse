-- =============================================================================
-- plsql/11_pkg_etl_ctl.sql
-- Batch context, watermarks and runtime parameters.
-- NOT autonomous on purpose: set_watermark must commit or roll back together
-- with the staging rows it describes.
-- =============================================================================

CREATE OR REPLACE PACKAGE fd_ops.pkg_etl_ctl AUTHID DEFINER AS

  FUNCTION  batch_as_of   (p_batch_id IN NUMBER) RETURN DATE;
  FUNCTION  batch_wm_from (p_batch_id IN NUMBER) RETURN DATE;   -- NULL on the first load

  FUNCTION  get_watermark (p_table_name IN VARCHAR2) RETURN DATE;
  PROCEDURE set_watermark (p_table_name IN VARCHAR2,
                           p_value      IN DATE,
                           p_batch_id   IN NUMBER);

  FUNCTION  get_param     (p_name IN VARCHAR2) RETURN VARCHAR2;

  -- Failure drill: raises ORA-20990 when etl_config.FAIL_AT_STEP = p_step_name.
  PROCEDURE raise_if_injected (p_step_name IN VARCHAR2);

END pkg_etl_ctl;
/

CREATE OR REPLACE PACKAGE BODY fd_ops.pkg_etl_ctl AS

  FUNCTION batch_as_of (p_batch_id IN NUMBER) RETURN DATE IS
    v_date DATE;
  BEGIN
    SELECT as_of_date INTO v_date FROM fd_ops.etl_batch WHERE batch_id = p_batch_id;
    RETURN v_date;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20010, 'Unknown batch_id ' || p_batch_id);
  END batch_as_of;

  FUNCTION batch_wm_from (p_batch_id IN NUMBER) RETURN DATE IS
    v_date DATE;
  BEGIN
    SELECT wm_from INTO v_date FROM fd_ops.etl_batch WHERE batch_id = p_batch_id;
    RETURN v_date;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20010, 'Unknown batch_id ' || p_batch_id);
  END batch_wm_from;

  FUNCTION get_watermark (p_table_name IN VARCHAR2) RETURN DATE IS
    v_date DATE;
  BEGIN
    SELECT last_loaded_value INTO v_date
      FROM fd_ops.etl_watermark
     WHERE table_name = UPPER(p_table_name);
    RETURN v_date;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20011, 'No watermark registered for ' || p_table_name);
  END get_watermark;

  PROCEDURE set_watermark (p_table_name IN VARCHAR2,
                           p_value      IN DATE,
                           p_batch_id   IN NUMBER) IS
  BEGIN
    UPDATE fd_ops.etl_watermark
       SET last_loaded_value = p_value,
           updated_batch_id  = p_batch_id,
           updated_ts        = SYSTIMESTAMP
     WHERE table_name = UPPER(p_table_name)
       AND (last_loaded_value IS NULL OR last_loaded_value <= p_value);   -- never move backwards
  END set_watermark;

  FUNCTION get_param (p_name IN VARCHAR2) RETURN VARCHAR2 IS
    v_value fd_ops.etl_config.param_value%TYPE;
  BEGIN
    SELECT param_value INTO v_value FROM fd_ops.etl_config WHERE param_name = UPPER(p_name);
    RETURN v_value;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN NULL;
  END get_param;

  PROCEDURE raise_if_injected (p_step_name IN VARCHAR2) IS
  BEGIN
    IF UPPER(get_param('FAIL_AT_STEP')) = UPPER(p_step_name) THEN
      RAISE_APPLICATION_ERROR(-20990,
        'Injected failure at step ' || p_step_name || ' (etl_config.FAIL_AT_STEP)');
    END IF;
  END raise_if_injected;

END pkg_etl_ctl;
/
SHOW ERRORS PACKAGE BODY fd_ops.pkg_etl_ctl

GRANT EXECUTE ON fd_ops.pkg_etl_ctl TO fd_raw, fd_stg, fd_cln, fd_dwh;

-- Set-based reject logging and audit triggers write straight to these tables.
GRANT INSERT ON fd_ops.etl_error_log TO fd_cln, fd_dwh;
GRANT SELECT ON fd_ops.dq_rule       TO fd_cln, fd_dwh;
GRANT INSERT ON fd_ops.audit_log     TO fd_dwh;
