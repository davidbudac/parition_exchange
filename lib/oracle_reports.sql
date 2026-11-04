-- =====================================================================
-- lib/oracle_reports.sql <run_id> - called by evidence.sql.
-- Spools Oracle's own ASH report (the run's measurement window) and AWR
-- report (the snapshots taken right before / after that window) for one
-- run. Needs the Diagnostics Pack and EXECUTE on DBMS_WORKLOAD_REPOSITORY.
-- =====================================================================
set termout off
column o_dbid new_value O_DBID
column o_inst new_value O_INST
column o_sb   new_value O_SB
column o_se   new_value O_SE
column o_ws   new_value O_WS
column o_we   new_value O_WE
column o_ashf new_value O_ASHF
column o_awrf new_value O_AWRF
select to_char(awr_dbid) o_dbid, to_char(inst_num) o_inst,
       to_char(awr_snap_begin) o_sb, to_char(awr_snap_end) o_se,
       to_char(window_start, 'YYYY-MM-DD HH24:MI:SS') o_ws,
       to_char(window_end + interval '1' second, 'YYYY-MM-DD HH24:MI:SS') o_we,
       'pinx_run'||run_id||'_'||lower(kind)||'_ash.html' o_ashf,
       'pinx_run'||run_id||'_'||lower(kind)||'_awr.html' o_awrf
from   pinx_run
where  run_id = &1;
set termout on
prompt   reports/&O_ASHF   (Oracle ASH report, &O_WS to &O_WE)
prompt   reports/&O_AWRF   (Oracle AWR report, snapshots &O_SB to &O_SE)
set termout off

spool reports/&O_ASHF
select output from table(dbms_workload_repository.ash_report_html(
         l_dbid     => &O_DBID,
         l_inst_num => &O_INST,
         l_btime    => to_date('&O_WS', 'YYYY-MM-DD HH24:MI:SS'),
         l_etime    => to_date('&O_WE', 'YYYY-MM-DD HH24:MI:SS')));
spool off

spool reports/&O_AWRF
select output from table(dbms_workload_repository.awr_report_html(&O_DBID, &O_INST, &O_SB, &O_SE));
spool off
set termout on
