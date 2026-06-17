#!/usr/bin/env bash
# Side-by-side smoke test: same workload against pgbouncer (6433) and pgdog (6432),
# then against the sharded pgdog (port 6432 from sharding/compose).
#
# Prereqs: docker, docker compose, psql client locally (or use the postgres container).
set -euo pipefail

POC_DIR="$(cd "$(dirname "$0")" && pwd)"

run_psql_via_container() {
  # avoids needing local psql; runs psql from the postgres image we already pulled
  local port="$1"; shift
  docker run --rm --network host -e PGPASSWORD=postgres postgres:18 \
    psql -h 127.0.0.1 -p "$port" -U postgres "$@"
}

section() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

section "Side-by-side: bring up pgbouncer + pgdog + postgres"
(cd "$POC_DIR/side-by-side" && docker compose up -d --wait)

section "pgbouncer (6433): row count"
run_psql_via_container 6433 -d appdb -c "SELECT count(*) FROM bookings;"

section "pgdog (6432): row count (same query, same backend)"
run_psql_via_container 6432 -d appdb -c "SELECT count(*) FROM bookings;"

section "pgbouncer admin: pool stats"
run_psql_via_container 6433 -d pgbouncer -c "SHOW POOLS;" || true

section "pgdog OpenMetrics endpoint (Prometheus-compatible, scrapeable by Datadog)"
curl -fsS http://localhost:9090/metrics 2>/dev/null | head -20 || echo "metrics not exposed; configure openmetrics_port in pgdog.toml"

section "Tear down side-by-side"
(cd "$POC_DIR/side-by-side" && docker compose down -v)

section "Sharding: 2 Postgres shards behind pgdog"
(cd "$POC_DIR/sharding" && docker compose up -d --wait)

section "Insert across shards (pgdog routes by salon_id)"
run_psql_via_container 6432 -d appdb -c "
INSERT INTO bookings (id, salon_id, customer, amount_cents)
SELECT g, (g % 10) + 1, 'cust_' || g, (random() * 10000)::bigint
FROM generate_series(1, 100) g;
"

section "Sharded query: filter on salon_id routes to ONE shard"
run_psql_via_container 6432 -d appdb -c "SELECT count(*) FROM bookings WHERE salon_id = 3;"

section "Cross-shard query: no filter -> scatter-gather"
run_psql_via_container 6432 -d appdb -c "SELECT count(*) FROM bookings;"

section "Cross-shard aggregate"
run_psql_via_container 6432 -d appdb -c "SELECT salon_id, count(*) FROM bookings GROUP BY salon_id ORDER BY salon_id;"

section "Inspect raw shard contents (bypass pgdog) — proves the split"
docker compose -f "$POC_DIR/sharding/docker-compose.yml" exec -T shard_0 \
  psql -U postgres -d appdb -c "SELECT 'shard_0' AS where_, count(*) FROM bookings;"
docker compose -f "$POC_DIR/sharding/docker-compose.yml" exec -T shard_1 \
  psql -U postgres -d appdb -c "SELECT 'shard_1' AS where_, count(*) FROM bookings;"

section "Tear down sharding"
(cd "$POC_DIR/sharding" && docker compose down -v)

echo
echo "Done. See MIGRATION.md for the gap analysis."
