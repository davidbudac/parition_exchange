-- =====================================================================
-- report.sql - compare the latest completed DROP and EXCHANGE runs.
-- Ends with OVERALL: PASS or FAIL; on FAIL the script exits with an
-- error so run.sh (and CI) see a non-zero exit code.
-- Read-only: can be run as often as you like.
-- =====================================================================
set lines 200 serveroutput on size unlimited format wrapped verify off feedback off
set lines 160 pages 200 trimspool on tab off
whenever sqlerror exit failure rollback

set termout off
column run_drop new_value RUN_DROP noprint
column run_exch new_value RUN_EXCH noprint
select nvl(max(case kind when 'DROP'     then run_id end), -1) run_drop,
       nvl(max(case kind when 'EXCHANGE' then run_id end), -1) run_exch
from   pinx_run
where  status = 'DONE';
set termout on

prompt
prompt ==== Runs compared
column run_id     format 9999
column kind       format a8
column started    format a19
column window_s   format 999.9
column workload   format a34
column env        format a44
select run_id, kind, to_char(started_at, 'YYYY-MM-DD HH24:MI:SS') started,
       round(extract(minute from (window_end - window_start)) * 60
           + extract(second from (window_end - window_start)), 1) window_s,
       njobs||' jobs, '||npart||' parts, '||nddl||' DDLs' workload,
       db_version||' '||con_name||' cpu='||cpu_count||' ash='||ash_enabled env
from   pinx_run
where  run_id in (&RUN_DROP, &RUN_EXCH)
order  by run_id;

prompt
prompt ==== Metrics (window only: after warm-up, until the quiet tail ends)
column metric   format a48 heading 'Metric'
column drop_v   format a20 heading 'A: DROP' justify right
column exch_v   format a20 heading 'B: EXCHANGE' justify right
select metric,
       lpad(nvl(max(case run_id when &RUN_DROP then val end), '-'), 20) drop_v,
       lpad(nvl(max(case run_id when &RUN_EXCH then val end), '-'), 20) exch_v
from   pinx_v_metric
where  run_id in (&RUN_DROP, &RUN_EXCH)
group  by ord, metric
order  by ord, metric;

prompt
prompt ==== DDL statements (elapsed time, and what each one did to the hot cursor)
column kind      format a8
column seq       format 99
column elapsed   format 99990.9 heading 'ms'
column inval     format a11 heading 'Invalidated'
column ddl_text  format a90
select r.kind, d.seq, d.elapsed_ms elapsed, d.invalidated inval, d.ddl_text
from   pinx_v_ddl d join pinx_run r on r.run_id = d.run_id
where  d.run_id in (&RUN_DROP, &RUN_EXCH)
order  by d.run_id, d.seq;

prompt
prompt ==== Checks
column check_name format a36 heading 'Check'
column expected   format a10 heading 'Expected'
column actual     format a10 heading 'Actual'
column result     format a6  heading 'Result'
select kind, check_name, expected, actual, result
from   pinx_v_check
where  run_id in (&RUN_DROP, &RUN_EXCH)
order  by run_id, ord;

declare
  l_fail   number;
  l_total  number;
begin
  if &RUN_DROP = -1 or &RUN_EXCH = -1 then
    dbms_output.put_line(chr(10)||'OVERALL: FAIL - need one completed DROP and one completed EXCHANGE run '||
                         '(see pinx_run.status / error_text).');
    raise_application_error(-20100, 'report incomplete');
  end if;
  select count(*), count(case result when 'FAIL' then 1 end) into l_total, l_fail
  from   pinx_v_check where run_id in (&RUN_DROP, &RUN_EXCH);
  if l_fail = 0 then
    dbms_output.put_line(chr(10)||'OVERALL: PASS ('||l_total||' checks)');
  else
    dbms_output.put_line(chr(10)||'OVERALL: FAIL ('||l_fail||' of '||l_total||' checks failed)');
    raise_application_error(-20101, l_fail||' check(s) failed');
  end if;
end;
/
set feedback on
