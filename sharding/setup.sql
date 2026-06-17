-- Same DDL on every shard. pgdog routes rows to shards by hash(salon_id).
CREATE TABLE bookings (
    id           BIGINT NOT NULL,
    salon_id     BIGINT NOT NULL,
    customer     TEXT   NOT NULL,
    amount_cents BIGINT NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (salon_id, id)
);

CREATE INDEX bookings_salon_idx ON bookings (salon_id);
