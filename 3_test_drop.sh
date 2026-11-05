#!/usr/bin/env bash
# ---------------------------------------------------------------------
# 3_test_drop.sh - step 3 of 5: the DROP PARTITION test.
#
# Needs the workers from step 2. Takes an AWR snapshot, opens a
# measurement window, drops NDDL partitions (one every SECS/(NDDL+1) s),
# closes the window, takes another AWR snapshot. Then writes the Oracle
# ASH/AWR reports and the timeline to reports/ and prints the results
# with their checks. The workers keep running afterwards.
# Exit code 0 only if every check passed.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib/common.sh"

step "3/5  Test: DROP PARTITION under load"
pinx_connect
run_sql pinx 3_test_drop "@test_drop.sql"

echo
echo "Step 3 done. The workers keep running. Next: ./4_test_exchange.sh"
