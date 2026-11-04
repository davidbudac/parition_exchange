-- =====================================================================
-- run_all.sql - the whole test case, start to finish.
--   preflight -> install -> Run A (DROP) -> Run B (EXCHANGE)
--   -> evidence (HTML charts + Oracle ASH/AWR reports in reports/)
--   -> report (text comparison and PASS/FAIL, last so it sets the exit code)
-- Takes about 2 x (WARMUP + SECS) + a minute or two for table builds,
-- AWR snapshots and reports.
-- =====================================================================
whenever sqlerror exit failure rollback
@@setup.sql
@@run_drop.sql
@@run_exchange.sql
@@evidence.sql
@@report.sql
