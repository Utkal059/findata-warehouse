# Data dictionary

Source: PKDD'99 Discovery Challenge financial dataset ("Berka"), a Czech bank, 1993-01-01 to 1998-12-31.
Amounts are in CZK. Anything marked **DERIVED** does not exist in the source and is computed by this warehouse.

## Schemas

| Schema | Login | Holds | Can be read by |
|---|---|---|---|
| `FD_RAW` | none (schema-only) | External tables over the `.asc` files | `FD_STG` |
| `FD_STG` | none | Staging copies, all text, tagged with `load_batch_id` | `FD_CLN` |
| `FD_CLN` | none | Typed, translated, validated rows; quarantine tables; validation views | `FD_DWH` |
| `FD_DWH` | none | Star schema, loan risk, fraud alerts | `FD_MART` (with grant option) |
| `FD_MART` | none | Reporting views | `FD_REPORT` |
| `FD_OPS` | none | Batch control, logs, error log, audit log, test and performance results; orchestrator | `FD_ETL` (logs only) |
| `FD_ETL` | password | Nothing; may run `fd_ops.proc_run_daily_etl`, `fd_ops.proc_replay_step`, `fd_dwh.close_fraud_alert` | - |
| `FD_REPORT` | password | Nothing; `SELECT` on the `FD_MART` views only | - |

## RAW (`FD_RAW`)

`ext_account`, `ext_card`, `ext_client`, `ext_disp`, `ext_district`, `ext_loan`, `ext_order`, `ext_trans`: one
external table per file (`ORACLE_LOADER`, `;`-separated, optional `"` enclosure, header skipped,
`REJECT LIMIT UNLIMITED`, BADFILE and LOGFILE in directory `FD_LOG_DIR`). Every column is `VARCHAR2`, so the RAW layer
never loses a row to a type error. Source column names that are SQL keywords are renamed: `date` becomes `acct_date`,
`loan_date` and `trans_date`, and `type` becomes `card_type`, `disp_type` and `trans_type`. `ext_district` keeps the
source names `a1` to `a16`.

`ext_file_lines` reads any registered file as whole lines. `fd_raw.pkg_raw_check.file_rows` uses it to count data lines,
and RAW_CHECK compares that count with the external table's.

## STAGING (`FD_STG`)

`stg_<file>`: the RAW columns as text, plus `stg_row_id` (identity), `load_batch_id` and `load_ts`.

* Master files (account, card, client, disp, district, loan, order) are reloaded in full every batch.
* `stg_trans` is incremental. A batch holds only the rows dated after the TRANS watermark and up to its as-of date.
  It is AUTOMATIC LIST partitioned by `load_batch_id`, so one partition per batch.

## CLEAN (`FD_CLN`)

| Table | Grain / key | Notes |
|---|---|---|
| `cln_district` | district_id | `a1..a16` renamed (see below); `'?'` becomes NULL in unemployment 95 and crimes 95 |
| `cln_account` | account_id | `frequency`: POPLATEK MESICNE becomes MONTHLY, POPLATEK TYDNE becomes WEEKLY, POPLATEK PO OBRATU becomes ON_TRANSACTION |
| `cln_client` | client_id | `gender` and `birth_date` derived from `birth_number` (YYMMDD, month + 50 = female) |
| `cln_disp` | disp_id | `disp_type` OWNER / DISPONENT |
| `cln_card` | card_id | `card_type` JUNIOR / CLASSIC / GOLD; `issued_date` from `YYMMDD hh:mi:ss` |
| `cln_loan` | loan_id | `status_code` A/B/C/D as delivered; `loan_status`: A FINISHED_OK, B FINISHED_DEFAULT, C RUNNING_OK, D RUNNING_DEBT |
| `cln_order` | order_id | `k_symbol`: POJISTNE INSURANCE, SIPO HOUSEHOLD, UVER LOAN_PAYMENT, LEASING LEASING |
| `cln_trans` | trans_id | translations below; `dq_warn_codes` lists WARN rules hit (R004) |
| `q_<file>` | stg_row_id + batch_id | quarantined rows: raw text plus `reject_codes` (e.g. `R002,R003`) |

District columns: a1 `district_id`, a2 `district_name`, a3 `region`, a4 `inhabitants`, a5-a8 municipalities by size
(<500, 500-1,999, 2,000-9,999, >=10,000), a9 `city_cnt`, a10 `urban_ratio_pct`, a11 `avg_salary`, a12 `unemp_rate_95`,
a13 `unemp_rate_96`, a14 `entrepreneurs_per_1000`, a15 `crimes_95`, a16 `crimes_96`.

