-- =============================================================================
-- 02_create_directories.sql
-- DIRECTORY objects for the external tables.
--   fd_data_dir : source .asc files (bind-mounted read-only into the container)
--   fd_log_dir  : BADFILE / LOGFILE output (container-local, writable)
-- Only the schemas that read external tables get access.
-- =============================================================================
CREATE OR REPLACE DIRECTORY fd_data_dir AS '/opt/oracle/fd_data';
CREATE OR REPLACE DIRECTORY fd_log_dir  AS '/opt/oracle/oradata/fd_logs';

GRANT READ        ON DIRECTORY fd_data_dir TO fd_raw;
GRANT READ, WRITE ON DIRECTORY fd_log_dir  TO fd_raw;

-- FD_STG reads the external tables during staging, which opens the files
-- and writes the external-table log under the querying session.
GRANT READ        ON DIRECTORY fd_data_dir TO fd_stg;
GRANT READ, WRITE ON DIRECTORY fd_log_dir  TO fd_stg;
