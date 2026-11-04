-- =====================================================================
-- admin/drop_user.sql
--
-- Removes the pinx test schema and everything it owns (tables, package,
-- scheduler jobs). Run as a DBA inside the same PDB as create_user.sql.
-- =====================================================================
set verify off feedback on serveroutput on
whenever sqlerror exit failure rollback

define PINX_USER = PINX

-- Stop any worker jobs still running before the user is dropped.
begin
  for j in (select owner, job_name from dba_scheduler_jobs
            where owner = upper('&PINX_USER') and job_name like 'PINX\_W%' escape '\') loop
    begin
      dbms_scheduler.drop_job(j.owner||'.'||j.job_name, force => true);
    exception when others then
      if sqlcode <> -27475 then   -- -27475: already finished and auto-dropped
        dbms_output.put_line('could not drop job '||j.job_name||': '||sqlerrm);
      end if;
    end;
  end loop;
end;
/

drop user &PINX_USER cascade;
prompt User &PINX_USER dropped.
