# db-migrate

Versioned database schema runner for GoCast, built on **golang-migrate**
(v4.19.0, `lib/pq`). Replaces the old per-service GORM `AutoMigrate`.

A single binary embeds **per-service** migration sets and applies pending versions to Postgres.

## Why per-service targets

identity-service and stream-service currently share one Postgres database (`database1`) only
because of limited local resources — in the ideal world each service owns its database/instance.
The migration design already accounts for the split:

- `migrations/identity/` — `users`, `casbin_rule`, `uuid-ossp`;
- `migrations/stream/` — `streams`;
- **each target has its own version table** (`schema_migrations_identity`,
  `schema_migrations_stream`) via `postgres.WithInstance(..., MigrationsTable)`.

So even on the shared DB the two sets never collide on versions (both start at `0001`), and
moving a service to its own database is just changing the `DB_*` envs of the corresponding Job.

## Layout

```
services/db-migrate/
├── main.go                  # -target=identity|stream, runs Up() only
├── Dockerfile               # scratch-based runner image
├── Makefile                 # build / push
├── migrations/
│   ├── identity/0001_baseline.{up,down}.sql
│   └── stream/
│       ├── 0001_baseline.{up,down}.sql
│       └── 0002_processing_tasks_array.{up,down}.sql
└── deploy/k8s/
    ├── job-identity.yaml    # K8s Job (envFrom identity-service-config)
    └── job-stream.yaml      # K8s Job (envFrom stream-service-config)
```

`0001_baseline` is an idempotent snapshot of the production schema
(`CREATE TABLE/INDEX IF NOT EXISTS`, `CREATE EXTENSION IF NOT EXISTS "uuid-ossp"`):
no-op on live DBs, full creation on a fresh one.

`0002_processing_tasks_array` converts the legacy single-object `streams.processing`
JSON to the task array shape (`[{"task_type": "transcode", ...}]`), leaving already-array
values untouched. The down migration is lossy (keeps only the first task).

Migration SQL is compiled into the image with `//go:embed migrations/<target>`, so adding a
migration file requires rebuilding the image.

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

`apply-db-migrate` applies the two Jobs and then
`kubectl wait --for=condition=complete` each. Jobs use `restartPolicy: Never`,
`backoffLimit: 2`, `imagePullPolicy: Always`, and `ttlSecondsAfterFinished: 600` so they
clean up ~10 min after finishing — a re-apply always creates a fresh pod.

## Environment

Jobs get non-secret settings via `envFrom` from `identity-service-config` /
`stream-service-config`, and credentials from the `go-app-secret` Secret:

| Variable | Source | Meaning |
|---|---|---|
| `DB_HOST` / `DB_PORT` / `DB_NAME` | ConfigMap | Postgres location + database name |
| `DB_USER` / `DB_PASS` | `go-app-secret` | Postgres credentials |

When a service moves to its own database, change only these at its Job (the migration set and
version table are already separate).

## Rollback

Down files exist, but the binary implements **`Up()` only** (no `-steps`/down flag) — a
deliberate choice for now. If you need a rollback path, either restore from backup or add the
down runner later.

## Notes

- Keep GORM model structs in identity/stream in sync with the SQL — test suites still build
  schemas via `AutoMigrate` on dedicated test databases. `AutoMigrate` is removed from
  production startup (connect + pool only).
- gorm-adapter (identity, Casbin) keeps its own idempotent `AutoMigrate` on the existing
  `casbin_rule` table.