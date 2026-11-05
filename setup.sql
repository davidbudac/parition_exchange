-- =====================================================================
-- setup.sql - install (or reinstall) the harness objects.
-- Idempotent: safe to run again at any time. Keeps old results unless
-- you run cleanup.sql first.
-- =====================================================================
@@preflight.sql
set lines 200 serveroutput on size unlimited format wrapped verify off feedback off
whenever sqlerror exit failure rollback

prompt
prompt ==== Installing harness objects

-- Refuse to reinstall while a run is active (same lock run_case takes).
declare
  l_handle varchar2(128);
  l_rc     integer;
begin
  dbms_lock.allocate_unique('PINX_CONTROLLER', l_handle);
  l_rc := dbms_lock.request(l_handle, dbms_lock.x_mode, timeout => 0, release_on_commit => false);
  if l_rc = 1 then
    raise_application_error(-20030,
      'A pinx run is in progress in this schema (its controller session may still be '||
      'finishing after a client disconnect). Wait for it, or kill that session.');
  end if;
  l_rc := dbms_lock.release(l_handle);
end;
/

-- Stop anything left over from an interrupted run before replacing code.
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
end;
/

-- ---------------------------------------------------------------------
-- Results / control tables. Created only if missing, so history survives
-- a reinstall.
-- ---------------------------------------------------------------------
declare
  n number;
  procedure ddl(p_name varchar2, p_sql varchar2) is
    c number;
  begin
    select count(*) into c from user_tables where table_name = p_name;
    if c = 0 then execute immediate p_sql; end if;
  end;
begin
  -- Live state, not history: recreated on every install.
  for t in (select table_name from user_tables where table_name in ('PINX_CTL', 'PINX_POOL')) loop
    execute immediate 'drop table '||t.table_name||' purge';
  end loop;

  -- One row the workers read after every execution:
  --   RUN     = keep running the hot query
  --   MEASURE = a test's measurement window is open (run_id says which)
  --   STOP    = finish and exit
  -- The workers also exit on their own at DEADLINE, so they never run
  -- forever if nobody stops them.
  ddl('PINX_CTL', q'[
    create table pinx_ctl (
      id          number       default 1 primary key check (id = 1),
      run_id      number,
      phase       varchar2(10) check (phase in ('RUN', 'MEASURE', 'STOP')),
      deadline    timestamp,
      parse_ms    number,
      think_ms    number,
      njobs       number,
      started_at  timestamp)]');

  -- One row per worker job while workers are started: its session and a
  -- heartbeat (every 2 s) so status.sql and the tests can see it is alive.
  ddl('PINX_POOL', q'[
    create table pinx_pool (
      worker      number primary key,
      sid         number,
      started_at  timestamp,
      ready_at    timestamp,
      last_beat   timestamp,
      execs       number,
      ended_at    timestamp)]');

  -- One row per run.
  ddl('PINX_RUN', q'[
    create table pinx_run (
      run_id               number generated always as identity primary key,
      kind                 varchar2(10)  not null check (kind in ('DROP', 'EXCHANGE')),
      status               varchar2(10)  not null check (status in ('RUNNING', 'DONE', 'FAILED')),
      njobs                number        not null,
      npart                number        not null,
      nddl                 number        not null,
      secs                 number        not null,
      warmup               number        not null,
      started_at           timestamp     not null,
      window_start         timestamp,
      window_end           timestamp,
      ended_at             timestamp,
      sql_id               varchar2(13),
      db_version           varchar2(30),
      con_name             varchar2(128),
      cpu_count            number,
      sys_cursor_inval     varchar2(30),
      ash_enabled          varchar2(1),
      worker_proc_status   varchar2(10),
      error_text           varchar2(4000))]');

  -- One row per worker per test run: written by the worker when it joins
  -- the run's measurement window (ready_at) and when it leaves (end_at).
  ddl('PINX_WORKER', q'[
    create table pinx_worker (
      run_id        number not null,
      worker        number not null,
      sid           number,
      ready_at      timestamp,
      end_at        timestamp,
      execs_window  number,
      constraint pinx_worker_pk primary key (run_id, worker))]');

  -- Per-worker session counters at window begin (B) and end (E).
  ddl('PINX_WORKER_SNAP', q'[
    create table pinx_worker_snap (
      run_id   number        not null,
      worker   number        not null,
      phase    varchar2(1)   not null check (phase in ('B', 'E')),
      name     varchar2(100) not null,
      val      number,
      time_us  number)]');

  -- Instance-level counters at window begin (B) and end (E).
  ddl('PINX_SYS_SNAP', q'[
    create table pinx_sys_snap (
      run_id   number        not null,
      phase    varchar2(1)   not null check (phase in ('B', 'E')),
      name     varchar2(100) not null,
      val      number,
      time_us  number)]');

  -- V$SQL rows for the hot cursor at window begin (B) and end (E).
  ddl('PINX_CURSOR_SNAP', q'[
    create table pinx_cursor_snap (
      run_id              number      not null,
      phase               varchar2(1) not null check (phase in ('B', 'E')),
      sql_id              varchar2(13),
      child_number        number,
      child_address       raw(8),
      plan_hash_value     number,
      loads               number,
      invalidations       number,
      parse_calls         number,
      executions          number,
      object_status       varchar2(19),
      is_rolling_invalid  varchar2(1),
      ddl_no_invalidate   varchar2(1))]');

  -- Each DDL statement the controller issued, with its elapsed time.
  ddl('PINX_DDL', q'[
    create table pinx_ddl (
      run_id      number         not null,
      seq         number         not null,
      ddl_text    varchar2(400)  not null,
      started_at  timestamp      not null,
      elapsed_ms  number         not null,
      -- Hot cursor signature (child_address:loads:invalidations of every
      -- child in V$SQL) just before the DDL, and again once things have
      -- settled (just before the next DDL / at window end). Different
      -- signatures = this DDL invalidated the cursor. Comparing per DDL
      -- is robust where summing V$SQL counters is not: under load each
      -- reparse builds a NEW child and the invalidated one leaves V$SQL.
      cursor_before   varchar2(1000),
      cursor_settled  varchar2(1000))]');

  -- ASH samples of the worker sessions inside the window, per event.
  ddl('PINX_ASH', q'[
    create table pinx_ash (
      run_id   number        not null,
      event    varchar2(64)  not null,
      samples  number        not null)]');

  -- Raw ASH rows (workers + controller) for the window, copied out of the
  -- in-memory ASH buffer right after each run so the evidence survives
  -- after V$ACTIVE_SESSION_HISTORY has wrapped. Feeds the timeline chart.
  ddl('PINX_ASH_SAMPLE', q'[
    create table pinx_ash_sample (
      run_id            number        not null,
      sample_id         number        not null,
      sample_time       timestamp(3)  not null,
      session_id        number,
      session_serial#   number,
      module            varchar2(64),
      action            varchar2(64),
      session_state     varchar2(7),
      event             varchar2(64),
      wait_class        varchar2(64),
      sql_id            varchar2(13),
      sql_opname        varchar2(64),
      blocking_session  number,
      time_waited       number)]');

  -- Columns added after the first release: add them to older installs.
  for c in (select 'PINX_DDL' tab, 'CURSOR_BEFORE' col, 'varchar2(1000)' typ from dual
            union all select 'PINX_DDL', 'CURSOR_SETTLED', 'varchar2(1000)' from dual
            union all select 'PINX_RUN', 'PARSE_MS',       'number'         from dual
            union all select 'PINX_RUN', 'THINK_MS',       'number'         from dual
            union all select 'PINX_RUN', 'AWR_ENABLED',    'varchar2(1)'    from dual
            union all select 'PINX_RUN', 'AWR_DBID',       'number'         from dual
            union all select 'PINX_RUN', 'INST_NUM',       'number'         from dual
            union all select 'PINX_RUN', 'AWR_SNAP_BEGIN', 'number'         from dual
            union all select 'PINX_RUN', 'AWR_SNAP_END',   'number'         from dual) loop
    select count(*) into n from user_tab_columns where table_name = c.tab and column_name = c.col;
    if n = 0 then execute immediate 'alter table '||c.tab||' add ('||c.col||' '||c.typ||')'; end if;
  end loop;
end;
/

merge into pinx_ctl c
using (select 1 id from dual) s on (c.id = s.id)
when not matched then insert (id, phase) values (1, 'STOP');
commit;

-- ---------------------------------------------------------------------
-- Controllable hard-parse cost.
--
-- The hot query carries the predicate pinx_parse_marker(a.id) >= 0. The
-- function itself is trivial (returns its argument). But it has
-- user-defined optimizer statistics (ASSOCIATE STATISTICS ... USING
-- pinx_parse_cost): to estimate the predicate's selectivity, the
-- optimizer calls pinx_parse_cost.ODCIStatsSelectivity during every hard
-- parse, and that burns PINX_CTL.PARSE_MS milliseconds of CPU. So every
-- hard parse of the hot query costs a known amount of CPU, like a
-- complex production statement would, while executions stay cheap and
-- no extra memory is used. That makes each invalidation pile-up last
-- long enough to be seen in ASH, which samples once per second.
-- ---------------------------------------------------------------------
begin
  execute immediate 'disassociate statistics from functions pinx_parse_marker';
exception when others then
  if sqlcode not in (-29931, -29816, -942, -4043) then raise; end if;   -- nothing to remove
