-- =====================================================================
-- status.sql - what the workers are doing right now. Read-only; run it
-- any time:  ./run.sh status
-- Every worker is a scheduler job (PINX_W001 ...) whose session has
-- MODULE = PINX_WORKER, so they also show up under that name in
-- V$SESSION, ASH and Enterprise Manager.
-- =====================================================================
set lines 200 pages 100 tab off verify off feedback off serveroutput on size unlimited format wrapped

prompt
prompt ==== Workers
column worker   format 999        heading 'W'
column job      format a10        heading 'JOB'
column state    format a8         heading 'STATE'
column sid      format 99999      heading 'SID'
column doing    format a34        heading 'DOING NOW'
column beat     format a10        heading 'HEARTBEAT'
column execs    format 999999990  heading 'EXECUTIONS'
select p.worker,
       'PINX_W'||lpad(p.worker, 3, '0') job,
       case when j.job_name is not null then 'running'
            when p.ended_at is not null then 'stopped'
            else 'missing' end state,
       p.sid,
       case when j.job_name is null or s.sid is null then null
            when s.state = 'WAITING' and s.event = 'PL/SQL lock timer' then 'think time (PL/SQL lock timer)'
            when s.state = 'WAITING' then s.event
            else 'ON CPU' end doing,
       case when p.last_beat is not null and j.job_name is not null
            then round((cast(systimestamp as date) - cast(p.last_beat as date)) * 86400)||' s ago' end beat,
       p.execs
from   pinx_pool p
       left join user_scheduler_running_jobs j on j.job_name = 'PINX_W'||lpad(p.worker, 3, '0')
       left join v$session s on s.sid = p.sid and s.module = 'PINX_WORKER'
order  by p.worker;

declare
  l_phase    varchar2(10);
  l_run      number;
  l_njobs    number;
  l_think    number;
  l_deadline timestamp;
  l_running  number;
  l_e1       number;
  l_e2       number;
  l_sql_id   varchar2(13);
  l_kids     number;
  l_loads    number;
  l_inval    number;
  l_inserts  number;
  l_i1       number;
  l_i2       number;
  procedure p(m varchar2) is begin dbms_output.put_line(m); end;
begin
  select phase, run_id, njobs, think_ms, inserts, deadline
  into   l_phase, l_run, l_njobs, l_think, l_inserts, l_deadline
  from   pinx_ctl where id = 1;
  select count(*) into l_running from user_scheduler_running_jobs
  where  job_name like 'PINX\_W%' escape '\';

  p('');
  if l_running = 0 then
    p('No workers running. Start them with ./2_start_workers.sh.');
    return;
  end if;
  p(l_running||' of '||l_njobs||' workers running. Each one, in a loop: the hot query on P1'||
    case when nvl(l_inserts, 0) > 0 then ', insert '||l_inserts||' row(s) into PCUR, commit' end||
    ', '||l_think||' ms think time.');
  p(case l_phase
      when 'MEASURE' then 'A test is measuring right now (run '||l_run||').'
      when 'STOP'    then 'They have been told to stop.'
      else 'No test is running: no DDL, the workers just run their loop.' end);
  p('They stop by themselves at '||to_char(l_deadline, 'YYYY-MM-DD HH24:MI:SS')||'.');

  -- Executions of the hot query over 5 seconds, from V$SQL.
  select nvl(sum(executions), 0) into l_e1 from v$sql
  where  parsing_schema_name = user and upper(sql_text) like 'SELECT /*+ QB_NAME(PINX) */%';
  select nvl(sum(executions), 0) into l_i1 from v$sql
  where  parsing_schema_name = user and upper(sql_text) like 'INSERT /*+ QB_NAME(PINX\_INS) */%' escape '\';
  dbms_session.sleep(5);
  select nvl(sum(executions), 0) into l_i2 from v$sql
  where  parsing_schema_name = user and upper(sql_text) like 'INSERT /*+ QB_NAME(PINX\_INS) */%' escape '\';
  select nvl(sum(executions), 0), max(sql_id), count(*), nvl(sum(loads), 0), nvl(sum(invalidations), 0)
  into   l_e2, l_sql_id, l_kids, l_loads, l_inval
  from   v$sql
  where  parsing_schema_name = user and upper(sql_text) like 'SELECT /*+ QB_NAME(PINX) */%';
  p('Hot query (sql_id '||l_sql_id||'): about '||round(greatest(l_e2 - l_e1, 0) / 5)||
    ' executions per second, all workers together (measured over 5 s).');
  p('Its cursor in V$SQL: '||l_kids||' child cursor(s), '||l_loads||' loads, '||l_inval||' invalidations so far.');
  if nvl(l_inserts, 0) > 0 then
    p('Inserts into PCUR: about '||round(greatest(l_i2 - l_i1, 0) / 5)||' rows per second, all workers together.');
  end if;
end;
/
set feedback on
