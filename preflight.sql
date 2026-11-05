-- =====================================================================
-- preflight.sql - verify the environment before anything is created.
-- Fails (ORA-20001) with a list of every problem found, so you fix them
-- all in one go instead of one error per attempt.
-- =====================================================================
@@config.sql
set lines 200 serveroutput on size unlimited format wrapped verify off feedback off
whenever sqlerror exit failure rollback

prompt
prompt ==== Preflight checks
declare
  l_errors   pls_integer := 0;
  l_val      varchar2(4000);
  l_cnt      number;
  l_any_dict boolean;

  procedure ok  (m varchar2) is begin dbms_output.put_line('  [ ok ] '||m); end;
  procedure warn(m varchar2) is begin dbms_output.put_line('  [warn] '||m); end;
  procedure bad (m varchar2) is begin dbms_output.put_line('  [FAIL] '||m); l_errors := l_errors + 1; end;

  function has_sys_priv(p varchar2) return boolean is
    c number;
  begin
    -- user_sys_privs = direct grants only (roles do not work inside
    -- definer-rights PL/SQL or scheduler jobs, which is where we need them)
    select count(*) into c from user_sys_privs where privilege = p;
    return c > 0;
  end;

  function param(p varchar2) return varchar2 is
    v varchar2(4000);
  begin
    execute immediate 'select value from v$parameter where name = :1' into v using p;
    return v;
  exception when others then return null;
  end;
