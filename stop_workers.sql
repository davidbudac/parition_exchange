-- =====================================================================
-- stop_workers.sql - stop the worker jobs, keep everything else.
-- Start them again with 2_start_workers.sh.
-- =====================================================================
set lines 200 serveroutput on size unlimited format wrapped verify off feedback off
whenever sqlerror exit failure rollback

prompt
prompt ==== Stopping the workers
exec pinx_lab.stop_workers(60)
@@status.sql
