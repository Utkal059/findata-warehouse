-- =============================================================================
-- 50_dwh/02_fact_transaction.sql
-- Grain: one row per bank transaction.
-- RANGE partitioned by txn_date with INTERVAL = 1 month: Oracle creates a new
-- partition automatically the first time a month arrives.
-- trans_id is unique, so re-running a batch can never duplicate a fact.
-- Performance indexes (bitmap / local) are added in sql/80_perf.
-- =============================================================================

CREATE TABLE fd_dwh.fact_transaction (
  txn_key               NUMBER GENERATED ALWAYS AS IDENTITY,
  trans_id              NUMBER(10)    NOT NULL,   -- degenerate key from source
  txn_date              DATE          NOT NULL,   -- partition key
  date_key              NUMBER(8)     NOT NULL,
  account_key           NUMBER        NOT NULL,
  customer_key          NUMBER        NOT NULL,   -- account owner, SCD2 version valid on txn_date
  branch_key            NUMBER        NOT NULL,
  channel_key           NUMBER        NOT NULL,
  category_key          NUMBER        NOT NULL,
  txn_type              VARCHAR2(6)   NOT NULL,   -- CREDIT / DEBIT
  amount                NUMBER(12,2)  NOT NULL,   -- always positive
  signed_amount         NUMBER(12,2)  NOT NULL,   -- + credit / - debit
  balance_after         NUMBER(12,2),
  counterparty_bank     VARCHAR2(2),
  counterparty_account  VARCHAR2(20),
  dq_warn_codes         VARCHAR2(40),
  batch_id              NUMBER        NOT NULL,
  load_ts               TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT fact_transaction_pk PRIMARY KEY (txn_key),
  CONSTRAINT fact_transaction_nk UNIQUE (trans_id),
  CONSTRAINT fact_txn_type_ck CHECK (txn_type IN ('CREDIT', 'DEBIT')),
  CONSTRAINT fact_txn_date_fk     FOREIGN KEY (date_key)     REFERENCES fd_dwh.dim_date (date_key),
  CONSTRAINT fact_txn_account_fk  FOREIGN KEY (account_key)  REFERENCES fd_dwh.dim_account (account_key),
  CONSTRAINT fact_txn_customer_fk FOREIGN KEY (customer_key) REFERENCES fd_dwh.dim_customer (customer_key),
  CONSTRAINT fact_txn_branch_fk   FOREIGN KEY (branch_key)   REFERENCES fd_dwh.dim_branch (branch_key),
  CONSTRAINT fact_txn_channel_fk  FOREIGN KEY (channel_key)  REFERENCES fd_dwh.dim_channel (channel_key),
  CONSTRAINT fact_txn_category_fk FOREIGN KEY (category_key) REFERENCES fd_dwh.dim_txn_category (category_key)
)
PARTITION BY RANGE (txn_date) INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))
  (PARTITION p_before_1993 VALUES LESS THAN (DATE '1993-01-01'));

-- Incremental fraud scans and reconciliation read one batch at a time.
CREATE INDEX fd_dwh.fact_txn_batch_ix ON fd_dwh.fact_transaction (batch_id) LOCAL;
