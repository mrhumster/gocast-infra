// Package metrics provides Prometheus instrumentation for the shared
// Asynq worker skeleton. Metrics are registered on the process-wide
// default registry, which is safe because each worker binary runs in its
// own process.
package metrics

import (
	"context"
	"time"

	"github.com/hibiken/asynq"
	"github.com/prometheus/client_golang/prometheus"
)

var (
	taskProcessed = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "asynq_task_processed_total",
		Help: "Total number of Asynq tasks processed by result.",
	}, []string{"task", "status"})

	taskDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "asynq_task_duration_seconds",
		Help:    "Duration of Asynq task processing in seconds.",
		Buckets: prometheus.DefBuckets,
	}, []string{"task"})

	taskInflight = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "asynq_task_inflight",
		Help: "Number of Asynq tasks currently being processed.",
	}, []string{"task"})
)

func init() {
	prometheus.MustRegister(taskProcessed, taskDuration, taskInflight)
}

// ObserveTask records the processing of a single Asynq task.
func ObserveTask(task string, err error, durationSeconds float64) {
	taskInflight.WithLabelValues(task).Dec()
	status := "success"
	if err != nil {
		status = "error"
	}
	taskProcessed.WithLabelValues(task, status).Inc()
	taskDuration.WithLabelValues(task).Observe(durationSeconds)
}

// IncInflight marks the start of a task; call ObserveTask when it finishes.
// We keep Dec inside ObserveTask so call sites only need a single call for
// both accounting and timing.
func IncInflight(task string) {
	taskInflight.WithLabelValues(task).Inc()
}

// Instrument wraps an Asynq task handler, recording processing count,
// duration and in-flight gauge. task is the asynq task type label.
func Instrument(task string, fn asynq.HandlerFunc) asynq.HandlerFunc {
	return func(ctx context.Context, t *asynq.Task) error {
		IncInflight(task)
		start := time.Now()
		err := fn(ctx, t)
		ObserveTask(task, err, time.Since(start).Seconds())
		return err
	}
}