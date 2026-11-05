-- =====================================================================
-- evidence.sql - write the graphical evidence for the latest completed
-- DROP and EXCHANGE test runs into reports/ (called by test_drop.sql and
-- test_exchange.sql; with only one kind run so far, just that one):
--
--   pinx_timeline_r<A>_r<B>.html  ASH timeline of both runs, side by side,
--                                 with every DDL marked (open this first;
--                                 pinx_timeline_r<N>.html for a single run)
--   pinx_run<N>_<kind>_ash.html   Oracle ASH report for the run's window
--   pinx_run<N>_<kind>_awr.html   Oracle AWR report between the AWR
--                                 snapshots taken right before and after
--                                 the run's window
--
-- The timeline needs ASH and the Oracle reports need AWR snapshots, both
-- Diagnostics Pack features (see AWR in config.sql). Without the pack the
-- timeline page still shows the licence-free counters and the checks.
-- Read-only apart from the files it writes; run it as often as you like.
-- =====================================================================
set lines 200 verify off feedback off
whenever sqlerror exit failure rollback
host mkdir -p reports

set termout off
column run_drop new_value RUN_DROP
column run_exch new_value RUN_EXCH
-- TO_CHAR: numbers would come back space-padded and break the file names.
column tl_file  new_value TL_FILE
select to_char(nvl(max(case kind when 'DROP'     then run_id end), -1)) run_drop,
       to_char(nvl(max(case kind when 'EXCHANGE' then run_id end), -1)) run_exch,
       'pinx_timeline'||
         nvl2(max(case kind when 'DROP'     then run_id end), '_r'||max(case kind when 'DROP'     then run_id end), null)||
         nvl2(max(case kind when 'EXCHANGE' then run_id end), '_r'||max(case kind when 'EXCHANGE' then run_id end), null)||
         '.html' tl_file
from   pinx_run
where  status = 'DONE';

-- Oracle ASH/AWR reports only for runs that took AWR snapshots. The
-- helper is included conditionally because it calls
-- DBMS_WORKLOAD_REPOSITORY, which may not even be granted.
column d_script new_value D_SCRIPT
column x_script new_value X_SCRIPT
select nvl(max(case when kind = 'DROP' and awr_enabled = 'Y' and awr_snap_end is not null
                    then 'lib/oracle_reports.sql '||run_id end), 'lib/noop.sql') d_script,
       nvl(max(case when kind = 'EXCHANGE' and awr_enabled = 'Y' and awr_snap_end is not null
                    then 'lib/oracle_reports.sql '||run_id end), 'lib/noop.sql') x_script
from   pinx_run
where  run_id in (&RUN_DROP, &RUN_EXCH);
set termout on

prompt
prompt ==== Writing evidence to reports/
prompt   reports/&TL_FILE   (open this one)

set termout off pages 0 lines 32767 trimspool on heading off tab off
spool reports/&TL_FILE
select column_value from table(pinx_lab.timeline_html(&RUN_DROP, &RUN_EXCH));
spool off
set termout on

@@&D_SCRIPT
@@&X_SCRIPT

set termout on pages 100 lines 200 heading on feedback on
