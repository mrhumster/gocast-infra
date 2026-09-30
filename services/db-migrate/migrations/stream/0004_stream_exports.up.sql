-- 0004: per-stream single-file export state.
-- A stream's mp4 lives at a fixed object key (processed/<id>/video.mp4), so
-- there is at most one export row per stream. stream-service owns the row: it
-- creates it as "pending" when the owner asks for a download, and the export
-- worker reports back over gRPC to flip it to "ready" or "failed".
-- NOTE: user_id is text, matching streams.owner_id in the 0001 baseline.
-- Idempotent, so it no-ops on an existing database and creates the table from
-- scratch on a fresh one.

CREATE TABLE IF NOT EXISTS stream_exports (
    id         uuid        NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    deleted_at timestamptz,
    stream_id  uuid        NOT NULL REFERENCES streams (id) ON DELETE CASCADE,
    user_id    text        NOT NULL,
    status     text        NOT NULL DEFAULT 'pending',
    size       bigint      NOT NULL DEFAULT 0,
    error      text,
    PRIMARY KEY (id),
    CONSTRAINT stream_exports_status_check CHECK (status IN ('pending', 'ready', 'failed'))
);

CREATE INDEX IF NOT EXISTS idx_stream_exports_deleted_at ON stream_exports (deleted_at);
CREATE INDEX IF NOT EXISTS idx_stream_exports_user_id ON stream_exports (user_id);

-- One live export per stream; soft-deleted rows are kept as history and do not
-- block a fresh export.
CREATE UNIQUE INDEX IF NOT EXISTS idx_stream_exports_stream_id
    ON stream_exports (stream_id) WHERE deleted_at IS NULL;
