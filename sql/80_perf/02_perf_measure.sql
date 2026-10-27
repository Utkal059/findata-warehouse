-- =============================================================================
-- 80_perf/02_perf_measure.sql  <BEFORE|AFTER>
-- Runs every query in fd_ops.perf_query once to warm the cache, then 5 timed
-- executions that fetch every row. Records median / min / max elapsed ms,
-- buffer gets per execution (v$sql) and the plan actually used
-- (DBMS_XPLAN.DISPLAY_CURSOR).
-- The run label is embedded in the SQL text as a comment so BEFORE and AFTER
-- get separate cursors and the AFTER run cannot reuse a BEFORE plan.
-- =============================================================================
SET SERVEROUTPUT ON FEEDBACK OFF VERIFY OFF
DEFINE run_label = &1

DECLARE
  c_runs   CONSTANT PLS_INTEGER := 5;
  TYPE t_ms IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
  v_ms     t_ms;
  v_sorted t_ms;
  v_sql    CLOB;
  v_tag    VARCHAR2(40);
  v_cur    INTEGER;
  v_rc     INTEGER;
  v_rows   NUMBER;
  v_t0     TIMESTAMP;
  v_sql_id VARCHAR2(13);
  v_child  NUMBER;
  v_phv    NUMBER;
  v_gets   NUMBER;
  v_line   PLS_INTEGER;
  v_tmp    NUMBER;

  FUNCTION elapsed_ms (p_from IN TIMESTAMP) RETURN NUMBER IS
    d INTERVAL DAY TO SECOND := SYSTIMESTAMP - p_from;
  BEGIN
    RETURN ROUND((EXTRACT(MINUTE FROM d) * 60 + EXTRACT(SECOND FROM d)) * 1000, 1);
  END elapsed_ms;
BEGIN
  DELETE FROM fd_ops.perf_result WHERE run_label = '&run_label';
  DELETE FROM fd_ops.perf_plan   WHERE run_label = '&run_label';

  FOR q IN (SELECT query_id, description, sql_text FROM fd_ops.perf_query ORDER BY query_id) LOOP
    v_tag := '/* FDPERF ' || q.query_id || ' &run_label */ ';
    v_sql := v_tag || q.sql_text;

    FOR i IN 0 .. c_runs LOOP                       -- run 0 = warm-up, not counted
      v_t0  := SYSTIMESTAMP;
      v_cur := DBMS_SQL.OPEN_CURSOR;
      DBMS_SQL.PARSE(v_cur, v_sql, DBMS_SQL.NATIVE);
      v_rc   := DBMS_SQL.EXECUTE(v_cur);
      v_rows := 0;
      WHILE DBMS_SQL.FETCH_ROWS(v_cur) > 0 LOOP
        v_rows := v_rows + 1;
      END LOOP;
      DBMS_SQL.CLOSE_CURSOR(v_cur);
      IF i > 0 THEN
        v_ms(i) := elapsed_ms(v_t0);
      END IF;
    END LOOP;

    -- median of the timed runs (simple insertion sort on 5 values)
    v_sorted := v_ms;
    FOR i IN 2 .. c_runs LOOP
      FOR j IN REVERSE 2 .. i LOOP
        EXIT WHEN v_sorted(j - 1) <= v_sorted(j);
        v_tmp := v_sorted(j); v_sorted(j) := v_sorted(j - 1); v_sorted(j - 1) := v_tmp;
      END LOOP;
    END LOOP;

    SELECT sql_id, child_number, plan_hash_value, ROUND(buffer_gets / NULLIF(executions, 0))
      INTO v_sql_id, v_child, v_phv, v_gets
      FROM v$sql
     WHERE sql_text LIKE '/* FDPERF ' || q.query_id || ' &run_label */%'
     ORDER BY last_active_time DESC
     FETCH FIRST 1 ROW ONLY;

    INSERT INTO fd_ops.perf_result (run_label, query_id, description, executions, median_ms, min_ms,
                                    max_ms, buffer_gets_per_exec, rows_returned, plan_hash_value)
    VALUES ('&run_label', q.query_id, q.description, c_runs, v_sorted(3), v_sorted(1), v_sorted(c_runs),
            v_gets, v_rows, v_phv);

    v_line := 0;
    FOR p IN (SELECT plan_table_output
                FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(v_sql_id, v_child, 'BASIC +ROWS +PARTITION'))) LOOP
      v_line := v_line + 1;
      INSERT INTO fd_ops.perf_plan (run_label, query_id, line_no, plan_line)
      VALUES ('&run_label', q.query_id, v_line, SUBSTR(p.plan_table_output, 1, 400));
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('&run_label ' || q.query_id || ': median ' || v_sorted(3) || ' ms, '
                         || v_gets || ' buffer gets/exec, ' || v_rows || ' rows, plan ' || v_phv);
  END LOOP;
  COMMIT;
END;
/
UNDEFINE run_label
