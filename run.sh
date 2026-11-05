#!/usr/bin/env bash
# ---------------------------------------------------------------------
# run.sh - run one SQL script as the test user, outside the five steps.
#
#   ./run.sh status         what the workers are doing right now
#   ./run.sh stop_workers   stop the workers, keep everything else
#   ./run.sh report         print the latest results and checks again
#   ./run.sh evidence       write the reports/ files again
#   ./run.sh preflight      check the environment only
#
# Connections come from connection.conf, settings from config.sql.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib/common.sh"

script="${1:-}"
script="${script%.sql}"
if [[ -z "$script" ]]; then
  sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi
if [[ ! -f "$script.sql" ]]; then
  echo "No such script: $script.sql" >&2
  exit 2
fi

pinx_connect
run_sql pinx "$script" "@$script.sql"
