-- =====================================================================
-- state.sql - where you are: the workers, the rows in T and T_X, and
-- the tests run so far. Read-only. The tests print it before and after
-- the DDL, step 1 after the build; run it any time with:
--   ./run.sh state
--
-- Rows are counted now with COUNT(*), not taken from the optimizer
-- statistics. Lists PCUR (the current partition, which the workers
-- insert into), the NDDL highest partitions below it (the ones the
-- tests use), P1 (the one the hot query reads), one line for the
-- partitions in between, and T_X.
-- =====================================================================
@@config.sql
set lines 200 pages 100 tab off verify off feedback off serveroutput on size unlimited format wrapped

prompt
prompt Workers
declare
  l_phase    varchar2(10);
  l_run      number;
  l_njobs    number;
  l_think    number;
  l_inserts  number;
  l_deadline timestamp;
  l_running  number;
  l_alive    number;
  l_doing    varchar2(4000);
  l_e1       number;
  l_e2       number;
  l_sql_id   varchar2(13);
  l_kids     number;
  l_loads    number;
  l_inval    number;
  l_i1       number;
  l_i2       number;
  l_ins_id   varchar2(13);
  procedure p(m varchar2) is begin dbms_output.put_line('  '||m); end;
begin
  select phase, run_id, njobs, think_ms, inserts, deadline
  into   l_phase, l_run, l_njobs, l_think, l_inserts, l_deadline
  from   pinx_ctl where id = 1;
  select count(*) into l_running from user_scheduler_running_jobs
  where  job_name like 'PINX\_W%' escape '\';
  select count(*) into l_alive from pinx_pool
  where  ended_at is null and last_beat > systimestamp - interval '15' second;

  if l_running = 0 then
    p('none running (start them with ./2_start_workers.sh)');
  else
    p(l_running||' of '||l_njobs||' worker jobs running, '||l_alive||' with a heartbeat in the last 15 s');
    p('each one, in a loop: the hot query on P1'||
      case when nvl(l_inserts, 0) > 0 then ', insert '||l_inserts||' row(s) into PCUR, commit' end||
      ', '||l_think||' ms think time');
    p(case l_phase
        when 'MEASURE' then 'a test is measuring right now (run '||l_run||')'
        when 'STOP'    then 'told to stop'
        else 'no test running: no DDL, they just run their loop' end);
    p('they stop by themselves at '||to_char(l_deadline, 'YYYY-MM-DD HH24:MI:SS'));
    select listagg(cnt||' '||doing, ', ') within group (order by cnt desc, doing)
    into   l_doing
    from  (select doing, count(*) cnt
           from  (select case when state = 'WAITING' and event = 'PL/SQL lock timer' then 'think time'
                              when state = 'WAITING' then event
                              else 'on CPU' end doing
                  from   v$session where module = 'PINX_WORKER')
           group  by doing);
    p('doing right now: '||nvl(l_doing, 'no worker sessions'));
  end if;

  -- The hot query and the insert in V$SQL; executions over 5 s when the
  -- workers run.
  select nvl(sum(executions), 0) into l_e1 from v$sql
  where  parsing_schema_name = user and upper(sql_text) like 'SELECT /*+ QB_NAME(PINX) */%';
  select nvl(sum(executions), 0) into l_i1 from v$sql
  where  parsing_schema_name = user and upper(sql_text) like 'INSERT /*+ QB_NAME(PINX\_INS) */%' escape '\';
  if l_running > 0 then
    dbms_session.sleep(5);
  end if;
  select nvl(sum(executions), 0), max(sql_id), count(*), nvl(sum(loads), 0), nvl(sum(invalidations), 0)
  into   l_e2, l_sql_id, l_kids, l_loads, l_inval
  from   v$sql
  where  parsing_schema_name = user and upper(sql_text) like 'SELECT /*+ QB_NAME(PINX) */%';
  if l_kids = 0 then
    p('hot query: not in the shared pool');
  else
    p('hot query (sql_id '||l_sql_id||'): '||l_kids||' child cursor(s), '||l_loads||' loads, '||
      l_inval||' invalidations, '||l_e2||' executions in total');
    if l_running > 0 then
      p('  about '||round(greatest(l_e2 - l_e1, 0) / 5)||' executions per second (measured over 5 s)');
    end if;
  end if;
  select nvl(sum(executions), 0), max(sql_id), count(*), nvl(sum(loads), 0), nvl(sum(invalidations), 0)
  into   l_i2, l_ins_id, l_kids, l_loads, l_inval
  from   v$sql
  where  parsing_schema_name = user and upper(sql_text) like 'INSERT /*+ QB_NAME(PINX\_INS) */%' escape '\';
  if l_kids = 0 then
    p('insert: not in the shared pool');
  else
    p('insert    (sql_id '||l_ins_id||'): '||l_kids||' child cursor(s), '||l_loads||' loads, '||
      l_inval||' invalidations, '||l_i2||' executions in total');
    if l_running > 0 then
      p('  about '||round(greatest(l_i2 - l_i1, 0) / 5)||' rows inserted per second (measured over 5 s)');
    end if;
  end if;
