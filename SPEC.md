# First thread spec (from Oracle)

**Goal:** repeatable Oracle test case showing DROP PARTITION on a busy partitioned table invalidates a hot cursor and causes `cursor: pin S wait on X`, while EXCHANGE PARTITION on the same partition leaves the cursor valid. Needs 12.2+, or 11.2.0.4/12.1 with the bug 24817834 backport.

## Build
1. Use `pinx_drop_vs_exchange.sql` as the base. Split into `setup.sql`, `run_drop.sql`, `run_exchange.sql`, `report.sql`, plus `run_all.sql` calling them in order.
2. Setup: table T with 400 range partitions and a local index; empty `t_x` shaped like one partition; `run_ctl` table to stop workers; procedures `hot_loop`, `start_workers`, `stop_workers`, `report`.
3. Workers: 24 `dbms_scheduler` jobs `PINX_W*`, each looping a P1-only, expensive-to-parse query (four-way self-join) tagged `/*+ qb_name(pinx) */`.
4. Run A: drop p400 while workers run, then add it back. Run B: `exchange partition p400 with table t_x including indexes without validation`. Flush shared pool between runs.
5. Report: V$SQL loads, invalidations, `ddl_no_invalidate`, `is_rolling_invalid`; V$SYSSTAT deltas for `parse count (hard)` and `parse time elapsed`; ASH counts for cursor and library cache waits; V$SESSION_EVENT fallback without Diagnostics Pack.
6. `NJOBS`, `NPART`, `SECS` as substitution variables at the top. README documents grants: CREATE TABLE, CREATE PROCEDURE, CREATE JOB, ALTER SYSTEM, SELECT_CATALOG_ROLE.

## Done when
`@run_all` runs clean in SQLcl. Run A: invalidations > 0 and pin S wait on X samples. Run B: 0 invalidations, `ddl_no_invalidate = Y`, no pin waits.
