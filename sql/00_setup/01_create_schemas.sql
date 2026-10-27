-- =============================================================================
-- 01_create_schemas.sql
-- One schema per layer. RAW is an Oracle reserved word, so every layer schema
-- carries an FD_ prefix (FD_RAW, FD_STG, FD_CLN, FD_DWH, FD_OPS, FD_MART).
--
-- Least privilege:
--   * Layer schemas are schema-only accounts (NO AUTHENTICATION): nobody can
--     log in as them. They own objects and hold only the object grants they
--     need, given in each layer's script.
--   * FD_ETL    : operator login. May run/replay batches and read ops logs.
--   * FD_REPORT : BI login. May read the FD_MART reporting views only.
-- &fd_app_password is defined by scripts/sqlplus.sh (container password);
-- run interactively and SQL*Plus will prompt for it.
-- =============================================================================
SET VERIFY OFF

CREATE USER fd_ops  NO AUTHENTICATION DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
CREATE USER fd_raw  NO AUTHENTICATION DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
CREATE USER fd_stg  NO AUTHENTICATION DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
CREATE USER fd_cln  NO AUTHENTICATION DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
CREATE USER fd_dwh  NO AUTHENTICATION DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
CREATE USER fd_mart NO AUTHENTICATION DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;

CREATE USER fd_etl    IDENTIFIED BY "&fd_app_password" DEFAULT TABLESPACE users;
CREATE USER fd_report IDENTIFIED BY "&fd_app_password" DEFAULT TABLESPACE users;
GRANT CREATE SESSION TO fd_etl;
GRANT CREATE SESSION TO fd_report;
