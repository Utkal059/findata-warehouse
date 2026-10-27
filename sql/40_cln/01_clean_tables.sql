-- =============================================================================
-- 40_cln/01_clean_tables.sql                               CLEAN (SILVER) LAYER
-- Typed, translated to English, de-duplicated and validated rows only.
-- Foreign keys between clean tables are enforced: anything that would break
-- them is quarantined first (rule R003), never loaded.
-- =============================================================================

CREATE TABLE fd_cln.cln_district (
  district_id             NUMBER(6)     NOT NULL,
  district_name           VARCHAR2(60)  NOT NULL,
  region                  VARCHAR2(60)  NOT NULL,
  inhabitants             NUMBER(10),
  munic_lt_500            NUMBER(6),    -- municipalities with < 500 inhabitants
  munic_500_1999          NUMBER(6),
  munic_2000_9999         NUMBER(6),
  munic_ge_10000          NUMBER(6),
  city_cnt                NUMBER(6),
  urban_ratio_pct         NUMBER(5,1),
  avg_salary              NUMBER(10),
  unemp_rate_95           NUMBER(5,2),  -- '?' in source -> NULL
  unemp_rate_96           NUMBER(5,2),
  entrepreneurs_per_1000  NUMBER(6),
  crimes_95               NUMBER(10),   -- '?' in source -> NULL
  crimes_96               NUMBER(10),
  batch_id                NUMBER        NOT NULL,
  updated_ts              TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT cln_district_pk PRIMARY KEY (district_id)
);

CREATE TABLE fd_cln.cln_account (
  account_id   NUMBER(10)    NOT NULL,
  district_id  NUMBER(6)     NOT NULL,
  frequency    VARCHAR2(20)  NOT NULL,   -- MONTHLY / WEEKLY / ON_TRANSACTION
  open_date    DATE          NOT NULL,
  batch_id     NUMBER        NOT NULL,
  updated_ts   TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT cln_account_pk PRIMARY KEY (account_id),
  CONSTRAINT cln_account_district_fk FOREIGN KEY (district_id) REFERENCES fd_cln.cln_district (district_id)
);

CREATE TABLE fd_cln.cln_client (
  client_id     NUMBER(10)   NOT NULL,
  birth_number  VARCHAR2(6)  NOT NULL,   -- kept for lineage; encodes gender (month + 50 = female)
  gender        CHAR(1)      NOT NULL,   -- M / F (derived)
  birth_date    DATE         NOT NULL,   -- derived
  district_id   NUMBER(6)    NOT NULL,
  batch_id      NUMBER       NOT NULL,
  updated_ts    TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT cln_client_pk PRIMARY KEY (client_id),
  CONSTRAINT cln_client_gender_ck CHECK (gender IN ('M', 'F')),
  CONSTRAINT cln_client_district_fk FOREIGN KEY (district_id) REFERENCES fd_cln.cln_district (district_id)
);

CREATE TABLE fd_cln.cln_disp (
  disp_id     NUMBER(10)    NOT NULL,
  client_id   NUMBER(10)    NOT NULL,
  account_id  NUMBER(10)    NOT NULL,
  disp_type   VARCHAR2(10)  NOT NULL,    -- OWNER / DISPONENT
  batch_id    NUMBER        NOT NULL,
  updated_ts  TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT cln_disp_pk PRIMARY KEY (disp_id),
  CONSTRAINT cln_disp_client_fk  FOREIGN KEY (client_id)  REFERENCES fd_cln.cln_client (client_id),
  CONSTRAINT cln_disp_account_fk FOREIGN KEY (account_id) REFERENCES fd_cln.cln_account (account_id)
);
CREATE INDEX fd_cln.cln_disp_account_ix ON fd_cln.cln_disp (account_id);
CREATE INDEX fd_cln.cln_disp_client_ix  ON fd_cln.cln_disp (client_id);

