-- =============================================================================
-- 70_fraud/02_fraud_rules_seed.sql
-- Rule catalogue and thresholds. The values were picked from a profile of the
-- loaded PKDD'99 facts (amounts in CZK), aiming for an alert volume an
-- analyst team could review; they are not calibrated against labelled fraud
-- (the dataset has none). Profile highlights that drove them:
--   * cash credits never reach 50,000 (max 49,999) -> a 50,000 limit exists
--   * card withdrawals max 8,000; cash withdrawals p99 = 42,800
--   * true dormancy is rare: only 3 debits follow >= 180 days of no activity
-- =============================================================================

INSERT INTO fd_dwh.rule_config (rule_code, rule_name, severity, description) VALUES
  ('F01', 'NEW_ACCOUNT_LARGE_OUTFLOW', 'HIGH',
   'Large cash withdrawal or outbound transfer shortly after the account was opened (mule / bust-out pattern)');
INSERT INTO fd_dwh.rule_config (rule_code, rule_name, severity, description) VALUES
  ('F02', 'DORMANT_ACCOUNT_REACTIVATION', 'HIGH',
   'Debit on an account with no client-initiated activity for a long period (account takeover pattern)');
INSERT INTO fd_dwh.rule_config (rule_code, rule_name, severity, description) VALUES
  ('F03', 'RAPID_PASS_THROUGH', 'MEDIUM',
   'Most of a large non-income credit leaves the account within a few days (layering pattern)');
INSERT INTO fd_dwh.rule_config (rule_code, rule_name, severity, description) VALUES
  ('F04', 'CASH_STRUCTURING', 'MEDIUM',
   'Several same-day cash transactions just below the cash limit (structuring / smurfing pattern)');
INSERT INTO fd_dwh.rule_config (rule_code, rule_name, severity, description) VALUES
  ('F05', 'LARGE_ROUND_CASH_WITHDRAWAL', 'LOW',
   'Large cash withdrawal in an exact round amount');

INSERT INTO fd_dwh.rule_param VALUES ('F01', 'MAX_ACCOUNT_AGE_DAYS', 30,    'days', 'Account age at the time of the outflow');
INSERT INTO fd_dwh.rule_param VALUES ('F01', 'MIN_AMOUNT',           30000, 'CZK',  'Smallest outflow that alerts');
INSERT INTO fd_dwh.rule_param VALUES ('F02', 'MIN_DORMANT_DAYS',     90,    'days', 'Days since the previous client-initiated transaction');
INSERT INTO fd_dwh.rule_param VALUES ('F02', 'MIN_AMOUNT',           2500,  'CZK',  'Smallest debit that alerts');
INSERT INTO fd_dwh.rule_param VALUES ('F03', 'WINDOW_DAYS',          3,     'days', 'Look-back from the debit to the credit');
INSERT INTO fd_dwh.rule_param VALUES ('F03', 'MIN_CREDIT',           50000, 'CZK',  'Smallest non-income credit considered');
INSERT INTO fd_dwh.rule_param VALUES ('F03', 'MIN_OUT_PCT',          90,    '%',    'Debit as a share of that credit');
INSERT INTO fd_dwh.rule_param VALUES ('F04', 'REPORTING_LIMIT',      50000, 'CZK',  'Cash limit being avoided');
INSERT INTO fd_dwh.rule_param VALUES ('F04', 'BAND_PCT',             10,    '%',    'Width of the just-below band (45,000 - 49,999 at 10%)');
INSERT INTO fd_dwh.rule_param VALUES ('F04', 'MIN_COUNT',            2,     'txns', 'Cash transactions in the band on one day');
INSERT INTO fd_dwh.rule_param VALUES ('F05', 'MIN_AMOUNT',           30000, 'CZK',  'Smallest withdrawal that alerts');
INSERT INTO fd_dwh.rule_param VALUES ('F05', 'ROUND_UNIT',           10000, 'CZK',  'Amount must be an exact multiple of this');

COMMIT;
