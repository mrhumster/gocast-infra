-- 0001_baseline: initial schema for stream-service.
-- Baseline mirrored from the live GORM AutoMigrate schema (2026-09-10).
-- NOTE: owner_id is stored as text (matches the current live schema, though users.id is uuid).
-- Idempotent so it no-ops on the existing database and creates everything from scratch on a fresh one.

CREATE TABLE IF NOT EXISTS streams (
    id           uuid         NOT NULL,
    created_at   timestamptz  NOT NULL,
    updated_at   timestamptz  NOT NULL,
    deleted_at   timestamptz,
    title        text         NOT NULL,
    description  text,
    status       text         NOT NULL DEFAULT 'draft',
    owner_id     text,
    visibility   text         NOT NULL DEFAULT 'private',
    tags         jsonb,
    metadata     jsonb,
    storage      jsonb,
    processing   jsonb,
    analytics    jsonb,
    published_at timestamptz,
    PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_streams_deleted_at ON streams (deleted_at);
CREATE INDEX IF NOT EXISTS idx_streams_owner_id ON streams (owner_id);