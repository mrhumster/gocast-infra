CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS reactions (
    stream_id  uuid NOT NULL,
    user_id    uuid NOT NULL,
    kind       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (stream_id, user_id),
    CONSTRAINT chk_reactions_kind CHECK (kind IN ('like', 'dislike'))
);

CREATE INDEX IF NOT EXISTS idx_reactions_stream ON reactions (stream_id, created_at DESC);

CREATE TABLE IF NOT EXISTS stream_views (
    stream_id  uuid PRIMARY KEY,
    count      bigint NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now()
);