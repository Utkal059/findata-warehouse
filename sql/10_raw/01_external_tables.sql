-- =============================================================================
-- 10_raw/01_external_tables.sql                                   BRONZE LAYER
-- One external table per source file, 1:1 with the file:
--   * every column is VARCHAR2 - no typing, trimming or translation here
--   * NOTRIM keeps values exactly as delivered (e.g. k_symbol " ")
--   * REJECT LIMIT UNLIMITED: malformed lines go to the BADFILE instead of
--     failing the query; pkg_raw_check compares counts so they are never lost
-- Source columns named date/type/order (reserved words) are renamed.
-- =============================================================================

CREATE TABLE fd_raw.ext_account (
  account_id   VARCHAR2(20),
  district_id  VARCHAR2(20),
  frequency    VARCHAR2(40),
  acct_date    VARCHAR2(20)
)
ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER
  DEFAULT DIRECTORY fd_data_dir
  ACCESS PARAMETERS (
    RECORDS DELIMITED BY DETECTED NEWLINE
    SKIP 1
    BADFILE fd_log_dir:'ext_account.bad'
    LOGFILE fd_log_dir:'ext_account.log'
    FIELDS TERMINATED BY ';' OPTIONALLY ENCLOSED BY '"' NOTRIM
    MISSING FIELD VALUES ARE NULL
  )
  LOCATION ('account.asc')
)
REJECT LIMIT UNLIMITED;

CREATE TABLE fd_raw.ext_card (
  card_id      VARCHAR2(20),
  disp_id      VARCHAR2(20),
  card_type    VARCHAR2(20),
  issued       VARCHAR2(30)
)
ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER
  DEFAULT DIRECTORY fd_data_dir
  ACCESS PARAMETERS (
    RECORDS DELIMITED BY DETECTED NEWLINE
    SKIP 1
    BADFILE fd_log_dir:'ext_card.bad'
    LOGFILE fd_log_dir:'ext_card.log'
    FIELDS TERMINATED BY ';' OPTIONALLY ENCLOSED BY '"' NOTRIM
    MISSING FIELD VALUES ARE NULL
  )
  LOCATION ('card.asc')
)
REJECT LIMIT UNLIMITED;

CREATE TABLE fd_raw.ext_client (
  client_id    VARCHAR2(20),
  birth_number VARCHAR2(20),
  district_id  VARCHAR2(20)
)
ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER
  DEFAULT DIRECTORY fd_data_dir
  ACCESS PARAMETERS (
    RECORDS DELIMITED BY DETECTED NEWLINE
    SKIP 1
    BADFILE fd_log_dir:'ext_client.bad'
    LOGFILE fd_log_dir:'ext_client.log'
    FIELDS TERMINATED BY ';' OPTIONALLY ENCLOSED BY '"' NOTRIM
    MISSING FIELD VALUES ARE NULL
  )
  LOCATION ('client.asc')
)
REJECT LIMIT UNLIMITED;

CREATE TABLE fd_raw.ext_disp (
  disp_id      VARCHAR2(20),
  client_id    VARCHAR2(20),
  account_id   VARCHAR2(20),
  disp_type    VARCHAR2(20)
)
ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER
  DEFAULT DIRECTORY fd_data_dir
  ACCESS PARAMETERS (
    RECORDS DELIMITED BY DETECTED NEWLINE
    SKIP 1
    BADFILE fd_log_dir:'ext_disp.bad'
    LOGFILE fd_log_dir:'ext_disp.log'
    FIELDS TERMINATED BY ';' OPTIONALLY ENCLOSED BY '"' NOTRIM
    MISSING FIELD VALUES ARE NULL
  )
  LOCATION ('disp.asc')
)
REJECT LIMIT UNLIMITED;

-- district.asc uses generic headers A1..A16; names are documented in
-- docs/data_dictionary.md and applied in the CLEAN layer.
CREATE TABLE fd_raw.ext_district (
  a1  VARCHAR2(20),  a2  VARCHAR2(60),  a3  VARCHAR2(60),  a4  VARCHAR2(20),
  a5  VARCHAR2(20),  a6  VARCHAR2(20),  a7  VARCHAR2(20),  a8  VARCHAR2(20),
  a9  VARCHAR2(20),  a10 VARCHAR2(20),  a11 VARCHAR2(20),  a12 VARCHAR2(20),
  a13 VARCHAR2(20),  a14 VARCHAR2(20),  a15 VARCHAR2(20),  a16 VARCHAR2(20)
)
ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER
  DEFAULT DIRECTORY fd_data_dir
  ACCESS PARAMETERS (
    RECORDS DELIMITED BY DETECTED NEWLINE
    SKIP 1
    BADFILE fd_log_dir:'ext_district.bad'
    LOGFILE fd_log_dir:'ext_district.log'
    FIELDS TERMINATED BY ';' OPTIONALLY ENCLOSED BY '"' NOTRIM
    MISSING FIELD VALUES ARE NULL
  )
  LOCATION ('district.asc')
)
REJECT LIMIT UNLIMITED;

