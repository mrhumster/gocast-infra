-- 0001_baseline: initial schema for identity-service.
-- Baseline mirrored from the live GORM AutoMigrate schema (2026-09-10).
-- Idempotent so it no-ops on the existing database and creates everything from scratch on a fresh one.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS users (
    id            uuid         NOT NULL DEFAULT uuid_generate_v4(),
    created_at    timestamptz  NOT NULL,
    updated_at    timestamptz  NOT NULL,
    deleted_at    timestamptz,
    email         text         NOT NULL,
    password_hash text         NOT NULL,
    role          text,
    token_version text         DEFAULT 'v1',
    PRIMARY KEY (id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email ON users (email);
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email_lower ON users (lower(email));
CREATE INDEX IF NOT EXISTS idx_users_deleted_at ON users (deleted_at);

-- Schema expected by casbin gorm-adapter v3 (created with AutoMigrate internally).
CREATE TABLE IF NOT EXISTS casbin_rule (
    id    bigserial PRIMARY KEY,
    ptype varchar,
    v0    varchar,
    v1    varchar,
    v2    varchar,
    v3    varchar,
    v4    varchar,
    v5    varchar
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_casbin_rule ON casbin_rule (ptype, v0, v1, v2, v3, v4, v5);