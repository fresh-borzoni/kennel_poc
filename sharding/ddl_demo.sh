#!/usr/bin/env bash
# DDL across shards: demonstrates what pgdog does with CREATE / ALTER / INDEX / TRUNCATE
# when issued against a sharded cluster.
#
# Prereq: sharding stack already up (`docker compose -f docker-compose.yml up -d --wait`)
# from this directory, or run this script and it will bring it up.

set -euo pipefail

POC_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$POC_DIR"

section() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note()    { printf '\033[2m   %s\033[0m\n' "$*"; }

via_pgdog()  { docker run --rm --network sharding_shards -e PGPASSWORD=postgres postgres:18 \
                 psql -h pgdog -p 6432 -U postgres -d appdb "$@"; }
on_shard_0() { docker exec sharding-shard_0-1 psql -U postgres -d appdb "$@"; }
on_shard_1() { docker exec sharding-shard_1-1 psql -U postgres -d appdb "$@"; }

if ! docker ps --format '{{.Names}}' | grep -q '^sharding-pgdog-1$'; then
  section "Bringing up sharding stack"
  docker compose up -d --wait
fi

# ─────────────────────────────────────────────────────────────────────────────
section "1. Baseline: bookings exists on both shards with the same DDL"
note "Both shards run the same setup.sql at init; pgdog just routes."
on_shard_0 -c "\d bookings" | head -10
on_shard_1 -c "\d bookings" | head -10

# ─────────────────────────────────────────────────────────────────────────────
section "2. ALTER TABLE: broadcast to all shards"
note "Unqualified DDL → pgdog routes to Shard::All (ddl.rs:120-123)."
via_pgdog -c "ALTER TABLE bookings ADD COLUMN tip_cents BIGINT NOT NULL DEFAULT 0;"
note "Verify column landed on BOTH shards:"
on_shard_0 -c "\d bookings" | grep tip_cents || echo "MISSING on shard_0"
on_shard_1 -c "\d bookings" | grep tip_cents || echo "MISSING on shard_1"

# ─────────────────────────────────────────────────────────────────────────────
section "3. CREATE INDEX: also broadcast"
note "ddl.rs:74-76 — IndexStmt with no schema binding → Shard::All."
via_pgdog -c "CREATE INDEX bookings_amount_idx ON bookings (amount_cents);"
note "Verify index landed on BOTH shards:"
on_shard_0 -c "SELECT indexname FROM pg_indexes WHERE tablename='bookings' AND indexname='bookings_amount_idx';"
on_shard_1 -c "SELECT indexname FROM pg_indexes WHERE tablename='bookings' AND indexname='bookings_amount_idx';"

# ─────────────────────────────────────────────────────────────────────────────
section "4. CREATE TABLE: broadcast (every new table is omnisharded by default)"
note "ddl.rs:30-33 — unprefixed CREATE TABLE goes to all shards."
note "Per pgdog-config core.rs:237: 'tables default to omnisharded status'."
via_pgdog -c "CREATE TABLE audit_log (id BIGSERIAL PRIMARY KEY, msg TEXT NOT NULL, at TIMESTAMPTZ NOT NULL DEFAULT NOW());"
note "Both shards now have audit_log:"
on_shard_0 -c "\d audit_log" | head -8
on_shard_1 -c "\d audit_log" | head -8

# ─────────────────────────────────────────────────────────────────────────────
section "5. Routed write into the new omnisharded table"
note "Without a [[sharded_tables]] entry, inserts also broadcast."
via_pgdog -c "INSERT INTO audit_log (msg) VALUES ('hello from pgdog');"
note "Each shard got the row independently (so id sequence is per-shard):"
on_shard_0 -c "SELECT id, msg FROM audit_log;"
on_shard_1 -c "SELECT id, msg FROM audit_log;"
note "↑ This is the 'omnisharded' pattern: reference/lookup tables that exist"
note "  on every shard. For Fresha, things like static enums, country codes,"
note "  feature flags. List them in [[omnisharded_tables]] to make the intent"
note "  explicit and to enable read-from-one-shard optimization."

# ─────────────────────────────────────────────────────────────────────────────
section "6. DROP INDEX: broadcast"
via_pgdog -c "DROP INDEX bookings_amount_idx;"
on_shard_0 -c "SELECT indexname FROM pg_indexes WHERE indexname='bookings_amount_idx';"
on_shard_1 -c "SELECT indexname FROM pg_indexes WHERE indexname='bookings_amount_idx';"

# ─────────────────────────────────────────────────────────────────────────────
section "7. TRUNCATE: per-table shard routing"
note "Truncating the sharded table broadcasts (no schema binding → Shard::All)."
via_pgdog -c "TRUNCATE bookings;"
on_shard_0 -c "SELECT count(*) AS shard_0_rows FROM bookings;"
on_shard_1 -c "SELECT count(*) AS shard_1_rows FROM bookings;"

# ─────────────────────────────────────────────────────────────────────────────
section "8. The DDL gotchas worth knowing"
cat <<'TXT'
   • No two-phase commit on DDL: shards run the statement in parallel.
     If one shard fails (e.g. duplicate index name), the other has already
     applied. Use IF NOT EXISTS / IF EXISTS and idempotent migrations.

   • TRUNCATE across multiple tables in different shards (via
     [[sharded_schemas]]) errors out:
        TRUNCATE shard_0.foo, shard_1.bar;
     → "CrossShardTruncateSchemaSharding" error.

   • Schema-qualified DDL on a schema that IS bound to a single shard via
     [[sharded_schemas]] routes to that shard only. Useful when you want
     to add a per-tenant table without touching every shard.

   • Long-running DDL (CREATE INDEX without CONCURRENTLY) runs serially
     against each shard from pgdog's perspective but in parallel on the
     Postgres side. Use CREATE INDEX CONCURRENTLY for hot tables.

   • Migrations should always pass through pgdog (not direct-to-shard)
     unless you explicitly want per-shard divergence. The Rails migration
     runner with DATABASE_URL pointed at pgdog → all shards stay in sync.
TXT

# ─────────────────────────────────────────────────────────────────────────────
section "9. Cleanup"
via_pgdog -c "DROP TABLE audit_log; ALTER TABLE bookings DROP COLUMN tip_cents;"
note "Verify cleanup landed on both shards:"
on_shard_0 -c "\d bookings" | head -8
on_shard_1 -c "\d bookings" | head -8

echo
echo "Done. Sharding stack still running — 'docker compose down -v' to tear down."
