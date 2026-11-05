# shellcheck shell=bash
# ---------------------------------------------------------------------
# lib/common.sh - shared by 1_build.sh ... 5_cleanup.sh and run.sh.
# Not meant to be run on its own.
# ---------------------------------------------------------------------
set -euo pipefail

PINX_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PINX_HOME"
# shellcheck source=/dev/null
source ./connection.conf

PINX_USER=PINX                       # fixed: admin/create_user.sql creates PINX
mkdir -p logs reports

if [[ -z "$PINX_CLIENT" ]]; then
  if   command -v sql     >/dev/null 2>&1; then PINX_CLIENT=sql
  elif command -v sqlplus >/dev/null 2>&1; then PINX_CLIENT=sqlplus
  else echo "Neither SQLcl (sql) nor SQL*Plus (sqlplus) is on PATH." >&2; exit 2
  fi
fi

# step "<n>/5  <title>"  - print a header for the step
step() {
  echo
  echo "======================================================================"
  echo "  $1    $(date '+%Y-%m-%d %H:%M:%S')"
  echo "======================================================================"
}

# need_pinx_password [prompt] - make sure PINX_PASSWORD is set (asks for it).
need_pinx_password() {
  if [[ -z "${PINX_PASSWORD:-}" ]]; then
    read -rsp "${1:-Password for $PINX_USER: }" PINX_PASSWORD; echo
    [[ -n "$PINX_PASSWORD" ]] || { echo "No password given." >&2; exit 2; }
  fi
}

# pinx_connect - sets PINX_CONN, the CONNECT argument for the test user.
pinx_connect() {
  if [[ -n "$PINX_CONNECT" ]]; then
    PINX_CONN="$PINX_CONNECT"
  else
    need_pinx_password
    PINX_CONN="$PINX_USER/\"$PINX_PASSWORD\"@$PINX_SERVICE"
  fi
}

# dba_connect - sets DBA_CONN; asks for the password when DBA_CONNECT is
# user@service (with or without 'as sysdba').
dba_connect() {
  if [[ "$DBA_CONNECT" =~ ^([^/@[:space:]]+)@([^[:space:]]+)(.*)$ ]]; then
    if [[ -z "${DBA_PASSWORD:-}" ]]; then
      read -rsp "Password for DBA ${BASH_REMATCH[1]}: " DBA_PASSWORD; echo
    fi
    DBA_CONN="${BASH_REMATCH[1]}/\"$DBA_PASSWORD\"@${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
  else
    DBA_CONN="$DBA_CONNECT"
  fi
}

# run_sql dba|pinx <log name> <SQL*Plus command> - connect and run one
# command (usually @script). The SQL goes in on stdin, so passwords never
# show up in the process list. Output is shown and kept in logs/.
# Exits the calling script on failure.
run_sql() {
  local who=$1 name=$2 cmd=$3 conn container="" rc
  if [[ $who == dba ]]; then
    conn=$DBA_CONN
    [[ -n "$DBA_CONTAINER" ]] && container="set feedback off
alter session set container = $DBA_CONTAINER;
set feedback on"
  else
    conn=$PINX_CONN
  fi
  local log
  log="logs/$(date +%Y%m%d_%H%M%S)_${name}.log"
  set +e
  "$PINX_CLIENT" -S /nolog <<SQL 2>&1 | tee "$log"
whenever sqlerror exit failure rollback
whenever oserror exit failure rollback
connect $conn
$container
$( [[ "$PINX_CLIENT" == sql ]] && echo "@lib/sqlcl.sql" )
$cmd
exit success
SQL
  rc=${PIPESTATUS[0]}
  set -e
  if [[ $rc -ne 0 ]]; then
    echo >&2
    echo "FAILED ($name), exit code $rc. Full output: $log" >&2
    exit "$rc"
  fi
}
