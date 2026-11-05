# partition_exchange

A repeatable Oracle **19c** test case that answers one question, and
proves the answer with Oracle's own diagnostics:

> On a busy partitioned table, does partition maintenance on a partition
> that the hot query never reads still disturb that query?

It compares two ways of getting rid of a partition's data while 24
sessions keep running the same loop: the hot query on partition `P1`,
then an `INSERT` of one row into the current partition `PCUR` and a
`COMMIT`.

| Test | DDL | Hot query cursor | Insert cursor | Effect on the sessions |
|------|-----|------------------|---------------|------------------------|
| **DROP** (step 3) | `ALTER TABLE t DROP PARTITION p400 UPDATE INDEXES` | **Invalidated** by every drop | Invalidated by every drop | One session hard-parses the hot query (2 s) while all the others queue on **`cursor: pin S wait on X`** (a hard-parse pile-up). |
| **EXCHANGE** (step 4) | `ALTER TABLE t EXCHANGE PARTITION p390 WITH TABLE t_x INCLUDING INDEXES WITHOUT VALIDATION` | **Stays valid** (fine-grained cursor invalidation, 12.2+) | Invalidated by every exchange | The insert is re-parsed in a few milliseconds: short waits only (0.14 s in total over 10 exchanges). No pile-up. |

The hot query reads only `P1` and the inserts go only to `PCUR`; neither
DDL touches those partitions. The DROP pile-up is overhead caused by
cursor invalidation. That's why "exchange the partition out, then drop
the swapped-out table later" is the low-impact way to age out data on a
busy system.

The `INSERT ... VALUES` cursor is invalidated by both DDLs (measured on
19.27). Its parse is cheap, so this costs milliseconds. A DML statement
with an expensive parse would be expected to pile up after an EXCHANGE
as well; this harness does not test that.

**Read the illustrated guide first:** [`docs/guide.html`](docs/guide.html)
explains the mechanism with diagrams, shows the measurements from a real
run, and quotes the scripts that produced them.

**Step by step:** [`docs/story.html`](docs/story.html) is a run sheet:
what you type, which script runs next, and what the screen showed.

The test is split into five scripts you run one after the other:

| Script | Runs as | What it does |
|--------|---------|--------------|
| `./1_build.sh` | DBA, then PINX | Creates the user `PINX`, installs the harness objects, builds table `T` (400 partitions, 400,000 rows, plus the empty current partition `PCUR`) and `T_X`. |
| `./2_start_workers.sh` | PINX | Starts 24 background jobs. Each one runs the hot query, inserts a row into `PCUR` and commits, over and over. Then shows them working. No DDL. They keep running. |
| `./3_test_drop.sh` | PINX | The DROP test, against the running workers. Prints the results and writes the reports. |
| `./4_test_exchange.sh` | PINX | The EXCHANGE test, against the same workers. Prints both tests side by side. |
| `./5_cleanup.sh` | DBA | Stops the workers and drops the user with everything in it. |

The harness:

* **checks** every expectation and ends with `OVERALL: PASS` or
  `OVERALL: FAIL`, with a non-zero exit code on FAIL;
* **takes AWR snapshots** right before and after each test's measurement
  window;
* **writes the evidence as HTML** into `reports/`:
  * a graphical ASH timeline of both tests, side by side;
  * Oracle's own **ASH report** for each test;
  * Oracle's own **AWR report** for each test.

---

## What the evidence looks like

From a real run of the five steps on 19.27 (2 CPUs, PDB, default
settings, 5 Nov 2026, 12:50 to 12:54). The same run is shown in
`docs/guide.html` and `docs/story.html`.

**The timeline** (`reports/pinx_timeline_r<A>_r<B>.html`):
* **DROP test:** after every red DDL marker, a red column of 23 sessions
  waits on `cursor: pin S wait on X` for about 2 seconds.
* **EXCHANGE test:** a flat line of one or two sessions on CPU, with grey
  markers where the DDL did nothing to the cursor.

**Oracle AWR report**, Top 10 Foreground Events:

