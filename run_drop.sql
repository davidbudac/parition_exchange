-- =====================================================================
-- run_drop.sql - Run A: ALTER TABLE ... DROP PARTITION under load.
-- Expected on 19c: the hot cursor is invalidated by every drop, the
-- workers pile up on "cursor: pin S wait on X" while one of them
-- hard-parses it again.
-- =====================================================================
@@config.sql
set lines 200 serveroutput on size unlimited format wrapped verify off feedback off
whenever sqlerror exit failure rollback

prompt
prompt ==== Run A: DROP PARTITION (about &WARMUP + &SECS s plus table build)
exec pinx_lab.run_case('DROP', &NJOBS, &NPART, &NDDL, &SECS, &WARMUP, &PARSE_MS, &THINK_MS, '&AWR')
set feedback on
