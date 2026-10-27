#!/usr/bin/env bash
# Run a SQL*Plus script inside the Oracle container as SYSTEM.
# The password never leaves the container: it is read from the container's
# own ORACLE_PASSWORD environment variable and fed to SQL*Plus on stdin.
# It is also exposed to scripts as &fd_app_password (used for the FD_ETL and
# FD_REPORT logins created by sql/00_setup/01_create_schemas.sql).
#
# Usage (from the repo root):
#   bash scripts/sqlplus.sh scripts/run_all.sql
#   bash scripts/sqlplus.sh sql/90_tests/run_tests.sql
set -euo pipefail

CONTAINER="${FD_CONTAINER:-findata-oracle}"
SCRIPT="${1:?usage: scripts/sqlplus.sh <script.sql> [args...]}"
shift

docker exec -i -w /workspace "$CONTAINER" bash -c '
  script="$1"; shift
  {
    echo "whenever sqlerror exit failure"
    printf "connect system/\"%s\"@//localhost/FREEPDB1\n" "$ORACLE_PASSWORD"
    echo "set verify off"
    printf "define fd_app_password = \"%s\"\n" "$ORACLE_PASSWORD"
    printf "@%s %s\n" "$script" "$*"
    echo "exit"
  } | sqlplus -L -S /nolog
' _ "$SCRIPT" "$@"
