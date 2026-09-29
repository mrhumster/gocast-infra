# go-shared

Shared Go library for the GoCast worker services: the **env-driven config** struct every worker
loads, the **asynq server scaffolding** they all run on, **Prometheus** instrumentation for task
handlers, and the **gRPC mTLS client** helper for the calls workers make into stream-service.

It is a library, not a service — there is no `cmd/`, no `Dockerfile`, no `Makefile` and no
deployment of its own. It is committed into the `gocast-infra` root repo and consumed as a
`replace`-d local module.

## Packages

| Package | Purpose |
|---|---|
| `config` | `LoadConfig()` → one `Config` struct with Redis / MinIO / server / worker / mail / transcoder / faces groups |
| `worker` | `NewAsynqServer(Options)` — Redis preflight, asynq config, error reporter, optional metrics endpoint |
| `metrics` | `Instrument()` wrapper + `asynq_task_*` Prometheus series, registered on the default registry |
| `grpctls` | `ClientTLSCreds(cert, key, ca, serverName)` for mTLS gRPC dials |

## Consumers

Five services import it (each with `replace github.com/mrhumster/go-shared => ../shared`), and
the root `go.work` also lists `./services/shared` so `go build` resolves it in workspace mode:

| Service | `config` | `worker` | `metrics` | `grpctls` |
|---|---|---|---|---|
| thumbnail-service | ✅ | ✅ | ✅ | ✅ |
| transcoder-service | ✅ | ✅ | ✅ | ✅ |
| faces-worker | ✅ | ✅ | ✅ | ✅ |
| mailer-service | ✅ | ✅ | ✅ | — |
| events-service | — | ✅ | ✅ | — |

Only `faces-worker` currently sets `worker.Options.RetryDelay`; the other four fall back to
asynq's own default (see below). `config.MinIO` is only meaningful for the three services that
also ship an `internal/storage` factory (thumbnail, transcoder, faces-worker).

## config

`LoadConfig()` reads **all** groups in one pass. In Kubernetes the values arrive from ConfigMaps
rendered by `scripts/render-env.sh`, Secrets mounted as env, and a few inline `env` entries — the
per-service Deployment manifests document which of the variables below each one actually sets.

```go
cfg, err := sharedconfig.LoadConfig()   // err is always nil today (see below)
```

`LoadConfig` returns `(*Config, error)`, but **the error is always `nil`**: each field is parsed
independently, and a bad value only logs a warning and falls back to the default. A typo'd
`WORKER_CONCURRENCY=many` therefore does not fail startup — the pod comes up with concurrency 1
and a log line, which is easy to miss.

### Env-var semantics

Values are read with a `getEnv` helper that treats an **empty or unset** variable the same as
"not provided" and returns the default. This is what makes the render script's habit of emitting
bare keys meaningful:

- `METRICS_ADDR=` in a ConfigMap **disables** the metrics endpoint (the intended default), it does
  not set it to an empty listen address.
- `SMTP_ADDR=` in `mailer-service-config` is the deliberate "log-only, no SMTP" switch.
- `GRPC_TLS_ENABLED=` therefore resolves to `false`, i.e. insecure gRPC.

A value that is present but unparsable (`"abc"` for an int/duration/bool) is a third case: it
overrides the default, fails to parse, logs, and lands back on the default.

### Groups and variables

| Group | Variables (env → field) |
|---|---|
| `Redis` | `REDIS_ADDR` → `Addr` (default `localhost:6379`), `redis-password` → `Password` (default `""`), `REDIS_DB` → `DB` (default `2`) |
| `MinIO` | `MINIO_ENDPOINT` (`localhost:9000`), `MINIO_ACCESS_KEY` (`admin`), `MINIO_SECRET_KEY` (`minio123`), `MINIO_BUCKET_NAME` (`stream-service-test`), `MINIO_USE_SSL` (`false`), `MINIO_REGION` (`ru-east-1`) |
| `Server` | `STREAM_SERVICE_ADDR` (`localhost:50051`), `METRICS_ADDR` (`""` = metrics off), `GRPC_TLS_ENABLED` (`false`), `GRPC_TLS_CERT` / `GRPC_TLS_KEY` / `GRPC_TLS_CA` (`""`) |
| `Worker` | `WORKER_CONCURRENCY` (`1`), `WORKER_SHUTDOWN_TIMEOUT` (`50m`), `WORKER_RETRY_DELAY` (`30s`) |
| `Mail` | `SMTP_ADDR` (`""`), `SMTP_USER` (`""`), `SMTP_PASS` (`""`), `SMTP_FROM` (`""`), `FRONTEND_URL` (`https://example.com`) |
| `Transcoder` | `TRANSCODER_ENCODER` (`auto`) |
| `Faces` | `FACES_SERVICE_URL` (`http://faces-service:80`), `FACES_INTERNAL_TOKEN` (`""`), `STREAM_SERVICE_URL` (`http://stream-service:80`), `FACES_INFER_TIMEOUT` (`600s`) |

