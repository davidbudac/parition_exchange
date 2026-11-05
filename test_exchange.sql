-- =====================================================================
-- test_exchange.sql - step 4 (called by 4_test_exchange.sh): the
-- EXCHANGE PARTITION test, against the workers started in step 2.
-- Expected on 19c: the hot cursor does not read the exchanged
-- partition, so fine-grained invalidation leaves it valid: no reparse,
-- no waits.
-- Afterwards: Oracle ASH/AWR reports and the timeline in reports/, and
-- the comparison with the latest DROP test, if there is one.
-- =====================================================================
@@config.sql
set lines 200 serveroutput on size unlimited format wrapped verify off feedback off
whenever sqlerror exit failure rollback

prompt
prompt ==== EXCHANGE PARTITION test (about &WARMUP + &SECS s)
exec pinx_lab.run_case('EXCHANGE', &NDDL, &SECS, &WARMUP, &PARSE_MS, '&AWR')
@@evidence.sql
@@report.sql
