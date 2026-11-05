#!/usr/bin/env bash
# ---------------------------------------------------------------------
# 2_start_workers.sh - step 2 of 5: start the workers.
#
# Starts NJOBS scheduler jobs (PINX_W001 ...) that run the hot query
# over and over, then shows what they are doing. Nothing else happens:
# no DDL, no measurement. The workers keep running after this script
# ends, until 5_cleanup.sh stops them (or WORKER_MINUTES pass).
# Running it again restarts them.
#
# Watch them any time with:   ./run.sh status
# Stop them (keep the rest):  ./run.sh stop_workers
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib/common.sh"

step "2/5  Start the workers"
pinx_connect
run_sql pinx 2_start_workers "@start_workers.sql"

echo
echo "Step 2 done. The workers keep running. Next: ./3_test_drop.sh"
