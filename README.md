# PgDog PoC

A runnable proof-of-concept for replacing **pgbouncer** with **[pgdog](https://github.com/pgdogdev/pgdog)** as Fresha's Postgres connection pooler. Two Docker Compose stacks demonstrate behavioural parity, the operational wins (multi-threading, query-aware routing, native Prometheus), and the things to watch for during a migration (sharding foot-guns, DDL semantics).

Companion RFC (data-architect case): the migration argument and the OSS-vs-Enterprise / HA / auth assessment live in the parallel proposal — ask Anton (`anton.borisov@fresha.com`) for the FIP if you don't have it.

## What's in here

```
.
├── side-by-side/         # pgbouncer (6433) + pgdog (6432) against the same Postgres
│   ├── docker-compose.yml
│   ├── setup.sql
│   ├── pgbouncer/{pgbouncer.ini,userlist.txt}
│   └── pgdog/{pgdog.toml,users.toml}
├── sharding/             # 2 Postgres shards behind pgdog, hash on salon_id
│   ├── docker-compose.yml
│   ├── setup.sql
│   ├── pgdog.toml
│   ├── users.toml
│   └── ddl_demo.sh       # cross-shard DDL: broadcast, omnisharded, TRUNCATE
└── smoke.sh              # end-to-end smoke runner for the side-by-side stack
```

### Prerequisites

- Docker Desktop (or Docker Engine + compose v2). Tested on Docker Desktop 4.30+ on macOS.
- Free ports: `6432` (pgdog), `6433` (pgbouncer), and the internal `5432` per shard inside the compose networks.
- ~1 GB free disk for the postgres:18 and pgdog/pgbouncer images.

No local `psql` required — every demo uses `psql` from the `postgres:18` image via `docker run`.

## Stack 1 — side-by-side

**What it shows.** pgbouncer and pgdog running against the same Postgres backend, with production-shaped config translated key-by-key from one of Fresha's `deploy-multi/*/values.yaml` files. Identical SQL goes through both proxies; you can see they behave the same, and you can scrape pgdog's native OpenMetrics endpoint.

**The translated config** mirrors the non-default settings from Fresha's pgbouncer pools: transaction pooling, `default_pool_size=1000`, `max_prepared_statements=1500`, the TCP keepalive triplet, query/idle timeouts. The full per-key mapping is documented in `side-by-side/pgdog/pgdog.toml` (inline comments).

```sh
cd side-by-side
docker compose up -d --wait

# Both proxies should return the same answer
docker run --rm --network side-by-side_pool -e PGPASSWORD=postgres postgres:18 \
  psql -h pgbouncer -p 6433 -U postgres -d appdb -c "SELECT count(*) FROM bookings;"

docker run --rm --network side-by-side_pool -e PGPASSWORD=postgres postgres:18 \
  psql -h pgdog -p 6432 -U postgres -d appdb -c "SELECT count(*) FROM bookings;"

# pgdog OpenMetrics endpoint (scrapeable by Datadog Autodiscovery in prod)
docker run --rm --network side-by-side_pool curlimages/curl:latest \
  -s http://pgdog:9090/metrics | grep ^pgdog_ | head

# pgbouncer admin DB
docker run --rm --network side-by-side_pool -e PGPASSWORD=postgres postgres:18 \
  psql -h pgbouncer -p 6433 -U postgres -d pgbouncer -c "SHOW POOLS;"

docker compose down -v
```

**What you'll see.** Both `SELECT count(*)` return `1000`. pgdog's `/metrics` returns Prometheus-format metrics with labels `{user, database, host, port, shard, role}` — strictly more dimensionality than the current Datadog pgbouncer integration's `{database, user}`.

## Stack 2 — sharding

**What it shows.** Two Postgres shards behind pgdog, with the `bookings` table sharded by hash on `salon_id`. Demonstrates the killer feature pgbouncer simply does not have: the application keeps issuing the same SQL, pgdog inspects WHERE clauses and routes each statement to the right shard.

```sh
cd sharding
docker compose up -d --wait

# Insert 10 rows with mixed salon_ids — pgdog splits them by hash
docker run --rm --network sharding_shards -e PGPASSWORD=postgres postgres:18 \
  psql -h pgdog -p 6432 -U postgres -d appdb -c "
INSERT INTO bookings (id, salon_id, customer, amount_cents) VALUES
  (1,1,'a',100),(2,2,'b',200),(3,3,'c',300),(4,4,'d',400),(5,5,'e',500),
  (6,6,'f',600),(7,7,'g',700),(8,8,'h',800),(9,9,'i',900),(10,10,'j',1000);"

# Verify the split — each shard has its slice
docker exec sharding-shard_0-1 psql -U postgres -d appdb \
  -c "SELECT salon_id, customer FROM bookings ORDER BY salon_id;"
docker exec sharding-shard_1-1 psql -U postgres -d appdb \
  -c "SELECT salon_id, customer FROM bookings ORDER BY salon_id;"

# Sharded read: filter on salon_id → single shard
docker run --rm --network sharding_shards -e PGPASSWORD=postgres postgres:18 \
  psql -h pgdog -p 6432 -U postgres -d appdb \
  -c "SELECT salon_id, customer FROM bookings WHERE salon_id = 3;"

# Cross-shard scatter-gather aggregate
docker run --rm --network sharding_shards -e PGPASSWORD=postgres postgres:18 \
  psql -h pgdog -p 6432 -U postgres -d appdb \
  -c "SELECT salon_id, count(*), sum(amount_cents) FROM bookings
      GROUP BY salon_id ORDER BY salon_id;"

docker compose down -v
```

**What you'll see.** Rows land on shard_0 vs shard_1 by hash(salon_id) — uneven distribution is expected (10 rows on 2 shards typically split 2/8 or 3/7). Single-shard query touches only one shard; scatter-gather merges results from both.

### DDL demo

Cross-shard DDL is a distinct topic from DML. The `ddl_demo.sh` script exercises every DDL kind pgdog handles specially:

```sh
cd sharding
./ddl_demo.sh
```

It walks through: `ALTER TABLE` broadcast, `CREATE INDEX` broadcast, `CREATE TABLE` for an omnisharded reference table (and the per-shard sequence quirk that pattern produces), `DROP INDEX`, `TRUNCATE`. Each step shows the resulting schema state on each shard so you can see the routing rather than infer it.

## Live-verified findings

Everything in this list was actually observed running, not read from docs:

- **Config parity.** Both proxies accept the production-shaped config and return identical results for the same workload.
- **OpenMetrics labels.** Scraped output includes `pgdog_*` metrics labelled by `{user, database, host, port, shard, role}` — usable as Datadog OpenMetrics dimensions or Prometheus labels.
- **Hash sharding routes correctly.** 10-row insert splits 2/8 across shards by hash; single-shard SELECT filters to one shard; `count(*)` and `GROUP BY` scatter-gather and merge.
- **DDL broadcasts as expected.** `ALTER TABLE`, `CREATE INDEX`, `CREATE TABLE`, `DROP INDEX`, and `TRUNCATE` all reach both shards; the resulting schema state matches on each.

## Gotchas surfaced during the PoC

These were discovered by running the stacks, not by reading documentation. Worth knowing before any production move:

- **`INSERT … SELECT` is broadcast across shards.** pgdog cannot evaluate the SELECT at routing time, so an `INSERT INTO sharded_table SELECT FROM source` inserts the same rows on *every* shard. A 100-row PoC INSERT produced 200 rows total in a 2-shard cluster. Affects backfill jobs and one-off data migrations; hot paths in shedul do not use this pattern.
- **`[rewrite]` defaults to `enabled = false`.** Multi-tuple `INSERT VALUES` also broadcasts unless `split_inserts = "rewrite"` is set explicitly in pgdog.toml. A quiet default that bites the first time someone tries the obvious thing.
- **Omnisharded write quirk.** A `CREATE TABLE foo (...)` (with no `[[sharded_tables]]` entry) is created on every shard and writes broadcast to every shard. If `foo` has a `BIGSERIAL` PK, each shard runs its own sequence — collisions are guaranteed. For reference/lookup tables, list them in `[[omnisharded_tables]]` and use UUID PKs or coordinate the sequences out-of-band.
- **No two-phase commit on DDL.** Shards run DDL in parallel; partial failure (e.g., one shard runs out of memory, the other succeeds) produces schema drift. Mitigation: always use `IF NOT EXISTS` / `IF EXISTS`, run migrations through pgdog rather than direct-to-shard.

## What this PoC does NOT cover

- **No TLS.** Disabled for local-compose simplicity. Real deployment must configure `tls_certificate`, `tls_private_key`, `tls_client_required`.
- **No authentication exercise.** `passthrough_auth` and `server_auth = "rds_iam"` (the two interesting pgdog auth options) are not demonstrated. Both are easy to add; ask if you want them.
- **No HA shape.** Single pgdog process. Real deployment runs 2+ pgdog pods behind a Kubernetes Service with PodDisruptionBudget and topology spread. The pgdog Helm chart at https://github.com/pgdogdev/helm handles this; not exercised here.
- **No performance numbers.** pgdog ships a pgbench-vs-pgbouncer benchmark setup at `pgdog/examples/pgbouncer_benchmark/`; running it on Fresha-shaped hardware is a separate task.
- **No real RDS.** Everything runs against Postgres in Docker. RDS-specific behaviours (IAM auth via STS, RDS CA bundle pinning, RDS Performance Insights attribution) are not exercised.

## References

- **pgdog source**: https://github.com/pgdogdev/pgdog
- **pgdog Helm chart** (used in production-shaped deployments): https://github.com/pgdogdev/helm
- **pgdog docs**: https://docs.pgdog.dev/
