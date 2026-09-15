-- 0001_comments schema for comments-service
-- Stores user comments on streams
-- parent_id links replies to root comments
-- unlimited nesting via parent_id self-reference (cascade delete)

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS comments (
    id         uuid         NOT NULL DEFAULT gen_random_uuid(),
    stream_id  uuid         NOT NULL,
    user_id    uuid         NOT NULL,
    parent_id  uuid         REFERENCES comments(id) ON DELETE CASCADE,
    body       text         NOT NULL,
    edited_at  timestamptz,
    created_at timestamptz  NOT NULL DEFAULT now(),
    updated_at timestamptz  NOT NULL DEFAULT now(),
    PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_comments_stream ON comments (stream_id, parent_id, created_at DESC, id);
CREATE INDEX IF NOT EXISTS idx_comments_user ON comments (user_id);