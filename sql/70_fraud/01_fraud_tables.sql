-- =============================================================================
-- 70_fraud/01_fraud_tables.sql
-- Transaction-monitoring rules. Every threshold lives in rule_param, so an
-- analyst can tune a rule with an UPDATE instead of a code change.
-- =============================================================================

CREATE TABLE fd_dwh.rule_config (
  rule_code    VARCHAR2(5)    NOT NULL,
  rule_name    VARCHAR2(60)   NOT NULL,
  severity     VARCHAR2(6)    NOT NULL,
  is_active    CHAR(1)        DEFAULT 'Y' NOT NULL,
  description  VARCHAR2(400)  NOT NULL,
  CONSTRAINT rule_config_pk PRIMARY KEY (rule_code),
  CONSTRAINT rule_config_sev_ck CHECK (severity IN ('HIGH', 'MEDIUM', 'LOW')),
  CONSTRAINT rule_config_act_ck CHECK (is_active IN ('Y', 'N'))
);

CREATE TABLE fd_dwh.rule_param (
  rule_code    VARCHAR2(5)    NOT NULL,
  param_name   VARCHAR2(30)   NOT NULL,
  param_value  NUMBER         NOT NULL,
  unit         VARCHAR2(20)   NOT NULL,
  description  VARCHAR2(400)  NOT NULL,
  CONSTRAINT rule_param_pk PRIMARY KEY (rule_code, param_name),
  CONSTRAINT rule_param_rule_fk FOREIGN KEY (rule_code) REFERENCES fd_dwh.rule_config (rule_code)
);

CREATE TABLE fd_dwh.fraud_alerts (
  alert_id         NUMBER GENERATED ALWAYS AS IDENTITY,
  txn_key          NUMBER         NOT NULL,
  trans_id         NUMBER(10)     NOT NULL,
  account_key      NUMBER         NOT NULL,
  txn_date         DATE           NOT NULL,
  rule_code        VARCHAR2(5)    NOT NULL,
  severity         VARCHAR2(6)    NOT NULL,
  alert_reason     VARCHAR2(400)  NOT NULL,
  status           VARCHAR2(6)    DEFAULT 'OPEN' NOT NULL,
  created_ts       TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
  closed_ts        TIMESTAMP,
  closed_by        VARCHAR2(128),
  resolution_note  VARCHAR2(400),
  batch_id         NUMBER         NOT NULL,
  CONSTRAINT fraud_alerts_pk PRIMARY KEY (alert_id),
  CONSTRAINT fraud_alerts_nk UNIQUE (txn_key, rule_code),          -- idempotent re-scans
  CONSTRAINT fraud_alerts_status_ck CHECK (status IN ('OPEN', 'CLOSED')),
  CONSTRAINT fraud_alerts_txn_fk  FOREIGN KEY (txn_key)     REFERENCES fd_dwh.fact_transaction (txn_key),
  CONSTRAINT fraud_alerts_acct_fk FOREIGN KEY (account_key) REFERENCES fd_dwh.dim_account (account_key),
  CONSTRAINT fraud_alerts_rule_fk FOREIGN KEY (rule_code)   REFERENCES fd_dwh.rule_config (rule_code)
);
CREATE INDEX fd_dwh.fraud_alerts_batch_ix ON fd_dwh.fraud_alerts (batch_id);
CREATE INDEX fd_dwh.fraud_alerts_acct_ix  ON fd_dwh.fraud_alerts (account_key);
