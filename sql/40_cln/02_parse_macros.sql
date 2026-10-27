-- =============================================================================
-- 40_cln/02_parse_macros.sql
-- Scalar SQL macros: expanded into the calling SQL at parse time, so the
-- validation views stay readable with no PL/SQL context switch per row.
-- =============================================================================

-- Text -> NUMBER with a fixed '.' decimal separator (independent of the
-- session's NLS settings). Blank and the '?' placeholder become NULL.
CREATE OR REPLACE FUNCTION fd_cln.to_num (p_text VARCHAR2)
  RETURN VARCHAR2 SQL_MACRO(SCALAR)
IS
BEGIN
  RETURN q'[TO_NUMBER(NULLIF(TRIM(p_text), '?') DEFAULT NULL ON CONVERSION ERROR,
                      '999999999990D9999', 'NLS_NUMERIC_CHARACTERS=''.,''')]';
END;
/

-- 1 when a non-blank, non-placeholder value is not a valid number (rule R007).
CREATE OR REPLACE FUNCTION fd_cln.bad_num (p_text VARCHAR2)
  RETURN VARCHAR2 SQL_MACRO(SCALAR)
IS
BEGIN
  RETURN q'[CASE WHEN NULLIF(TRIM(p_text), '?') IS NOT NULL
                  AND VALIDATE_CONVERSION(NULLIF(TRIM(p_text), '?') AS NUMBER,
                        '999999999990D9999', 'NLS_NUMERIC_CHARACTERS=''.,''') = 0
                 THEN 1 ELSE 0 END]';
END;
/

-- YYMMDD (optionally followed by a time, as in card.issued) -> DATE.
-- Every date in this dataset is in the 1900s, so the century is fixed to 19
-- (an RR/YY mask would turn 1911 birth dates into 2011).
CREATE OR REPLACE FUNCTION fd_cln.to_yymmdd (p_text VARCHAR2)
  RETURN VARCHAR2 SQL_MACRO(SCALAR)
IS
BEGIN
  RETURN q'[CASE WHEN REGEXP_LIKE(TRIM(p_text), '^[0-9]{6}( |$)')
                 THEN TO_DATE('19' || SUBSTR(TRIM(p_text), 1, 6) DEFAULT NULL ON CONVERSION ERROR,
                              'YYYYMMDD')
            END]';
END;
/