```
DROP        cursor: pin S wait on X   279 waits   460.4 s   87.5% DB time   Concurrency
            DB CPU                                 55.1 s   10.5% DB time
EXCHANGE    DB CPU                                 45.5 s   78.8% DB time
            cursor: pin S wait on X    43 waits     0.1 s    0.2% DB time   (the insert's re-parses)
```

**Oracle ASH report**, Top User Events:

```
DROP        cursor: pin S wait on X   90.4%   7.69 average active sessions
EXCHANGE    CPU + Wait for CPU       100.0%   0.64 average active sessions
```

**Text report** (`report.sql`, licence-free counters):

```
Metric                                                        A: DROP          B: EXCHANGE
Hot cursor: DDLs that invalidated it                         10 of 10              0 of 10
Insert cursor: DDLs that invalidated it                      10 of 10             10 of 10
Hot cursor: ddl_no_invalidate (at end)                              N                    X
Workers: executions per second                                    798                 1162
Workers: rows inserted per second                                 798                 1162
Workers: hard parses                                               52                   10
Workers: waits on cursor: pin S wait on X                         233                   43
Workers: time in cursor: pin S wait on X (ms)                  460032                  136
ASH samples: pin S wait on X, hot query                           469                    0
ASH samples: pin S wait on X, insert                                0                    0
OVERALL: PASS (17 checks)
```

So the DROP test lost a third of its throughput, and 87.5% of its database
time was sessions waiting for one another to rebuild a cursor that the
DDL had no reason to touch. In the EXCHANGE test the 10 hard parses are
the insert's, one per exchange.

---

## Requirements

* **Oracle Database 19c**. That's the only release it's written and
  verified for (tested on 19.27 in a PDB). The preflight check refuses
  anything older and warns on newer.
* A **PDB** (or a non-CDB). Not `CDB$ROOT`, and not `SYS`/`SYSTEM`.
* **DBA access** for steps 1 and 5 (creating and dropping the user), as
  `/ as sysdba` on the database host or as a user like `SYSTEM` over the
  network. Steps 2 to 4 run as the test user `PINX`.
* `job_queue_processes >= NJOBS + 1` (25 with the defaults).
* About 160 MB in the schema's default tablespace, plus about 150 MB per
  hour of inserts while the workers run (the quota is 500 MB).
* SQLcl (`sql`) or SQL\*Plus (`sqlplus`), and `bash`.
* **Licensing:**
  * The PASS/FAIL verdicts come from session counters (`V$SESSION_EVENT`,
    `V$MYSTAT`, `V$SQL`) and need **no licence**.
  * ASH, AWR snapshots and the ASH/AWR reports need the **Diagnostics
    Pack**. With `AWR = AUTO` (the default) they're used only when
    `control_management_pack_access` includes `DIAGNOSTIC`. Otherwise
    they're never touched, and the timeline page shows the counters
    only.

> **Test databases only.** The harness creates and drops a user, runs 24
> scheduler jobs from step 2 until step 5 (at most `WORKER_MINUTES`),
> burns CPU on purpose during hard parses, and takes two AWR snapshots per
> test. It does **not** need `ALTER SYSTEM` and never flushes the shared
> pool.

## Quick start

Once: say how to connect, in `connection.conf`. The defaults suit running
on the database host:

```bash
PINX_SERVICE=//localhost:1521/pdb1.world   # the PDB service PINX connects to
DBA_CONNECT='/ as sysdba'                   # or 'system@//dbhost:1521/pdb1'
DBA_CONTAINER=PDB1                          # PDB to switch to after '/ as sysdba'
```

Then run the steps in order. Each one asks for the passwords it needs
(or set `PINX_PASSWORD` and `DBA_PASSWORD` in the environment):

```bash
./1_build.sh            # user, objects, data                          ~30 s
./2_start_workers.sh    # 24 workers: hot query, insert, commit        ~10 s
./run.sh status         # optional: watch them, any time
./3_test_drop.sh        # DROP test + reports                          ~90 s
./4_test_exchange.sh    # EXCHANGE test + reports + comparison         ~90 s
./5_cleanup.sh          # workers stopped, user dropped                ~15 s

open reports/pinx_timeline_r1_r2.html
```

* Every script stops at the first error, with a non-zero exit code. Steps
  3 and 4 also exit non-zero if any check fails.
