-- =============================================================================
-- 20_ops/02_ops_seed.sql
-- Reference rows for the operations layer.
-- =============================================================================

INSERT INTO fd_ops.etl_step (step_seq, step_name, description) VALUES
  (1, 'RAW_CHECK', 'Verify external-table row counts against source file line counts'),
  (2, 'STAGE',     'Copy RAW to STAGING: master files in full, TRANS incrementally by watermark'),
  (3, 'CLEAN',     'Type, translate, de-duplicate and validate; bad rows to quarantine'),
  (4, 'LOAD_DWH',  'MERGE dimensions (customer = SCD2) and append new fact_transaction rows'),
  (5, 'RISK',      'DERIVED loan schedule, days-past-due and SMA/NPA month-end snapshots'),
  (6, 'FRAUD',     'Run transaction-monitoring rules F01-F05 on the batch''s new facts');

INSERT INTO fd_ops.dq_rule (rule_code, rule_name, severity, description) VALUES
  ('R001', 'MISSING_REQUIRED',  'REJECT', 'Required field is empty (key, amount, type)');
INSERT INTO fd_ops.dq_rule (rule_code, rule_name, severity, description) VALUES
  ('R002', 'INVALID_DATE',      'REJECT', 'Date is not a valid YYMMDD value');
INSERT INTO fd_ops.dq_rule (rule_code, rule_name, severity, description) VALUES
  ('R003', 'ORPHAN_REFERENCE',  'REJECT', 'Referenced parent (account, client, disposition, district) does not exist');
INSERT INTO fd_ops.dq_rule (rule_code, rule_name, severity, description) VALUES
  ('R004', 'BALANCE_MISMATCH',  'WARN',   'Running balance differs from previous balance +/- amount');
INSERT INTO fd_ops.dq_rule (rule_code, rule_name, severity, description) VALUES
  ('R005', 'UNKNOWN_CODE',      'REJECT', 'Code value has no translation (type, operation, k_symbol, frequency, status...)');
INSERT INTO fd_ops.dq_rule (rule_code, rule_name, severity, description) VALUES
  ('R006', 'DUPLICATE_KEY',     'REJECT', 'Natural key repeated in the batch or already loaded by an earlier batch');
INSERT INTO fd_ops.dq_rule (rule_code, rule_name, severity, description) VALUES
  ('R007', 'INVALID_NUMBER',    'REJECT', 'Numeric field is not a number (placeholder ''?'' is standardised to NULL, not rejected)');
INSERT INTO fd_ops.dq_rule (rule_code, rule_name, severity, description) VALUES
  ('R008', 'UNRESOLVED_DIM_KEY','WARN',   'Fact row mapped to the unknown (-1) member because a dimension lookup failed');

INSERT INTO fd_ops.etl_watermark (table_name, last_loaded_value) VALUES ('TRANS', NULL);

INSERT INTO fd_ops.etl_config (param_name, param_value, description) VALUES
  ('RAW_REJECT_TOLERANCE', '0',
   'Max rows a source file may lose to the external-table BADFILE before RAW_CHECK fails');
INSERT INTO fd_ops.etl_config (param_name, param_value, description) VALUES
  ('FAIL_AT_STEP', NULL,
   'Failure drill: name of a step that should raise an error (used by tests and the runbook). Keep NULL in normal runs.');

COMMIT;
