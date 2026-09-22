CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS clusters (
    id           uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_id     uuid NOT NULL,
    name         text,
    is_named     boolean NOT NULL DEFAULT false,
    centroid     float8[] NOT NULL,
    sample_count integer NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS face_occurrences (
    id         uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_id   uuid NOT NULL,
    stream_id  uuid NOT NULL,
    cluster_id uuid REFERENCES clusters(id) ON DELETE CASCADE,
    embedding  float8[] NOT NULL,
    t_seconds  double precision NOT NULL,
    confidence double precision NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (stream_id, cluster_id, t_seconds)
);

CREATE INDEX IF NOT EXISTS idx_clusters_owner ON clusters (owner_id);
CREATE INDEX IF NOT EXISTS idx_clusters_owner_named ON clusters (owner_id) WHERE name IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_occurrences_owner ON face_occurrences (owner_id);
CREATE INDEX IF NOT EXISTS idx_occurrences_stream ON face_occurrences (stream_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS idx_clusters_owner_name ON clusters (owner_id, lower(name)) WHERE name IS NOT NULL;