* Every script writes a timestamped log to `logs/`.
* Each script is safe to run again. You can repeat steps 3 and 4 as often
  as you like while the workers run; each DROP test uses up `NDDL` of the
  400 partitions.
* SQLcl is used if it's on the PATH, otherwise SQL\*Plus. Force one with
  `PINX_CLIENT=sqlplus` or `PINX_CLIENT=sql`.

Extra scripts, run as `PINX` with `./run.sh <name>`:

| Name | What it does |
|------|--------------|
| `status` | Each worker: its job, session, what it's doing right now, its heartbeat and executions. Then the hot query's executions per second and the rows inserted per second, measured over 5 s. |
| `state` | Where you are: the workers (how many run, what they are doing, the hot query and insert cursors' counters, executions and inserts per second), the row counts in `T` and `T_X` (counted with `COUNT(*)`: `PCUR`, the partitions the tests use, `P1`, `T_X`), and the tests run so far. Steps 1, 3 and 4 print it too (3 and 4 before and after the DDL). |
| `stop_workers` | Stops the workers, keeps everything else. Step 2 starts them again. |
| `report` | Prints the results and checks of the latest tests again. |
| `evidence` | Writes the `reports/` files again. |
| `preflight` | Checks the environment only. |

## What each step does

**1. Build** (`1_build.sh`):
* As the DBA, `admin/create_user.sql` creates `PINX` with direct grants.
  If `PINX` already exists, it's kept and gets the password you typed.
* As `PINX`, `build.sql` runs `preflight.sql`, then `setup.sql` (the
  result tables, the parse-cost function and type, the `PINX_LAB`
  package, the worker procedure and the report views), then
  `pinx_lab.build_table`.
* `build_table` creates `T` with `NPART` (400) range partitions of 1000
  rows each, plus the empty current partition `PCUR` (`VALUES LESS THAN
  (MAXVALUE)`), a local index on `GRP` and fresh statistics. It also
  creates the sequence `T_SEQ`, which starts above `P400`'s range, and
  an empty `T_X` for the exchange.

**2. Start the workers** (`2_start_workers.sh`): `pinx_lab.start_workers`
starts `NJOBS` (24) scheduler jobs, `PINX_W001` to `PINX_W024`. Each one
runs the hot query, inserts `INSERTS` (1) row into `PCUR`, commits,
pauses `THINK_MS` (20 ms), and repeats:

```sql
select /*+ qb_name(pinx) */ count(*)
from   t a, t b, t c, t d
where  a.id < 1000 and b.id < 1000 and c.id < 1000 and d.id < 1000
and    a.id = b.id and b.id = c.id and c.id = d.id
and    a.grp = 7
and    pinx_parse_marker(a.id) >= 0;

insert /*+ qb_name(pinx_ins) */ into t (id, grp, pad)
values (t_seq.nextval, mod(l_total, 50), 'current');
commit;
```

* The query prunes statically to `P1`. The insert's ids come from
  `T_SEQ`, so every row lands in `PCUR`. The `qb_name` hints tag both
  statements, because PL/SQL strips comments but keeps hints.
* With `INSERTS = 0` the workers run the hot query only, as in earlier
  versions of this harness.
* After every execution a worker reads the one-row table `PINX_CTL`,
  which says `RUN`, `MEASURE` (a test is measuring) or `STOP`.
* Every 2 seconds it writes a heartbeat to `PINX_POOL`. That's what
  `./run.sh status` and the tests use to see that it's alive.
* The sessions have `MODULE = PINX_WORKER`, so they also show up under
  that name in `V$SESSION`, ASH and Enterprise Manager.
* The workers stop when told to, or by themselves after `WORKER_MINUTES`
  (60), so they never run forever.

**3. DROP test and 4. EXCHANGE test** (`3_test_drop.sh`,
`4_test_exchange.sh`) each call `pinx_lab.run_case('DROP' | 'EXCHANGE',
...)`. Both follow the same steps, so they're directly comparable:

1. **Check the workers.** All 24 jobs must be running with a fresh
   heartbeat. Otherwise the test stops and tells you to run step 2.
2. **Let them settle** (`WARMUP`, 10 s). This keeps start-up parses, or
   the tail of a previous test, out of the measurement.
3. **Take an AWR snapshot**, if enabled.
4. **Open the measurement window** (`PINX_CTL` = `MEASURE`). Every worker
   snapshots its own session counters. The controller snapshots the
   instance counters and the hot cursor's `V$SQL` rows.
5. **Run `NDDL` (10) DDL statements** spread evenly over `SECS` (60 s):
   Both tests work on the partitions just below `PCUR` and never touch
   `PCUR` or `P1`.
   - The DROP test drops the highest partition, ten times: `p400`,
     `p399`, ... `p391` on a fresh table.
   - The EXCHANGE test exchanges the highest partition with `T_X` ten
     times (back and forth). After the DROP test that is `p390`, which
     still holds its 1,000 rows. Each exchange swaps the two segments:
     after an odd number the rows are in `T_X` and `p390` is empty;
     after ten they are back in `p390`.

   Before each DDL, and again once things have settled (just before the
   next DDL), the controller records a signature of the hot query cursor
   and of the insert cursor. If a signature changed, that DDL
   invalidated the cursor.

   The output shows, for each DDL: what the workers are doing 0.5 s
   after it, the rows in the dropped partition (DROP) or in the
   exchanged partition and `T_X` (EXCHANGE), and whether each of the two
   cursors was invalidated by the time of the next DDL.
6. **Close the window** (`PINX_CTL` = `RUN`). The workers take their end
   snapshots and carry on running. Then the second AWR snapshot.
7. **Copy the window's ASH rows** for the worker and controller sessions
   into `PINX_ASH_SAMPLE`. The evidence then survives after the
   in-memory ASH buffer wraps.

Then `evidence.sql` writes the HTML for the latest DROP and EXCHANGE
tests, and `report.sql` prints the comparison and the verdict. After
step 3 alone, it reports the DROP test on its own.

**5. Clean up** (`5_cleanup.sh`): as the DBA, `admin/drop_user.sql` tells
the workers to stop, waits up to 30 s for them, removes their jobs and
drops `PINX` with everything it owns. `./5_cleanup.sh --keep-user` runs
`cleanup.sql` as `PINX` instead: workers and harness objects go, the
user stays.

### Why `pinx_parse_marker` and `THINK_MS`?

They make the pile-up big and long enough for ASH, which samples active
sessions **once per second**, to see it reliably. Without them, a plain
four-way join re-parses in a few milliseconds:

* The pile-up after each DROP lasts a few hundred ms.
* The session counters still prove it: hundreds of waits and seconds of
  wait time.
* ASH mostly misses it.
* On a small box, 24 sessions in a tight loop also keep every CPU busy.
  Every session then shows up in ASH as "ON CPU" (the run queue), even
  while it's really waiting for the cursor.

So:

* **`PARSE_MS`** (default 2000) sets how much CPU each hard parse costs.
  `pinx_parse_marker` is a trivial function with **user-defined
  optimizer statistics** (`ASSOCIATE STATISTICS ... USING
  pinx_parse_cost`):
  * To estimate the predicate's selectivity, the optimizer calls
    `pinx_parse_cost.ODCIStatsSelectivity` during every hard parse.
  * That function burns `PARSE_MS` of CPU.
  * The hot query then parses like a complex production statement would,
    while executions stay cheap (well under 1 ms) and no extra memory is
    used.
* **`THINK_MS`** gives the sessions think time, as real users have.
  Average load stays well below the CPU count, so waits show up as waits.

`PARSE_MS = 0` gives the plain query back. The DROP test still passes the
cursor and counter checks; only the ASH picture gets thin.

## Reading the evidence

| Where | What to look at |
|-------|-----------------|
| **Timeline** (`pinx_timeline_*.html`) | Bars are ASH samples of the worker sessions, stacked by event. Numbered markers are the DDLs: **red** means it invalidated the hot cursor, **grey** means it didn't. Hover for details. The tiles above each chart are the licence-free counters. |
| **AWR report** (`pinx_run<N>_drop_awr.html`, `..._exchange_awr.html`) | *Top 10 Foreground Events by Total Wait Time*. DROP: `cursor: pin S wait on X` dominates DB time. EXCHANGE: DB CPU, and a fraction of a second of `cursor: pin S wait on X` from the insert's re-parses. *SQL ordered by Parse Calls* and the *Library Cache Activity* section tell the same story. |
| **ASH report** (`pinx_run<N>_*_ash.html`) | *Top User Events* and *Activity Over Time* for the exact measurement window. |
| **Text report** (`report.sql`) | All metrics side by side, the elapsed time of each DDL, whether it invalidated the hot query and the insert cursor, and the checks. |

| Metric | Meaning |
|--------|---------|
| **Hot cursor: DDLs that invalidated it** | The headline number: per DDL, did the hot cursor change between "just before" and "settled"? DROP: every time. EXCHANGE: never. |
| **Insert cursor: DDLs that invalidated it** | The same for the workers' `INSERT`. Both DDLs invalidate it every time. |
| **Workers: hard parses** | Hard parses in the worker sessions inside the window (`V$MYSTAT`). DROP: the hot query and the insert, plus recursive dictionary SQL, so more than the number of DDLs. EXCHANGE: one per exchange (the insert); 0 with `INSERTS = 0`. |
| **Workers: rows inserted per second** | Throughput of the insert. It runs in the same loop as the hot query, so it drops with it. |
| **Workers: waits / time on cursor: pin S wait on X** | The pile-up: sessions waiting for another session to finish building the cursor they need (the workers' own `V$SESSION_EVENT`). |
| **Workers: executions per second** | Throughput of the hot query. The DROP test loses everything while a pile-up lasts. |
| **ddl_no_invalidate** | `V$SQL.DDL_NO_INVALIDATE` at the end. In 19c the values are `N` (no DDL skipped this cursor), `Y` (a DDL skipped it and it hasn't run since) and `X` (a DDL skipped it and it has run since). A hot cursor after an exchange shows `X`. |
| **ASH samples** | Oracle's own sampler agreeing with the counters. The `pin S wait on X` samples are also split by statement (hot query, insert). |
| **Instance: ...** | `V$SYSSTAT` / `V$SYSTEM_EVENT` deltas for the window. They include background activity and the DDL's own recursive SQL. Use them as a cross-check. |

### Checks

Each test must have completed, run all `NDDL` statements, measured all
`NJOBS` workers, and left the worker procedure VALID. In addition:

| | DROP test | EXCHANGE test |
|---|---|---|
| DDLs that invalidated the hot cursor | `= NDDL` | `0` |
| Worker time in `cursor: pin S wait on X` | `> PARSE_MS` | `< PARSE_MS` |
| Worker hard parses | `> 0` | `<=` DDLs that invalidated the insert cursor |
| `ddl_no_invalidate` of the hot cursor | n/a | `Y` or `X` |
| ASH samples on `cursor: pin S wait on X` for the hot query (only with the Diagnostics Pack) | `> 0` | `0` |

The insert cursor is invalidated by both DDLs, so with `INSERTS > 0` the
worker-wide checks can't expect zero. One re-parse of the hot query
makes the other workers wait about `PARSE_MS` each, so a total below
`PARSE_MS` means no hot-query pile-up happened. The hard-parse limit
leaves room for the insert's re-parses only.

With `INSERTS = 0` the stricter checks apply: zero waits on
`cursor: pin S wait on X` and zero hard parses in the EXCHANGE test.

## Configuration

**How to connect:** `connection.conf` (see Quick start). A variable set in
the environment wins over the file, e.g. `DBA_CONTAINER=PDB2 ./1_build.sh`.
With an Oracle wallet, set `PINX_CONNECT='/@alias'` and no password is
asked for in steps 2 to 4.

**What to test:** `config.sql`. Every step includes it.

| Variable | Default | Used in step | Effect |
|----------|---------|--------------|--------|
| `NPART`    | 400  | 1 | Partitions in `T`, below the current partition `PCUR`. Each DROP test uses up `NDDL` of them. |
| `NJOBS`    | 24   | 2 | Concurrent worker sessions. A bigger pile-up per invalidation. Must be `<= job_queue_processes - 1`. |
| `THINK_MS` | 20   | 2 | Pause after each execution. Keep the average number of busy sessions well under `cpu_count`. |
| `INSERTS`  | 1    | 2 | Rows each worker inserts into `PCUR`, and commits, after each execution of the hot query. `0` = the hot query only. |
| `WORKER_MINUTES` | 60 | 2 | The workers stop by themselves after this long. A test extends it when it needs more time. |
| `NDDL`     | 10   | 3, 4 | DDL statements per test, the same for both. |
| `SECS`     | 60   | 3, 4 | Measurement window. The DDLs are spaced `SECS / (NDDL+1)` apart, with a quiet tail at the end. Keep the gap above about 1.5 x `PARSE_MS`. |
| `WARMUP`   | 10   | 3, 4 | Seconds the test waits, with the workers running, before the window opens. |
| `PARSE_MS` | 2000 | 2, 3, 4 | CPU cost of each hard parse of the hot query, which is about how long each pile-up lasts. `0` = the plain query. Each test applies its own value. |
| `AWR`      | AUTO | 3, 4 | `AUTO`: AWR snapshots and Oracle reports when the Diagnostics Pack is enabled. `YES`: required. `NO`: never. |

## Files

| File | Purpose |
|------|---------|
| `1_build.sh` ... `5_cleanup.sh` | The five steps. |
| `run.sh` | Runs one SQL script as `PINX`: `status`, `state`, `stop_workers`, `report`, `evidence`, `preflight`. |
| `connection.conf` | How to connect, as the DBA and as `PINX`. No passwords. |
| `config.sql` | What to test. |
| `lib/common.sh`, `lib/sqlcl.sql` | Shared by the shell scripts: connecting, logging, exit codes. |
| `admin/create_user.sql`, `admin/drop_user.sql` | Create or drop the test user, as a DBA (steps 1 and 5). |
| `build.sql` | Step 1 as `PINX`: `preflight.sql`, `setup.sql`, then the data. |
| `preflight.sql` | Checks version, container, privileges, `job_queue_processes`, quota, licence settings and parameters, and lists **every** problem at once. |
| `setup.sql` | Installs the result tables, the parse-cost function and type, the `PINX_LAB` package, the `PINX_HOT_LOOP` worker and the report views. It's idempotent and keeps earlier results. |
| `start_workers.sql`, `status.sql`, `stop_workers.sql` | Step 2 and the worker helpers. |
| `state.sql` | Where you are: workers, row counts in `T` and `T_X`, tests so far. Read-only. |
| `test_drop.sql`, `test_exchange.sql` | Steps 3 and 4: `state.sql`, the test, `state.sql`, then `evidence.sql` and `report.sql`. |
| `evidence.sql`, `lib/oracle_reports.sql` | Write the HTML timeline and Oracle's ASH/AWR reports to `reports/`. |
| `report.sql` | Read-only text comparison plus PASS/FAIL. |
| `cleanup.sql` | Stops the workers and drops every harness object, keeping the user (`5_cleanup.sh --keep-user`). |
| `docs/guide.html`, `docs/story.html` | The illustrated guide and the step-by-step run sheet. |
| `SPEC.md` | The original brief. Where the harness differs from it, see below. |

Results stay in `PINX_RUN`, `PINX_DDL`, `PINX_WORKER(_SNAP)`,
`PINX_SYS_SNAP`, `PINX_CURSOR_SNAP`, `PINX_ASH` and `PINX_ASH_SAMPLE`
until step 5, so you can query earlier tests (`select * from pinx_v_check
where run_id = :n`). For the AWR snapshot IDs of a test, see
`pinx_run.awr_snap_begin/awr_snap_end`. You can also produce any other
AWR report for that range, for example `@?/rdbms/admin/awrrpti.sql`.

## Robustness built in

* **Direct grants only.** The logic runs in definer-rights PL/SQL and in
  scheduler jobs, where roles are disabled. `SELECT_CATALOG_ROLE` is
  therefore *not* enough, and the preflight checks the direct grants.
* **One controller at a time.** Building, starting the workers and each
  test take a `DBMS_LOCK` lock that survives commits. A second one
  started meanwhile is refused with ORA-20030 and doesn't touch the
  active one.
* **A test never runs without its load.** It checks that every worker
  job is running and has sent a heartbeat in the last 15 s, and stops
  with ORA-20013 otherwise.
* **No orphaned load.** Workers stop by themselves after
  `WORKER_MINUTES`, even if nobody runs step 5. Rebuilding `T` (step 1)
  stops them first. A failed test records `FAILED` plus the error in
  `PINX_RUN` and leaves the workers running. A test left `RUNNING` by a
  killed session is marked `FAILED` by the next one.
* **The controller can't invalidate itself.** The `PINX_LAB` package
  touches `T` only through dynamic SQL. The worker procedure is
  regenerated after every table rebuild, before 24 jobs could race to
  recompile it.
* **Passwords stay out of sight.** The shell scripts send everything,
  including `CONNECT`, to the client on stdin. Passwords never appear
  in the process list, the logs or `connection.conf`.
* **No measurement self-pollution.** Worker snapshots are a single
  `INSERT ... SELECT`, parsed before it reads the counters, so they
  don't count their own parse. That's why the EXCHANGE test shows exactly
  0 hard parses.
* **Works without the licence or the grant.** AWR and ASH are reached
  only through dynamic SQL and conditionally included scripts. Without
  the Diagnostics Pack, or without `DBMS_WORKLOAD_REPOSITORY`, nothing
  fails: those parts are simply skipped.
* **Small extents.** In 19c each partition gets an 8 MB initial extent
  by default, which would make `T` about 3 GB. The harness uses 64 KB
  extents, so `T` stays around 100 MB.
* **Compile errors fail the install.** SQL\*Plus only *warns* on
  `CREATE ... with compilation errors`, so setup checks `USER_ERRORS`
  explicitly.

> Note: killing the SQL\*Plus/SQLcl client does **not** stop a test. The
> server session finishes it (normally within a minute or two) and
> records the result. To abort for real, kill the controller *session*
> (module `PINX_CONTROLLER`). The workers carry on until
> `./run.sh stop_workers`, step 5, or `WORKER_MINUTES`.

## Findings beyond the original brief

These came up while verifying on 19.27 and shaped the harness:

1. **Summing `V$SQL` counters undercounts invalidations under load.**
   With many sessions, each reparse after a DROP builds the cursor in
   the *other* child slot, and the invalidated child disappears from
   `V$SQL`. Each child's `INVALIDATIONS` therefore goes up only every
   second DDL, so a begin/end delta reported 5 invalidations for 10
   drops. The harness decides per DDL instead.
2. **`ddl_no_invalidate` is `X`, not `Y`, for a hot cursor.** In 19c
   `Y` means "skipped by a DDL and not executed since". A cursor that
   keeps running shows `X`.
3. **Short pile-ups are invisible to ASH, and a saturated CPU hides
   waits.**
   * With a cheap query, each pile-up lasts about 200 ms. The workers'
     `V$SESSION_EVENT` showed 36 s of `cursor: pin S wait on X`, yet ASH
     recorded zero such samples. Polling `V$SESSION` 4 times a second
     showed the same picture: the sessions spent most of that "wait"
     spinning on CPU.
   * Only with real think time (CPU headroom) and a parse that takes
     seconds do the waiters actually sleep and show up in ASH. That's
     what `PARSE_MS` and `THINK_MS` are for.
4. **Making a hard parse expensive by *size* doesn't scale.** A statement
   with hundreds of `UNION ALL` branches does take seconds to parse, but
   each session then holds about 300 MB of PGA for it. Twenty-four
   sessions hit `PGA_AGGREGATE_LIMIT` (ORA-04036). User-defined
   selectivity costs CPU at parse time and nothing else.
5. **A package named like its schema breaks schema-qualified calls.**
   With a package `PINX` in schema `PINX`, the name `PINX.X` resolves to
   the package. Oracle's own `ASSOCIATE STATISTICS` validation then
   fails with PLS-00302, so the package is called `PINX_LAB`.
6. **`TRUNCATE PARTITION` didn't invalidate the cursor either** (a
   single-session probe). This isn't part of the automated checks.

## Differences from SPEC.md

* There's no shared-pool flush between tests (and so no need for
  `ALTER SYSTEM`). Each test measures deltas inside its own window, so a
  flush adds nothing.
* The test runs in five separate steps, with one long-lived set of
  workers that both tests measure. The EXCHANGE test therefore sees the
  table after the DROP test (390 partitions instead of 400). The hot query
  reads only `P1`, so that makes no difference to it.
* Each test does `NDDL` DDLs instead of one, and there are extra knobs
  (`WARMUP`, `PARSE_MS`, `THINK_MS`, `AWR`) to make the effect large,
  repeatable and visible in ASH/AWR.
* The DROP test drops ten *different* partitions instead of drop, re-add,
  drop. Re-adding a partition is DDL too and would blur the comparison.
* The "`V$SESSION_EVENT` fallback" is the primary source: every worker
  records its own wait and parse counters, which is precise, licence
  free and limited to the test sessions. ASH and AWR are independent
  confirmation.
* Grants: `CREATE SESSION/TABLE/VIEW/PROCEDURE/SEQUENCE/TYPE/JOB`,
  `EXECUTE ON DBMS_LOCK`, `EXECUTE ON DBMS_WORKLOAD_REPOSITORY`, and
  `SELECT` on ten `V_$` views, all direct. See `admin/create_user.sql`.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `ORA-01017` in step 1 or 5 | Wrong DBA login. Check `DBA_CONNECT` in `connection.conf`. On the database host, `'/ as sysdba'` needs the right `ORACLE_SID` in the environment. |
| `ORA-65040` / `Connected to CDB$ROOT` in step 1 | The DBA login landed in the root container. Set `DBA_CONTAINER` to the PDB. |
| `ORA-01017` in steps 2 to 4 | Wrong `PINX` password or `PINX_SERVICE`. Running step 1 again sets the password. |
| `[FAIL] Missing DIRECT grant` | Run step 1 again, or grant directly. A role isn't enough. |
| `ORA-20013 The workers are not running` | Start them with `./2_start_workers.sh`. They stop after `WORKER_MINUTES`, on `./run.sh stop_workers`, and when step 1 rebuilds the table. |
| `ORA-20014 Table T has not been built yet` | Run `./1_build.sh`. |
| `ORA-20021 Table T has only N partitions left` | Many DROP tests used them up. Run `./1_build.sh` again for a fresh table. |
| `ORA-20030 Another pinx run is in progress` | Another step is active, maybe from a disconnected client. Wait a minute, or kill that session. |
| `ORA-20010 Timed out ... workers ready` | Jobs aren't starting or are failing. Check `user_scheduler_job_run_details`, `job_queue_processes` and CPU saturation. |
| `User PINX is still connected` in step 5 | You have a session open as `PINX` (SQL Developer, SQL\*Plus). Close it and run step 5 again. |
| `ORA-04036 ... PGA_AGGREGATE_LIMIT` in the job log | The instance is short of PGA. Lower `NJOBS`. |
| `ORA-01536 space quota exceeded` | Raise the quota, or lower `NPART`. |
| DROP check: fewer than `NDDL` invalidations | Shouldn't happen on 19c with `cursor_invalidation=IMMEDIATE` (the harness forces this for its DDL session). Look at `pinx_v_ddl` for the per-DDL signatures. |
| Timeline shows mostly green (CPU) and few red bars | The CPUs are saturated or the pile-ups are short. Raise `THINK_MS`, lower `NJOBS`, or raise `PARSE_MS`. |
| No ASH/AWR files in `reports/` | Diagnostics Pack not enabled, `AWR = NO`, or no grant on `DBMS_WORKLOAD_REPOSITORY`. The preflight says which. |
| A test failed | `select run_id, status, error_text from pinx_run order by run_id;` |

## Cleanup

```bash
./5_cleanup.sh               # workers stopped, user PINX dropped with everything it owns
./5_cleanup.sh --keep-user   # workers and harness objects dropped, user kept
./run.sh stop_workers        # only the workers
```

`reports/` and `logs/` are kept. The AWR snapshots the tests created stay
in the repository and age out with your normal AWR retention.
