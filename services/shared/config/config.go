package config

import (
	"log/slog"
	"os"
	"strconv"
	"time"
)

type Config struct {
	Redis  Redis
	MinIO  MinIO
	Server Server
	Worker Worker
	Mail   Mail
}

type Worker struct {
	Concurrency     int
	ShutdownTimeout time.Duration
}

type Server struct {
	StreamServiceAddr string
	GRPCTLSCertFile   string
	GRPCTLSKeyFile    string
	GRPCTLSCAFile     string
	GRPCTLSEnabled    bool
	MetricsAddr       string
}

type Redis struct {
	Addr     string
	Password string
	DB       int
}

type MinIO struct {
	Endpoint        string
	AccessKeyID     string
	SecretAccessKey string
	BucketName      string
	UseSSL          bool
	Region          string
}

// Mail configures the outgoing email transport of a notification worker.
// SenderAddr empty turns the worker into log-only mode (no real delivery).
type Mail struct {
	SenderAddr  string // SMTP_ADDR, e.g. smtp.example.com:587
	SenderUser  string // SMTP_USER
	SenderPass  string // SMTP_PASS
	From        string // SMTP_FROM, sender address used in headers
	FrontendURL string // FRONTEND_URL, base for links in messages
}

func LoadConfig() (*Config, error) {
	useSSL, err := strconv.ParseBool(getEnv("MINIO_USE_SSL", "false"))
	if err != nil {
		slog.Error("Minio use SSL from config parse failed. The defaul value is `False`", "error", err)
		useSSL = false
	}
	redisDB, err := strconv.ParseUint(getEnv("REDIS_DB", "2"), 10, 32)
	if err != nil {
		slog.Error("Redis DB from config parse failed. The dafault value is `2`", "error", err)
		redisDB = 2
	}
	concurrency, err := strconv.ParseUint(getEnv("WORKER_CONCURRENCY", "1"), 10, 32)
	if err != nil {
		slog.Error("Worker concurrency from config parse failed. The defaul value is `1`", "error", err)
		concurrency = 1
	}

	shutdownTimeout, err := time.ParseDuration(getEnv("WORKER_SHUTDOWN_TIMEOUT", "50m"))
	if err != nil {
		slog.Error("Worker shutdown timeout from config parse failed. The defaul value is `50m`")
		shutdownTimeout = 50 * time.Minute
	}

	return &Config{
		Redis: Redis{
			Addr:     getEnv("REDIS_ADDR", "localhost"),
			Password: getEnv("redis-password", ""),
			DB:       int(redisDB),
		},
		MinIO: MinIO{
			Endpoint:        getEnv("MINIO_ENDPOINT", "localhost:9000"),
			AccessKeyID:     getEnv("MINIO_ACCESS_KEY", "admin"),
			SecretAccessKey: getEnv("MINIO_SECRET_KEY", "minio123"),
			BucketName:      getEnv("MINIO_BUCKET_NAME", "stream-service-test"),
			UseSSL:          useSSL,
			Region:          getEnv("MINIO_REGION", "ru-east-1"),
		},
		Server: Server{
			StreamServiceAddr: getEnv("STREAM_SERVICE_ADDR", "localhost:50051"),
			GRPCTLSCertFile:   os.Getenv("GRPC_TLS_CERT"),
			GRPCTLSKeyFile:    os.Getenv("GRPC_TLS_KEY"),
			GRPCTLSCAFile:     os.Getenv("GRPC_TLS_CA"),
			GRPCTLSEnabled:    getBool("GRPC_TLS_ENABLED"),
			MetricsAddr:       getEnv("METRICS_ADDR", ""),
		},
		Worker: Worker{
			Concurrency:     int(concurrency),
			ShutdownTimeout: shutdownTimeout,
		},
		Mail: Mail{
			SenderAddr:  getEnv("SMTP_ADDR", ""),
			SenderUser:  getEnv("SMTP_USER", ""),
			SenderPass:  getEnv("SMTP_PASS", ""),
			From:        getEnv("SMTP_FROM", ""),
			FrontendURL: getEnv("FRONTEND_URL", "https://example.com"),
		},
	}, nil
}

func getEnv(key, defaultValue string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultValue
}

func getBool(key string) bool {
	v, _ := strconv.ParseBool(os.Getenv(key))
	return v
}