end;
/

create or replace function pinx_parse_marker(p in number) return number deterministic is
begin
  return p;
end pinx_parse_marker;
/

create or replace type pinx_parse_cost force as object (
  dummy number,
  static function ODCIGetInterfaces(ifclist out sys.ODCIObjectList) return number,
  static function ODCIStatsSelectivity(pred sys.ODCIPredInfo, sel out number,
                                       args sys.ODCIArgDescList, strt number, stop number,
                                       p number, env sys.ODCIEnv) return number
);
/

create or replace type body pinx_parse_cost as
  static function ODCIGetInterfaces(ifclist out sys.ODCIObjectList) return number is
  begin
    ifclist := sys.ODCIObjectList(sys.ODCIObject('SYS', 'ODCISTATS2'));
    return ODCIConst.Success;
  end;

  static function ODCIStatsSelectivity(pred sys.ODCIPredInfo, sel out number,
                                       args sys.ODCIArgDescList, strt number, stop number,
                                       p number, env sys.ODCIEnv) return number is
    l_ms    number;
    l_until number;
    l_n     number := 0;
  begin
    select nvl(max(parse_ms), 0) into l_ms from pinx_ctl;
    l_until := dbms_utility.get_time + l_ms / 10;          -- get_time is in centiseconds
    while dbms_utility.get_time < l_until loop
      l_n := l_n + 1;                                      -- burn CPU, like real optimizer work
    end loop;
    sel := 50;                                             -- percent; any plausible value
    return ODCIConst.Success;
  end;
end;
/

-- Through EXECUTE IMMEDIATE: SQLcl does not recognise ASSOCIATE as a SQL
-- command and would send the trailing ';' along (ORA-00933).
begin
  execute immediate 'associate statistics with functions pinx_parse_marker using pinx_parse_cost';
end;
/

-- The package source contains HTML/JavaScript with '&' characters:
-- switch substitution off so SQL*Plus / SQLcl leave them alone.
set define off

-- ---------------------------------------------------------------------
-- Controller package. All SQL against T is dynamic on purpose: the
-- package must not depend on T, so dropping/recreating T or its
-- partitions can never invalidate the code that is running the test.
-- ---------------------------------------------------------------------
create or replace package pinx_lab authid definer as

  c_module      constant varchar2(30) := 'PINX_WORKER';      -- worker sessions
  c_ctl_module  constant varchar2(30) := 'PINX_CONTROLLER';  -- the session issuing DDL
  c_job_prefix  constant varchar2(10) := 'PINX_W';
  c_lock_name   constant varchar2(30) := 'PINX_CONTROLLER';

  -- Step 1 (build.sql): stop any workers, then (re)create T (p_npart range
  -- partitions, 1000 rows each, local index, stats) and T_X, and
  -- regenerate the worker procedure.
  procedure build_table(p_npart in pls_integer);

  -- (Re)generate and compile PINX_HOT_LOOP (needs T to exist).
  procedure create_worker;

  -- Step 2 (start_workers.sql): start p_njobs scheduler jobs that run the
  -- hot query until stop_workers is called or p_minutes have passed.
  -- Restarts them if they are already running. Returns once every worker
  -- has executed the query.
  procedure start_workers(p_njobs    in pls_integer,
                          p_think_ms in pls_integer,
                          p_parse_ms in pls_integer,
                          p_minutes  in pls_integer);

  -- Steps 3 and 4 (test_drop.sql, test_exchange.sql): one measured test
  -- against the workers that are already running. p_kind = 'DROP' or
  -- 'EXCHANGE'. Leaves the workers running.
  -- p_awr: AUTO (snapshots when the Diagnostics Pack is enabled and
  -- DBMS_WORKLOAD_REPOSITORY is granted), YES (required) or NO.
  procedure run_case(p_kind     in varchar2,
                     p_nddl     in pls_integer,
                     p_secs     in pls_integer,
                     p_warmup   in pls_integer,
                     p_parse_ms in pls_integer default 0,
                     p_awr      in varchar2    default 'AUTO');

  -- Self-contained HTML page (one row per line) with the ASH timeline of
  -- a DROP and an EXCHANGE run side by side. Used by evidence.sql.
  function timeline_html(p_drop in number, p_exch in number)
    return sys.odcivarchar2list pipelined;

  -- Called by the worker jobs: snapshot their own session counters.
  procedure worker_snap(p_run_id in number, p_worker in pls_integer, p_phase in varchar2);

  -- Signal STOP and remove every PINX_W* job. Safe to call any time.
  procedure stop_workers(p_timeout_s in pls_integer default 60);

  -- Drop T, T_X and all results (keeps the code).
  procedure purge_all;

end pinx_lab;
/

create or replace package body pinx_lab as

  -- One controller per schema at a time. DBMS_LOCK (not a row lock)
  -- because run_case commits many times; the lock is released by
  -- release_lock or automatically when the session ends.
  g_lock_handle varchar2(128);

  -- Source of PINX_HOT_LOOP; {{HOT_QUERY}} is filled in by create_worker.
  c_worker_tpl constant varchar2(32767) := q'~create or replace procedure pinx_hot_loop(
  p_worker in pls_integer, p_think_ms in pls_integer default 0)
  authid definer
as
  -- GENERATED by pinx_lab.create_worker - do not edit; rerun setup.sql.
  --
  -- The worker. Separate from the package because it is the only code
  -- with a static dependency on T. Runs as a DBMS_SCHEDULER job, started
  -- by start_workers, and keeps running the hot query until PINX_CTL
  -- says STOP or its deadline passes. When a test opens a measurement
  -- window (phase MEASURE) the worker snapshots its own counters, and
  -- again when the window closes.
  -- The hot query reads only P1 of T (id < 1000 prunes statically).
  -- pinx_parse_marker(a.id) >= 0 is always true but makes every hard
  -- parse cost PARSE_MS of CPU (see pinx_parse_cost). When the cursor is
  -- invalidated, one session hard-parses while the others queue on
  -- "cursor: pin S wait on X". p_think_ms is a pause after each
  -- execution, so the sessions do not just saturate the CPUs.
  -- qb_name(pinx) tags the statement: PL/SQL strips comments from
  -- static SQL but keeps hints, so the tag survives into V$SQL.
  n          number;
  l_ctl_run  number;
  l_phase    varchar2(10);
  l_deadline timestamp;
  l_run      number;                 -- the test run being measured, if any
  l_execs    pls_integer := 0;       -- executions inside that window
  l_total    number := 0;            -- executions since the worker started
  l_beat     timestamp;
  l_batch    pls_integer := case when p_think_ms > 0 then 1 else 20 end;

  procedure leave_window is
  begin
    pinx_lab.worker_snap(l_run, p_worker, 'E');
    update pinx_worker set end_at = systimestamp, execs_window = l_execs
    where  run_id = l_run and worker = p_worker;
    commit;
    l_run := null;
  end leave_window;
begin
  dbms_application_info.set_module(pinx_lab.c_module, 'W'||p_worker);
  update pinx_pool set sid = sys_context('userenv', 'sid'), started_at = systimestamp
  where  worker = p_worker;
  commit;

  loop
    for k in 1 .. l_batch loop
      {{HOT_QUERY}};
      l_execs := l_execs + 1;
      l_total := l_total + 1;
      if p_think_ms > 0 then dbms_session.sleep(p_think_ms / 1000); end if;
    end loop;

    select run_id, phase, deadline into l_ctl_run, l_phase, l_deadline
    from   pinx_ctl where id = 1;
    exit when l_phase = 'STOP' or systimestamp > l_deadline;

    -- The window this worker was measuring has closed (or was abandoned).
    if l_run is not null and (l_phase <> 'MEASURE' or l_ctl_run <> l_run) then
      leave_window;
    end if;
    -- A test opened a window: baseline snapshot, then count executions.
    if l_run is null and l_phase = 'MEASURE' then
      insert into pinx_worker (run_id, worker, sid, ready_at)
      values (l_ctl_run, p_worker, sys_context('userenv', 'sid'), systimestamp);
      pinx_lab.worker_snap(l_ctl_run, p_worker, 'B');      -- commits
      l_run   := l_ctl_run;
      l_execs := 0;
    end if;
    -- Heartbeat every 2 s.
    if l_beat is null or systimestamp - l_beat > interval '2' second then
      l_beat := systimestamp;
      update pinx_pool set ready_at = nvl(ready_at, l_beat), last_beat = l_beat, execs = l_total
      where  worker = p_worker;
      commit;
    end if;
  end loop;

  if l_run is not null then
    leave_window;
  end if;
  update pinx_pool set ended_at = systimestamp, execs = l_total where worker = p_worker;
  commit;
