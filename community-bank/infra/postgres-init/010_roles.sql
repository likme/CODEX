-- 010_roles.sql
-- Creates least-privilege runtime role for the application.
-- Executed once at DB init time (fresh PGDATA).
-- Dev-only password. Use secrets in prod.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ledger_app') THEN
    CREATE ROLE ledger_app
      LOGIN
      PASSWORD 'ledger'
      NOSUPERUSER
      NOCREATEDB
      NOCREATEROLE
      NOREPLICATION
      NOBYPASSRLS
      INHERIT;
  END IF;
END $$;
