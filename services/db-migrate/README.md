# db-migrate

Versioned database schema runner for GoCast, built on **golang-migrate**
(v4.19.0, `lib/pq`). Replaces the old per-service GORM `AutoMigrate`.

A single binary embeds **per-service** migration sets and applies pending versions to Postgres.
Six targets are supported: `identity`, `stream`, `events`, `comments`, `stats`, `faces`.

## Why per-service targets

Most GoCast services share one Postgres database (`database1`) only because of limited local
resources — in the ideal world each service owns its database/instance. The migration design
already accounts for the split (stats and faces already run on their own databases):

- `migrations/identity/` — `users`, `casbin_rule`, `email_verified`, `uuid-ossp`;
- `migrations/stream/` — `streams`, `processing` task array, `faces_detected`;
- `migrations/events/` — `activity_events`;
- `migrations/comments/` — `comments` + `user_email` backfill;
- `migrations/stats/` — `reactions`, `stream_views` (own database `stats`);
- `migrations/faces/` — `clusters`, `face_occurrences`, `crop_object` (own database `faces`);
- **each target has its own version table** (`schema_migrations_{identity,stream,events,
  comments,stats,faces}`) via `postgres.WithInstance(..., MigrationsTable)`.

So even on the shared `database1` the sets never collide on versions (all start at `0001`),
moving a service to its own database is just changing the `DB_*` envs of the corresponding Job,
and per-service databases are auto-created (see `ensureDatabase` below).

## Layout

```
services/db-migrate/
├── main.go                  # -target=<t>, auto-creates DB, runs Up() only
├── Dockerfile               # scratch-based runner image
├── Makefile                 # build / push
├── migrations/
│   ├── identity/
│   │   ├── 0001_baseline.{up,down}.sql
│   │   └── 0002_email_verified.{up,down}.sql
│   ├── stream/
│   │   ├── 0001_baseline.{up,down}.sql
│   │   ├── 0002_processing_tasks_array.{up,down}.sql
│   │   └── 0003_faces_detected.{up,down}.sql
│   ├── events/0001_activity_events.{up,down}.sql
│   ├── comments/
│   │   ├── 0001_comments.{up,down}.sql
│   │   └── 0002_comments_user_email.{up,down}.sql
│   ├── stats/0001_reactions.{up,down}.sql
│   └── faces/
│       ├── 0001_clusters_occurrences.{up,down}.sql
│       └── 0002_cluster_crop.{up,down}.sql
└── deploy/k8s/
    ├── job-identity.yaml    # K8s Job (envFrom identity-service-config)
    ├── job-stream.yaml      # K8s Job (envFrom stream-service-config)
    ├── job-events.yaml      # K8s Job (envFrom events-service-config)
    ├── job-comments.yaml    # K8s Job (envFrom comments-service-config)
    ├── job-stats.yaml       # K8s Job (envFrom stats-service-config)
    └── job-faces.yaml       # K8s Job (envFrom faces-service-config)
```

`0001_baseline` (identity/stream) is an idempotent snapshot of the production schema
(`CREATE TABLE/INDEX IF NOT EXISTS`, `CREATE EXTENSION IF NOT EXISTS "uuid-ossp"`):
no-op on live DBs, full creation on a fresh one. The other sets use descriptive names.

Notable migrations:
- `stream/0002_processing_tasks_array` converts the legacy single-object `streams.processing`
  JSON to the task array shape (`[{"task_type": "transcode", ...}]`), leaving already-array
  values untouched. The down migration is lossy (keeps only the first task).
- `comments/0002_comments_user_email` adds `comments.user_email` and backfills it from
  `users.email` (both tables in `database1`).
- `faces/0002_cluster_crop` adds the `clusters.crop_object` preview path.

Migration SQL is compiled into the image with `//go:embed migrations/<target>`, so adding a
migration file requires rebuilding the image.

## Per-service databases and ensureDatabase

`main.go` connects to the `DB_MAINTENANCE_NAME` database (default `postgres`) and creates the
target `DB_NAME` automatically if it does not exist yet (`CREATE DATABASE` when
`DB_NAME != DB_MAINTENANCE_NAME`, quoted identifier, no-op if it already exists). For the
legacy shared `database1` this is effectively a no-op — the database already exists.

In practice:
- identity/stream/events/comments point `DB_NAME=database1` (shared);
- stats uses `DB_NAME=stats`, faces uses `DB_NAME=faces` — both are created on first run.

## Adding a migration

```bash
# 1. Write the pair (numeric prefix, up/down):
services/db-migrate/migrations/stream/0002_add_some_column.up.sql
services/db-migrate/migrations/stream/0002_add_some_column.down.sql

# 2. Rebuild + push the runner (go:embed picks up the new files):
make -C services/db-migrate all          # build + push xomrkob/db-migrate:latest

# 3. Apply on the cluster (runs only pending versions):
make apply-db-migrate
```

`apply-db-migrate` applies the six Jobs and then `kubectl wait --for=condition=complete` each
(`db-migrate-{identity,stream,events,comments,stats,faces}`). Jobs use `restartPolicy: Never`,
`backoffLimit: 2`, `imagePullPolicy: Always`, and `ttlSecondsAfterFinished: 600` so they
clean up ~10 min after finishing — a re-apply always creates a fresh pod.

## Environment

Jobs get non-secret settings via `envFrom` from the matching `*-service-config` ConfigMap
(`identity-`, `stream-`, `events-`, `comments-`, `stats-`, `faces-service-config`), and
credentials from the `go-app-secret` Secret:

| Variable | Source | Meaning |
|---|---|---|
| `DB_HOST` / `DB_PORT` / `DB_NAME` | ConfigMap | Postgres location + target database |
| `DB_MAINTENANCE_NAME` | optional | maintenance database (`postgres` default) for `ensureDatabase` |
| `DB_USER` / `DB_PASS` | `go-app-secret` | Postgres credentials |

When a service moves to its own database, change only `DB_NAME` at its Job (the migration set
and version table are already separate).

## Rollback

Down files exist, but the binary implements **`Up()` only** (no `-steps`/down flag) — a
deliberate choice for now. If you need a rollback path, either restore from backup or add the
down runner later.

## Notes

- Keep GORM model structs in the Go services in sync with the SQL — test suites still build
  schemas via `AutoMigrate` on dedicated test databases. `AutoMigrate` is removed from
  production startup (connect + pool only).
- gorm-adapter (identity, Casbin) keeps its own idempotent `AutoMigrate` on the existing
  `casbin_rule` table.