end pinx_hot_loop;~';

  -- -------------------------------------------------------------------
  -- Timeline page. The static parts are two templates; every template
  -- line is indented so SQL*Plus never sees a command character in
  -- column 1 while it reads this package.
  c_tl_head constant varchar2(32767) := q'~  <!doctype html>
  <html lang="en">
  <head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>DROP vs EXCHANGE PARTITION</title>
  <style>
    :root{--bg:#f6f6f3;--fg:#1c1c1f;--muted:#66666d;--card:#fff;--line:#e2e2de;
      --pin:#d33a2c;--lib:#ee8a00;--mtx:#8f7cc4;--oth:#a3a7ad;--cpu:#3d9a5b;--ok:#2e8b4f;--bad:#c62828}
    /* dark mode */ @media (prefers-color-scheme: dark){:root:not([data-theme="light"]){--bg:#131315;--fg:#ececef;
      --muted:#9b9ba3;--card:#1c1c20;--line:#2d2d33;--oth:#6d7279}}
    :root[data-theme="dark"]{--bg:#131315;--fg:#ececef;--muted:#9b9ba3;--card:#1c1c20;--line:#2d2d33;--oth:#6d7279}
    body{margin:0;background:var(--bg);color:var(--fg);
      font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
    main{max-width:1120px;margin:0 auto;padding:28px 16px 48px}
    h1{font-size:26px;line-height:1.2;margin:0 0 6px;letter-spacing:-.01em}
    h2{font-size:18px;margin:0}
    h3{font-size:15px;margin:22px 0 6px}
    p{margin:0 0 10px}
    .sub{color:var(--muted)}
    .verdict{display:inline-block;padding:5px 12px;border-radius:6px;font-weight:650;color:#fff;margin:4px 0 2px}
    .pass{background:var(--ok)}
    .fail{background:var(--bad)}
    .card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:18px 18px 12px;margin:18px 0}
    .head{display:flex;flex-wrap:wrap;gap:4px 16px;align-items:baseline;justify-content:space-between}
    .mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px;color:var(--muted)}
    .kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:10px;margin:14px 0 8px}
    .kpi{border:1px solid var(--line);border-radius:8px;padding:8px 10px}
    .kpi b{display:block;font-size:22px;line-height:1.25;font-variant-numeric:tabular-nums}
    .kpi span{font-size:12px;color:var(--muted)}
    .kpi.hot b{color:var(--pin)}
    .legend{display:flex;flex-wrap:wrap;gap:4px 16px;font-size:12.5px;color:var(--muted);margin:4px 0}
    .sw{display:inline-block;width:11px;height:11px;border-radius:2px;margin-right:5px;vertical-align:-1px}
    svg{width:100%;height:auto;display:block}
    .axis text{fill:var(--muted);font-size:11px}
    .grid line{stroke:var(--line)}
    .f-pin{fill:var(--pin)} .f-lib{fill:var(--lib)} .f-mtx{fill:var(--mtx)} .f-oth{fill:var(--oth)} .f-cpu{fill:var(--cpu)}
    .b-pin{background:var(--pin)} .b-lib{background:var(--lib)} .b-mtx{background:var(--mtx)} .b-oth{background:var(--oth)} .b-cpu{background:var(--cpu)}
    .m-y line{stroke:var(--pin);stroke-width:1.5;stroke-dasharray:4 3}
    .m-n line{stroke:var(--muted);stroke-width:1.2;stroke-dasharray:4 3}
    .m-y circle{fill:var(--pin)} .m-n circle{fill:var(--muted)}
    .m-y text,.m-n text{fill:#fff;font-size:10.5px;font-weight:650}
    .links{font-size:13px;margin:8px 0 2px}
    .links a{color:inherit;margin-right:16px}
    .na{color:var(--muted);font-style:italic;font-size:13px}
    .tbl{overflow-x:auto}
    table{border-collapse:collapse;width:100%;font-size:13px}
    th,td{border-bottom:1px solid var(--line);padding:5px 8px;text-align:left;white-space:nowrap}
    td.r{text-align:right;font-variant-numeric:tabular-nums}
    .ok{color:var(--ok);font-weight:650} .bad{color:var(--bad);font-weight:650}
    .notes{color:var(--muted);font-size:13.5px}
    .notes li{margin:3px 0}
  </style>
  </head>
  <body>
  <main>
  <h1>DROP vs EXCHANGE PARTITION under load</h1>
  <p class="sub" id="sub"></p>
  <div id="verdict"></div>
  <div id="runs"></div>
  <h3>Checks</h3>
  <div class="tbl" id="checks"></div>
  <h3>How to read this</h3>
  <ul class="notes">
    <li>Each bar is one in-memory ASH sample (Oracle samples active sessions once per second) of the worker sessions, stacked by what they were doing.</li>
    <li>Numbered markers are the DDL statements. Red: the statement invalidated the hot cursor. Grey: the cursor stayed valid. Hover a bar or marker for details.</li>
    <li>Red bars after a red marker are the pile-up: one session hard-parses the invalidated cursor while every other session waits for it on <b>cursor: pin S wait on X</b>.</li>
    <li>Purple (cursor mutex / pin S) is background contention from many sessions executing one cursor. It shows up in both runs and is not caused by the DDL.</li>
    <li>The tiles come from the worker sessions' own counters (V$SESSION_EVENT, V$MYSTAT) and need no licence. ASH and AWR need the Diagnostics Pack.</li>
  </ul>
  </main>~';
  c_tl_js   constant varchar2(32767) := q'~  <script>
  (function(){
    var D = window.PINX;
    var CATS = [["pin","cursor: pin S wait on X"],["lib","library cache lock / pin / mutex"],
                ["mtx","cursor: mutex / pin S (hot-cursor contention)"],["oth","other waits"],["cpu","ON CPU"]];
    function esc(v){ return String(v).replace(/[<>"&]/g, function(c){
      return {"<":"&lt;", ">":"&gt;", '"':"&quot;", "&":"&amp;"}[c]; }); }
    function f1(v){ return (Math.round(v * 10) / 10).toString(); }

    var T = 0, ymax = 0;
    D.runs.forEach(function(r){
      T = Math.max(T, r.window); ymax = Math.max(ymax, r.njobs);
      r.ash.forEach(function(a){ var n = 0; for (var i = 1; i < a.length; i++) n += a[i]; ymax = Math.max(ymax, n); });
    });
    T = Math.max(5, Math.ceil(T));
    var ystep = ymax <= 12 ? 2 : (ymax <= 32 ? 4 : 10);
    ymax = Math.ceil(ymax / ystep) * ystep;

    function chart(r){
      var W = 1000, H = 330, ml = 42, mr = 14, mt = 28, mb = 38, pw = W - ml - mr, ph = H - mt - mb;
      function x(t){ return ml + t / T * pw; }
      function y(v){ return mt + ph - v / ymax * ph; }
      var s = [];
      s.push('<svg viewBox="0 0 ' + W + ' ' + H + '" role="img" aria-label="ASH timeline, ' + r.kind + ' run">');
      s.push('<g class="grid axis">');
      for (var v = 0; v <= ymax; v += ystep) {
        s.push('<line x1="' + ml + '" x2="' + (W - mr) + '" y1="' + y(v) + '" y2="' + y(v) + '"/>');
        s.push('<text x="' + (ml - 6) + '" y="' + (y(v) + 4) + '" text-anchor="end">' + v + '</text>');
      }
      var xs = T > 90 ? 15 : (T > 40 ? 10 : 5);
      for (var t = 0; t <= T + 0.01; t += xs)
        s.push('<text x="' + x(t) + '" y="' + (H - mb + 16) + '" text-anchor="middle">' + t + ' s</text>');
      s.push('<text x="' + (ml + pw / 2) + '" y="' + (H - 4) + '" text-anchor="middle">seconds since the measurement window opened</text>');
      s.push('<text transform="rotate(-90)" x="' + (-(mt + ph / 2)) + '" y="11" text-anchor="middle">active worker sessions</text>');
      s.push('</g>');
      var bw = Math.max(2, pw / T * 0.8);
      r.ash.forEach(function(a){
        var base = 0, tot = 0, parts = [];
        for (var i = 0; i < CATS.length; i++) if (a[i + 1]) { tot += a[i + 1]; parts.push(a[i + 1] + ' ' + CATS[i][1]); }
        var tip = '+' + f1(a[0]) + ' s: ' + tot + ' active (' + parts.join(', ') + ')';
        for (var j = 0; j < CATS.length; j++) {
          var n = a[j + 1]; if (!n) continue;
          s.push('<rect class="f-' + CATS[j][0] + '" x="' + (x(a[0]) - bw / 2).toFixed(1) + '" width="' + bw.toFixed(1) +
                 '" y="' + y(base + n).toFixed(1) + '" height="' + (y(base) - y(base + n)).toFixed(1) + '"><title>' + esc(tip) + '</title></rect>');
          base += n;
        }
      });
      r.ddl.forEach(function(d, i){
        var cx = x(d[0]).toFixed(1), inv = d[2] === "Y";
        s.push('<g class="' + (inv ? 'm-y' : 'm-n') + '"><line x1="' + cx + '" x2="' + cx + '" y1="' + (mt - 4) + '" y2="' + (mt + ph) + '"/>' +
               '<circle cx="' + cx + '" cy="' + (mt - 13) + '" r="9"/><text x="' + cx + '" y="' + (mt - 9) + '" text-anchor="middle">' + (i + 1) + '</text>' +
               '<title>' + esc('DDL ' + (i + 1) + ' at +' + f1(d[0]) + ' s, ' + d[1] + ' ms - ' +
               (inv ? 'INVALIDATED the hot cursor' : 'hot cursor stayed valid') + ' - ' + d[3]) + '</title></g>');
      });
      s.push('</svg>');
      return s.join('');
    }

    function tile(v, label, hot){ return '<div class="kpi' + (hot ? ' hot' : '') + '"><b>' + esc(v) + '</b><span>' + esc(label) + '</span></div>'; }

    var r0 = D.runs[0] || {};
    document.getElementById('sub').textContent =
      'Oracle ' + r0.ver + ' / ' + r0.con + ' / ' + r0.cpu + ' CPUs. ' + r0.njobs + ' sessions run the same query (it reads only partition P1) on a ' +
      r0.npart + '-partition table, while ' + r0.nddl + ' DDL statements, one every ' + f1(r0.window / (r0.nddl + 1)) +
      ' s, touch a partition the query never reads. Generated ' + D.generated + '.';
    document.getElementById('verdict').innerHTML =
      '<span class="verdict ' + (D.overall === 'PASS' ? 'pass' : 'fail') + '">OVERALL: ' + esc(D.overall) + '</span>';

    var html = [];
    D.runs.forEach(function(r){
      var label = r.kind === 'DROP' ? 'Run A - DROP PARTITION' : 'Run B - EXCHANGE PARTITION';
      html.push('<section class="card"><div class="head"><h2>' + label + ' <span class="mono">(run ' + r.id + ')</span></h2>' +
                '<span class="mono">' + esc(r.ddl.length ? r.ddl[0][3] : '') + '</span></div>');
      html.push('<div class="kpis">' +
        tile(r.m.inval + ' of ' + r.ddl.length, 'DDLs that invalidated the hot cursor', r.m.inval > 0) +
        tile(r.m.hp, 'hard parses in the worker sessions (incl. recursive SQL)', r.m.hp > 0) +
        tile(f1(r.m.pinms / 1000) + ' s', 'waited on cursor: pin S wait on X (' + r.m.pinw + ' waits)', r.m.pinw > 0) +
        tile(r.ashok === 'Y' ? r.m.ashpin : 'n/a', 'ASH samples in cursor: pin S wait on X', r.m.ashpin > 0) +
        tile(r.m.eps, 'hot query executions per second', false) + '</div>');
      html.push('<div class="legend">' + CATS.map(function(c){ return '<span><i class="sw b-' + c[0] + '"></i>' + esc(c[1]) + '</span>'; }).join('') +
                '<span><i class="sw b-pin" style="border-radius:50%"></i>DDL: invalidated</span>' +
                '<span><i class="sw" style="background:var(--muted);border-radius:50%"></i>DDL: cursor stayed valid</span></div>');
      html.push(r.ashok === 'Y' ? chart(r) :
        '<p class="na">No ASH data (Diagnostics Pack not enabled, or V$ACTIVE_SESSION_HISTORY not granted). The tiles above are licence-free counters.</p>');
      if (r.awr === 'Y')
        html.push('<div class="links">Oracle reports for this run: <a href="' + r.ashfile + '">ASH report</a>' +
                  '<a href="' + r.awrfile + '">AWR report (snapshots ' + r.snapb + ' to ' + r.snape + ')</a></div>');
      html.push('</section>');
    });
    document.getElementById('runs').innerHTML = html.join('');

    var t = ['<table><thead><tr><th>Run</th><th>Check</th><th>Expected</th><th>Actual</th><th>Result</th></tr></thead><tbody>'];
    D.checks.forEach(function(c){
      t.push('<tr><td>' + esc(c[0]) + '</td><td>' + esc(c[1]) + '</td><td class="r">' + esc(c[2]) + '</td><td class="r">' + esc(c[3]) +
             '</td><td class="' + (c[4] === 'PASS' ? 'ok' : 'bad') + '">' + esc(c[4]) + '</td></tr>');
    });
    t.push('</tbody></table>');
    document.getElementById('checks').innerHTML = t.join('');
  })();
  </script>
  </body>
  </html>~';

  -- -------------------------------------------------------------------
  procedure say(p_msg in varchar2) is
  begin
    dbms_output.put_line(to_char(systimestamp, 'HH24:MI:SS')||'  '||p_msg);
  end;

  procedure acquire_lock is
    l_rc integer;
  begin
    if g_lock_handle is null then
      dbms_lock.allocate_unique(c_lock_name, g_lock_handle);
    end if;
    l_rc := dbms_lock.request(g_lock_handle, dbms_lock.x_mode, timeout => 0,
                              release_on_commit => false);
    if l_rc = 1 then
      raise_application_error(-20030,
        'Another pinx run is in progress in this schema (its controller session may '||
        'still be finishing after a client disconnect). Wait for it, or kill that session.');
    elsif l_rc not in (0, 4) then          -- 4 = this session already holds it
      raise_application_error(-20031, 'DBMS_LOCK.REQUEST returned '||l_rc);
    end if;
  end acquire_lock;

  procedure release_lock is
    l_rc integer;
  begin
    if g_lock_handle is not null then
      l_rc := dbms_lock.release(g_lock_handle);
    end if;
  end release_lock;

  function elapsed_ms(p_since in timestamp) return number is
    l_iv interval day(3) to second(6) := systimestamp - p_since;
  begin
    return round(extract(day    from l_iv) * 86400000 + extract(hour   from l_iv) * 3600000
               + extract(minute from l_iv) * 60000    + extract(second from l_iv) * 1000, 1);
  end;

  function job_name(p_i in pls_integer) return varchar2 is
  begin
    return c_job_prefix||lpad(p_i, 3, '0');
  end;

  function param(p_name in varchar2) return varchar2 is
    l_val varchar2(4000);
  begin
    select value into l_val from v$parameter where name = p_name;
    return l_val;
  exception when no_data_found then return null;
  end;

  procedure drop_if_exists(p_table in varchar2) is
    e_no_table exception; pragma exception_init(e_no_table, -942);
  begin
    execute immediate 'drop table '||p_table||' purge';
  exception when e_no_table then null;
  end;

  -- Wait until p_sql (a count query; with one bind, the run id, unless
  -- p_run_id is null) reaches p_target, or fail after p_timeout_s seconds.
  procedure wait_for(p_what in varchar2, p_sql in varchar2, p_run_id in number,
                     p_target in pls_integer, p_timeout_s in pls_integer) is
    l_cnt   number;
    l_until timestamp := systimestamp + numtodsinterval(p_timeout_s, 'second');
  begin
    loop
      if p_run_id is null then
        execute immediate p_sql into l_cnt;
      else
        execute immediate p_sql into l_cnt using p_run_id;
      end if;
      exit when l_cnt >= p_target;
      if systimestamp > l_until then
        raise_application_error(-20010,
          'Timed out after '||p_timeout_s||' s waiting for '||p_what||': '||
          l_cnt||' of '||p_target||'. Check job_queue_processes, CPU load and '||
          'user_scheduler_job_run_details for worker errors.');
      end if;
      dbms_session.sleep(0.2);
    end loop;
  end;

  -- -------------------------------------------------------------------
  procedure create_worker is
    l_status varchar2(10);
  begin
    execute immediate replace(c_worker_tpl, '{{HOT_QUERY}}',
         'select /*+ qb_name(pinx) */ count(*) into n'||chr(10)||
         '      from   t a, t b, t c, t d'||chr(10)||
         '      where  a.id < 1000 and b.id < 1000 and c.id < 1000 and d.id < 1000'||chr(10)||
         '      and    a.id = b.id and b.id = c.id and c.id = d.id'||chr(10)||
         '      and    a.grp = 7'||chr(10)||
         '      and    pinx_parse_marker(a.id) >= 0');

    select status into l_status from user_objects
    where  object_name = 'PINX_HOT_LOOP' and object_type = 'PROCEDURE';
    if l_status <> 'VALID' then
      raise_application_error(-20011, 'PINX_HOT_LOOP is '||l_status||' after generation.');
    end if;
  end create_worker;

  -- -------------------------------------------------------------------
  procedure build_table(p_npart in pls_integer) is
    l_sql    clob;
    l_cnt    number;
  begin
    if p_npart not between 20 and 5000 then
      raise_application_error(-20021, 'NPART must be between 20 and 5000.');
    end if;
    acquire_lock;
    -- Workers run a query on T: they must not be running while T is replaced.
    select count(*) into l_cnt from user_scheduler_jobs where job_name like c_job_prefix||'%';
    if l_cnt > 0 then
      say('stopping '||l_cnt||' running workers first');
      stop_workers(60);
    end if;

    say('building table T ('||p_npart||' partitions, '||p_npart * 1000||' rows) and T_X');
    drop_if_exists('T_X');
    drop_if_exists('T');

    -- Explicit small extents: 19c gives each partition an 8 MB initial
    -- extent by default, which would make T about 3 GB instead of ~100 MB.
    l_sql := 'create table t (id number not null, grp number not null, pad varchar2(100)) '||
             'storage (initial 64k next 64k) partition by range (id) (';
    for i in 1 .. p_npart loop
      l_sql := l_sql || case when i > 1 then ',' end ||
               'partition p'||i||' values less than ('||(i * 1000)||')';
    end loop;
    execute immediate l_sql || ')';

    execute immediate
      q'[insert /*+ append */ into t
         select level - 1, mod(level, 50), rpad('x', 100, 'x')
         from   dual connect by level <= :n]' using p_npart * 1000;
    commit;
    execute immediate 'create index t_grp on t (grp) storage (initial 64k next 64k) local';
    dbms_stats.gather_table_stats(user, 'T', cascade => true);

    -- Empty table with the same shape as one partition, for the exchange.
    execute immediate 'create table t_x for exchange with table t';
    execute immediate 'create index t_x_grp on t_x (grp) storage (initial 64k next 64k)';

    -- The worker depends on T, which was just recreated. Regenerate (and
    -- so compile) it now rather than letting 24 jobs race to do it.
    create_worker;
    select count(*) into l_cnt from user_tab_partitions where table_name = 'T';
    say('table T ready: '||l_cnt||' partitions; T_X ready for the exchange');
    release_lock;
  exception when others then
    release_lock;
    raise;
  end build_table;

  -- -------------------------------------------------------------------
  procedure worker_snap(p_run_id in number, p_worker in pls_integer, p_phase in varchar2) is
  begin
    -- One INSERT..SELECT on purpose: the statement is parsed before it
    -- reads the counters, so the snapshot does not count its own parse.
    insert into pinx_worker_snap (run_id, worker, phase, name, val, time_us)
    select p_run_id, p_worker, p_phase, 'wait: '||e.event, e.total_waits, e.time_waited_micro
    from   v$session_event e
    where  e.sid = sys_context('userenv', 'sid')
    and   (e.event like 'cursor:%' or e.event like 'library cache%')
    union all
    select p_run_id, p_worker, p_phase, 'stat: '||n.name, s.value, null
    from   v$mystat s join v$statname n on n.statistic# = s.statistic#
    where  n.name in ('parse count (hard)', 'parse count (total)',
                      'parse time elapsed', 'parse time cpu');
    commit;
  end worker_snap;

  -- -------------------------------------------------------------------
  procedure sys_snap(p_run_id in number, p_phase in varchar2) is
  begin
    insert into pinx_sys_snap (run_id, phase, name, val, time_us)
    select p_run_id, p_phase, 'stat: '||name, value, null
    from   v$sysstat
    where  name in ('parse count (hard)', 'parse count (total)', 'parse time elapsed')
    union all
    select p_run_id, p_phase, 'wait: '||event, total_waits, time_waited_micro
    from   v$system_event
    where  event like 'cursor:%' or event like 'library cache%';

    insert into pinx_cursor_snap
      (run_id, phase, sql_id, child_number, child_address, plan_hash_value, loads,
       invalidations, parse_calls, executions, object_status, is_rolling_invalid,
       ddl_no_invalidate)
    select p_run_id, p_phase, sql_id, child_number, child_address, plan_hash_value, loads,
           invalidations, parse_calls, executions, object_status, is_rolling_invalid,
           ddl_no_invalidate
    from   v$sql
    where  parsing_schema_name = user
    and    upper(sql_text) like 'SELECT /*+ QB_NAME(PINX) */%';
    commit;
  end sys_snap;

  -- -------------------------------------------------------------------
  function cursor_sig(p_sql_id in varchar2) return varchar2 is
    l_sig varchar2(1000);
  begin
    select substr(listagg(rawtohex(child_address)||':'||loads||':'||invalidations, ' ')
                  within group (order by child_address), 1, 1000)
    into   l_sig
    from   v$sql where sql_id = p_sql_id;
    return nvl(l_sig, 'none');
  end cursor_sig;

  -- -------------------------------------------------------------------
  procedure stop_workers(p_timeout_s in pls_integer default 60) is
    l_cnt   number;
    l_until timestamp := systimestamp + numtodsinterval(p_timeout_s, 'second');
  begin
    update pinx_ctl set phase = 'STOP' where id = 1;
    commit;
    loop
      select count(*) into l_cnt from user_scheduler_running_jobs
      where  job_name like c_job_prefix||'%';
      exit when l_cnt = 0 or systimestamp > l_until;
      dbms_session.sleep(0.5);
    end loop;
    for j in (select job_name from user_scheduler_jobs where job_name like 'PINX\_W%' escape '\') loop
      begin
        dbms_scheduler.drop_job(j.job_name, force => true);
      exception when others then
        if sqlcode <> -27475 then          -- already finished and auto-dropped
          say('warning: could not drop job '||j.job_name||': '||sqlerrm);
        end if;
      end;
    end loop;
    update pinx_pool set ended_at = nvl(ended_at, systimestamp);
    commit;
  end stop_workers;

  -- -------------------------------------------------------------------
  procedure start_workers(p_njobs    in pls_integer,
                          p_think_ms in pls_integer,
                          p_parse_ms in pls_integer,
                          p_minutes  in pls_integer) is
    l_cnt    number;
    l_status varchar2(10);
    l_until  timestamp;
  begin
    if p_njobs not between 2 and 200 then
      raise_application_error(-20022, 'NJOBS must be between 2 and 200.');
    end if;
    if p_minutes not between 5 and 1440 then
      raise_application_error(-20022, 'WORKER_MINUTES must be between 5 and 1440.');
    end if;
    acquire_lock;
    begin
      select count(*) into l_cnt from user_tab_partitions where table_name = 'T';
      if l_cnt = 0 then
        raise_application_error(-20014, 'Table T has not been built yet. Run ./1_build.sh first.');
      end if;

      select count(*) into l_cnt from user_scheduler_jobs where job_name like c_job_prefix||'%';
      if l_cnt > 0 then
        say('stopping the '||l_cnt||' workers that are already running, to start fresh');
        stop_workers(60);
      end if;

      select status into l_status from user_objects
      where  object_name = 'PINX_HOT_LOOP' and object_type = 'PROCEDURE';
      if l_status <> 'VALID' then
        create_worker;
      end if;

      l_until := systimestamp + numtodsinterval(p_minutes, 'minute');
      update pinx_ctl
      set    run_id = null, phase = 'RUN', deadline = l_until, parse_ms = p_parse_ms,
             think_ms = p_think_ms, njobs = p_njobs, started_at = systimestamp
      where  id = 1;
      delete pinx_pool;
      for i in 1 .. p_njobs loop
        insert into pinx_pool (worker) values (i);
      end loop;
      commit;

      for i in 1 .. p_njobs loop
        dbms_scheduler.create_job(
          job_name   => job_name(i),
          job_type   => 'PLSQL_BLOCK',
          job_action => 'begin pinx_hot_loop('||i||', '||p_think_ms||'); end;',
          enabled    => true,
          auto_drop  => true,
          comments   => 'pinx worker '||i||': runs the hot query until stopped');
      end loop;
      say('started '||p_njobs||' worker jobs ('||job_name(1)||' to '||job_name(p_njobs)||
          '), waiting until each has run the hot query');
      wait_for('workers ready', 'select count(*) from pinx_pool where ready_at is not null',
               null, p_njobs, 120);
      say('all '||p_njobs||' workers are running the hot query ('||p_think_ms||
          ' ms think time between executions)');
      say('they stop by themselves at '||to_char(l_until, 'YYYY-MM-DD HH24:MI:SS')||
          ' ('||p_minutes||' min), or when ./5_cleanup.sh or stop_workers.sql stops them');
      release_lock;
    exception when others then
      rollback;
      begin stop_workers(30); exception when others then null; end;
      release_lock;
      raise;
    end;
  end start_workers;

  -- -------------------------------------------------------------------
  -- AWR snapshot through dynamic SQL, so the package compiles (and the
  -- harness works) without any grant on DBMS_WORKLOAD_REPOSITORY.
  function awr_snapshot return number is
    l_snap number;
  begin
    execute immediate 'begin :s := dbms_workload_repository.create_snapshot(); end;'
      using out l_snap;
    return l_snap;
  end awr_snapshot;

  -- -------------------------------------------------------------------
  procedure run_case(p_kind     in varchar2,
                     p_nddl     in pls_integer,
                     p_secs     in pls_integer,
                     p_warmup   in pls_integer,
                     p_parse_ms in pls_integer default 0,
                     p_awr      in varchar2    default 'AUTO') is
    type t_names is table of varchar2(128);
    l_kind     varchar2(10) := upper(p_kind);
    l_run      number;
    l_interval number;
    l_sql      varchar2(400);
    l_t0       timestamp;
    l_ms       number;
    l_ash      varchar2(1);
    l_sql_id   varchar2(13);
    l_status   varchar2(10);
    l_cpu      number;
    l_sig      varchar2(1000);
    l_cinv     varchar2(30);
    l_ver      varchar2(30);
    l_awr_mode varchar2(4) := upper(p_awr);
    l_awr      varchar2(1) := 'N';
    l_snap_b   number;
    l_snap_e   number;
    l_inst     number;
    l_njobs    number;
    l_think    number;
    l_phase    varchar2(10);
    l_running  number;
    l_alive    number;
    l_npart    number;
    l_parts    t_names;
  begin
    if l_kind not in ('DROP', 'EXCHANGE') then
      raise_application_error(-20020, 'p_kind must be DROP or EXCHANGE');
    end if;
    if p_parse_ms not between 0 and 10000 then
      raise_application_error(-20022, 'PARSE_MS must be between 0 and 10000.');
    end if;
    if l_awr_mode not in ('AUTO', 'YES', 'NO') then
      raise_application_error(-20023, 'AWR must be AUTO, YES or NO');
    end if;

    -- Outside the main block on purpose: if another test holds the lock
    -- we must fail WITHOUT the cleanup below, which would touch its run.
    acquire_lock;

    begin

      dbms_application_info.set_module(c_ctl_module, l_kind);

      -- A run still RUNNING here was killed (client gone, session killed).
      update pinx_run
      set    status = 'FAILED', ended_at = nvl(ended_at, systimestamp),
             error_text = nvl(error_text, 'aborted: controller session ended before the run finished')
      where  status = 'RUNNING';
      update pinx_ctl set phase = 'RUN' where id = 1 and phase = 'MEASURE';
      commit;

      -- The workers from step 2 must be running, every one of them.
      select njobs, think_ms, phase into l_njobs, l_think, l_phase from pinx_ctl where id = 1;
      select count(*) into l_running from user_scheduler_running_jobs
      where  job_name like c_job_prefix||'%';
      select count(*) into l_alive from pinx_pool
      where  ended_at is null and last_beat > systimestamp - interval '15' second;
      if l_phase <> 'RUN' or l_njobs is null or l_running < l_njobs or l_alive < l_njobs then
        raise_application_error(-20013,
          'The workers are not running ('||l_running||' worker jobs running, '||nvl(l_alive, 0)||
          ' with a recent heartbeat, '||nvl(l_njobs, 0)||' expected). Start them with ./2_start_workers.sh.');
      end if;

      -- The DDL works from the top of the table down; P1, which the hot
      -- query reads, is never touched.
      select partition_name bulk collect into l_parts
      from   user_tab_partitions where table_name = 'T'
      order  by partition_position desc;
      l_npart := l_parts.count;
      if l_npart < p_nddl + 10 then
        raise_application_error(-20021,
          'Table T has only '||l_npart||' partitions left, '||(p_nddl + 10)||
          ' are needed. Rebuild it with ./1_build.sh.');
      end if;

      say('---- '||l_kind||' test: '||l_njobs||' workers already running, '||l_npart||
          ' partitions, '||p_parse_ms||' ms per hard parse, '||p_nddl||' DDLs over '||
          p_secs||' s (+'||p_warmup||' s settle)');

      l_ash := case when instr(nvl(param('control_management_pack_access'), 'NONE'), 'DIAGNOSTIC') > 0
                    then 'Y' else 'N' end;
      l_cpu   := to_number(param('cpu_count'));
      l_cinv  := param('cursor_invalidation');
      select version_full, instance_number into l_ver, l_inst from v$instance;

      -- AWR (Diagnostics Pack): AUTO uses it only when the pack is enabled.
      if l_awr_mode = 'YES' and l_ash = 'N' then
        raise_application_error(-20024,
          'AWR = YES but control_management_pack_access does not include DIAGNOSTIC.');
      end if;
      l_awr := case when l_awr_mode <> 'NO' and l_ash = 'Y' then 'Y' else 'N' end;

      insert into pinx_run (kind, status, njobs, npart, nddl, secs, warmup, parse_ms, think_ms, started_at,
                            db_version, con_name, cpu_count, sys_cursor_inval, ash_enabled,
                            awr_enabled, awr_dbid, inst_num)
      values (l_kind, 'RUNNING', l_njobs, l_npart, p_nddl, p_secs, p_warmup, p_parse_ms, l_think, systimestamp,
              l_ver, sys_context('userenv', 'con_name'), l_cpu, l_cinv, l_ash,
              l_awr, to_number(sys_context('userenv', 'con_dbid')), l_inst)
      returning run_id into l_run;

      -- This test's hard-parse cost, and enough worker lifetime to finish.
      update pinx_ctl
      set    parse_ms = p_parse_ms,
             deadline = greatest(deadline, systimestamp + numtodsinterval(p_warmup + p_secs + 300, 'second'))
      where  id = 1;
      commit;

      -- Let the workers settle (start-up parses, or the tail of a previous test).
      say('workers settling for '||p_warmup||' s');
      dbms_session.sleep(p_warmup);

      -- AWR snapshot just before the window (and one just after it), so
      -- an AWR report between the two covers exactly this run.
      if l_awr = 'Y' then
        begin
          l_snap_b := awr_snapshot;
          say('AWR snapshot '||l_snap_b||' (before)');
        exception when others then
          if l_awr_mode = 'YES' then raise; end if;
          say('AWR snapshot not possible ('||sqlerrm||') - continuing without AWR');
          l_awr := 'N';
        end;
      end if;

      -- Open the measurement window: workers snapshot their counters first.
      update pinx_ctl set run_id = l_run, phase = 'MEASURE' where id = 1;
      commit;
      wait_for('worker baseline snapshots',
               q'[select count(distinct worker) from pinx_worker_snap where run_id = :1 and phase = 'B']',
               l_run, l_njobs, 60);
      sys_snap(l_run, 'B');

      select max(sql_id) into l_sql_id from pinx_cursor_snap where run_id = l_run and phase = 'B';
      if l_sql_id is null then
        raise_application_error(-20012, 'Hot cursor not found in V$SQL.');
      end if;
      update pinx_run set window_start = systimestamp, sql_id = l_sql_id where run_id = l_run;
      commit;
      say('window open (hot cursor sql_id '||l_sql_id||')');

      -- The DDL. IMMEDIATE is the 19c default; set it explicitly so a
      -- system-level DEFERRED setting cannot change the result.
      execute immediate 'alter session set cursor_invalidation = immediate';
      execute immediate 'alter session set ddl_lock_timeout = 60';
      l_interval := round(p_secs / (p_nddl + 1), 2);

      for i in 1 .. p_nddl loop
        dbms_session.sleep(l_interval);
        -- Settled state after the previous DDL = state before this one.
        l_sig := cursor_sig(l_sql_id);
        update pinx_ddl set cursor_settled = l_sig where run_id = l_run and seq = i - 1;
        l_sql := case l_kind
                   when 'DROP' then             -- the highest partition still there
                     'alter table t drop partition '||lower(l_parts(i))||' update indexes'
                   else                         -- always the highest partition
                     'alter table t exchange partition '||lower(l_parts(1))||
                     ' with table t_x including indexes without validation'
                 end;
        l_t0 := systimestamp;
        execute immediate l_sql;
        l_ms := elapsed_ms(l_t0);
        insert into pinx_ddl (run_id, seq, ddl_text, started_at, elapsed_ms, cursor_before)
        values (l_run, i, l_sql, l_t0, l_ms, l_sig);
        commit;
        say('DDL '||i||'/'||p_nddl||' ('||l_ms||' ms): '||l_sql);
      end loop;
      dbms_session.sleep(l_interval);       -- quiet tail: let the last storm finish
      l_sig := cursor_sig(l_sql_id);
      update pinx_ddl set cursor_settled = l_sig where run_id = l_run and seq = p_nddl;

      sys_snap(l_run, 'E');
      update pinx_run set window_end = systimestamp where run_id = l_run;
      commit;
      say('window closed');
      if l_awr = 'Y' then
        l_snap_e := awr_snapshot;
        say('AWR snapshot '||l_snap_e||' (after)');
      end if;
      update pinx_run
      set    awr_enabled = l_awr, awr_snap_begin = l_snap_b, awr_snap_end = l_snap_e
      where  run_id = l_run;

      -- Close the window; the workers take their end snapshot and carry on.
      update pinx_ctl set phase = 'RUN' where id = 1;
      commit;
      wait_for('worker end snapshots',
               'select count(*) from pinx_worker where run_id = :1 and end_at is not null',
               l_run, l_njobs, 60);

      if l_ash = 'Y' then
        begin
          -- Keep the raw samples: the in-memory ASH buffer wraps eventually.
          execute immediate q'[
            insert into pinx_ash_sample
              (run_id, sample_id, sample_time, session_id, session_serial#, module, action,
               session_state, event, wait_class, sql_id, sql_opname, blocking_session, time_waited)
            select :1, h.sample_id, h.sample_time, h.session_id, h.session_serial#, h.module,
                   h.action, h.session_state, h.event, h.wait_class, h.sql_id, h.sql_opname,
                   h.blocking_session, h.time_waited
            from   v$active_session_history h, pinx_run r
            where  r.run_id = :2
            and    h.sample_time between r.window_start and r.window_end
            and    h.module in (:3, :4)]' using l_run, l_run, c_module, c_ctl_module;
          insert into pinx_ash (run_id, event, samples)
          select l_run, nvl(event, 'ON CPU'), count(*)
          from   pinx_ash_sample
          where  run_id = l_run and module = c_module
          group  by nvl(event, 'ON CPU');
          say('ASH: '||sql%rowcount||' events captured');
        exception when others then
          say('ASH not readable ('||sqlerrm||') - skipped');
          l_ash := 'N';
        end;
      end if;

      select status into l_status from user_objects
      where  object_name = 'PINX_HOT_LOOP' and object_type = 'PROCEDURE';
      update pinx_run
      set    status = 'DONE', ended_at = systimestamp, ash_enabled = l_ash,
             worker_proc_status = l_status
      where  run_id = l_run;
      commit;
      say(l_kind||' test run '||l_run||' complete; the workers keep running');

    exception
      when others then
        declare
          l_err varchar2(4000) := substr(sqlerrm||chr(10)||dbms_utility.format_error_backtrace, 1, 4000);
        begin
          rollback;
          update pinx_ctl set phase = 'RUN' where id = 1 and phase = 'MEASURE';
          if l_run is not null then
            update pinx_run set status = 'FAILED', ended_at = systimestamp, error_text = l_err
            where  run_id = l_run;
          end if;
          commit;
          say('TEST FAILED: '||l_err);
          dbms_application_info.set_module(null, null);
          release_lock;
        end;
        raise;
    end;
    dbms_application_info.set_module(null, null);
    release_lock;
  end run_case;


  function num(p in number) return varchar2 is
  begin
    return nvl(to_char(round(p, 1), 'FM999999990.0', q'[NLS_NUMERIC_CHARACTERS='.,']'), 'null');
  end num;

  function secs_between(p_t1 in timestamp, p_t0 in timestamp) return number is
    l_iv interval day(3) to second(6) := p_t1 - p_t0;
  begin
    return extract(day from l_iv) * 86400 + extract(hour from l_iv) * 3600
         + extract(minute from l_iv) * 60 + extract(second from l_iv);
  end secs_between;

  -- JSON string literal; '<' escaped so data can never close the script tag.
  function js(p in varchar2) return varchar2 is
  begin
    return '"'||replace(replace(replace(replace(p, '\', '\\'), '"', '\"'), '<', '<'), chr(10), ' ')||'"';
  end js;

  function timeline_html(p_drop in number, p_exch in number)
    return sys.odcivarchar2list pipelined is
    l_out   sys.odcivarchar2list := sys.odcivarchar2list();
    l_cur   sys_refcursor;
    l_fail  number := 0;
    l_any   number := 0;
    l_kind  varchar2(10);
    l_name  varchar2(100);
    l_exp   varchar2(30);
    l_act   varchar2(30);
    l_res   varchar2(10);
    l_inval number;
    l_hp    number;
    l_pinw  number;
    l_pinus number;
    l_ashp  number;
    l_execs number;
    l_wsec  number;

    procedure add(p in varchar2) is
    begin
      l_out.extend;
      l_out(l_out.count) := p;
    end add;

    -- Append a multi-line template, one output row per line.
    procedure add_text(p in varchar2) is
      l_pos pls_integer := 1;
      l_nl  pls_integer;
    begin
      loop
        l_nl := instr(p, chr(10), l_pos);
        if l_nl = 0 then add(substr(p, l_pos)); exit; end if;
        add(substr(p, l_pos, l_nl - l_pos));
        l_pos := l_nl + 1;
      end loop;
    end add_text;

    function wdelta(p_run number, p_name varchar2, p_time boolean default false) return number is
      l_v  number;
      l_us number;
    begin
      select nvl(sum(case phase when 'E' then val     else -val     end), 0),
             nvl(sum(case phase when 'E' then time_us else -time_us end), 0)
      into   l_v, l_us
      from   pinx_worker_snap where run_id = p_run and name = p_name;
      return case when p_time then l_us else l_v end;
    end wdelta;
  begin
    add_text(c_tl_head);
    add('<script>');
    add('window.PINX = {generated: '||js(to_char(sysdate, 'YYYY-MM-DD HH24:MI'))||', runs: [], checks: []};');

    for r in (select * from pinx_run where run_id in (p_drop, p_exch)
              order by case kind when 'DROP' then 1 else 2 end) loop
      l_wsec := secs_between(r.window_end, r.window_start);
      select count(case when cursor_settled <> cursor_before then 1 end) into l_inval
      from   pinx_ddl where run_id = r.run_id;
      l_hp    := wdelta(r.run_id, 'stat: parse count (hard)');
      l_pinw  := wdelta(r.run_id, 'wait: cursor: pin S wait on X');
      l_pinus := wdelta(r.run_id, 'wait: cursor: pin S wait on X', true);
      select count(*) into l_ashp from pinx_ash_sample
      where  run_id = r.run_id and module = c_module and event = 'cursor: pin S wait on X';
      select nvl(sum(execs_window), 0) into l_execs from pinx_worker where run_id = r.run_id;

      add('PINX.runs.push({id: '||r.run_id||', kind: '||js(r.kind)||', window: '||num(l_wsec)||
          ', njobs: '||r.njobs||', npart: '||r.npart||', nddl: '||r.nddl||', cpu: '||nvl(r.cpu_count, 0)||
          ', ver: '||js(r.db_version)||', con: '||js(r.con_name)||', ashok: '||js(nvl(r.ash_enabled, 'N'))||
          ', awr: '||js(nvl(r.awr_enabled, 'N'))||', snapb: '||nvl(r.awr_snap_begin, 0)||
          ', snape: '||nvl(r.awr_snap_end, 0)||
          ', ashfile: '||js('pinx_run'||r.run_id||'_'||lower(r.kind)||'_ash.html')||
          ', awrfile: '||js('pinx_run'||r.run_id||'_'||lower(r.kind)||'_awr.html')||',');
      add('  m: {inval: '||l_inval||', hp: '||l_hp||', pinw: '||l_pinw||', pinms: '||round(l_pinus / 1000)||
          ', ashpin: '||l_ashp||', eps: '||nvl(round(l_execs / nullif(l_wsec, 0)), 0)||'},');
      add('  ddl: [');
      for d in (select started_at, elapsed_ms, ddl_text,
                       case when cursor_settled is null then '?'
                            when cursor_settled = cursor_before then 'N' else 'Y' end inv
                from   pinx_ddl where run_id = r.run_id order by seq) loop
        add('    ['||num(secs_between(d.started_at, r.window_start))||', '||num(d.elapsed_ms)||', '||
            js(d.inv)||', '||js(d.ddl_text)||'],');
      end loop;
      add('  ],');
      -- [seconds, pin S wait on X, library cache, cursor mutex / pin S, other, CPU]
      add('  ash: [');
      for a in (select sample_time,
                       count(case when event = 'cursor: pin S wait on X' then 1 end) pin,
                       count(case when event like 'library cache%' then 1 end) lib,
                       count(case when event like 'cursor:%' and event <> 'cursor: pin S wait on X' then 1 end) mtx,
                       count(case when session_state = 'ON CPU' then 1 end) cpu,
                       count(*) tot
                from   pinx_ash_sample
                where  run_id = r.run_id and module = c_module
                group  by sample_id, sample_time
                order  by sample_time) loop
        add('    ['||num(secs_between(a.sample_time, r.window_start))||','||a.pin||','||a.lib||','||a.mtx||','||
            (a.tot - a.pin - a.lib - a.mtx - a.cpu)||','||a.cpu||'],');
      end loop;
      add('  ]});');
    end loop;

    -- Checks come from the view through dynamic SQL: the view is created
    -- after this package, so a static reference would not compile on a
    -- first install.
    open l_cur for
      'select kind, check_name, expected, actual, result from pinx_v_check
       where run_id in (:1, :2) order by run_id, ord' using p_drop, p_exch;
    loop
      fetch l_cur into l_kind, l_name, l_exp, l_act, l_res;
      exit when l_cur%notfound;
      l_any := l_any + 1;
      if l_res <> 'PASS' then l_fail := l_fail + 1; end if;
      add('PINX.checks.push(['||js(l_kind)||', '||js(l_name)||', '||js(l_exp)||', '||
          js(nvl(l_act, '-'))||', '||js(l_res)||']);');
    end loop;
    close l_cur;
    add('PINX.overall = '||js(case when l_any = 0 or l_fail > 0 then 'FAIL' else 'PASS' end)||';');
    add('</script>');
    add_text(c_tl_js);

    for i in 1 .. l_out.count loop
      pipe row(l_out(i));
    end loop;
    return;
  end timeline_html;

  -- -------------------------------------------------------------------
  procedure purge_all is
  begin
    acquire_lock;
    stop_workers(30);
    drop_if_exists('T_X');
    drop_if_exists('T');
    delete pinx_ash_sample;  delete pinx_ash;  delete pinx_ddl;  delete pinx_cursor_snap;  delete pinx_sys_snap;
    delete pinx_worker_snap;  delete pinx_worker;  delete pinx_run;
    commit;
    release_lock;
  end purge_all;

end pinx_lab;
/
set define on

-- ---------------------------------------------------------------------
-- The worker procedure PINX_HOT_LOOP is generated by pinx_lab.create_worker
-- (template c_worker_tpl in the package body) and regenerated after every
-- table rebuild. It needs T to compile: on a first install create a
-- placeholder, which build_table() replaces before every run.
-- ---------------------------------------------------------------------
declare
  c number;
begin
  select count(*) into c from user_tables where table_name = 'T';
  if c = 0 then
    execute immediate 'create table t (id number not null, grp number not null, pad varchar2(100))';
  end if;
end;
/
exec pinx_lab.create_worker

-- ---------------------------------------------------------------------
-- Report views
-- ---------------------------------------------------------------------
-- Begin/end deltas for worker counters, summed over all workers.
create or replace view pinx_v_worker_delta as
select run_id, name,
       sum(case phase when 'E' then val     else -val     end) as delta,
       sum(case phase when 'E' then time_us else -time_us end) as delta_time_us
from   pinx_worker_snap
group  by run_id, name;

create or replace view pinx_v_sys_delta as
select run_id, name,
       sum(case phase when 'E' then val     else -val     end) as delta,
       sum(case phase when 'E' then time_us else -time_us end) as delta_time_us
from   pinx_sys_snap
group  by run_id, name;

create or replace view pinx_v_cursor as
select run_id,
       max(ddl_no_invalidate)  as ddl_no_invalidate,
       max(is_rolling_invalid) as rolling_invalid,
       max(object_status)      as object_status
from   pinx_cursor_snap
where  phase = 'E'
group  by run_id;

-- Per DDL: did it invalidate the hot cursor?
create or replace view pinx_v_ddl as
select d.*,
       case when cursor_settled is null       then null
            when cursor_settled = cursor_before then 'N' else 'Y' end as invalidated
from   pinx_ddl d;

-- One row per (run, metric); text values so they line up in the report.
create or replace view pinx_v_metric as
with r as (
  select r.*,
         extract(day    from (window_end - window_start)) * 86400
       + extract(hour   from (window_end - window_start)) * 3600
       + extract(minute from (window_end - window_start)) * 60
       + extract(second from (window_end - window_start)) as window_s
  from   pinx_run r
),
wd as (select * from pinx_v_worker_delta),
w as (select run_id, sum(execs_window) execs, count(end_at) ended, count(*) workers
      from pinx_worker group by run_id)
select r.run_id, 10 ord, 'DDL statements executed' metric,
       to_char((select count(*) from pinx_ddl d where d.run_id = r.run_id)) val from r
union all
select r.run_id, 11, 'DDL elapsed, avg / max (ms)',
       (select round(avg(elapsed_ms), 1)||' / '||round(max(elapsed_ms), 1)
        from pinx_ddl d where d.run_id = r.run_id) from r
union all
select r.run_id, 20, 'Hot cursor: DDLs that invalidated it',
       (select count(case invalidated when 'Y' then 1 end)||' of '||count(*)
        from pinx_v_ddl d where d.run_id = r.run_id) from r
union all
select r.run_id, 23, 'Hot cursor: ddl_no_invalidate (at end)', c.ddl_no_invalidate from r join pinx_v_cursor c on c.run_id = r.run_id
union all
select r.run_id, 24, 'Hot cursor: is_rolling_invalid (at end)', c.rolling_invalid  from r join pinx_v_cursor c on c.run_id = r.run_id
union all
select r.run_id, 30, 'Workers: hot query executions', to_char(w.execs) from r join w on w.run_id = r.run_id
union all
select r.run_id, 31, 'Workers: executions per second', to_char(round(w.execs / nullif(r.window_s, 0)))
from r join w on w.run_id = r.run_id
union all
select r.run_id, 40, 'Workers: hard parses', to_char(nvl(
         (select delta from wd where wd.run_id = r.run_id and wd.name = 'stat: parse count (hard)'), 0)) from r
union all
select r.run_id, 41, 'Workers: parse time elapsed (ms)', to_char(10 * nvl(
         (select delta from wd where wd.run_id = r.run_id and wd.name = 'stat: parse time elapsed'), 0)) from r
union all
select r.run_id, 50, 'Workers: waits on cursor: pin S wait on X', to_char(nvl(
         (select delta from wd where wd.run_id = r.run_id and wd.name = 'wait: cursor: pin S wait on X'), 0)) from r
union all
select r.run_id, 51, 'Workers: time in cursor: pin S wait on X (ms)', to_char(round(nvl(
         (select delta_time_us from wd where wd.run_id = r.run_id and wd.name = 'wait: cursor: pin S wait on X'), 0) / 1000)) from r
union all
-- Every other cursor / library cache wait the workers saw in any run.
select r.run_id, 60, 'Workers: waits on '||substr(e.name, 7), to_char(nvl(
         (select delta from wd where wd.run_id = r.run_id and wd.name = e.name), 0))
from r, (select distinct name from wd
         where name like 'wait: %' and name <> 'wait: cursor: pin S wait on X' and delta > 0) e
union all
select r.run_id, 70, 'ASH samples: '||a.event, to_char(a.samples)
from r join pinx_ash a on a.run_id = r.run_id
where a.event like 'cursor:%' or a.event like 'library cache%'
union all
select r.run_id, 80, 'Instance: hard parses', to_char(nvl(
         (select delta from pinx_v_sys_delta s where s.run_id = r.run_id and s.name = 'stat: parse count (hard)'), 0)) from r
union all
select r.run_id, 81, 'Instance: waits on cursor: pin S wait on X', to_char(nvl(
         (select delta from pinx_v_sys_delta s where s.run_id = r.run_id and s.name = 'wait: cursor: pin S wait on X'), 0)) from r;

-- Pass/fail expectations per run.
create or replace view pinx_v_check as
with m as (
  select r.run_id, r.kind, r.status, r.nddl, r.njobs, r.worker_proc_status, r.ash_enabled,
         (select count(*) from pinx_ash_sample a where a.run_id = r.run_id
          and a.module = 'PINX_WORKER' and a.event = 'cursor: pin S wait on X') ash_pin,
         c.ddl_no_invalidate,
         (select count(case invalidated when 'Y' then 1 end) from pinx_v_ddl d
          where d.run_id = r.run_id) inval_ddls,
         (select count(*) from pinx_ddl d where d.run_id = r.run_id) ddls,
         (select count(end_at) from pinx_worker w where w.run_id = r.run_id) workers_ended,
         (select count(distinct worker) from pinx_worker_snap s
          where s.run_id = r.run_id and s.phase = 'E') workers_measured,
         nvl((select delta from pinx_v_worker_delta d
              where d.run_id = r.run_id and d.name = 'wait: cursor: pin S wait on X'), 0) pin_waits,
         nvl((select delta from pinx_v_worker_delta d
              where d.run_id = r.run_id and d.name = 'stat: parse count (hard)'), 0) hard_parses
  from   pinx_run r left join pinx_v_cursor c on c.run_id = r.run_id
)
select run_id, kind, 1 ord, 'Run completed' check_name, 'DONE' expected, status actual,
       case when status = 'DONE' then 'PASS' else 'FAIL' end result from m
union all
select run_id, kind, 2, 'DDL statements executed', to_char(nddl), to_char(ddls),
       case when ddls = nddl then 'PASS' else 'FAIL' end from m
union all
select run_id, kind, 3, 'Workers measured', to_char(njobs), to_char(workers_measured),
       case when workers_measured = njobs and workers_ended = njobs then 'PASS' else 'FAIL' end from m
union all
select run_id, kind, 4, 'Worker procedure still VALID', 'VALID', worker_proc_status,
       case when worker_proc_status = 'VALID' then 'PASS' else 'FAIL' end from m
union all
select run_id, kind, 5, 'DDLs that invalidated the hot cursor',
       case kind when 'DROP' then to_char(nddl) else '0' end, to_char(inval_ddls),
       case when kind = 'DROP'     and inval_ddls = nddl then 'PASS'
            when kind = 'EXCHANGE' and inval_ddls = 0    then 'PASS' else 'FAIL' end from m
union all
select run_id, kind, 6, 'Waits on cursor: pin S wait on X',
       case kind when 'DROP' then '> 0' else '0' end, to_char(pin_waits),
       case when kind = 'DROP'     and pin_waits > 0 then 'PASS'
            when kind = 'EXCHANGE' and pin_waits = 0 then 'PASS' else 'FAIL' end from m
union all
select run_id, kind, 7, 'Worker hard parses',
       case kind when 'DROP' then '> 0' else '0' end, to_char(hard_parses),
       case when kind = 'DROP'     and hard_parses > 0 then 'PASS'
            when kind = 'EXCHANGE' and hard_parses = 0 then 'PASS' else 'FAIL' end from m
union all
-- Y = skipped by a DDL, not executed since; X = skipped and executed
-- since (what a hot cursor shows). Both mean fine-grained invalidation
-- left the cursor alone.
select run_id, kind, 8, 'ddl_no_invalidate', 'Y or X', ddl_no_invalidate,
       case when ddl_no_invalidate in ('Y', 'X') then 'PASS' else 'FAIL' end
from m where kind = 'EXCHANGE'
union all
-- Only when ASH was available (Diagnostics Pack): independent evidence
-- from Oracle's own sampler that the pile-up happened (or did not).
select run_id, kind, 9, 'ASH samples on pin S wait on X',
       case kind when 'DROP' then '> 0' else '0' end, to_char(ash_pin),
       case when kind = 'DROP'     and ash_pin > 0 then 'PASS'
            when kind = 'EXCHANGE' and ash_pin = 0 then 'PASS' else 'FAIL' end
from m where ash_enabled = 'Y';

-- CREATE ... with compilation errors is only a warning in SQL*Plus;
-- turn it into a hard failure.
declare
  l_msg varchar2(4000);
begin
  for e in (select name, type, line, position, text from user_errors
            where name in ('PINX_LAB', 'PINX_HOT_LOOP', 'PINX_PARSE_COST', 'PINX_PARSE_MARKER', 'PINX_V_WORKER_DELTA', 'PINX_V_SYS_DELTA',
                           'PINX_V_CURSOR', 'PINX_V_DDL', 'PINX_V_METRIC', 'PINX_V_CHECK')
            order by name, type, sequence) loop
    l_msg := substr(l_msg||e.type||' '||e.name||' line '||e.line||': '||e.text||chr(10), 1, 3900);
  end loop;
  for o in (select object_name, object_type from user_objects
            where object_name in ('PINX_LAB', 'PINX_HOT_LOOP', 'PINX_PARSE_COST', 'PINX_PARSE_MARKER',
                                  'PINX_V_METRIC', 'PINX_V_CHECK')
            and status <> 'VALID') loop
    l_msg := substr(l_msg||o.object_type||' '||o.object_name||' is INVALID'||chr(10), 1, 3900);
  end loop;
  if l_msg is not null then
    raise_application_error(-20002, 'Install failed:'||chr(10)||l_msg);
  end if;
end;
/

prompt Harness installed.
set feedback on
