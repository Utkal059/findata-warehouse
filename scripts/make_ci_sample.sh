#!/usr/bin/env bash
# Builds a referentially consistent sample of the PKDD'99 files for CI:
# every Nth account (account_id % N == 0) with its dispositions, clients,
# cards, loans, orders and transactions; districts are kept in full.
# Usage: bash scripts/make_ci_sample.sh [SRC_DIR] [DST_DIR] [N]
set -euo pipefail
SRC="${1:-data/raw}"
DST="${2:-data/ci}"
N="${3:-10}"
mkdir -p "$DST"

# key lists written by one pass, read by the next
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT


cp "$SRC/district.asc" "$DST/district.asc"

awk -F';' -v n="$N" -v keys="$TMP/accounts" '
  NR == 1 { print; next }
  { id = $1; gsub(/"/, "", id); if (id % n == 0) { print; print id > keys } }
' "$SRC/account.asc" > "$DST/account.asc"

# disp: keep rows of kept accounts; remember their disp and client ids
awk -F';' -v dk="$TMP/disps" -v ck="$TMP/clients" '
  FNR == NR { keep[$1] = 1; next }
  FNR == 1 { print; next }
  { a = $3; gsub(/"/, "", a); if (a in keep) { print; d = $1; c = $2; gsub(/"/, "", d); gsub(/"/, "", c); print d > dk; print c > ck } }
' "$TMP/accounts" "$SRC/disp.asc" > "$DST/disp.asc"

# client: kept when one of its dispositions is kept
awk -F';' 'FNR == NR { keep[$1] = 1; next } FNR == 1 { print; next }
  { c = $1; gsub(/"/, "", c); if (c in keep) print }' "$TMP/clients" "$SRC/client.asc" > "$DST/client.asc"

# card: by disposition
awk -F';' 'FNR == NR { keep[$1] = 1; next } FNR == 1 { print; next }
  { d = $2; gsub(/"/, "", d); if (d in keep) print }' "$TMP/disps" "$SRC/card.asc" > "$DST/card.asc"

# loan, order, trans: by account (column 2)
for f in loan order trans; do
  awk -F';' 'FNR == NR { keep[$1] = 1; next } FNR == 1 { print; next }
    { a = $2; gsub(/"/, "", a); if (a in keep) print }' "$TMP/accounts" "$SRC/$f.asc" > "$DST/$f.asc"
done

for f in account card client disp district loan order trans; do
  printf '%-13s %8d data rows\n' "$f.asc" "$(( $(wc -l < "$DST/$f.asc") - 1 ))"
done