Two names trip people up:

- The Redis password key is **`redis-password`** (lowercase, from the `casbin-redis` Secret), not
  `REDIS_PASS`.
- The gRPC address is **`STREAM_SERVICE_ADDR`**, not `STREAM_SERVICE_ADDRESS`. The separate
  `Faces.STREAM_SERVICE_URL` (`STREAM_SERVICE_URL`) is the plain HTTP base URL used for REST calls,
  and it defaults to `http://stream-service:80`.

The `Mail` / `Transcoder` / `Faces` groups are consumed by only one service each but live here so
that there is exactly one `LoadConfig` in the monorepo. `WORKER_RETRY_DELAY` is likewise
present for every worker even though only `faces-worker` reads it today.

`config_test.go` has a single `TestLoadConfig` covering defaults and env overrides; there are no
tests for the parse-failure fallback path.

## worker

`NewAsynqServer(Options)` is the common worker bootstrap: it pings Redis, builds the
`*asynq.Server`, wires the error reporter, and optionally starts the metrics HTTP server.

```go
srv, err := sharedworker.NewAsynqServer(sharedworker.Options{
    Addr:            cfg.Redis.Addr,
    Password:        cfg.Redis.Password,
    DB:              cfg.Redis.DB,
    Concurrency:     cfg.Worker.Concurrency,
    ShutdownTimeout: cfg.Worker.ShutdownTimeout,
    Queues:          map[string]int{"thumbsnails": 6},
    MetricsAddr:     cfg.Server.MetricsAddr,
    ErrorReporter:   reportError,     // optional
    RetryDelay:      cfg.Worker.RetryDelay, // optional
})
if err != nil {
    return err
}
return srv.Run(mux)   // blocks until SIGINT/SIGTERM
```

Behaviour worth knowing:

- **Fail-fast Redis preflight.** `NewAsynqServer` pings Redis with `context.Background()` — no
  timeout — and returns an error if it fails, so a worker with bad credentials or a missing Redis
  exits instead of starting in a broken state. The ping has no deadline, so a *hung* (not refused)
  Redis blocks startup until the OS TCP timeout rather than failing quickly.
- **Retry delay.** When `RetryDelay > 0` it is installed as `Config.RetryDelayFunc`, i.e. a
  **fixed** delay before every retry. A zero or negative value leaves the field nil and asynq uses
  its own default: exponential backoff `n^4 + 15 + rand(30)*(n+1)` seconds. Retry *count* is not
  configured here — it is a client-side enqueue option (`asynq.MaxRetry`), so a `RetryDelay` in
  this package does not by itself make a task retryable.
- **Error reporter.** `ErrorReporter` is `func(ctx, *asynq.Task, error)`. A nil value becomes a
  no-op. It is invoked from asynq's `ErrorHandler`, which fires only when a handler returns a
  non-nil error, and it fires *before* the retry is scheduled.
- **Shutdown.** `Run` blocks in asynq's own signal loop: `SIGTSTP` stops processing new tasks but
  keeps the process alive, `SIGINT`/`SIGTERM` shut down and let in-flight tasks finish for
  `ShutdownTimeout`, then abort. Because the default `WORKER_SHUTDOWN_TIMEOUT` is **50m**, a
  Kubernetes `terminationGracePeriodSeconds` shorter than that is what actually bounds the wait.
- **Metrics endpoint.** When `MetricsAddr` is set, `NewAsynqServer` starts a bare
  `net/http` server on that address serving `/metrics` and the Go/process collectors. The error
  from `ListenAndServe` is only logged, the server is never shut down, and there is no readiness or
  health endpoint — worker Deployments consequently probe `/metrics` for **liveness only**. Note
  the metrics server starts inside `NewAsynqServer`, i.e. before `Run` returns control.

## metrics

`metrics.Instrument(task, handler)` wraps an `asynq.HandlerFunc` and records, for the given task
type label:

| Series | Type | Labels | Meaning |
|---|---|---|---|
| `asynq_task_processed_total` | counter | `task`, `status` | one increment per completed attempt, `status="success"` or `"error"` |
| `asynq_task_duration_seconds` | histogram (`DefBuckets`) | `task` | wall-clock duration of the wrapped handler |
| `asynq_task_inflight` | gauge | `task` | tasks being processed right now |

