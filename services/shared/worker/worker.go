// Package worker provides a shared Asynq worker skeleton used by
// background worker services (thumbnail, transcoder, and future
// queue-based services such as notification).
//
// It encapsulates the common concerns of an Asynq worker: creating the
// Redis client options, verifying connectivity to Redis at startup, and
// wiring an ErrorHandler that reports task failures back to the caller
// so the service can notify stream-service via gRPC.
package worker

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/hibiken/asynq"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/redis/go-redis/v9"
)

// ErrorReporter is called by the default ErrorHandler for every failed
// task. Implementations typically unmarshal the task payload and report
// the failure back to stream-service (UpdateStreamProcessing) so the
// frontend can surface an error to the user.
type ErrorReporter func(ctx context.Context, task *asynq.Task, err error)

// Options configures the shared Asynq worker skeleton.
type Options struct {
	Addr            string         // Redis address (host:port)
	Password        string         // Redis password (may be empty)
	DB              int            // Redis logical database
	Concurrency     int            // Asynq worker concurrency
	ShutdownTimeout time.Duration  // Grace period for in-flight tasks on shutdown
	Queues          map[string]int // Asynq queue -> priority map
	ErrorReporter   ErrorReporter  // Optional; default no-op
	MetricsAddr     string         // Optional; if set, expose Prometheus /metrics on this addr
}

// NewAsynqServer builds an *asynq.Server, first verifying Redis
// connectivity (a health check that both workers previously wanted but
// only one had). It returns an error if Redis is unreachable.
func NewAsynqServer(o Options) (*asynq.Server, error) {
	redisOpt := asynq.RedisClientOpt{
		Addr:     o.Addr,
		Password: o.Password,
		DB:       o.DB,
	}

	// Fail fast if Redis is down instead of silently queueing.
	checkClient := redisOpt.MakeRedisClient().(redis.UniversalClient)
	if err := checkClient.Ping(context.Background()).Err(); err != nil {
		slog.Error("Redis connection failed", "error", err)
		return nil, err
	}
	checkClient.Close()

	reporter := o.ErrorReporter
	if reporter == nil {
		reporter = func(context.Context, *asynq.Task, error) {}
	}

	cfg := asynq.Config{
		Concurrency:     o.Concurrency,
		ShutdownTimeout: o.ShutdownTimeout,
		Queues:          o.Queues,
		ErrorHandler: asynq.ErrorHandlerFunc(func(ctx context.Context, task *asynq.Task, err error) {
			reporter(ctx, task, err)
		}),
	}

	if o.MetricsAddr != "" {
		startMetricsServer(o.MetricsAddr)
	}

	return asynq.NewServer(redisOpt, cfg), nil
}

// startMetricsServer exposes Prometheus metrics on the given address in a
// background goroutine. The process-wide default registry already includes
// the Go and process collectors.
func startMetricsServer(addr string) {
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	srv := &http.Server{Addr: addr, Handler: mux}
	go func() {
		slog.Info("metrics server started", "addr", addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("metrics server failed", "addr", addr, "error", err)
		}
	}()
}
