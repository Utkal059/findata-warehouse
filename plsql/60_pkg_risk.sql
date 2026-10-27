-- =============================================================================
-- plsql/60_pkg_risk.sql
-- RISK step: loan early-warning classification.
--
-- For every loan granted on or before the batch date:
--   1. DERIVED schedule: installment k (1..duration) due ADD_MONTHS(loan_date, k)
--   2. at every month-end in the batch window:
--        paid      = LOAN_PAYMENT debits on the loan account since loan_date
--        covered   = whole installments those payments cover (oldest first)
--        due       = installments due on or before the month-end
--        DPD       = month-end - due date of the oldest uncovered installment
--   3. DPD -> RBI-style bucket (framework only; data is Czech, not Indian)
--        0 STANDARD | 1-30 SMA-0 | 31-60 SMA-1 | 61-90 SMA-2 | >90 NPA
--
-- Source quirk: payments in trans are the installment rounded to 0.1 CZK
-- (3372.7 paid against a 3373 installment). A cumulative shortfall below 1%
-- of one installment is treated as rounding, not as an unpaid installment.
-- =============================================================================

CREATE OR REPLACE PACKAGE fd_dwh.pkg_risk AUTHID DEFINER AS

  c_rounding_tolerance CONSTANT NUMBER := 0.01;   -- fraction of one installment

  FUNCTION classify_dpd (p_dpd IN NUMBER) RETURN VARCHAR2 DETERMINISTIC;

  FUNCTION dpd_bucket (p_dpd IN NUMBER) RETURN VARCHAR2 DETERMINISTIC;

  PROCEDURE run (p_batch_id IN NUMBER, p_parent_log_id IN NUMBER);

END pkg_risk;
/

