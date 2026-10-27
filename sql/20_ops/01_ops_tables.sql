-- =============================================================================
-- 20_ops/01_ops_tables.sql                                   OPERATIONS LAYER
-- Built before any ETL so that every later step can be logged.
--   etl_batch      one row per pipeline run (as-of date + watermark window)
--   etl_log        one row per step / sub-task attempt (rows read/loaded/rejected)
--   etl_error_log  one row per rejected or warned source record, per rule
--   etl_watermark  incremental high-water marks
--   etl_step       the ordered list of pipeline steps (drives orchestration)
--   etl_config     runtime switches (incl. failure injection for drills)
--   dq_rule        data-quality rule catalogue (R001..)
--   audit_log      who changed what (written by triggers)
--   test_result    output of sql/90_tests
--   perf_result    output of the sql/80_perf benchmark
-- =============================================================================

CREATE TABLE fd_ops.etl_batch (
  batch_id     NUMBER GENERATED ALWAYS AS IDENTITY (NOCACHE),   -- gap-free batch ids
  as_of_date   DATE           NOT NULL,
  wm_from      DATE,                       -- TRANS watermark when the batch started (exclusive)
  wm_to        DATE           NOT NULL,    -- = as_of_date (inclusive)
  status       VARCHAR2(10)   DEFAULT 'RUNNING' NOT NULL,
  start_ts     TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
  end_ts       TIMESTAMP,
  run_by       VARCHAR2(128)  DEFAULT SYS_CONTEXT('USERENV', 'SESSION_USER') NOT NULL,
  error_msg    VARCHAR2(4000),
  CONSTRAINT etl_batch_pk PRIMARY KEY (batch_id),
  CONSTRAINT etl_batch_status_ck CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED'))
);

CREATE TABLE fd_ops.etl_log (
  log_id         NUMBER GENERATED ALWAYS AS IDENTITY,
  batch_id       NUMBER         NOT NULL,
  parent_log_id  NUMBER,                   -- NULL for a pipeline step, set for its sub-tasks
  step_name      VARCHAR2(60)   NOT NULL,
  attempt_no     NUMBER         DEFAULT 1 NOT NULL,
  rows_read      NUMBER,
  rows_loaded    NUMBER,
  rows_rejected  NUMBER,
  start_ts       TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
  end_ts         TIMESTAMP,
  status         VARCHAR2(10)   DEFAULT 'RUNNING' NOT NULL,
  error_msg      VARCHAR2(4000),
  error_stack    VARCHAR2(4000),
  CONSTRAINT etl_log_pk PRIMARY KEY (log_id),
  CONSTRAINT etl_log_batch_fk FOREIGN KEY (batch_id) REFERENCES fd_ops.etl_batch (batch_id),
  CONSTRAINT etl_log_parent_fk FOREIGN KEY (parent_log_id) REFERENCES fd_ops.etl_log (log_id),
  CONSTRAINT etl_log_status_ck CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED'))
);
CREATE INDEX fd_ops.etl_log_batch_ix  ON fd_ops.etl_log (batch_id, step_name);
CREATE INDEX fd_ops.etl_log_parent_ix ON fd_ops.etl_log (parent_log_id);

CREATE TABLE fd_ops.dq_rule (
  rule_code    VARCHAR2(10)   NOT NULL,
  rule_name    VARCHAR2(40)   NOT NULL,
  severity     VARCHAR2(10)   NOT NULL,    -- REJECT: row quarantined | WARN: row kept, flagged
  description  VARCHAR2(400)  NOT NULL,
  CONSTRAINT dq_rule_pk PRIMARY KEY (rule_code),
  CONSTRAINT dq_rule_sev_ck CHECK (severity IN ('REJECT', 'WARN'))
);

CREATE TABLE fd_ops.etl_error_log (
  error_id      NUMBER GENERATED ALWAYS AS IDENTITY,
  batch_id      NUMBER         NOT NULL,
  log_id        NUMBER,                    -- the step attempt that raised it
  source_table  VARCHAR2(60)   NOT NULL,
  source_key    VARCHAR2(200),
  rule_code     VARCHAR2(10)   NOT NULL,
  severity      VARCHAR2(10),
  error_msg     VARCHAR2(4000),
  created_ts    TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT etl_error_log_pk PRIMARY KEY (error_id),
  CONSTRAINT etl_error_log_batch_fk FOREIGN KEY (batch_id) REFERENCES fd_ops.etl_batch (batch_id)
);
CREATE INDEX fd_ops.etl_error_log_batch_ix ON fd_ops.etl_error_log (batch_id, source_table, rule_code);

CREATE TABLE fd_ops.etl_watermark (
  table_name         VARCHAR2(60)  NOT NULL,
  last_loaded_value  DATE,
  updated_batch_id   NUMBER,
  updated_ts         TIMESTAMP,
  CONSTRAINT etl_watermark_pk PRIMARY KEY (table_name)
);

CREATE TABLE fd_ops.etl_step (
  step_seq     NUMBER         NOT NULL,
  step_name    VARCHAR2(30)   NOT NULL,
  description  VARCHAR2(200)  NOT NULL,
  CONSTRAINT etl_step_pk PRIMARY KEY (step_name),
  CONSTRAINT etl_step_seq_uk UNIQUE (step_seq)
);

CREATE TABLE fd_ops.etl_config (
  param_name   VARCHAR2(60)   NOT NULL,
  param_value  VARCHAR2(400),
  description  VARCHAR2(400),
  CONSTRAINT etl_config_pk PRIMARY KEY (param_name)
);

CREATE TABLE fd_ops.audit_log (
  audit_id     NUMBER GENERATED ALWAYS AS IDENTITY,
  table_name   VARCHAR2(128)  NOT NULL,
  record_key   VARCHAR2(100)  NOT NULL,
  column_name  VARCHAR2(128)  NOT NULL,
  old_value    VARCHAR2(400),
  new_value    VARCHAR2(400),
  changed_by   VARCHAR2(128)  NOT NULL,
  os_user      VARCHAR2(128),
  changed_ts   TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT audit_log_pk PRIMARY KEY (audit_id)
);

CREATE TABLE fd_ops.test_result (
  run_id       NUMBER         NOT NULL,
  test_code    VARCHAR2(20)   NOT NULL,
  description  VARCHAR2(400)  NOT NULL,
  status       VARCHAR2(4)    NOT NULL,
  detail       VARCHAR2(4000),
  run_ts       TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT test_result_pk PRIMARY KEY (run_id, test_code),
  CONSTRAINT test_result_status_ck CHECK (status IN ('PASS', 'FAIL'))
);

CREATE TABLE fd_ops.perf_result (
  run_label        VARCHAR2(10)   NOT NULL,   -- BEFORE / AFTER
  query_id         VARCHAR2(10)   NOT NULL,
  description      VARCHAR2(200),
  executions       NUMBER,
  median_ms        NUMBER,
  min_ms           NUMBER,
  max_ms           NUMBER,
  buffer_gets_per_exec NUMBER,
  rows_returned    NUMBER,
  plan_hash_value  NUMBER,
  captured_ts      TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT perf_result_pk PRIMARY KEY (run_label, query_id)
);

CREATE TABLE fd_ops.perf_plan (
  run_label   VARCHAR2(10)   NOT NULL,
  query_id    VARCHAR2(10)   NOT NULL,
  line_no     NUMBER         NOT NULL,
  plan_line   VARCHAR2(400),
  CONSTRAINT perf_plan_pk PRIMARY KEY (run_label, query_id, line_no)
);
