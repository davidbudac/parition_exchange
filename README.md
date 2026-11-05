# partition_exchange

An Oracle **19c** test that compares two ways of removing a partition's data while 24 sessions keep querying a different partition and inserting into the current one.

`DROP PARTITION` invalidates the hot query's cursor. `EXCHANGE PARTITION` does not. The sessions never read the partition the DDL touches.

**Architecture diagrams:** open [`docs/guide.html`](docs/guide.html). It draws the test setup, what each DDL does to the cursors, the production sequence, and the harness. A walkthrough of one real run is in [`docs/story.html`](docs/story.html).

Use this on a test database only. The scripts create and drop a user, run scheduler jobs, and take AWR snapshots. They do not change instance parameters and they do not flush the shared pool.

## Requirements

- Oracle Database 19c, in a PDB (not `CDB$ROOT`). Tested on 19.27.
- DBA access for the first and last step (`/ as sysdba` on the database host, or a user such as `SYSTEM` over the network). Steps 2–4 run as the test user `PINX`.
- `job_queue_processes` at least 25.
- About 160 MB in the schema's default tablespace. The quota is 500 MB.
- `bash`, and SQLcl (`sql`) or SQL\*Plus (`sqlplus`).
- PASS/FAIL comes from session counters and needs no extra licence. ASH and AWR reports are written only when the Diagnostics Pack is enabled.

## Install and run

Edit `connection.conf` once. Defaults suit a run on the database host:

```bash
PINX_SERVICE=//localhost:1521/pdb1.world   # PDB service that PINX connects to
DBA_CONNECT='/ as sysdba'                   # or 'system@//dbhost:1521/pdb1'
DBA_CONTAINER=PDB1                          # PDB to enter after '/ as sysdba'
```

Passwords are not stored in the file. Each script asks for the ones it needs, or you can set `PINX_PASSWORD` and `DBA_PASSWORD` in the environment. An environment variable wins over the file.

Then run the steps in order:

```bash
./1_build.sh            # user PINX, objects, table T          ~30 s
./2_start_workers.sh    # 24 sessions: query, insert, commit   ~10 s
./3_test_drop.sh        # DROP test and its reports            ~90 s
./4_test_exchange.sh    # EXCHANGE test and the comparison     ~90 s
./5_cleanup.sh          # stop the workers, drop the user      ~15 s

open reports/pinx_timeline_r1_r2.html
```

Each script stops at the first error and writes a log under `logs/`. Steps 3 and 4 exit non-zero when a check fails. You can repeat steps 3 and 4 while the workers are running; each DROP test uses 10 of the 400 partitions. Rebuild with step 1 when they run out.

SQLcl is used when `sql` is on `PATH`, otherwise SQL\*Plus. Force one with `PINX_CLIENT=sqlplus` or `PINX_CLIENT=sql`.

Knobs (partition count, workers, window length, parse cost) are in `config.sql`.

While the workers are up:

```bash
./run.sh status          # what each worker is doing, and the current rate
./run.sh stop_workers    # stop the workers, keep the user and the data
./5_cleanup.sh --keep-user   # drop the harness, keep the user
```
