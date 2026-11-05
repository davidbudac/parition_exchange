-- =====================================================================
-- admin/drop_user.sql
--
-- Removes the pinx test schema and everything it owns (tables, results,
-- package, scheduler jobs). 5_cleanup.sh runs it for you; by hand, as a
-- DBA inside the same PDB as create_user.sql. Safe to run again: a user
-- that is already gone is reported, not an error.
--
-- AWR snapshots the tests took stay in AWR and age out with its
-- retention; the files in reports/ are not touched.
-- =====================================================================
set verify off feedback off serveroutput on
whenever sqlerror exit failure rollback

define PINX_USER = PINX

declare
  e_connected exception; pragma exception_init(e_connected, -1940);
  e_no_job    exception; pragma exception_init(e_no_job, -27475);
  l_user  varchar2(128) := upper('&PINX_USER');
  l_cnt   number;
  l_until date;
begin
  select count(*) into l_cnt from dba_users where username = l_user;
  if l_cnt = 0 then
    dbms_output.put_line('User '||l_user||' does not exist: nothing to drop.');
    return;
  end if;

  -- 1. Ask the workers to stop (they finish their current execution and
  --    exit cleanly), give them 30 s, then remove whatever is left.
  select count(*) into l_cnt from dba_scheduler_running_jobs
  where  owner = l_user and job_name like 'PINX\_W%' escape '\';
  if l_cnt > 0 then
    dbms_output.put_line('Stopping '||l_cnt||' running worker jobs.');
    begin
      execute immediate 'update '||l_user||'.pinx_ctl set phase = ''STOP''';
      commit;
    exception when others then null;     -- no control table: force-stop below
    end;
    l_until := sysdate + 30 / 86400;
    loop
      select count(*) into l_cnt from dba_scheduler_running_jobs
      where  owner = l_user and job_name like 'PINX\_W%' escape '\';
      exit when l_cnt = 0 or sysdate > l_until;
      dbms_session.sleep(1);
    end loop;
  end if;
  for j in (select job_name from dba_scheduler_jobs
            where  owner = l_user and job_name like 'PINX\_W%' escape '\') loop
    begin
      dbms_scheduler.drop_job(l_user||'.'||j.job_name, force => true);
    exception when e_no_job then null;   -- finished and auto-dropped meanwhile
    end;
  end loop;

  -- 2. Drop the user. A job session can take a moment to disappear
  --    (ORA-01940 "cannot drop a user that is currently connected").
  l_until := sysdate + 60 / 86400;
  loop
    begin
      execute immediate 'drop user '||l_user||' cascade';
      exit;
    exception when e_connected then
      if sysdate > l_until then
        raise_application_error(-20000, 'User '||l_user||' is still connected after 60 s. '||
          'Close your own sessions as '||l_user||' (SQL Developer, SQL*Plus) and run this again.');
      end if;
      dbms_session.sleep(2);
    end;
  end loop;
  dbms_output.put_line('User '||l_user||' dropped, with everything it owned.');
end;
/
set feedback on
