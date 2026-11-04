-- =====================================================================
-- cleanup.sql - stop any workers and drop every object the harness
-- created in this schema (tables, results, code, views).
-- To remove the schema itself, run admin/drop_user.sql as a DBA.
-- =====================================================================
set lines 200 serveroutput on size unlimited format wrapped feedback off
whenever sqlerror continue

declare
  e_no_table exception; pragma exception_init(e_no_table, -942);
  e_no_job   exception; pragma exception_init(e_no_job, -27475);
begin
  begin
    execute immediate q'[update pinx_ctl set phase = 'STOP']';
    commit;
  exception when e_no_table then null;
  end;
  for j in (select job_name from user_scheduler_jobs where job_name like 'PINX\_W%' escape '\') loop
    begin
      dbms_scheduler.drop_job(j.job_name, force => true);
    exception when e_no_job then null;   -- finished and auto-dropped meanwhile
    end;
  end loop;
  begin
    execute immediate 'disassociate statistics from functions pinx_parse_marker';
  exception when others then null;                    -- not associated / not there
  end;
  for o in (select object_name, object_type from user_objects
            where  object_type in ('VIEW', 'PROCEDURE', 'PACKAGE', 'FUNCTION', 'TYPE')
            and    object_name like 'PINX%'
            order  by decode(object_type, 'TYPE', 2, 1)) loop
    execute immediate 'drop '||o.object_type||' '||o.object_name||
                      case o.object_type when 'TYPE' then ' force' end;
  end loop;
  for t in (select table_name from user_tables
            where  table_name in ('T', 'T_X') or table_name like 'PINX\_%' escape '\') loop
    execute immediate 'drop table '||t.table_name||' cascade constraints purge';
  end loop;
  dbms_output.put_line('Harness objects removed.');
end;
/
set feedback on
