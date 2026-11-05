-- =====================================================================
-- build.sql - step 1 (called by 1_build.sh), as the test user:
--   preflight checks -> install the harness objects -> build table T
--   (NPART partitions of 1000 rows) and T_X, the empty exchange table.
-- Safe to run again; running workers are stopped before T is replaced.
-- =====================================================================
whenever sqlerror exit failure rollback
@@setup.sql
@@config.sql
set lines 200 serveroutput on size unlimited format wrapped verify off feedback off

prompt
prompt ==== Building the data
exec pinx_lab.build_table(&NPART)

prompt
prompt ==== Where you are: workers, data, tests so far
@@state.sql
set feedback on
