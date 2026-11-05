-- =====================================================================
-- start_workers.sql - step 2 (called by 2_start_workers.sh):
-- start NJOBS scheduler jobs that run the hot query over and over and
-- after each execution insert INSERTS rows into PCUR and commit, then
-- show what they are doing. They keep running after this script ends:
-- until 5_cleanup.sh (or stop_workers.sql) stops them, or for at most
-- WORKER_MINUTES. Starting them again restarts them.
-- =====================================================================
@@config.sql
set lines 200 serveroutput on size unlimited format wrapped verify off feedback off
whenever sqlerror exit failure rollback

prompt
prompt ==== Starting the workers
exec pinx_lab.start_workers(&NJOBS, &THINK_MS, &PARSE_MS, &WORKER_MINUTES, &INSERTS)
@@status.sql