CREATE TABLE fd_raw.ext_loan (
  loan_id      VARCHAR2(20),
  account_id   VARCHAR2(20),
  loan_date    VARCHAR2(20),
  amount       VARCHAR2(30),
  duration     VARCHAR2(20),
  payments     VARCHAR2(30),
  status       VARCHAR2(10)
)
ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER
  DEFAULT DIRECTORY fd_data_dir
  ACCESS PARAMETERS (
    RECORDS DELIMITED BY DETECTED NEWLINE
    SKIP 1
    BADFILE fd_log_dir:'ext_loan.bad'
    LOGFILE fd_log_dir:'ext_loan.log'
    FIELDS TERMINATED BY ';' OPTIONALLY ENCLOSED BY '"' NOTRIM
    MISSING FIELD VALUES ARE NULL
  )
  LOCATION ('loan.asc')
)
REJECT LIMIT UNLIMITED;

-- order.asc = permanent (standing) payment orders
CREATE TABLE fd_raw.ext_order (
  order_id     VARCHAR2(20),
  account_id   VARCHAR2(20),
  bank_to      VARCHAR2(10),
  account_to   VARCHAR2(20),
  amount       VARCHAR2(30),
  k_symbol     VARCHAR2(30)
)
ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER
  DEFAULT DIRECTORY fd_data_dir
  ACCESS PARAMETERS (
    RECORDS DELIMITED BY DETECTED NEWLINE
    SKIP 1
    BADFILE fd_log_dir:'ext_order.bad'
    LOGFILE fd_log_dir:'ext_order.log'
    FIELDS TERMINATED BY ';' OPTIONALLY ENCLOSED BY '"' NOTRIM
    MISSING FIELD VALUES ARE NULL
  )
  LOCATION ('order.asc')
)
REJECT LIMIT UNLIMITED;

CREATE TABLE fd_raw.ext_trans (
  trans_id     VARCHAR2(20),
  account_id   VARCHAR2(20),
  trans_date   VARCHAR2(20),
  trans_type   VARCHAR2(20),
  operation    VARCHAR2(40),
  amount       VARCHAR2(30),
  balance      VARCHAR2(30),
  k_symbol     VARCHAR2(30),
  bank         VARCHAR2(10),
  account      VARCHAR2(20)
)
ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER
  DEFAULT DIRECTORY fd_data_dir
  ACCESS PARAMETERS (
    RECORDS DELIMITED BY DETECTED NEWLINE
    SKIP 1
    BADFILE fd_log_dir:'ext_trans.bad'
    LOGFILE fd_log_dir:'ext_trans.log'
    FIELDS TERMINATED BY ';' OPTIONALLY ENCLOSED BY '"' NOTRIM
    MISSING FIELD VALUES ARE NULL
  )
  LOCATION ('trans.asc')
)
REJECT LIMIT UNLIMITED;

-- -----------------------------------------------------------------------------
-- Line counter: reads any file as whole lines (header included), so
--   rows expected = lines - 1 = COUNT(*) of the matching ext_ table.
-- Pointed at each file at query time with EXTERNAL MODIFY (LOCATION (...)).
-- -----------------------------------------------------------------------------
CREATE TABLE fd_raw.ext_file_lines (
  line_text VARCHAR2(4000)
)
ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER
  DEFAULT DIRECTORY fd_data_dir
  ACCESS PARAMETERS (
    RECORDS DELIMITED BY DETECTED NEWLINE
    NOBADFILE
    NOLOGFILE
    NODISCARDFILE
    FIELDS TERMINATED BY X'01' NOTRIM
    MISSING FIELD VALUES ARE NULL
    (line_text CHAR(4000))
  )
  LOCATION ('account.asc')
)
REJECT LIMIT UNLIMITED;

-- Staging reads the external tables.
GRANT SELECT ON fd_raw.ext_account  TO fd_stg;
GRANT SELECT ON fd_raw.ext_card     TO fd_stg;
GRANT SELECT ON fd_raw.ext_client   TO fd_stg;
GRANT SELECT ON fd_raw.ext_disp     TO fd_stg;
GRANT SELECT ON fd_raw.ext_district TO fd_stg;
GRANT SELECT ON fd_raw.ext_loan     TO fd_stg;
GRANT SELECT ON fd_raw.ext_order    TO fd_stg;
GRANT SELECT ON fd_raw.ext_trans    TO fd_stg;
