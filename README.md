# partition_exchange

A repeatable Oracle **19c** test case that answers one question, and
proves the answer with Oracle's own diagnostics:

> On a busy partitioned table, does partition maintenance on a partition
> that the hot query never reads still disturb that query?

It compares two ways of getting rid of a partition's data while 24
sessions keep running the same SQL statement:

| Run | DDL | What 19c does to the hot cursor | Effect on the sessions |
|-----|-----|---------------------------------|------------------------|
| **A** | `ALTER TABLE t DROP PARTITION p400 UPDATE INDEXES` | **Invalidates** it, on every drop | Everyone needs the cursor at once. One session hard-parses while all the others queue on **`cursor: pin S wait on X`** (a hard-parse pile-up). |
| **B** | `ALTER TABLE t EXCHANGE PARTITION p400 WITH TABLE t_x INCLUDING INDEXES WITHOUT VALIDATION` | **Leaves it valid** (fine-grained cursor invalidation, 12.2+) | Nothing happens: no reparse, no waits. |

The hot query reads only partition `P1`, so neither DDL changes its
result. The DROP pile-up is pure overhead caused by cursor invalidation.
That's why "exchange the partition out, then drop the swapped-out table
later" is the low-impact way to age out data on a busy system.

**Read the illustrated guide first:** [`docs/guide.html`](docs/guide.html)
explains the mechanism with diagrams, shows the measurements from a real
run, and quotes the scripts that produced them.

The harness:

* **checks** every expectation and ends with `OVERALL: PASS` or
  `OVERALL: FAIL`, with a non-zero exit code on FAIL;
* **takes AWR snapshots** right before and after each run's measurement
  window;
* **writes the evidence as HTML** into `reports/`:
  * a graphical ASH timeline of both runs, side by side;
  * Oracle's own **ASH report** for each run;
  * Oracle's own **AWR report** for each run.

---

## What the evidence looks like

From a real run on 19.27 (2 CPUs, PDB, default settings).

**The timeline** (`reports/pinx_timeline_r<A>_r<B>.html`):
* **DROP run:** after every red DDL marker, a red column of 23 sessions
  waits on `cursor: pin S wait on X` for about 2 seconds.
* **EXCHANGE run:** a flat line of one or two sessions on CPU, with grey
  markers where the DDL did nothing to the cursor.

**Oracle AWR report**, Top 10 Foreground Events:

```
Run A (DROP)        cursor: pin S wait on X   253 waits   458.2 s   84.6% DB time   Concurrency
                    DB CPU                                 58.9 s   10.9% DB time
Run B (EXCHANGE)    DB CPU                                 32.3 s   83.8% DB time
                    (no cursor: pin S wait on X at all)
```

**Oracle ASH report**, Top User Events:

```
Run A (DROP)        cursor: pin S wait on X   87.1%   7.74 average active sessions
Run B (EXCHANGE)    CPU + Wait for CPU       100.0%   0.34 average active sessions
```

**Text report** (`report.sql`, licence-free counters):

```
Metric                                                        A: DROP          B: EXCHANGE
Hot cursor: DDLs that invalidated it                         10 of 10              0 of 10
Hot cursor: ddl_no_invalidate (at end)                              N                    X
Workers: executions per second                                    804                 1179
Workers: waits on cursor: pin S wait on X                         230                    0
Workers: time in cursor: pin S wait on X (ms)                  457937                    0
ASH samples: cursor: pin S wait on X                              472                    -
OVERALL: PASS (17 checks)
```

So the DROP run lost about a third of its throughput, and 85% of its
database time was sessions waiting for one another to rebuild a cursor
that the DDL had no reason to touch.

---

## Requirements

* **Oracle Database 19c**. That's the only release it's written and
  verified for (tested on 19.27 in a PDB). The preflight check refuses
  anything older and warns on newer.
* A **PDB** (or a non-CDB). Not `CDB$ROOT`, and not `SYS`/`SYSTEM`.
* A **dedicated test schema**, created by `admin/create_user.sql`.
* `job_queue_processes >= NJOBS + 1` (25 with the defaults).
* About 160 MB in the schema's default tablespace (the quota is 500 MB).
* SQLcl (`sql`) or SQL\*Plus (`sqlplus`).
* **Licensing:**
  * The PASS/FAIL verdicts come from session counters (`V$SESSION_EVENT`,
    `V$MYSTAT`, `V$SQL`) and need **no licence**.
  * ASH, AWR snapshots and the ASH/AWR reports need the **Diagnostics
    Pack**. With `AWR = AUTO` (the default) they're used only when
    `control_management_pack_access` includes `DIAGNOSTIC`. Otherwise
    they're never touched, and the timeline page shows the counters
    only.

