-- =====================================================================
-- test_drop.sql - step 3 (called by 3_test_drop.sh): the DROP PARTITION
-- test, against the workers started in step 2.
-- Expected on 19c: every drop invalidates the hot cursor, and the
-- workers pile up on "cursor: pin S wait on X" while one of them
-- hard-parses it again.
-- Prints the workers, the row counts in T and T_X and the tests so far
-- before and after the DDL, and after each DDL what it changed.
-- Afterwards: Oracle ASH/AWR reports and the timeline in reports/, and
-- the comparison with the latest EXCHANGE test, if there is one.
-- =====================================================================
@@config.sql
set lines 200 serveroutput on size unlimited format wrapped verify off feedback off
whenever sqlerror exit failure rollback

prompt
prompt ==== Before the DROP test: workers, data, tests so far
@@state.sql

prompt
prompt ==== DROP PARTITION test (about &WARMUP + &SECS s)
exec pinx_lab.run_case('DROP', &NDDL, &SECS, &WARMUP, &PARSE_MS, '&AWR')

prompt
prompt ==== After the DROP test: workers, data, tests so far
@@state.sql
@@evidence.sql
@@report.sql
