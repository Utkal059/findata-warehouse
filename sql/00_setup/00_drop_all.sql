-- =============================================================================
-- 00_drop_all.sql
-- Removes every FinData schema so the build always starts from empty.
-- Order matters only for readability: DROP USER ... CASCADE handles objects.
-- =============================================================================
DECLARE
  PROCEDURE drop_user (p_name VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE 'DROP USER ' || p_name || ' CASCADE';
    DBMS_OUTPUT.PUT_LINE('dropped ' || p_name);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE != -1918 THEN   -- ORA-01918: user does not exist
        RAISE;
      END IF;
  END;
BEGIN
  FOR u IN (SELECT column_value AS name
              FROM TABLE(sys.odcivarchar2list(
                     'FD_REPORT', 'FD_ETL', 'FD_MART', 'FD_DWH',
                     'FD_CLN', 'FD_STG', 'FD_RAW', 'FD_OPS')))
  LOOP
    drop_user(u.name);
  END LOOP;
END;
/
