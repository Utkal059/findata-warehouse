-- =============================================================================
-- plsql/99_assert_valid.sql
-- Build gate: recompile the FinData schemas and stop the build if any object
-- is still INVALID (lists them first).
-- =============================================================================
BEGIN
  FOR s IN (SELECT username FROM dba_users WHERE username LIKE 'FD\_%' ESCAPE '\' ORDER BY username) LOOP
    DBMS_UTILITY.COMPILE_SCHEMA(schema => s.username, compile_all => FALSE);
  END LOOP;
END;
/

DECLARE
  v_bad NUMBER := 0;
BEGIN
  FOR o IN (SELECT owner, object_type, object_name
              FROM dba_objects
             WHERE owner LIKE 'FD\_%' ESCAPE '\'
               AND status <> 'VALID'
             ORDER BY owner, object_type, object_name) LOOP
    v_bad := v_bad + 1;
    DBMS_OUTPUT.PUT_LINE('INVALID: ' || o.owner || '.' || o.object_name || ' (' || o.object_type || ')');
  END LOOP;
  IF v_bad > 0 THEN
    RAISE_APPLICATION_ERROR(-20000, v_bad || ' invalid object(s); see the list above');
  END IF;
  DBMS_OUTPUT.PUT_LINE('All FD_ objects are VALID');
END;
/
