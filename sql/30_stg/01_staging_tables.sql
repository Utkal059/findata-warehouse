-- =============================================================================
-- 30_stg/01_staging_tables.sql                                  STAGING LAYER
-- Physical copies of RAW, still all VARCHAR2, plus lineage columns:
--   stg_row_id     surrogate row id (used for deterministic de-duplication)
--   load_batch_id  batch that delivered the row
--   load_ts        when it was staged
-- Master files are re-delivered in full every batch (staging keeps the latest
-- copy). TRANS is incremental and kept per batch, list-partitioned
-- automatically by load_batch_id so a replay can clear exactly one batch.
-- =============================================================================

CREATE TABLE fd_stg.stg_account (
  stg_row_id     NUMBER GENERATED ALWAYS AS IDENTITY,
  account_id     VARCHAR2(20),
  district_id    VARCHAR2(20),
  frequency      VARCHAR2(40),
  acct_date      VARCHAR2(20),
  load_batch_id  NUMBER    NOT NULL,
  load_ts        TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT stg_account_pk PRIMARY KEY (stg_row_id)
);

CREATE TABLE fd_stg.stg_card (
  stg_row_id     NUMBER GENERATED ALWAYS AS IDENTITY,
  card_id        VARCHAR2(20),
  disp_id        VARCHAR2(20),
  card_type      VARCHAR2(20),
  issued         VARCHAR2(30),
  load_batch_id  NUMBER    NOT NULL,
  load_ts        TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT stg_card_pk PRIMARY KEY (stg_row_id)
);

CREATE TABLE fd_stg.stg_client (
  stg_row_id     NUMBER GENERATED ALWAYS AS IDENTITY,
  client_id      VARCHAR2(20),
  birth_number   VARCHAR2(20),
  district_id    VARCHAR2(20),
  load_batch_id  NUMBER    NOT NULL,
  load_ts        TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT stg_client_pk PRIMARY KEY (stg_row_id)
);

CREATE TABLE fd_stg.stg_disp (
  stg_row_id     NUMBER GENERATED ALWAYS AS IDENTITY,
  disp_id        VARCHAR2(20),
  client_id      VARCHAR2(20),
  account_id     VARCHAR2(20),
  disp_type      VARCHAR2(20),
  load_batch_id  NUMBER    NOT NULL,
  load_ts        TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT stg_disp_pk PRIMARY KEY (stg_row_id)
);

CREATE TABLE fd_stg.stg_district (
  stg_row_id     NUMBER GENERATED ALWAYS AS IDENTITY,
  a1  VARCHAR2(20),  a2  VARCHAR2(60),  a3  VARCHAR2(60),  a4  VARCHAR2(20),
  a5  VARCHAR2(20),  a6  VARCHAR2(20),  a7  VARCHAR2(20),  a8  VARCHAR2(20),
  a9  VARCHAR2(20),  a10 VARCHAR2(20),  a11 VARCHAR2(20),  a12 VARCHAR2(20),
  a13 VARCHAR2(20),  a14 VARCHAR2(20),  a15 VARCHAR2(20),  a16 VARCHAR2(20),
  load_batch_id  NUMBER    NOT NULL,
  load_ts        TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT stg_district_pk PRIMARY KEY (stg_row_id)
);

CREATE TABLE fd_stg.stg_loan (
  stg_row_id     NUMBER GENERATED ALWAYS AS IDENTITY,
  loan_id        VARCHAR2(20),
  account_id     VARCHAR2(20),
  loan_date      VARCHAR2(20),
  amount         VARCHAR2(30),
  duration       VARCHAR2(20),
  payments       VARCHAR2(30),
  status         VARCHAR2(10),
  load_batch_id  NUMBER    NOT NULL,
  load_ts        TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT stg_loan_pk PRIMARY KEY (stg_row_id)
);

CREATE TABLE fd_stg.stg_order (
  stg_row_id     NUMBER GENERATED ALWAYS AS IDENTITY,
  order_id       VARCHAR2(20),
  account_id     VARCHAR2(20),
  bank_to        VARCHAR2(10),
  account_to     VARCHAR2(20),
  amount         VARCHAR2(30),
  k_symbol       VARCHAR2(30),
  load_batch_id  NUMBER    NOT NULL,
  load_ts        TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT stg_order_pk PRIMARY KEY (stg_row_id)
);

CREATE TABLE fd_stg.stg_trans (
  stg_row_id     NUMBER GENERATED ALWAYS AS IDENTITY,
  trans_id       VARCHAR2(20),
  account_id     VARCHAR2(20),
  trans_date     VARCHAR2(20),
  trans_type     VARCHAR2(20),
  operation      VARCHAR2(40),
  amount         VARCHAR2(30),
  balance        VARCHAR2(30),
  k_symbol       VARCHAR2(30),
  bank           VARCHAR2(10),
  account        VARCHAR2(20),
  load_batch_id  NUMBER    NOT NULL,
  load_ts        TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
)
PARTITION BY LIST (load_batch_id) AUTOMATIC
  (PARTITION p_initial VALUES (0));

CREATE INDEX fd_stg.stg_trans_tid_ix ON fd_stg.stg_trans (trans_id) LOCAL;

GRANT SELECT ON fd_stg.stg_account  TO fd_cln;
GRANT SELECT ON fd_stg.stg_card     TO fd_cln;
GRANT SELECT ON fd_stg.stg_client   TO fd_cln;
GRANT SELECT ON fd_stg.stg_disp     TO fd_cln;
GRANT SELECT ON fd_stg.stg_district TO fd_cln;
GRANT SELECT ON fd_stg.stg_loan     TO fd_cln;
GRANT SELECT ON fd_stg.stg_order    TO fd_cln;
GRANT SELECT ON fd_stg.stg_trans    TO fd_cln;