> **Test databases only.** The harness creates and drops tables, runs 24
> scheduler jobs for about a minute per run, burns CPU on purpose during
> hard parses, and takes two AWR snapshots per run. It does **not** need
> `ALTER SYSTEM` and never flushes the shared pool.

## Quick start

```bash
# 1. As a DBA, inside the target PDB: create the test schema
sqlplus sys@//dbhost:1521/pdb1 as sysdba @admin/create_user.sql 'Some_Passw0rd'

# 2. As that schema: run everything (about 4-5 minutes)
./run.sh pinx@//dbhost:1521/pdb1          # prompts for the password
#   or: PINX_CONNECT='pinx/pw@//dbhost:1521/pdb1' ./run.sh
#   or, without the wrapper:  sql pinx@//dbhost:1521/pdb1 @run_all.sql

# 3. Open the evidence
open reports/pinx_timeline_r*_r*.html
```

* `run.sh` picks SQLcl if it's on the PATH, otherwise SQL\*Plus. Force
  one with `PINX_CLIENT=sqlplus` or `PINX_CLIENT=sql`.
* Each run writes a timestamped log to `logs/`.
* The exit code is 0 only if every check passed.

Run a single step with `./run.sh <connect> <script>`, where `<script>` is
one of `preflight`, `setup`, `run_drop`, `run_exchange`, `evidence`,
`report` or `cleanup`. For example, `evidence` regenerates the HTML for
the latest runs.

## What one run does

`run_drop.sql` and `run_exchange.sql` each call
`pinx_lab.run_case('DROP' | 'EXCHANGE', ...)`. Both runs follow the same
steps, so they're directly comparable:

1. **Rebuild `T` from scratch.** That's `NPART` (400) range partitions of
   1000 rows each, a local index on `GRP` and fresh statistics, plus an
   empty `T_X` for the exchange. Every run starts from an identical
   table.
2. **Start `NJOBS` (24) scheduler jobs** (`PINX_W001`...). Each one runs
   the hot query, pauses `THINK_MS` (20 ms), and repeats:
   ```sql
   select /*+ qb_name(pinx) */ count(*)
   from   t a, t b, t c, t d
   where  a.id < 1000 and b.id < 1000 and c.id < 1000 and d.id < 1000
   and    a.id = b.id and b.id = c.id and c.id = d.id
   and    a.grp = 7
   and    pinx_parse_marker(a.id) >= 0;
   ```
   The query prunes statically to `P1`. The `qb_name` hint tags it,
   because PL/SQL strips comments but keeps hints.
3. **Warm up** (`WARMUP`, 10 s). This keeps the start-up pile-up (24
   sessions needing a brand-new cursor) out of the measurement.
4. **Take an AWR snapshot**, if enabled.
5. **Open the measurement window.** Every worker snapshots its own
   session counters. The controller snapshots the instance counters and
   the hot cursor's `V$SQL` rows.
6. **Run `NDDL` (10) DDL statements** spread evenly over `SECS` (60 s):
   - Run A drops partitions `p400`, `p399`, ... `p391`, one per
     statement.
   - Run B exchanges `p400` with `T_X` ten times (back and forth).

   Before each DDL, and again once things have settled (just before the
   next DDL), the controller records a signature of the hot cursor. If
   the signature changed, that DDL invalidated the cursor.
7. **Close the window**, take the second AWR snapshot, and stop the
   workers (they take their end snapshots).
8. **Copy the window's ASH rows** for the worker and controller sessions
   into `PINX_ASH_SAMPLE`. The evidence then survives after the
   in-memory ASH buffer wraps.

`evidence.sql` then writes the HTML for the latest completed DROP and
EXCHANGE runs, and `report.sql` prints the text comparison and the
verdict.

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

`PARSE_MS = 0` gives the plain query back. The DROP run still fails the
cursor and counter checks as expected; only the ASH picture gets thin.

## Reading the evidence

| Where | What to look at |
|-------|-----------------|
| **Timeline** (`pinx_timeline_*.html`) | Bars are ASH samples of the worker sessions, stacked by event. Numbered markers are the DDLs: **red** means it invalidated the hot cursor, **grey** means it didn't. Hover for details. The tiles above each chart are the licence-free counters. |
| **AWR report** (`pinx_run<N>_drop_awr.html`, `..._exchange_awr.html`) | *Top 10 Foreground Events by Total Wait Time*. DROP: `cursor: pin S wait on X` dominates DB time. EXCHANGE: only DB CPU. *SQL ordered by Parse Calls* and the *Library Cache Activity* section tell the same story. |
| **ASH report** (`pinx_run<N>_*_ash.html`) | *Top User Events* and *Activity Over Time* for the exact measurement window. |
| **Text report** (`report.sql`) | All metrics side by side, the elapsed time of each DDL, whether it invalidated the cursor, and the checks. |

