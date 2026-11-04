-- =====================================================================
-- Test case: DROP PARTITION invalidates dependent cursors and causes a
-- hard-parse storm ("cursor: pin S wait on X"), while EXCHANGE PARTITION
-- on a partition the cursors don't touch keeps them valid (12.2+
-- fine-grained cursor invalidation; backport is bug 24817834).
--
-- Run as a test user with: ALTER SYSTEM (for flush shared_pool), CREATE TABLE, CREATE PROCEDURE, CREATE JOB,
-- and SELECT on V$SQL, V$SESSION_EVENT, V$SYSSTAT, V$ACTIVE_SESSION_HISTORY
-- (SELECT_CATALOG_ROLE is enough; ASH needs Diagnostics Pack).
-- TEST DATABASES ONLY: drops and creates objects.
-- =====================================================================
set serveroutput on lines 200 pages 100 timing on
whenever sqlerror continue

define NJOBS   = 24     -- concurrent sessions running the hot query
define SECS    = 60     -- how long each run lasts
define NPART   = 400    -- more partitions = more expensive hard parse

-- ---------------------------------------------------------------------
-- 1. Setup
-- ---------------------------------------------------------------------
begin execute immediate 'drop table t purge'; exception when others then null; end;
/
begin execute immediate 'drop table t_x purge'; exception when others then null; end;
/
begin execute immediate 'drop table run_ctl purge'; exception when others then null; end;
/

create table run_ctl (stop_flag number);
insert into run_ctl values (0);
commit;

-- Range-partitioned table with &NPART partitions; the hot query only reads P1.
declare
  s clob := 'create table t (id number not null, grp number, pad varchar2(100)) '||
            'partition by range (id) (';
begin
  for i in 1 .. &NPART loop
    s := s || case when i > 1 then ',' end ||
         'partition p'||i||' values less than ('||(i*1000)||')';
  end loop;
  execute immediate s || ')';
end;
/
insert /*+ append */ into t
select rownum-1, mod(rownum,50), rpad('x',100,'x')
from   dual connect by level <= &NPART * 1000;
commit;
create index t_grp on t(grp) local;
exec dbms_stats.gather_table_stats(user,'T')

-- Empty table matching T, for the exchange
create table t_x for exchange with table t;
create index t_x_grp on t_x(grp);

-- ---------------------------------------------------------------------
-- 2. Worker: runs the hot query in a tight loop until stop_flag = 1.
--    The query prunes statically to P1 and is deliberately costly to parse
--    (self-joins), so concurrent re-parses pile up on the same cursor.
--    The qb_name hint tags it: PL/SQL strips plain comments but keeps hints.
-- ---------------------------------------------------------------------
create or replace procedure hot_loop as
  n number; stop_it number := 0;
begin
  while stop_it = 0 loop
    for k in 1 .. 200 loop
      select /*+ qb_name(pinx) */ count(*) into n
      from   t a, t b, t c, t d
      where  a.id < 1000 and b.id < 1000 and c.id < 1000 and d.id < 1000
      and    a.id = b.id and b.id = c.id and c.id = d.id
      and    a.grp = 7;
    end loop;
    select stop_flag into stop_it from run_ctl;
  end loop;
end;
/

-- Helper: start/stop &NJOBS workers
create or replace procedure start_workers(p_n number) as
begin
  update run_ctl set stop_flag = 0; commit;
  for i in 1 .. p_n loop
    dbms_scheduler.create_job('PINX_W'||i, 'STORED_PROCEDURE', 'HOT_LOOP',
                              enabled => true, auto_drop => true);
  end loop;
end;
/
create or replace procedure stop_workers as
  c number;
begin
  update run_ctl set stop_flag = 1; commit;
  loop
    select count(*) into c from user_scheduler_running_jobs where job_name like 'PINX_W%';
    exit when c = 0;
    dbms_session.sleep(1);   -- use dbms_lock.sleep before 18c
  end loop;
end;
/

-- Report: cursor loads/invalidations and the wait events we care about
create or replace procedure report(p_label varchar2, p_since timestamp) as
begin
  dbms_output.put_line('==== '||p_label);
  for r in (select sql_id, child_number, loads, invalidations, parse_calls, executions,
                   is_rolling_invalid, ddl_no_invalidate
            from   v$sql where lower(sql_text) like 'select /*+ qb_name(pinx) */%') loop
    dbms_output.put_line('  sql_id='||r.sql_id||' child='||r.child_number||
      ' loads='||r.loads||' invalidations='||r.invalidations||
      ' parse_calls='||r.parse_calls||' execs='||r.executions||
      ' rolling_invalid='||r.is_rolling_invalid||' ddl_no_invalidate='||r.ddl_no_invalidate);
  end loop;
  for r in (select event, count(*) samples
            from   v$active_session_history
            where  sample_time > p_since
            and    event in ('cursor: pin S wait on X','cursor: pin X',
                             'library cache lock','library cache: mutex X',
                             'library cache pin','cursor: mutex X')
            group by event order by 2 desc) loop
    dbms_output.put_line('  ASH '||rpad(r.event,30)||' samples='||r.samples);
  end loop;
end;
/

-- ---------------------------------------------------------------------
-- 3. Run A: DROP PARTITION (expected: cursor invalidated, pin S wait on X)
-- ---------------------------------------------------------------------
alter system flush shared_pool;
variable t0 varchar2(40)
exec :t0 := to_char(systimestamp,'YYYY-MM-DD HH24:MI:SS.FF')
select name, value from v$sysstat where name in ('parse count (hard)','parse time elapsed');

exec start_workers(&NJOBS)
exec dbms_session.sleep(15)                 -- let the cursor get hot

prompt >>> DROP PARTITION on a partition the query does NOT read
alter table t drop partition p&NPART update indexes;

exec dbms_session.sleep(&SECS)
exec stop_workers
select name, value from v$sysstat where name in ('parse count (hard)','parse time elapsed');
exec report('RUN A: DROP PARTITION', to_timestamp(:t0,'YYYY-MM-DD HH24:MI:SS.FF'))

-- Put the partition back so run B starts from the same shape
alter table t add partition p&NPART values less than (&NPART * 1000);

-- ---------------------------------------------------------------------
-- 4. Run B: EXCHANGE PARTITION (expected: cursor stays valid, no storm)
-- ---------------------------------------------------------------------
alter system flush shared_pool;
exec :t0 := to_char(systimestamp,'YYYY-MM-DD HH24:MI:SS.FF')
select name, value from v$sysstat where name in ('parse count (hard)','parse time elapsed');

exec start_workers(&NJOBS)
exec dbms_session.sleep(15)

prompt >>> EXCHANGE PARTITION on a partition the query does NOT read
alter table t exchange partition p&NPART with table t_x
  including indexes without validation;
-- 12.2+: you can also add DEFERRED INVALIDATION, or set
-- alter session set cursor_invalidation = deferred;

exec dbms_session.sleep(&SECS)
exec stop_workers
select name, value from v$sysstat where name in ('parse count (hard)','parse time elapsed');
exec report('RUN B: EXCHANGE PARTITION', to_timestamp(:t0,'YYYY-MM-DD HH24:MI:SS.FF'))

-- ---------------------------------------------------------------------
-- 5. Optional: per-session waits for the workers (run while they are active)
-- ---------------------------------------------------------------------
-- select s.sid, e.event, e.total_waits, e.time_waited_micro
-- from   v$session s join v$session_event e on e.sid = s.sid
-- where  s.module like 'DBMS_SCHEDULER%' and e.event like 'cursor:%';
