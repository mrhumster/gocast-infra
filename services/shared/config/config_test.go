package config

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLoadConfig(t *testing.T) {
	t.Run("defaults", func(t *testing.T) {
		cfg, err := LoadConfig()
		require.NoError(t, err)
		require.NotNil(t, cfg)
		assert.NotEmpty(t, cfg.Server.StreamServiceAddr)
		assert.NotEmpty(t, cfg.Redis.Addr)
		assert.NotEmpty(t, cfg.MinIO.Endpoint)
		assert.NotEmpty(t, cfg.MinIO.AccessKeyID)
		assert.NotEmpty(t, cfg.MinIO.SecretAccessKey)
		assert.NotEmpty(t, cfg.MinIO.BucketName)
		assert.NotEmpty(t, cfg.MinIO.Region)
		assert.Empty(t, cfg.Server.MetricsAddr)
		assert.Empty(t, cfg.Mail.SenderAddr)
		assert.Empty(t, cfg.Mail.From)
		assert.Equal(t, "https://example.com", cfg.Mail.FrontendURL)
		assert.Equal(t, "auto", cfg.Transcoder.Encoder)
		assert.Equal(t, "http://faces-service:80", cfg.Faces.ServiceURL)
		assert.Empty(t, cfg.Faces.InternalToken)
		assert.Equal(t, "http://stream-service:80", cfg.Faces.StreamServiceURL)
		assert.Equal(t, 600*time.Second, cfg.Faces.InferTimeout)
		assert.Equal(t, 30*time.Second, cfg.Worker.RetryDelay)
	})

	t.Run("reads from env", func(t *testing.T) {
		t.Setenv("REDIS_ADDR", "redis:6379")
		t.Setenv("MINIO_BUCKET_NAME", "custom-bucket")
		t.Setenv("WORKER_CONCURRENCY", "4")
		t.Setenv("METRICS_ADDR", ":9090")
		t.Setenv("SMTP_ADDR", "smtp.example.com:587")
		t.Setenv("SMTP_FROM", "no-reply@example.com")
		t.Setenv("FRONTEND_URL", "https://gocast.example.com")
		t.Setenv("TRANSCODER_ENCODER", "vaapi")
		t.Setenv("FACES_SERVICE_URL", "http://faces:8080")
		t.Setenv("FACES_INTERNAL_TOKEN", "s3cret")
		t.Setenv("STREAM_SERVICE_URL", "http://stream:8080")
		t.Setenv("FACES_INFER_TIMEOUT", "10m")
		t.Setenv("WORKER_RETRY_DELAY", "15s")

		cfg, err := LoadConfig()
		require.NoError(t, err)
		assert.Equal(t, "redis:6379", cfg.Redis.Addr)
		assert.Equal(t, "custom-bucket", cfg.MinIO.BucketName)
		assert.Equal(t, 4, cfg.Worker.Concurrency)
		assert.Equal(t, ":9090", cfg.Server.MetricsAddr)
		assert.Equal(t, "smtp.example.com:587", cfg.Mail.SenderAddr)
		assert.Equal(t, "no-reply@example.com", cfg.Mail.From)
		assert.Equal(t, "https://gocast.example.com", cfg.Mail.FrontendURL)
		assert.Equal(t, "vaapi", cfg.Transcoder.Encoder)
		assert.Equal(t, "http://faces:8080", cfg.Faces.ServiceURL)
		assert.Equal(t, "s3cret", cfg.Faces.InternalToken)
		assert.Equal(t, "http://stream:8080", cfg.Faces.StreamServiceURL)
		assert.Equal(t, 10*time.Minute, cfg.Faces.InferTimeout)
		assert.Equal(t, 15*time.Second, cfg.Worker.RetryDelay)
	})
}
