#!/bin/bash
# The slim image ships two 10 MB redo logs. Bulk ETL then spends most of its
# time waiting on "log file switch (checkpoint incomplete)". Replace them with
# five 256 MB groups. Runs on every start but only acts until that is in place.
sqlplus -S / as sysdba <<'SQL'
SET SERVEROUTPUT ON FEEDBACK OFF
DECLARE
  c_size  CONSTANT NUMBER := 256 * 1024 * 1024;
  v_small NUMBER;
  v_big   NUMBER;
  v_left  NUMBER;
BEGIN
  SELECT COUNT(CASE WHEN bytes < c_size THEN 1 END), COUNT(CASE WHEN bytes >= c_size THEN 1 END)
    INTO v_small, v_big
    FROM v$log;
  IF v_small = 0 AND v_big >= 5 THEN
    RETURN;
  END IF;

  FOR g IN 11 .. 15 LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER DATABASE ADD LOGFILE GROUP ' || g ||
                        ' (''/opt/oracle/oradata/FREE/redo' || g || '.log'') SIZE 256M REUSE';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE != -1184 THEN RAISE; END IF;   -- group already exists
    END;
  END LOOP;

  -- Move off the small groups, then drop them once they are no longer needed.
  FOR attempt IN 1 .. 10 LOOP
    EXECUTE IMMEDIATE 'ALTER SYSTEM SWITCH LOGFILE';
    EXECUTE IMMEDIATE 'ALTER SYSTEM CHECKPOINT GLOBAL';
    FOR r IN (SELECT group# FROM v$log WHERE bytes < c_size AND status IN ('INACTIVE', 'UNUSED')) LOOP
      EXECUTE IMMEDIATE 'ALTER DATABASE DROP LOGFILE GROUP ' || r.group#;
    END LOOP;
    SELECT COUNT(*) INTO v_left FROM v$log WHERE bytes < c_size;
    EXIT WHEN v_left = 0;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('redo logs resized; small groups left: ' || v_left);
END;
/
SQL
