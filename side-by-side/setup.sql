CREATE TABLE IF NOT EXISTS bookings (
    id          BIGSERIAL PRIMARY KEY,
    salon_id    BIGINT NOT NULL,
    customer    TEXT   NOT NULL,
    amount_cents BIGINT NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO bookings (salon_id, customer, amount_cents)
SELECT (g % 50) + 1, 'cust_' || g, (random() * 10000)::bigint
FROM generate_series(1, 1000) g;
