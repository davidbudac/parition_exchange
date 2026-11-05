-- =====================================================================
-- admin/create_user.sql
--
-- Creates the dedicated test schema for the pinx harness. 1_build.sh
-- runs it for you; by hand, as a DBA (e.g. SYS or a user with CREATE USER
-- and GRANT ANY OBJECT PRIVILEGE) *inside the target PDB* (or a non-CDB):
--
--   sqlplus sys@//host:1521/pdb1 as sysdba @admin/create_user.sql <password>
--
-- or, from CDB$ROOT:   alter session set container = PDB1;   first.
--
-- Safe to run again: an existing user is kept (with all its objects and
-- results) and gets the password you pass, so the build can log in.
-- Avoid quotes in the password.
--
-- Why direct grants (and not SELECT_CATALOG_ROLE)?
--   The harness runs its logic in definer-rights PL/SQL and in
--   DBMS_SCHEDULER jobs. Roles are disabled in both, so every privilege
--   and every V$ view the code touches must be granted directly.
--
-- TEST DATABASES ONLY.
-- =====================================================================
set verify off feedback off serveroutput on
whenever sqlerror exit failure rollback

define PINX_USER = PINX
define PINX_TBS  = USERS

-- Password = first argument:  @admin/create_user.sql <password>
-- (if omitted, SQL*Plus / SQLcl asks "Enter value for 1:").
define PINX_PASS = "&1"

declare
  l_con varchar2(128) := sys_context('userenv', 'con_name');
  l_cdb varchar2(3);
begin
  select cdb into l_cdb from v$database;
  if l_cdb = 'YES' and l_con = 'CDB$ROOT' then
    raise_application_error(-20000,
      'Connected to CDB$ROOT. Switch to the target PDB first '||
      '(alter session set container = <PDB>) - the harness needs a local user.');
  end if;
  if dbms_db_version.version < 19 then
    raise_application_error(-20000, 'Oracle 19c or later is required.');
  end if;
end;
/

declare
  n number;
begin
  select count(*) into n from dba_users where username = upper('&PINX_USER');
  if n = 0 then
    execute immediate 'create user &PINX_USER identified by "&PINX_PASS" '||
                      'default tablespace &PINX_TBS quota 500m on &PINX_TBS';
    dbms_output.put_line('User &PINX_USER created (default tablespace &PINX_TBS).');
  else
    execute immediate 'alter user &PINX_USER identified by "&PINX_PASS" account unlock '||
                      'quota 500m on &PINX_TBS';
    dbms_output.put_line('User &PINX_USER already exists: kept, password set to the one given.');
  end if;
end;
/

-- System privileges
grant create session   to &PINX_USER;
grant create table     to &PINX_USER;
grant create view      to &PINX_USER;
grant create procedure to &PINX_USER;
-- CREATE SEQUENCE: the identity column in PINX_RUN needs it
grant create sequence  to &PINX_USER;
-- CREATE TYPE: the user-defined optimizer statistics that set PARSE_MS
grant create type      to &PINX_USER;
grant create job       to &PINX_USER;

-- Single-controller lock (DBMS_LOCK is not granted to PUBLIC in 19c)
grant execute on sys.dbms_lock to &PINX_USER;

-- AWR snapshots and ASH/AWR HTML reports. Only used when the Diagnostics
-- Pack is enabled (config.sql: AWR = AUTO/YES). Harmless otherwise.
grant execute on sys.dbms_workload_repository to &PINX_USER;

-- Dynamic performance views read by the harness (must be direct grants)
grant select on sys.v_$sql                    to &PINX_USER;
-- V$SESSION: status.sql shows what each worker session is doing
grant select on sys.v_$session                to &PINX_USER;
grant select on sys.v_$session_event          to &PINX_USER;
grant select on sys.v_$mystat                 to &PINX_USER;
grant select on sys.v_$statname               to &PINX_USER;
grant select on sys.v_$sysstat                to &PINX_USER;
grant select on sys.v_$system_event           to &PINX_USER;
grant select on sys.v_$parameter              to &PINX_USER;
grant select on sys.v_$instance               to &PINX_USER;
-- Only queried when CONTROL_MANAGEMENT_PACK_ACCESS includes DIAGNOSTIC
-- (Diagnostics Pack licence). Harmless to grant either way.
grant select on sys.v_$active_session_history to &PINX_USER;

prompt Grants in place.
set feedback on
undefine PINX_PASS
