# go-shared

Shared Go module for GoCast worker services (`github.com/mrhumster/go-shared`).
Consumed by the thumbnail and transcoder services via `go.work` + `replace` to `../shared`.

## Packages

| Package | Purpose |
|---|---|
| `worker` | Asynq worker skeleton: Redis health-check at startup, `ErrorHandler` → `ErrorReporter` (so a failed task can be reported to stream-service via gRPC), optional Prometheus `/metrics` server. |
| `config` | `LoadConfig()` — env-driven config (`Config{Redis, MinIO, Server, Worker}`) shared between workers. |
| `grpctls` | `ClientTLSCreds(certFile, keyFile, caFile, serverName)` — mTLS client credentials for gRPC (used against stream-service). |
| `metrics` | Prometheus instrumentation of Asynq tasks (`asynq_task_*`) + `Instrument(task, fn)` handler wrapper. |

## worker

```go
srv, err := sharedworker.NewAsynqServer(sharedworker.Options{
    Addr:            cfg.Redis.Addr,
    Password:        cfg.Redis.Password,
    DB:              cfg.Redis.DB,          // 2 in stream-service's asynq
    Concurrency:     cfg.Worker.Concurrency,
    ShutdownTimeout: cfg.Worker.ShutdownTimeout,
    Queues:          map[string]int{"thumbsnails": 6}, // arbitrary priority map
    ErrorReporter:   reportError,             // optional
    MetricsAddr:     cfg.Server.MetricsAddr,  // empty = off
})
```

- Pings Redis before building the server (fail fast instead of silently queueing);
- `ErrorReporter` is called for every failed task (default no-op);
- `MetricsAddr` starts a `net/http` server on that address exposing `/metrics`.

## config

`sharedconfig.LoadConfig()` reads env vars (defaults for local runs). Relevant groups:

| Group | Env vars (selected) | Notes |
|---|---|---|
| `Redis` | `REDIS_ADDR`, `REDIS_PASS`, `REDIS_DB` | asynq queue Redis |
| `MinIO` | `MINIO_ENDPOINT`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, `MINIO_BUCKET_NAME`, `MINIO_USE_SSL`, `MINIO_REGION` | object storage |
| `Server` | `STREAM_SERVICE_ADDRESS`, `GRPC_TLS_CERT`, `GRPC_TLS_KEY`, `GRPC_TLS_CA`, `GRPC_TLS_ENABLED`, `METRICS_ADDR` | gRPC client to stream + metrics addr |
| `Worker` | `WORKER_CONCURRENCY`, `WORKER_SHUTDOWN_TIMEOUT` | asynq tuning |

In K8s values come from `thumbnail-service-config` / `transcoder-service-config` ConfigMaps
(rendered from the root `.env` by `scripts/render-env.sh`).

## metrics

Registered on the process-wide default registry (safe: one worker binary per process):

- `asynq_task_processed_total{task,status=success|error}`
- `asynq_task_duration_seconds{task}` (histogram)
- `asynq_task_inflight{task}` (gauge)

Wrap a handler with `sharedmetrics.Instrument("some_task", fn)` to record all three.
Note: counter vectors only appear after their first `Inc()` (lazy Vec), histograms are visible
immediately.

## grpctls

`ClientTLSCreds` builds mTLS transport credentials (`serverName = stream-service`).
The caller gates it on `GRPC_TLS_ENABLED` and falls back to `insecure.NewCredentials()` locally.

## Using in a service

`go.mod`:

```
require github.com/mrhumster/go-shared v0.0.0
replace github.com/mrhumster/go-shared => ../shared
```

The Docker build context is `services/` and the Dockerfile copies `shared` to `/shared`
before `go mod download` — the `replace` resolves there. A `replace` to the local dir requires
`go work sync` after changes (the root `go.work` includes `./services/shared`).