#!/usr/bin/env bash
# ---------------------------------------------------------------------
# 1_build.sh - step 1 of 5: build the whole environment.
#
#   as a DBA:  create the test user PINX and its grants
#              (admin/create_user.sql)
#   as PINX:   check the environment, install the harness objects, and
#              build table T (NPART partitions, 1000 rows each) and T_X
#              (build.sql -> preflight.sql, setup.sql)
#
# Safe to run again: an existing user is kept (its password is set to
# the one you type), the objects are reinstalled and T is rebuilt.
# Running workers are stopped first.
# Settings: config.sql. Connections: connection.conf.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib/common.sh"

step "1/5  Build: user, objects, data"
need_pinx_password "Password for the test user $PINX_USER (new, or the existing one): "
dba_connect
pinx_connect

echo; echo "---- as DBA: user $PINX_USER and its grants"
run_sql dba 1_build_user "@admin/create_user.sql \"$PINX_PASSWORD\""

echo; echo "---- as $PINX_USER: objects and data"
run_sql pinx 1_build "@build.sql"

echo
echo "Step 1 done. Next: ./2_start_workers.sh"