CREATE OR REPLACE PACKAGE BODY fd_dwh.pkg_risk AS

  g_batch_id   NUMBER;
  g_parent_id  NUMBER;
  g_log_id     NUMBER;
  g_as_of      DATE;
  g_wm_from    DATE;

  FUNCTION classify_dpd (p_dpd IN NUMBER) RETURN VARCHAR2 DETERMINISTIC IS
  BEGIN
    RETURN CASE
             WHEN p_dpd IS NULL OR p_dpd < 0 THEN NULL
             WHEN p_dpd = 0   THEN 'STANDARD'
             WHEN p_dpd <= 30 THEN 'SMA-0'
             WHEN p_dpd <= 60 THEN 'SMA-1'
             WHEN p_dpd <= 90 THEN 'SMA-2'
             ELSE 'NPA'
           END;
  END classify_dpd;

  FUNCTION dpd_bucket (p_dpd IN NUMBER) RETURN VARCHAR2 DETERMINISTIC IS
  BEGIN
    RETURN CASE
             WHEN p_dpd IS NULL OR p_dpd < 0 THEN NULL
             WHEN p_dpd = 0   THEN '0'
             WHEN p_dpd <= 30 THEN '1-30'
             WHEN p_dpd <= 60 THEN '31-60'
             WHEN p_dpd <= 90 THEN '61-90'
             ELSE '91+'
           END;
  END dpd_bucket;

  PROCEDURE begin_task (p_name IN VARCHAR2) IS
  BEGIN
    g_log_id := fd_ops.pkg_etl_log.start_step(g_batch_id, 'RISK:' || p_name, g_parent_id);
  END begin_task;

  PROCEDURE end_task (p_read IN NUMBER, p_loaded IN NUMBER, p_msg IN VARCHAR2 DEFAULT NULL) IS
  BEGIN
    fd_ops.pkg_etl_log.log_step(g_log_id, 'SUCCESS', p_read, p_loaded, 0, p_msg);
    g_log_id := NULL;
  END end_task;

  -- ------------------------------------------------------------ loan_schedule
  PROCEDURE build_schedule IS
    v_loans NUMBER;
  BEGIN
    begin_task('LOAN_SCHEDULE');
    SELECT COUNT(*) INTO v_loans FROM fd_cln.cln_loan WHERE loan_date <= g_as_of;

    INSERT INTO fd_dwh.loan_schedule (loan_id, installment_no, due_date, amount_due, batch_id)
    SELECT l.loan_id, n.k, ADD_MONTHS(l.loan_date, n.k), l.monthly_payment, g_batch_id
      FROM fd_cln.cln_loan l
      JOIN (SELECT LEVEL AS k FROM dual CONNECT BY LEVEL <= 120) n
        ON n.k <= l.duration_months
     WHERE l.loan_date <= g_as_of
       AND NOT EXISTS (SELECT 1 FROM fd_dwh.loan_schedule s WHERE s.loan_id = l.loan_id);

    end_task(v_loans, SQL%ROWCOUNT, 'DERIVED installments');
  END build_schedule;

  -- ------------------------------------------------------- fact_loan_snapshot
  PROCEDURE build_snapshots IS
    v_loaded NUMBER;
  BEGIN
    begin_task('LOAN_SNAPSHOT');

    MERGE INTO fd_dwh.fact_loan_snapshot f
    USING (
      WITH month_end AS (
             SELECT full_date AS snap
               FROM fd_dwh.dim_date
              WHERE is_month_end = 'Y'
                AND full_date > NVL(g_wm_from, DATE '1900-01-01')
                AND full_date <= g_as_of),
           loan_grid AS (
             SELECT l.loan_id, l.loan_date, l.amount, l.duration_months, l.monthly_payment,
                    l.status_code, l.loan_status, a.account_key, a.owner_client_id, a.district_id,
                    m.snap
               FROM fd_cln.cln_loan l
               JOIN fd_dwh.dim_account a ON a.account_id = l.account_id
               JOIN month_end m          ON m.snap >= l.loan_date
              WHERE l.loan_date <= g_as_of),
           loan_pay AS (
             SELECT f.account_key, f.txn_date, f.amount
               FROM fd_dwh.fact_transaction f
               JOIN fd_dwh.dim_txn_category c ON c.category_key = f.category_key
              WHERE c.category_code = 'LOAN_PAYMENT'
                AND f.txn_type = 'DEBIT'
                AND f.txn_date <= g_as_of),
           paid AS (
             SELECT g.loan_id, g.snap, NVL(SUM(p.amount), 0) AS amount_paid
               FROM loan_grid g
               LEFT JOIN loan_pay p
                 ON p.account_key = g.account_key
                AND p.txn_date BETWEEN g.loan_date AND g.snap
              GROUP BY g.loan_id, g.snap),
           due AS (
             SELECT g.loan_id, g.snap, COUNT(s.installment_no) AS installments_due
               FROM loan_grid g
               LEFT JOIN fd_dwh.loan_schedule s
                 ON s.loan_id = g.loan_id
                AND s.due_date <= g.snap
              GROUP BY g.loan_id, g.snap),
           calc AS (
             SELECT g.*, d.installments_due, p.amount_paid,
                    LEAST(g.duration_months,
                          FLOOR(p.amount_paid / g.monthly_payment + pkg_risk.c_rounding_tolerance))
                      AS installments_paid
               FROM loan_grid g
               JOIN due d  ON d.loan_id = g.loan_id AND d.snap = g.snap
               JOIN paid p ON p.loan_id = g.loan_id AND p.snap = g.snap),
           dpd AS (
             SELECT c.*,
                    CASE WHEN c.installments_paid < c.installments_due THEN s.due_date END
                      AS first_unpaid_due_date,
                    CASE WHEN c.installments_paid < c.installments_due THEN c.snap - s.due_date ELSE 0 END
                      AS dpd
               FROM calc c
               LEFT JOIN fd_dwh.loan_schedule s
                 ON s.loan_id = c.loan_id
                AND s.installment_no = c.installments_paid + 1)
      SELECT x.loan_id, x.snap, TO_NUMBER(TO_CHAR(x.snap, 'YYYYMMDD')) AS snap_key,
             x.account_key, NVL(cu.customer_key, -1) AS customer_key, NVL(b.branch_key, -1) AS branch_key,
             x.loan_date, x.amount, x.duration_months, x.monthly_payment,
             x.installments_due, x.installments_paid,
             x.installments_due * x.monthly_payment AS amount_due_cum,
             x.amount_paid,
             GREATEST(x.installments_due - x.installments_paid, 0) * x.monthly_payment AS overdue_amount,
             GREATEST(x.amount - x.amount_paid, 0) AS outstanding_amount,
             x.first_unpaid_due_date, x.dpd,
             pkg_risk.dpd_bucket(x.dpd) AS dpd_bucket,
             pkg_risk.classify_dpd(x.dpd) AS sma_class,
             x.status_code, x.loan_status
        FROM dpd x
        LEFT JOIN fd_dwh.dim_customer cu
          ON cu.client_id = x.owner_client_id
         AND x.snap BETWEEN cu.valid_from AND cu.valid_to
        LEFT JOIN fd_dwh.dim_branch b ON b.district_id = x.district_id
       -- keep a loan while it is running; after maturity only while still overdue
       WHERE x.snap <= LAST_DAY(ADD_MONTHS(x.loan_date, x.duration_months))
          OR x.dpd > 0
    ) s
    ON (f.loan_id = s.loan_id AND f.snapshot_date = s.snap)
    WHEN MATCHED THEN UPDATE SET
         f.customer_key = s.customer_key, f.installments_due = s.installments_due,
         f.installments_paid = s.installments_paid, f.amount_due_cum = s.amount_due_cum,
         f.amount_paid_cum = s.amount_paid, f.overdue_amount = s.overdue_amount,
         f.outstanding_amount = s.outstanding_amount, f.first_unpaid_due_date = s.first_unpaid_due_date,
         f.dpd = s.dpd, f.dpd_bucket = s.dpd_bucket, f.sma_class = s.sma_class,
         f.source_status_code = s.status_code, f.source_status = s.loan_status,
         f.batch_id = g_batch_id, f.load_ts = SYSTIMESTAMP
       WHERE f.dpd <> s.dpd
          OR f.amount_paid_cum <> s.amount_paid
          OR f.customer_key <> s.customer_key
          OR f.source_status_code <> s.status_code
    WHEN NOT MATCHED THEN INSERT
         (loan_id, snapshot_date, snapshot_date_key, account_key, customer_key, branch_key, loan_date,
          loan_amount, duration_months, monthly_installment, installments_due, installments_paid,
          amount_due_cum, amount_paid_cum, overdue_amount, outstanding_amount, first_unpaid_due_date,
          dpd, dpd_bucket, sma_class, source_status_code, source_status, batch_id)
         VALUES
         (s.loan_id, s.snap, s.snap_key, s.account_key, s.customer_key, s.branch_key, s.loan_date,
          s.amount, s.duration_months, s.monthly_payment, s.installments_due, s.installments_paid,
          s.amount_due_cum, s.amount_paid, s.overdue_amount, s.outstanding_amount, s.first_unpaid_due_date,
          s.dpd, s.dpd_bucket, s.sma_class, s.status_code, s.loan_status, g_batch_id);
    v_loaded := SQL%ROWCOUNT;

    end_task(NULL, v_loaded, 'loan x month-end rows inserted or changed');
  END build_snapshots;

  -- ----------------------------------------------------------------------- run
  PROCEDURE run (p_batch_id IN NUMBER, p_parent_log_id IN NUMBER) IS
  BEGIN
    g_batch_id  := p_batch_id;
    g_parent_id := p_parent_log_id;
    g_as_of     := fd_ops.pkg_etl_ctl.batch_as_of(p_batch_id);
    g_wm_from   := fd_ops.pkg_etl_ctl.batch_wm_from(p_batch_id);

    build_schedule;
    build_snapshots;

    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      IF g_log_id IS NOT NULL THEN
        fd_ops.pkg_etl_log.log_step(g_log_id, 'FAILED', p_error_msg => SQLERRM,
                                    p_error_stack => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        g_log_id := NULL;
      END IF;
      RAISE;
  END run;

END pkg_risk;
/
SHOW ERRORS PACKAGE BODY fd_dwh.pkg_risk

-- Only the orchestrator may run this step.
GRANT EXECUTE ON fd_dwh.pkg_risk TO fd_ops;
