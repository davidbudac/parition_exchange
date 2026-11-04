-- =====================================================================
-- run_exchange.sql - Run B: ALTER TABLE ... EXCHANGE PARTITION under load.
-- Expected on 19c: the hot cursor does not read the exchanged partition,
-- so fine-grained invalidation leaves it valid - no reparse, no waits.
-- =====================================================================
@@config.sql
set lines 200 serveroutput on size unlimited format wrapped verify off feedback off
whenever sqlerror exit failure rollback

prompt
prompt ==== Run B: EXCHANGE PARTITION (about &WARMUP + &SECS s plus table build)
exec pinx_lab.run_case('EXCHANGE', &NJOBS, &NPART, &NDDL, &SECS, &WARMUP, &PARSE_MS, &THINK_MS, '&AWR')
set feedback on