Transaction translations (Czech source codes):

| Column | Source | Clean value |
|---|---|---|
| `txn_type` | PRIJEM | CREDIT |
| | VYDAJ, VYBER | DEBIT |
| `operation` | VYBER KARTOU | CARD_WITHDRAWAL |
| | VKLAD | CASH_CREDIT |
| | PREVOD Z UCTU | INBOUND_TRANSFER |
| | VYBER | CASH_WITHDRAWAL |
| | PREVOD NA UCET | OUTBOUND_TRANSFER |
| | empty | NULL (bank-posted entries, i.e. interest) |
| `k_symbol` | POJISTNE | INSURANCE |
| | SLUZBY | STATEMENT |
| | UROK | INTEREST |
| | SANKC. UROK | PENALTY_INTEREST |
| | SIPO | HOUSEHOLD |
| | DUCHOD | PENSION |
| | UVER | LOAN_PAYMENT |
| | empty or a single space | NULL |

Validation views `v_chk_<file>` compute the typed columns and `reject_codes` for every staged row. `fd_cln.pkg_clean`
routes rows with codes to `q_<file>` and the rest to `cln_<file>`, in one transaction with the matching
`fd_ops.etl_error_log` rows.

### Data-quality rules (`fd_ops.dq_rule`)

| Code | Name | Severity | Meaning |
|---|---|---|---|
| R001 | MISSING_REQUIRED | REJECT | key, amount or type is empty |
| R002 | INVALID_DATE | REJECT | not a valid YYMMDD date |
| R003 | ORPHAN_REFERENCE | REJECT | parent account / client / disposition / district missing |
| R004 | BALANCE_MISMATCH | WARN | no ordering of the day's transactions makes the running balance add up; row kept and flagged |
| R005 | UNKNOWN_CODE | REJECT | code with no translation |
| R006 | DUPLICATE_KEY | REJECT | natural key repeated in the batch or already loaded by an earlier batch |
| R007 | INVALID_NUMBER | REJECT | numeric field is not a number, or the amount is negative |
| R008 | UNRESOLVED_DIM_KEY | WARN | fact row mapped to an unknown (-1) dimension member |

## DWH (`FD_DWH`)

All surrogate keys are identity columns. Every dimension has a `-1` UNKNOWN member, and a fact whose lookup fails is
kept on that member and logged as R008, never dropped. `row_hash` is `STANDARD_HASH(..., 'SHA256')` of the tracked
attributes and is used for change detection.

| Table | Grain | Type | Key columns / attributes |
|---|---|---|---|
| `dim_date` | calendar day 1993-01-01 .. 1999-12-31 | generated | `date_key` YYYYMMDD; day/ISO week/month/quarter/year, `month_end_date`, `is_month_end`, `is_weekend` |
| `dim_branch` | district | SCD1 | `branch_key`; `district_id` (NK); name, region, inhabitants, salary, unemployment, crimes |
| `dim_account` | account | SCD1 | `account_key`; `account_id` (NK); `district_id`, `statement_frequency`, `open_date`, `owner_client_id`, `disponent_cnt` |
| `dim_customer` | client version | **SCD2** | `customer_key`; `client_id` (NK); `gender`, `birth_date`, `birth_year`, home district/region, `card_tier` (NONE/JUNIOR/CLASSIC/GOLD, best card issued by then), `has_loan` (an owned account has a loan granted by then); `valid_from`, `valid_to`, `is_current`, `row_hash` |
| `dim_channel` | operation | SCD1 | `channel_code` (NK, NONE = bank-posted); `channel_group` CARD / CASH / TRANSFER / BANK_POSTED |
| `dim_txn_category` | k_symbol | SCD1 | `category_code` (NK, NONE = not characterised); `category_group` INCOME / OBLIGATION / BANK_FEE / UNSPECIFIED |
| `fact_transaction` | transaction | fact | `txn_key`; `trans_id` (unique NK); `txn_date` (partition key, monthly INTERVAL); FKs to all dimensions; `amount` (positive), `signed_amount` (+credit / -debit), `balance_after`, counterparty bank/account, `dq_warn_codes`, `batch_id` |

SCD2 rules:

* A client's first version is valid from 1900-01-01, so its history before the first load is collapsed into the state
  at that load.
* When a tracked attribute changes, the current version is closed the day before the business event that explains the
  change: the latest card issue or loan grant inside the batch window. If no event explains it, the batch as-of date is
  used. A new version then starts on that date.
