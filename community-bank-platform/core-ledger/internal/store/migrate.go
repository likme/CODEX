package store

import (
	"context"
	"embed"
	"fmt"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

func Migrate(ctx context.Context, db *pgxpool.Pool) error {
	entries, err := migrationsFS.ReadDir("migrations")
	if err != nil {
		return err
	}
	var files []string
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".sql") {
			files = append(files, "migrations/"+e.Name())
		}
	}
	sort.Strings(files)

	for _, f := range files {
		sqlBytes, err := migrationsFS.ReadFile(f)
		if err != nil {
			return err
		}
		if _, err := db.Exec(ctx, string(sqlBytes)); err != nil {
			return fmt.Errorf("migration %s failed: %w", f, err)
		}
	}
	return nil
}
