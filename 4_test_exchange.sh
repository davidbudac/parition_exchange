#!/usr/bin/env bash
# ---------------------------------------------------------------------
# 4_test_exchange.sh - step 4 of 5: the EXCHANGE PARTITION test.
#
# Same as step 3 with EXCHANGE instead of DROP: needs the workers from
# step 2, exchanges the highest partition with T_X NDDL times inside a
# measurement window, writes the reports to reports/ and prints the
# results, compared with the latest DROP test.
# Exit code 0 only if every check passed.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib/common.sh"

step "4/5  Test: EXCHANGE PARTITION under load"
pinx_connect
run_sql pinx 4_test_exchange "@test_exchange.sql"

echo
echo "Step 4 done. The workers keep running. Next: ./5_cleanup.sh"
