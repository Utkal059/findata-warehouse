-- =============================================================================
-- scripts/run_all.sql
-- Builds the whole warehouse from an empty database and loads it.
-- Run from the repository root as a DBA user (SYSTEM) in FREEPDB1:
--     bash scripts/sqlplus.sh scripts/run_all.sql        (Docker setup)
--     SQL> @scripts/run_all.sql                           (any SQL*Plus / SQLcl)
-- Prompts for fd_app_password (password of the two login accounts) unless it
-- is already DEFINEd. Re-running drops and rebuilds everything.
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF VERIFY OFF ECHO OFF LINESIZE 200 PAGESIZE 200
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
WHENEVER OSERROR EXIT FAILURE

PROMPT
PROMPT ==== 1/6 Schemas and directories
@sql/00_setup/00_drop_all.sql
@sql/00_setup/01_create_schemas.sql
@sql/00_setup/02_create_directories.sql

PROMPT ==== 2/6 Tables, views and reference data
@sql/10_raw/01_external_tables.sql
@sql/20_ops/01_ops_tables.sql
@sql/20_ops/02_ops_seed.sql
@sql/30_stg/01_staging_tables.sql
@sql/40_cln/01_clean_tables.sql
@sql/40_cln/02_parse_macros.sql
@sql/40_cln/03_validation_views.sql
@sql/50_dwh/01_dimensions.sql
@sql/50_dwh/02_fact_transaction.sql
@sql/60_risk/01_loan_risk_tables.sql
@sql/70_fraud/01_fraud_tables.sql
@sql/70_fraud/02_fraud_rules_seed.sql

PROMPT ==== 3/6 PL/SQL packages
@plsql/10_pkg_etl_log.sql
@plsql/11_pkg_etl_ctl.sql
@plsql/20_pkg_raw_check.sql
@plsql/30_pkg_stage.sql
@plsql/40_pkg_clean.sql
@plsql/50_pkg_load_dwh.sql
@plsql/60_pkg_risk.sql
@plsql/70_pkg_fraud.sql
@plsql/80_orchestrator.sql
@sql/50_dwh/03_seed_calendar.sql
@sql/75_mart/01_mart_views.sql
@plsql/99_assert_valid.sql

PROMPT ==== 4/6 Load: one batch per year-end, 1993 .. 1998
SET TIMING ON
BEGIN
  FOR y IN 1993 .. 1998 LOOP
    fd_ops.proc_run_daily_etl(TO_DATE(y || '-12-31', 'YYYY-MM-DD'));
  END LOOP;
END;
/
SET TIMING OFF

PROMPT ==== 5/6 Performance: BEFORE (no statistics, no bitmap indexes) and AFTER
@sql/80_perf/01_perf_queries.sql
EXEC DBMS_STATS.DELETE_SCHEMA_STATS('FD_DWH')
@sql/80_perf/02_perf_measure.sql BEFORE
@sql/80_perf/03_perf_tune.sql
@sql/80_perf/02_perf_measure.sql AFTER

PROMPT ==== 6/6 Run summary
COLUMN step_name FORMAT A12
SELECT b.batch_id, TO_CHAR(b.as_of_date, 'YYYY-MM-DD') AS as_of, b.status,
       l.step_name, l.rows_loaded,
       ROUND(EXTRACT(HOUR FROM (l.end_ts - l.start_ts)) * 3600 + EXTRACT(MINUTE FROM (l.end_ts - l.start_ts)) * 60 + EXTRACT(SECOND FROM (l.end_ts - l.start_ts)), 1) AS seconds
  FROM fd_ops.etl_batch b
  JOIN fd_ops.etl_log l ON l.batch_id = b.batch_id AND l.parent_log_id IS NULL
 ORDER BY b.batch_id, l.log_id;
PROMPT Build complete.
