-- =============================================================================
-- 60_risk/01_loan_risk_tables.sql
-- Loan early-warning tables.
--
-- The RBI SMA / NPA buckets are applied here as a classification FRAMEWORK on
-- the Czech PKDD'99 data. This is not Indian or AU Small Finance Bank data.
--
-- DERIVED: the source has no repayment schedule. loan_schedule is generated
-- from loan.date, loan.duration and loan.payments (installment k is due on
-- ADD_MONTHS(loan_date, k) for k = 1..duration). Actual repayments are the
-- LOAN_PAYMENT (k_symbol UVER) debits on the loan's account.
-- =============================================================================

CREATE TABLE fd_dwh.loan_schedule (
  loan_id          NUMBER(10)    NOT NULL,
  installment_no   NUMBER(3)     NOT NULL,
  due_date         DATE          NOT NULL,
  amount_due       NUMBER(12,2)  NOT NULL,
  batch_id         NUMBER        NOT NULL,
  CONSTRAINT loan_schedule_pk PRIMARY KEY (loan_id, installment_no)
);
COMMENT ON TABLE fd_dwh.loan_schedule IS
  'DERIVED expected repayment schedule: installment k due ADD_MONTHS(loan_date, k), amount = loan.payments';

-- Grain: one loan x one month-end.
CREATE TABLE fd_dwh.fact_loan_snapshot (
  snapshot_key           NUMBER GENERATED ALWAYS AS IDENTITY,
  loan_id                NUMBER(10)    NOT NULL,
  snapshot_date          DATE          NOT NULL,   -- month-end
  snapshot_date_key      NUMBER(8)     NOT NULL,
  account_key            NUMBER        NOT NULL,
  customer_key           NUMBER        NOT NULL,
  branch_key             NUMBER        NOT NULL,
  loan_date              DATE          NOT NULL,
  loan_amount            NUMBER(12,2)  NOT NULL,
  duration_months        NUMBER(3)     NOT NULL,
  monthly_installment    NUMBER(12,2)  NOT NULL,
  installments_due       NUMBER(3)     NOT NULL,   -- DERIVED: due on or before snapshot_date
  installments_paid      NUMBER(3)     NOT NULL,   -- DERIVED: whole installments covered by payments
  amount_due_cum         NUMBER(14,2)  NOT NULL,
  amount_paid_cum        NUMBER(14,2)  NOT NULL,
  overdue_amount         NUMBER(14,2)  NOT NULL,
  outstanding_amount     NUMBER(14,2)  NOT NULL,   -- loan_amount - amount_paid_cum (no interest split in source)
  first_unpaid_due_date  DATE,
  dpd                    NUMBER(5)     NOT NULL,   -- days past due of the oldest unpaid installment
  dpd_bucket             VARCHAR2(6)   NOT NULL,   -- 0 / 1-30 / 31-60 / 61-90 / 91+
  sma_class              VARCHAR2(8)   NOT NULL,   -- STANDARD / SMA-0 / SMA-1 / SMA-2 / NPA
  source_status_code     CHAR(1)       NOT NULL,   -- loan.status as delivered (A/B/C/D)
  source_status          VARCHAR2(20)  NOT NULL,
  batch_id               NUMBER        NOT NULL,
  load_ts                TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT fact_loan_snapshot_pk PRIMARY KEY (snapshot_key),
  CONSTRAINT fact_loan_snapshot_nk UNIQUE (loan_id, snapshot_date),
  CONSTRAINT fls_sma_ck CHECK (sma_class IN ('STANDARD', 'SMA-0', 'SMA-1', 'SMA-2', 'NPA')),
  CONSTRAINT fls_date_fk     FOREIGN KEY (snapshot_date_key) REFERENCES fd_dwh.dim_date (date_key),
  CONSTRAINT fls_account_fk  FOREIGN KEY (account_key)       REFERENCES fd_dwh.dim_account (account_key),
  CONSTRAINT fls_customer_fk FOREIGN KEY (customer_key)      REFERENCES fd_dwh.dim_customer (customer_key),
  CONSTRAINT fls_branch_fk   FOREIGN KEY (branch_key)        REFERENCES fd_dwh.dim_branch (branch_key)
);
COMMENT ON TABLE fd_dwh.fact_loan_snapshot IS
  'Month-end loan risk snapshot. RBI SMA/NPA buckets used as a framework on Czech PKDD''99 data; schedule fields are DERIVED.';