CREATE TABLE fd_cln.cln_card (
  card_id      NUMBER(10)    NOT NULL,
  disp_id      NUMBER(10)    NOT NULL,
  card_type    VARCHAR2(10)  NOT NULL,   -- JUNIOR / CLASSIC / GOLD
  issued_date  DATE          NOT NULL,
  batch_id     NUMBER        NOT NULL,
  updated_ts   TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT cln_card_pk PRIMARY KEY (card_id),
  CONSTRAINT cln_card_disp_fk FOREIGN KEY (disp_id) REFERENCES fd_cln.cln_disp (disp_id)
);
CREATE INDEX fd_cln.cln_card_disp_ix ON fd_cln.cln_card (disp_id);

CREATE TABLE fd_cln.cln_loan (
  loan_id          NUMBER(10)    NOT NULL,
  account_id       NUMBER(10)    NOT NULL,
  loan_date        DATE          NOT NULL,
  amount           NUMBER(12,2)  NOT NULL,
  duration_months  NUMBER(3)     NOT NULL,
  monthly_payment  NUMBER(12,2)  NOT NULL,
  status_code      CHAR(1)       NOT NULL,   -- A / B / C / D as delivered
  loan_status      VARCHAR2(20)  NOT NULL,   -- FINISHED_OK / FINISHED_DEFAULT / RUNNING_OK / RUNNING_DEBT
  batch_id         NUMBER        NOT NULL,
  updated_ts       TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT cln_loan_pk PRIMARY KEY (loan_id),
  CONSTRAINT cln_loan_account_fk FOREIGN KEY (account_id) REFERENCES fd_cln.cln_account (account_id)
);
CREATE INDEX fd_cln.cln_loan_account_ix ON fd_cln.cln_loan (account_id);

CREATE TABLE fd_cln.cln_order (
  order_id    NUMBER(10)    NOT NULL,
  account_id  NUMBER(10)    NOT NULL,
  bank_to     VARCHAR2(2),
  account_to  VARCHAR2(20),
  amount      NUMBER(12,2)  NOT NULL,
  k_symbol    VARCHAR2(20),               -- INSURANCE / HOUSEHOLD / LOAN_PAYMENT / LEASING / NULL
  batch_id    NUMBER        NOT NULL,
  updated_ts  TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT cln_order_pk PRIMARY KEY (order_id),
  CONSTRAINT cln_order_account_fk FOREIGN KEY (account_id) REFERENCES fd_cln.cln_account (account_id)
);

CREATE TABLE fd_cln.cln_trans (
  trans_id              NUMBER(10)    NOT NULL,
  account_id            NUMBER(10)    NOT NULL,
  trans_date            DATE          NOT NULL,
  txn_type              VARCHAR2(6)   NOT NULL,   -- CREDIT / DEBIT
  operation             VARCHAR2(20),             -- CARD_WITHDRAWAL, CASH_CREDIT, ... or NULL
  amount                NUMBER(12,2)  NOT NULL,
  balance               NUMBER(12,2),
  k_symbol              VARCHAR2(20),             -- INSURANCE, STATEMENT, ... or NULL
  bank                  VARCHAR2(2),              -- counterparty bank
  counterparty_account  VARCHAR2(20),
  dq_warn_codes         VARCHAR2(40),             -- WARN rules hit (row kept), e.g. R004
  batch_id              NUMBER        NOT NULL,
  load_ts               TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT cln_trans_pk PRIMARY KEY (trans_id),
  CONSTRAINT cln_trans_type_ck CHECK (txn_type IN ('CREDIT', 'DEBIT')),
  CONSTRAINT cln_trans_account_fk FOREIGN KEY (account_id) REFERENCES fd_cln.cln_account (account_id)
);
CREATE INDEX fd_cln.cln_trans_batch_ix ON fd_cln.cln_trans (batch_id);
CREATE INDEX fd_cln.cln_trans_acct_ix  ON fd_cln.cln_trans (account_id, trans_date, trans_id);

