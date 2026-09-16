package main

import (
	"database/sql"
	"embed"
	"flag"
	"fmt"
	"log"
	"os"

	"github.com/golang-migrate/migrate/v4"
	"github.com/golang-migrate/migrate/v4/database/postgres"
	"github.com/golang-migrate/migrate/v4/source/iofs"
	pq "github.com/lib/pq"
)

var (
	version   = "dev"
	buildDate = "unknown"
)

//go:embed migrations
var migrationsFS embed.FS

func main() {
	fsSet := flag.NewFlagSet("db-migrate", flag.ExitOnError)
	target := fsSet.String("target", "", "migration target: identity|stream")
	showVersion := fsSet.Bool("version", false, "print version and exit")
	_ = fsSet.Parse(os.Args[1:])

	if *showVersion {
		fmt.Printf("db-migrate version=%s build_date=%s\n", version, buildDate)
		return
	}

	if *target == "" {
		log.Fatalf("usage: db-migrate -target=identity|stream|events|comments|stats")
	}

	var dir, table string
	switch *target {
	case "identity":
		dir, table = "migrations/identity", "schema_migrations_identity"
	case "stream":
		dir, table = "migrations/stream", "schema_migrations_stream"
	case "events":
		dir, table = "migrations/events", "schema_migrations_events"
	case "comments":
		dir, table = "migrations/comments", "schema_migrations_comments"
	case "stats":
		dir, table = "migrations/stats", "schema_migrations_stats"
	default:
		log.Fatalf("unknown target %q: must be identity, stream, events, comments or stats", *target)
	}

	if err := ensureDatabase(); err != nil {
		log.Fatalf("ensure database: %v", err)
	}

	m, err := newMigrate(dir, table)
	if err != nil {
		log.Fatalf("init migrate: %v", err)
	}
	defer m.Close()

	if err := m.Up(); err != nil && err != migrate.ErrNoChange {
		log.Fatalf("migrate up failed: %v", err)
	}

	ver, dirty, err := m.Version()
	if err != nil {
		log.Printf("target=%s: no schema version recorded", *target)
		return
	}
	log.Printf("target=%s version=%d dirty=%v done", *target, ver, dirty)
}

func newMigrate(dir, table string) (*migrate.Migrate, error) {
	src, err := iofs.New(migrationsFS, dir)
	if err != nil {
		return nil, fmt.Errorf("source %s: %w", dir, err)
	}

	dsn := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=disable TimeZone=UTC",
		os.Getenv("DB_HOST"), os.Getenv("DB_PORT"), os.Getenv("DB_USER"), os.Getenv("DB_PASS"), os.Getenv("DB_NAME"))
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, fmt.Errorf("open postgres: %w", err)
	}

	drv, err := postgres.WithInstance(db, &postgres.Config{
		MigrationsTable:       table,
		MultiStatementEnabled: true,
	})
	if err != nil {
		return nil, fmt.Errorf("postgres driver: %w", err)
	}

	m, err := migrate.NewWithInstance("iofs", src, "postgres", drv)
	if err != nil {
		return nil, fmt.Errorf("migrate instance: %w", err)
	}
	return m, nil
}

// ensureDatabase creates the target database if it does not exist yet. The
// maintenance connection uses DB_MAINTENANCE_NAME (default "postgres"); when
// the target equals the maintenance DB (legacy shared database1) this is a no-op.
func ensureDatabase() error {
	target := os.Getenv("DB_NAME")
	maint := os.Getenv("DB_MAINTENANCE_NAME")
	if maint == "" {
		maint = "postgres"
	}
	if target == "" || target == maint {
		return nil
	}

	dsn := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
		os.Getenv("DB_HOST"), os.Getenv("DB_PORT"), os.Getenv("DB_USER"), os.Getenv("DB_PASS"), maint)
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return fmt.Errorf("open maintenance db: %w", err)
	}
	defer db.Close()

	var exists bool
	if err := db.QueryRow("SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)", target).Scan(&exists); err != nil {
		return fmt.Errorf("check database %s: %w", target, err)
	}
	if exists {
		return nil
	}

	if _, err := db.Exec("CREATE DATABASE " + pq.QuoteIdentifier(target)); err != nil {
		return fmt.Errorf("create database %s: %w", target, err)
	}
	log.Printf("created database %q", target)
	return nil
}