Registration happens in the package `init()` on the process-wide default registry, which is safe
here only because each worker is its own binary — importing `metrics` twice in one process would
panic on duplicate registration.

Accounting is split into `IncInflight(task)` and `ObserveTask(task, err, seconds)`, and the gauge
decrement lives in `ObserveTask`, so a call site that increments without finishing leaves the
gauge permanently high. `Instrument` is the paired version and is what every service uses.
Note that `status` is derived from `err != nil` only: returning `asynq.SkipRetry` still counts as
an error, which inflates the error rate for terminal failures that were handled on purpose.

Series only exist after the first task of that type runs, and idle KEDA-scaled pods disappear from
scrape entirely, so empty panels are normal between bursts.

## grpctls

`ClientTLSCreds(certFile, keyFile, caFile, serverName)` builds client-side mTLS credentials: it
loads the service's own keypair, reads the CA PEM into a fresh `x509.CertPool`, and returns
`credentials.NewTLS` with `MinVersion: tls.VersionTLS12`. Failures are wrapped with context
(`load client keypair`, `read CA cert`, `failed to parse CA certificate`) — an unreadable or
non-PEM CA file returns an error rather than silently producing an empty pool.

This is the **client** half only. Servers keep their own credential construction, plus
stream-service's `AllowOUsInterceptor` which authorises the calling service by the OU in its
client certificate. Workers call it as
`ClientTLSCreds(cert, key, ca, "stream-service")` — the server name must match the certificate
SAN, it is not free-form. Callers should only dial through it when their own `GRPC_TLS_ENABLED`
is true.

## Docker builds

Consumers are built with the **`services/` directory as the Docker build context** so the
`replace ../shared` directive can resolve. In each Dockerfile the shared tree is copied to `/shared`
*before* `go mod download` (otherwise module resolution fails):

```dockerfile
WORKDIR /app
COPY <service>/go.mod ./
COPY shared /shared
RUN go mod download
COPY <service>/. .
```

Because `go-shared` lives in the root repo, a service checkout on its own is not buildable; the
local path dependency and the shared source must travel together.

## Project layout

```
shared/
├── config/
│   ├── config.go       # Config + LoadConfig + getEnv helper
│   └── config_test.go  # TestLoadConfig (defaults + env overrides)
├── grpctls/grpctls.go  # ClientTLSCreds
├── metrics/metrics.go  # asynq_task_* + Instrument/IncInflight/ObserveTask
├── worker/worker.go    # Options + NewAsynqServer
├── go.mod / go.sum     # module github.com/mrhumster/go-shared
└── README.md
```

Module: `github.com/mrhumster/go-shared` (go 1.25.14). Dependencies: `hibiken/asynq`,
`prometheus/client_golang`, `redis/go-redis/v9`, `grpc`, `stretchr/testify` (test only).

## Commands

There is no Makefile here; run the Go toolchain from this directory:

```bash
go build ./...
go vet ./...
go test ./...
```

Other checks live in the consumer repos (`gocast-infra` root Makefile, per-service
`make build/test/vet/docker-build`).

## Known issues

- **`LoadConfig` never returns an error.** Misconfigured values degrade silently to defaults with
  only a log line, so a typo in a ConfigMap is a runtime surprise rather than a failed deploy.
- **Empty == unset.** `getEnv` cannot express "explicitly empty"; there is no way to override a
  default with an empty string. This is load-bearing for `METRICS_ADDR=` / `SMTP_ADDR=` as opt-out
  switches, but it also means a stray `REDIS_DB=` silently becomes DB 2.
- **Redis preflight has no timeout** (`context.Background()`), so a hung Redis blocks worker
  startup until the TCP timeout rather than failing fast.
- **`SHUTDOWN_TIMEOUT=50m` default.** Services that inherit it can keep running far longer than
  their pod's `terminationGracePeriodSeconds`; asynq will be killed mid-task by the kubelet.
- **Metrics endpoint has no lifecycle management.** It is fire-and-forget inside
  `NewAsynqServer`, exposes no readiness probe, and a port clash is only logged, so the worker then
  runs with no metrics and no visible error.
- **`asynq_task_processed_total{status="error"}` counts deliberate `SkipRetry` returns** as failures,
  so terminal-failure handling (missing sources, bad payloads) shows up in dashboards as errors.
- **No parse-failure test coverage** in `config`; no tests at all in `worker`, `metrics` or
  `grpctls`.
- **`config.MinIO` defaults point at a local MinIO** (`localhost:9000`, bucket
  `stream-service-test`, `admin`/`minio123`). A worker that reaches the defaults in a cluster is
  misconfigured, not "working locally".