-- -----------------------------------------------------------------------------
-- Quarantine: rejected rows exactly as staged, plus every rule they broke.
-- One table per source; never silently dropped.
-- -----------------------------------------------------------------------------
CREATE TABLE fd_cln.q_district (
  stg_row_id NUMBER, batch_id NUMBER NOT NULL, reject_codes VARCHAR2(100) NOT NULL,
  a1  VARCHAR2(20),  a2  VARCHAR2(60),  a3  VARCHAR2(60),  a4  VARCHAR2(20),
  a5  VARCHAR2(20),  a6  VARCHAR2(20),  a7  VARCHAR2(20),  a8  VARCHAR2(20),
  a9  VARCHAR2(20),  a10 VARCHAR2(20),  a11 VARCHAR2(20),  a12 VARCHAR2(20),
  a13 VARCHAR2(20),  a14 VARCHAR2(20),  a15 VARCHAR2(20),  a16 VARCHAR2(20),
  quarantined_ts TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE fd_cln.q_account (
  stg_row_id NUMBER, batch_id NUMBER NOT NULL, reject_codes VARCHAR2(100) NOT NULL,
  account_id VARCHAR2(20), district_id VARCHAR2(20), frequency VARCHAR2(40), acct_date VARCHAR2(20),
  quarantined_ts TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE fd_cln.q_client (
  stg_row_id NUMBER, batch_id NUMBER NOT NULL, reject_codes VARCHAR2(100) NOT NULL,
  client_id VARCHAR2(20), birth_number VARCHAR2(20), district_id VARCHAR2(20),
  quarantined_ts TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE fd_cln.q_disp (
  stg_row_id NUMBER, batch_id NUMBER NOT NULL, reject_codes VARCHAR2(100) NOT NULL,
  disp_id VARCHAR2(20), client_id VARCHAR2(20), account_id VARCHAR2(20), disp_type VARCHAR2(20),
  quarantined_ts TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE fd_cln.q_card (
  stg_row_id NUMBER, batch_id NUMBER NOT NULL, reject_codes VARCHAR2(100) NOT NULL,
  card_id VARCHAR2(20), disp_id VARCHAR2(20), card_type VARCHAR2(20), issued VARCHAR2(30),
  quarantined_ts TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE fd_cln.q_loan (
  stg_row_id NUMBER, batch_id NUMBER NOT NULL, reject_codes VARCHAR2(100) NOT NULL,
  loan_id VARCHAR2(20), account_id VARCHAR2(20), loan_date VARCHAR2(20), amount VARCHAR2(30),
  duration VARCHAR2(20), payments VARCHAR2(30), status VARCHAR2(10),
  quarantined_ts TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE fd_cln.q_order (
  stg_row_id NUMBER, batch_id NUMBER NOT NULL, reject_codes VARCHAR2(100) NOT NULL,
  order_id VARCHAR2(20), account_id VARCHAR2(20), bank_to VARCHAR2(10), account_to VARCHAR2(20),
  amount VARCHAR2(30), k_symbol VARCHAR2(30),
  quarantined_ts TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE fd_cln.q_trans (
  stg_row_id NUMBER, batch_id NUMBER NOT NULL, reject_codes VARCHAR2(100) NOT NULL,
  trans_id VARCHAR2(20), account_id VARCHAR2(20), trans_date VARCHAR2(20), trans_type VARCHAR2(20),
  operation VARCHAR2(40), amount VARCHAR2(30), balance VARCHAR2(30), k_symbol VARCHAR2(30),
  bank VARCHAR2(10), account VARCHAR2(20),
  quarantined_ts TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);
CREATE INDEX fd_cln.q_trans_batch_ix ON fd_cln.q_trans (batch_id);

GRANT SELECT ON fd_cln.cln_district TO fd_dwh;
GRANT SELECT ON fd_cln.cln_account  TO fd_dwh;
GRANT SELECT ON fd_cln.cln_client   TO fd_dwh;
GRANT SELECT ON fd_cln.cln_disp     TO fd_dwh;
GRANT SELECT ON fd_cln.cln_card     TO fd_dwh;
GRANT SELECT ON fd_cln.cln_loan     TO fd_dwh;
GRANT SELECT ON fd_cln.cln_order    TO fd_dwh;
GRANT SELECT ON fd_cln.cln_trans    TO fd_dwh;
