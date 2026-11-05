-- =====================================================================
-- config.sql - the test settings; the only SQL file you should need to
-- edit. Every step includes it, so values apply to all of them.
-- (How to connect is in connection.conf.)
-- =====================================================================

-- Step 2: concurrent sessions (DBMS_SCHEDULER jobs) running the hot
-- query. Must be <= job_queue_processes - 1. More sessions = bigger pile-up.
define NJOBS  = 24

-- Step 2: the workers stop by themselves after this many minutes, in
-- case nobody stops them. Each test extends it if it needs more time.
define WORKER_MINUTES = 60

-- Step 1: range partitions in table T (1000 rows each). The hot query
-- reads only P1; the DDL only touches the highest partitions. Every DROP
-- test removes NDDL of them, so 400 lasts for dozens of tests.
define NPART  = 400

-- Steps 3 and 4: partition DDL statements per test. The DROP test drops
-- the NDDL highest partitions one by one; the EXCHANGE test exchanges the
-- highest partition with T_X NDDL times. Same number of DDLs on both
-- sides keeps the tests comparable.
define NDDL   = 10

-- Length of the measurement window in seconds. The NDDL statements are
-- spread evenly across it, with a quiet tail after the last one. Leave
-- enough room between DDLs for each pile-up to finish (several seconds
-- with a high PARSE_MS).
define SECS   = 60

-- Steps 3 and 4: seconds a test waits, with the workers running, before
-- it opens the measurement window, so the start-up parse storm or the
-- tail of a previous test is excluded.
define WARMUP = 10

-- CPU cost (ms) of every hard parse of the hot query. The optimizer
-- burns this much CPU while optimizing it (user-defined selectivity on
-- pinx_parse_marker, see setup.sql), like a complex production query,
-- while executions stay cheap. Each DROP then causes a pile-up of about
-- this long - long enough for ASH (1 sample per second) and AWR to show
-- it clearly. 0 = the plain query: pile-ups of a few hundred ms that the
-- counters still prove but ASH mostly misses.
define PARSE_MS = 2000

-- Pause (ms) each worker takes after every execution. Real sessions have
-- think time; without it NJOBS sessions just saturate the CPUs, and then
-- every session, waiting or not, shows up as "ON CPU" (run queue) in ASH.
-- Aim for well under cpu_count busy sessions on average.
define THINK_MS = 20

-- AWR snapshots before and after each test's measurement window, plus
-- Oracle ASH/AWR HTML reports from evidence.sql. Needs the Diagnostics
-- Pack licence. AUTO = only when control_management_pack_access
-- includes DIAGNOSTIC; YES = required (fail otherwise); NO = never.
define AWR = AUTO