* `valid_to` of the current version is 9999-12-31.
* A function-based unique index enforces at most one `is_current = 'Y'` row per client.
* `fact_transaction.customer_key` is the version valid on `txn_date` (point-in-time).

## Loan risk (`FD_DWH`)

The RBI SMA/NPA buckets are used here as a classification **framework** on Czech data. This is not Indian bank data.

| Table | Grain | Columns |
|---|---|---|
| `loan_schedule` **DERIVED** | loan x installment | `installment_no` 1..duration, `due_date = ADD_MONTHS(loan_date, k)`, `amount_due = loan.payments` |
| `fact_loan_snapshot` | loan x month-end | `installments_due`, `installments_paid`, `amount_due_cum`, `amount_paid_cum`, `overdue_amount`, `outstanding_amount` (amount - paid; the source has no interest split), `first_unpaid_due_date`, `dpd`, `dpd_bucket`, `sma_class`, `source_status_code/source_status` (as delivered) |

* Repayments are the LOAN_PAYMENT (`UVER`) debits on the loan account. Each source loan has its own account.
* `installments_paid` is the number of whole installments the cumulative repayments cover, oldest first. A cumulative
  shortfall under 1% of one installment counts as rounding, because the source pays 3,372.70 against a 3,373 installment.
* DPD = month-end minus the due date of the oldest uncovered installment. An installment due on the month-end itself is
  0 DPD.
* Classes: 0 STANDARD, 1-30 SMA-0, 31-60 SMA-1, 61-90 SMA-2, >90 NPA (`fd_dwh.pkg_risk.classify_dpd`).
* A loan gets a snapshot at every month-end from its grant until maturity, and after maturity only while it is still
  overdue.

## Transaction monitoring (`FD_DWH`)

| Table | Content |
|---|---|
| `rule_config` | `rule_code` F01-F05, `rule_name`, `severity` HIGH/MEDIUM/LOW, `is_active`, `description` |
| `rule_param` | one row per threshold: `rule_code`, `param_name`, `param_value`, `unit` |
| `fraud_alerts` | `alert_id`, `txn_key` (FK to the fact), `trans_id`, `account_key`, `txn_date`, `rule_code`, `severity`, `alert_reason` (text with the actual values and thresholds), `status` OPEN/CLOSED, `created_ts`, `closed_ts`, `closed_by`, `resolution_note`, `batch_id`; unique (`txn_key`, `rule_code`) |

`trg_fraud_alerts_audit` (AFTER UPDATE OF status, resolution_note) writes old value, new value, database user and OS
user to `fd_ops.audit_log`.

## MART (`FD_MART`)

| View | Answers |
|---|---|
| `v_monthly_txn_trend` | credits, debits, net flow, active accounts per month |
| `v_branch_performance` | per region / district / year: activity, volumes, district salary and unemployment |
| `v_channel_mix` | per year: count, amount and share by channel |
| `v_customer_segment` | per year: gender x age band x card tier x loan holder, using the SCD2 version valid at the time |
| `v_loan_portfolio_quality` | per month-end: loans, outstanding and overdue by SMA class |
| `v_loan_status_vs_sma` | worst DERIVED class reached vs the source `loan.status` |
| `v_fraud_alert_summary` | alerts, accounts and amount by rule and status |

## OPS (`FD_OPS`)

| Table | Content |
|---|---|
| `etl_batch` | one row per batch: `as_of_date`, `wm_from` (exclusive), `wm_to`, `status` RUNNING/SUCCESS/FAILED, timings, `run_by`, `error_msg` |
| `etl_log` | one row per step attempt (`parent_log_id` NULL) and per sub-task; `attempt_no`, rows read/loaded/rejected, status, `error_msg`, `error_stack` |
| `etl_error_log` | one row per data-quality hit or runtime error, with the rule, source table and source key |
| `etl_watermark` | `TRANS` = last as-of date whose transactions are staged |
| `etl_step` | the pipeline order: RAW_CHECK, STAGE, CLEAN, LOAD_DWH, RISK, FRAUD |
| `etl_config` | `RAW_REJECT_TOLERANCE`, `FAIL_AT_STEP` (failure drill) |
| `dq_rule` | R001-R008 (above) |
| `audit_log` | column-level change history (fraud alert status and notes) |
| `test_result` | one row per test per run |
| `perf_query`, `perf_result`, `perf_plan` | the five benchmark queries, their BEFORE/AFTER timings and plans |
