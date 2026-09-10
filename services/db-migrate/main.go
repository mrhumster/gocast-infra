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
	_ "github.com/lib/pq"
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
		log.Fatalf("usage: db-migrate -target=identity|stream")
	}

	var dir, table string
	switch *target {
	case "identity":
		dir, table = "migrations/identity", "schema_migrations_identity"
	case "stream":
		dir, table = "migrations/stream", "schema_migrations_stream"
	default:
		log.Fatalf("unknown target %q: must be identity or stream", *target)
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