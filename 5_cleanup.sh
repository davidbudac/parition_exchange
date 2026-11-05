#!/usr/bin/env bash
# ---------------------------------------------------------------------
# 5_cleanup.sh - step 5 of 5: clean up everything.
#
#   ./5_cleanup.sh              as a DBA: stop the workers and drop the
#                               user PINX with everything it owns
#                               (admin/drop_user.sql)
#   ./5_cleanup.sh --keep-user  as PINX: stop the workers and drop the
#                               harness objects, keep the user (cleanup.sql)
#
# reports/ and logs/ are kept. AWR snapshots age out with AWR retention.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib/common.sh"

case "${1:-}" in
  "")
    step "5/5  Clean up: workers, user $PINX_USER and everything it owns"
    dba_connect
    run_sql dba 5_cleanup "@admin/drop_user.sql"
    ;;
  --keep-user)
    step "5/5  Clean up: workers and harness objects (user $PINX_USER kept)"
    pinx_connect
    run_sql pinx 5_cleanup "@cleanup.sql"
    ;;
  *)
    echo "usage: $0 [--keep-user]" >&2; exit 2 ;;
esac

echo
echo "Step 5 done. Your reports are still in reports/."