begin
  -- 1. Version -------------------------------------------------------
  if dbms_db_version.version < 19 then
    bad('Oracle '||dbms_db_version.version||' detected; this harness supports 19c only.');
  elsif dbms_db_version.version > 19 then
    warn('Oracle '||dbms_db_version.version||' detected; the harness is written and verified for 19c.');
  else
    ok('Oracle 19c');
  end if;

  -- 2. Who / where -----------------------------------------------------
  if user in ('SYS', 'SYSTEM') then
    bad('Connected as '||user||'. Use the dedicated schema from admin/create_user.sql.');
  else
    ok('Schema '||user);
  end if;
  if sys_context('userenv', 'con_name') = 'CDB$ROOT' then
    bad('Connected to CDB$ROOT. Connect to the PDB that holds the test schema.');
  else
    ok('Container '||sys_context('userenv', 'con_name'));
  end if;

  -- 3. Direct system privileges --------------------------------------
  for p in (select column_value priv from table(sys.odcivarchar2list(
              'CREATE SESSION', 'CREATE TABLE', 'CREATE VIEW', 'CREATE PROCEDURE',
              'CREATE SEQUENCE', 'CREATE TYPE', 'CREATE JOB'))) loop
    if has_sys_priv(p.priv) then ok('Direct grant: '||p.priv);
    else bad('Missing DIRECT grant: '||p.priv||' (granting it through a role is not enough)');
    end if;
  end loop;

  -- 4. Direct grants on the V$ views ---------------------------------
  l_any_dict := has_sys_priv('SELECT ANY DICTIONARY');
  for v in (select column_value vw from table(sys.odcivarchar2list(
              'V_$SQL', 'V_$SESSION', 'V_$SESSION_EVENT', 'V_$MYSTAT', 'V_$STATNAME',
              'V_$SYSSTAT', 'V_$SYSTEM_EVENT', 'V_$PARAMETER', 'V_$INSTANCE'))) loop
    select count(*) into l_cnt from user_tab_privs
    where  owner = 'SYS' and table_name = v.vw and privilege = 'SELECT';
    if l_cnt > 0 or l_any_dict then ok('Can read '||replace(v.vw, 'V_$', 'V$'));
    else bad('Missing DIRECT grant: select on sys.'||v.vw);
    end if;
  end loop;

  select count(*) into l_cnt from user_tab_privs
  where  owner = 'SYS' and table_name = 'DBMS_LOCK' and privilege = 'EXECUTE';
  if l_cnt > 0 then ok('Can execute DBMS_LOCK');
  else bad('Missing DIRECT grant: execute on sys.dbms_lock');
  end if;

  -- 5. Scheduler capacity ----------------------------------------------
  l_val := param('job_queue_processes');
  if l_val is null then
    bad('Cannot read job_queue_processes (grant select on sys.v_$parameter).');
  elsif to_number(l_val) = 0 then
    bad('job_queue_processes = 0: scheduler jobs cannot run.');
  elsif to_number(l_val) < &NJOBS + 1 then
    bad('job_queue_processes = '||l_val||' < NJOBS + 1 ('||(&NJOBS + 1)||'). Lower NJOBS in config.sql or raise the parameter.');
  else
    ok('job_queue_processes = '||l_val||' (need >= '||(&NJOBS + 1)||')');
  end if;

  l_val := param('cpu_count');
  if l_val is not null then
    if &NJOBS < to_number(l_val) then
      warn('NJOBS (&NJOBS) < cpu_count ('||l_val||'): the pile-up will be small. Consider NJOBS >= 2 x cpu_count.');
    else
      ok('cpu_count = '||l_val||', NJOBS = &NJOBS');
    end if;
  end if;

  -- 6. Parameters that change the outcome ------------------------------
  l_val := param('cursor_invalidation');
  ok('cursor_invalidation (system) = '||nvl(l_val, '?')||
     ' - the harness forces IMMEDIATE in its own DDL session');

  l_val := param('control_management_pack_access');
  if instr(nvl(l_val, 'NONE'), 'DIAGNOSTIC') > 0 then
    select count(*) into l_cnt from user_tab_privs
    where  owner = 'SYS' and table_name = 'V_$ACTIVE_SESSION_HISTORY';
    if l_cnt > 0 or l_any_dict then
      ok('Diagnostics Pack enabled: ASH samples will be captured');
    else
      warn('Diagnostics Pack enabled but no grant on V$ACTIVE_SESSION_HISTORY: ASH timeline skipped');
    end if;
    select count(*) into l_cnt from user_tab_privs
    where  owner = 'SYS' and table_name = 'DBMS_WORKLOAD_REPOSITORY' and privilege = 'EXECUTE';
    if upper('&AWR') = 'NO' then
      ok('AWR = NO: no AWR snapshots or Oracle ASH/AWR reports');
    elsif l_cnt > 0 then
      ok('AWR snapshots and ASH/AWR reports enabled (AWR = &AWR)');
    elsif upper('&AWR') = 'YES' then
      bad('AWR = YES but no DIRECT grant: execute on sys.dbms_workload_repository');
    else
      warn('No grant on DBMS_WORKLOAD_REPOSITORY: no AWR snapshots or Oracle ASH/AWR reports');
    end if;
  else
    if upper('&AWR') = 'YES' then
      bad('AWR = YES but the Diagnostics Pack is not enabled (control_management_pack_access)');
    end if;
    ok('Diagnostics Pack not enabled: no ASH/AWR; the licence-free session counters are used');
  end if;

  -- 7. Parameter sanity --------------------------------------------------
  if &NPART < 20 or &NPART > 5000 then bad('NPART must be between 20 and 5000.'); end if;
  if &NDDL < 1 or &NDDL > &NPART - 10 then bad('NDDL must be between 1 and NPART - 10.'); end if;
  if &NJOBS < 2 or &NJOBS > 200 then bad('NJOBS must be between 2 and 200.'); end if;
  if &SECS < 10 then bad('SECS must be at least 10.'); end if;
  if &WARMUP < 3 then bad('WARMUP must be at least 3.'); end if;
  if &WORKER_MINUTES < 5 or &WORKER_MINUTES > 1440 then bad('WORKER_MINUTES must be between 5 and 1440.'); end if;
  if &INSERTS < 0 or &INSERTS > 100 then bad('INSERTS must be between 0 and 100.'); end if;
  if &PARSE_MS < 0 or &PARSE_MS > 10000 then bad('PARSE_MS must be between 0 and 10000.'); end if;
  if &PARSE_MS * 1.5 > &SECS * 1000 / (&NDDL + 1) then
    warn('PARSE_MS is long compared with the gap between DDLs (SECS / (NDDL+1)); pile-ups may overlap.');
  end if;
  if &THINK_MS < 0 or &THINK_MS > 5000 then bad('THINK_MS must be between 0 and 5000.'); end if;
  if upper('&AWR') not in ('AUTO', 'YES', 'NO') then bad('AWR must be AUTO, YES or NO.'); end if;
  if &SECS / (&NDDL + 1) < 1 then
    warn('Less than 1 s between DDLs (SECS / (NDDL+1)); invalidation storms may overlap.');
  end if;

  -- 8. Space ---------------------------------------------------------------
  -- T + local index + T_X: roughly 400 bytes per row incl. extent overhead,
  -- 1000 rows per partition. Plus the workers' inserts into PCUR: about
  -- 150 MB per hour per inserted row per execution, for WORKER_MINUTES.
  -- Space held by an existing T / T_X counts as free, because the build
  -- drops and rebuilds them.
  select count(*) into l_cnt
  from   user_ts_quotas q, user_users u
  where  q.tablespace_name = u.default_tablespace
  and   (q.max_bytes = -1
         or q.max_bytes - q.bytes
            + (select nvl(sum(bytes), 0) from user_segments
               where segment_name in ('T', 'T_X', 'T_GRP', 'T_X_GRP'))
            >= &NPART * 1000 * 400 + &INSERTS * 157286400.0 * &WORKER_MINUTES / 60);
  if l_cnt > 0 or has_sys_priv('UNLIMITED TABLESPACE') then
    ok('Quota on default tablespace for about '||
       round((&NPART * 1000 * 400 + &INSERTS * 157286400.0 * &WORKER_MINUTES / 60) / 1048576)||
       ' MB (the table, and the inserts of one WORKER_MINUTES period)');
  else
    bad('Not enough quota on the default tablespace (need about '||
        round((&NPART * 1000 * 400 + &INSERTS * 157286400.0 * &WORKER_MINUTES / 60) / 1048576)||
        ' MB: the table, and the inserts of one WORKER_MINUTES period).');
  end if;

  if l_errors > 0 then
    raise_application_error(-20001, l_errors||' preflight check(s) failed - see [FAIL] lines above.');
  end if;
  dbms_output.put_line('  All preflight checks passed.');
end;
/
set feedback on