end;
/

prompt
prompt Tables T and T_X
column st_obj   format a22          heading 'TABLE / PARTITION'
column st_rows  format 999,999,990  heading 'ROWS'
column st_note  format a90          heading 'NOTE'
with seg as (
  -- rows per segment; a partition's segment is its data_object_id
  select data_obj, count(*) cnt
  from  (select dbms_rowid.rowid_object(rowid) data_obj from t)
  group  by data_obj
), parts as (
  select p.partition_position pos, p.partition_name pname, nvl(s.cnt, 0) cnt,
         row_number() over (order by p.partition_position desc) rn
  from   user_tab_partitions p
         join user_objects o on  o.object_name    = p.table_name
                             and o.subobject_name = p.partition_name
                             and o.object_type    = 'TABLE PARTITION'
         left join seg s on s.data_obj = o.data_object_id
  where  p.table_name = 'T' and p.partition_name <> 'PCUR'
), cur as (
  select count(*) cur_cnt from t partition (pcur)
)
select st_obj, st_rows, st_note
from (
  select 1 k, 0 pos, 'T' st_obj, sum(cnt) + max(cur_cnt) st_rows,
         count(*)||' partitions plus PCUR, '||count(case when cnt = 0 then 1 end)||' of them empty' st_note
  from   parts cross join cur
  union all
  select 1.5, 0, '  PCUR', cur_cnt, 'current partition: the workers insert into it; no test changes it'
  from   cur
  union all
  select case when pos = 1 and rn > &NDDL then 4 else 2 end, pos, '  '||pname, cnt,
         case when rn = 1     then 'highest below PCUR: the DROP test drops it, the EXCHANGE test exchanges it with T_X'
              when rn <= &NDDL then 'the DROP test drops it'
              else 'read by the hot query; no test changes it' end
  from   parts
  where  rn <= &NDDL or pos = 1
  union all
  select 3, max(pos),
         '  '||min(pname) keep (dense_rank first order by pos)||' ... '||
               max(pname) keep (dense_rank last order by pos),
         sum(cnt), count(*)||' partitions, '||count(case when cnt = 0 then 1 end)||' of them empty'
  from   parts
  where  rn > &NDDL and pos > 1
  having count(*) > 0
  union all
  select 5, 0, 'T_X', (select count(*) from t_x), 'exchange table, not partitioned' from dual
)
order by k, pos desc;
column st_obj  clear
column st_rows clear
column st_note clear

prompt
prompt Tests run so far
declare
  l_n number := 0;
begin
  for r in (select run_id, kind, status, started_at, npart, nddl,
                   (select count(*) from pinx_ddl d where d.run_id = r.run_id and d.seq > 0) ddls
            from   pinx_run r order by run_id) loop
    l_n := l_n + 1;
    dbms_output.put_line('  run '||r.run_id||'  '||rpad(r.kind, 8)||' '||rpad(r.status, 7)||' '||
                         to_char(r.started_at, 'YYYY-MM-DD HH24:MI:SS')||'  '||r.ddls||' of '||r.nddl||
                         ' DDLs, T had '||r.npart||' partitions at the start');
  end loop;
  if l_n = 0 then
    dbms_output.put_line('  none yet');
  end if;
end;
/
