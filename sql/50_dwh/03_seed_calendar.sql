-- =============================================================================
-- 50_dwh/03_seed_calendar.sql
-- dim_date covers the full span of the source data (1993-01-01 .. 1998-12-31)
-- plus one spare year for month-end loan snapshots and test fixtures.
-- =============================================================================
BEGIN
  fd_dwh.pkg_load_dwh.build_dim_date(DATE '1993-01-01', DATE '1999-12-31');
END;
/
