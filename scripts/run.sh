#!/usr/bin/env bash
# One command, end to end:
#   1. download the dataset (skipped when already present)
#   2. start Oracle and wait until it is healthy
#   3. build every layer and load all batches   (scripts/run_all.sql)
#   4. run the test suite                        (sql/90_tests/run_tests.sql)
#   5. regenerate docs/performance.md and docs/run_results.md from this run
#
# Usage:  bash scripts/run.sh            full build + tests
#         bash scripts/run.sh --tests    tests only (warehouse already built)
set -euo pipefail
cd "$(dirname "$0")/.."

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
else
  DC=(docker-compose)          # Compose v1 fallback (older WSL installs)
fi

DATA_DIR="${FD_DATA_DIR:-../data/raw}"
if [ "$DATA_DIR" = "../data/raw" ] && [ ! -f data/raw/trans.asc ]; then
  python3 scripts/download_data.py
fi

"${DC[@]}" -p findata -f docker/docker-compose.yml up -d

echo "Waiting for Oracle to report healthy..."
status=starting
for _ in $(seq 1 120); do
  status=$(docker inspect -f '{{.State.Health.Status}}' findata-oracle 2>/dev/null || echo starting)
  [ "$status" = "healthy" ] && break
  sleep 5
done
if [ "$status" != "healthy" ]; then
  echo "Oracle did not become healthy (last status: $status)" >&2
  exit 1
fi

if [ "${1:-}" != "--tests" ]; then
  start=$(date +%s)
  bash scripts/sqlplus.sh scripts/run_all.sql
  echo "Build finished in $(( $(date +%s) - start ))s"
fi

bash scripts/sqlplus.sh sql/90_tests/run_tests.sql

# Regenerate the evidence files from the numbers of this run.
bash scripts/sqlplus.sh sql/80_perf/04_perf_report.sql   > docs/performance.md
bash scripts/sqlplus.sh sql/95_report/01_run_results.sql > docs/run_results.md
echo "docs/performance.md and docs/run_results.md refreshed"
