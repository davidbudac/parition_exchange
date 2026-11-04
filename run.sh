#!/usr/bin/env bash
# ---------------------------------------------------------------------
# run.sh - run one of the harness scripts with SQLcl or SQL*Plus and
# keep a timestamped log in logs/.
#
#   ./run.sh <connect> [script]
#
#   <connect>  e.g. pinx@//dbhost:1521/pdb1   (you are prompted for the
#              password), or pinx/secret@//dbhost:1521/pdb1, or
#              /@wallet_alias. Can also come from $PINX_CONNECT.
#   [script]   run_all (default), setup, run_drop, run_exchange, evidence,
#              report, preflight, cleanup
#
# Uses SQLcl (`sql`) if it is on PATH, otherwise `sqlplus`; force one
# with PINX_CLIENT=sqlplus or PINX_CLIENT=sql.
# Exit code is 0 only if the script finished and (for run_all/report)
# every check passed.
# ---------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")"

connect="${1:-${PINX_CONNECT:-}}"
script="${2:-run_all}"
script="${script%.sql}"

if [[ -z "$connect" ]]; then
  sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi
if [[ ! -f "$script.sql" ]]; then
  echo "No such script: $script.sql" >&2
  exit 2
fi

# user@service without a password: ask for it here, because the SQL is
# fed to the client on stdin and it could not prompt itself.
if [[ "$connect" =~ ^([^/@]+)@(.+)$ ]]; then
  read -rsp "Password for ${BASH_REMATCH[1]}: " pw; echo
  connect="${BASH_REMATCH[1]}/\"${pw}\"@${BASH_REMATCH[2]}"
fi

client="${PINX_CLIENT:-}"
if [[ -z "$client" ]]; then
  if command -v sql >/dev/null 2>&1; then client=sql
  elif command -v sqlplus >/dev/null 2>&1; then client=sqlplus
  else echo "Neither SQLcl (sql) nor SQL*Plus (sqlplus) is on PATH." >&2; exit 2
  fi
fi

mkdir -p logs reports
log="logs/$(date +%Y%m%d_%H%M%S)_${script}.log"
echo "Running $script.sql with $client; log: $log"

# Connect inside the session (/nolog + CONNECT) so the password never
# appears on the process list. The trailing EXIT makes the client leave
# even if a script forgets to.
set +e
"$client" -S /nolog <<SQL 2>&1 | tee "$log"
whenever sqlerror exit failure rollback
whenever oserror exit failure rollback
connect $connect
$( [[ "$client" == sql ]] && echo "set sqlformat default" )
@$script.sql
exit success
SQL
rc=${PIPESTATUS[0]}
set -e

if [[ $rc -eq 0 ]]; then
  echo "OK ($script)"
else
  echo "FAILED ($script), exit code $rc - see $log" >&2
fi
exit "$rc"