| Metric | Meaning |
|--------|---------|
| **DDLs that invalidated it** | The headline number: per DDL, did the hot cursor change between "just before" and "settled"? DROP: every time. EXCHANGE: never. |
| **Workers: hard parses** | Hard parses in the worker sessions inside the window (`V$MYSTAT`). This includes recursive dictionary SQL triggered by each reparse, so it's larger than the number of DDLs. EXCHANGE: exactly 0. |
| **Workers: waits / time on cursor: pin S wait on X** | The pile-up: sessions waiting for another session to finish building the cursor they need (the workers' own `V$SESSION_EVENT`). |
| **Workers: executions per second** | Throughput of the hot query. The DROP run loses everything while a pile-up lasts. |
| **ddl_no_invalidate** | `V$SQL.DDL_NO_INVALIDATE` at the end. In 19c the values are `N` (no DDL skipped this cursor), `Y` (a DDL skipped it and it hasn't run since) and `X` (a DDL skipped it and it has run since). A hot cursor after an exchange shows `X`. |
| **ASH samples** | Oracle's own sampler agreeing with the counters. |
| **Instance: ...** | `V$SYSSTAT` / `V$SYSTEM_EVENT` deltas for the window. They include background activity and the DDL's own recursive SQL. Use them as a cross-check. |

### Checks

Each run must have completed, run all `NDDL` statements, measured all
`NJOBS` workers, and left the worker procedure VALID. In addition:

| | Run A (DROP) | Run B (EXCHANGE) |
|---|---|---|
| DDLs that invalidated the hot cursor | `= NDDL` | `0` |
| Worker waits on `cursor: pin S wait on X` | `> 0` | `0` |
| Worker hard parses | `> 0` | `0` |
| `ddl_no_invalidate` | n/a | `Y` or `X` |
| ASH samples on `cursor: pin S wait on X` (only with the Diagnostics Pack) | `> 0` | `0` |

## Configuration

Edit `config.sql`. Every script includes it.

| Variable | Default | Effect |
|----------|---------|--------|
| `NJOBS`    | 24   | Concurrent worker sessions. A bigger pile-up per invalidation. Must be `<= job_queue_processes - 1`. |
| `NPART`    | 400  | Partitions in `T`. |
| `NDDL`     | 10   | DDL statements per run, the same for both runs. |
| `SECS`     | 60   | Measurement window. The DDLs are spaced `SECS / (NDDL+1)` apart, with a quiet tail at the end. Keep the gap above about 1.5 x `PARSE_MS`. |
| `WARMUP`   | 10   | Seconds of load before the window opens. |
| `PARSE_MS` | 2000 | CPU cost of each hard parse of the hot query, which is about how long each pile-up lasts. `0` = the plain query. |
| `THINK_MS` | 20   | Pause after each execution. Keep the average number of busy sessions well under `cpu_count`. |
| `AWR`      | AUTO | `AUTO`: AWR snapshots and Oracle reports when the Diagnostics Pack is enabled. `YES`: required. `NO`: never. |

## Files

| File | Purpose |
|------|---------|
| `run.sh` | Wrapper: picks the client, logs to `logs/`, returns a meaningful exit code. |
| `run_all.sql` | `setup`, Run A, Run B, `evidence`, then `report`. |
| `config.sql` | The only file you should need to edit. |
| `preflight.sql` | Checks version, container, privileges, `job_queue_processes`, quota, licence settings and parameters, and lists **every** problem at once. |
| `setup.sql` | Installs the result tables, the parse-cost function and type, the `PINX_LAB` package, the `PINX_HOT_LOOP` worker and the report views. It's idempotent and keeps earlier results. |
| `run_drop.sql`, `run_exchange.sql` | Run A and Run B. |
| `evidence.sql`, `lib/` | Write the HTML timeline and Oracle's ASH/AWR reports to `reports/`. |
| `report.sql` | Read-only text comparison plus PASS/FAIL. Run it as often as you like. |
| `cleanup.sql` | Stops workers and drops every harness object in the schema. |
| `admin/create_user.sql`, `admin/drop_user.sql` | Create or remove the test schema (as a DBA). |
| `SPEC.md` | The original brief. Where the harness differs from it, see below. |

Results stay in `PINX_RUN`, `PINX_DDL`, `PINX_WORKER(_SNAP)`,
`PINX_SYS_SNAP`, `PINX_CURSOR_SNAP`, `PINX_ASH` and `PINX_ASH_SAMPLE`,
so you can query earlier runs (`select * from pinx_v_check where run_id
= :n`). For the AWR snapshot IDs of a run, see
`pinx_run.awr_snap_begin/awr_snap_end`. You can also produce any other
AWR report for that range, for example `@?/rdbms/admin/awrrpti.sql`.

## Robustness built in

* **Direct grants only.** The logic runs in definer-rights PL/SQL and in
  scheduler jobs, where roles are disabled. `SELECT_CATALOG_ROLE` is
  therefore *not* enough, and the preflight checks the direct grants.
* **One run at a time.** `run_case` takes a `DBMS_LOCK` lock that
  survives its commits. A second run, or a reinstall, started while a
  run is active is refused with ORA-20030 and doesn't touch the active
  run.
* **No orphaned load.** Workers stop by themselves at a deadline
  (`WARMUP + SECS + 120 s`) even if the controller dies. Any failure
  stops the workers and records `FAILED` plus the error in `PINX_RUN`.
  A run left `RUNNING` by a killed session is marked `FAILED` on the
  next run.
* **The controller can't invalidate itself.** The `PINX_LAB` package
  touches `T` only through dynamic SQL. The worker procedure is
  regenerated after every table rebuild, before 24 jobs could race to
  recompile it.
* **No measurement self-pollution.** Worker snapshots are a single
  `INSERT ... SELECT`, parsed before it reads the counters, so they
  don't count their own parse. That's why Run B shows exactly 0 hard
  parses.
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

> Note: killing the SQL\*Plus/SQLcl client does **not** stop a run. The
> server session finishes it (normally within a minute or two) and
> records the result. To abort for real, kill the controller *session*
> (module `PINX_CONTROLLER`). The workers then stop at their deadline, or
> on the next `setup`, run or `cleanup`.

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

* There's no shared-pool flush between runs (and so no need for
  `ALTER SYSTEM`). Each run rebuilds `T` and measures deltas inside its
  own window, so a flush adds nothing.
* Each run does `NDDL` DDLs instead of one, and there are extra knobs
  (`WARMUP`, `PARSE_MS`, `THINK_MS`, `AWR`) to make the effect large,
  repeatable and visible in ASH/AWR.
* Run A drops ten *different* partitions instead of drop, re-add, drop.
  Re-adding a partition is DDL too and would blur the comparison.
* The "`V$SESSION_EVENT` fallback" is the primary source: every worker
  records its own wait and parse counters, which is precise, licence
  free and limited to the test sessions. ASH and AWR are independent
  confirmation.
* Grants: `CREATE SESSION/TABLE/VIEW/PROCEDURE/SEQUENCE/TYPE/JOB`,
  `EXECUTE ON DBMS_LOCK`, `EXECUTE ON DBMS_WORKLOAD_REPOSITORY`, and
  `SELECT` on nine `V_$` views, all direct. See `admin/create_user.sql`.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `[FAIL] Missing DIRECT grant` | Run `admin/create_user.sql`, or grant directly. A role isn't enough. |
| `ORA-20030 Another pinx run is in progress` | A run is active, maybe from a disconnected client. Wait a minute, or kill that session. |
| `ORA-20010 Timed out ... workers ready` | Jobs aren't starting or are failing. Check `user_scheduler_job_run_details`, `job_queue_processes` and CPU saturation. |
| `ORA-04036 ... PGA_AGGREGATE_LIMIT` in the job log | The instance is short of PGA. Lower `NJOBS`. |
| `ORA-01536 space quota exceeded` | Raise the quota, or lower `NPART`. |
| DROP check: fewer than `NDDL` invalidations | Shouldn't happen on 19c with `cursor_invalidation=IMMEDIATE` (the harness forces this for its DDL session). Look at `pinx_v_ddl` for the per-DDL signatures. |
| Timeline shows mostly green (CPU) and few red bars | The CPUs are saturated or the pile-ups are short. Raise `THINK_MS`, lower `NJOBS`, or raise `PARSE_MS`. |
| No ASH/AWR files in `reports/` | Diagnostics Pack not enabled, `AWR = NO`, or no grant on `DBMS_WORKLOAD_REPOSITORY`. The preflight says which. |
| Run failed | `select run_id, status, error_text from pinx_run order by run_id;` |

## Cleanup

```bash
./run.sh pinx@//dbhost:1521/pdb1 cleanup                         # objects only
sqlplus sys@//dbhost:1521/pdb1 as sysdba @admin/drop_user.sql   # the schema itself
```

The AWR snapshots the runs created stay in the repository and age out
with your normal AWR retention.
