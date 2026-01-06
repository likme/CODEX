-- 000_genesis.sql
--
-- STATUS: DRAFT / PRE-RELEASE
--
-- This schema is NOT frozen.
-- It may change at any time until the first public release.
--
-- Consumers MUST drop and recreate the database when this file changes.
--
-- Once published:
-- - This file will be frozen.
-- - All future schema changes will be done via incremental migrations (002+, 003+, ...).
--
-- Source of truth: internal/store/store.go
--
-- ============================================================


BEGIN;

-- Needed for hashing in the event chain.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =========================
-- Domain types (weapon-grade)
-- =========================

DO $$ BEGIN
  CREATE TYPE entry_direction AS ENUM ('DEBIT','CREDIT');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE idempotency_status AS ENUM ('RESERVED','COMMITTED');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- =========================
-- Core tables
-- =========================

-- Accounts
CREATE TABLE IF NOT EXISTS accounts (
    account_id UUID PRIMARY KEY,
    label TEXT NOT NULL,
    currency CHAR(3) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_accounts_currency CHECK (currency ~ '^[A-Z]{3}$')
);

CREATE INDEX IF NOT EXISTS ix_accounts_label
  ON accounts(label);

-- Idempotency (strict: key -> request_hash, plus replay anchor)
CREATE TABLE IF NOT EXISTS idempotency (
    key TEXT PRIMARY KEY,
    request_hash TEXT NOT NULL,

    -- Bind key -> tx_id and optional replay response
    tx_id UUID,
    response_json JSONB,
    status idempotency_status NOT NULL DEFAULT 'RESERVED',

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_idem_key_nonempty CHECK (length(btrim(key)) > 0),
    CONSTRAINT ck_idem_hash_len64 CHECK (length(request_hash) = 64)
);

-- =========================
-- Idempotency inviolable (DB-level, Option B)
-- =========================
-- Policy:
-- - ledger_app has NO UPDATE on idempotency.
-- - Only mutation path is idem_commit() (SECURITY DEFINER).
-- - Transition allowed: RESERVED -> COMMITTED only.
-- - Once COMMITTED: tx_id/status/response_json immutable.
-- - Guard trigger is ENABLE ALWAYS (non-bypassable via session_replication_role).

CREATE OR REPLACE FUNCTION trg_idempotency_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Immutable columns
  IF NEW.key IS DISTINCT FROM OLD.key THEN
    RAISE EXCEPTION 'idempotency.key is immutable' USING ERRCODE = '42501';
  END IF;

  IF NEW.request_hash IS DISTINCT FROM OLD.request_hash THEN
    RAISE EXCEPTION 'idempotency.request_hash is immutable' USING ERRCODE = '42501';
  END IF;

  IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'idempotency.created_at is immutable' USING ERRCODE = '42501';
  END IF;

  -- Legal status transitions only
  IF OLD.status = 'RESERVED' THEN
    IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status <> 'COMMITTED' THEN
      RAISE EXCEPTION 'illegal idempotency status transition: % -> %', OLD.status, NEW.status
      USING ERRCODE = '42501';
    END IF;
  ELSE
    -- COMMITTED is frozen
    IF NEW.status IS DISTINCT FROM OLD.status THEN
      RAISE EXCEPTION 'idempotency.status is immutable once COMMITTED' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- tx_id set-once
  IF OLD.tx_id IS NOT NULL AND NEW.tx_id IS DISTINCT FROM OLD.tx_id THEN
    RAISE EXCEPTION 'idempotency.tx_id is immutable once set' USING ERRCODE = '42501';
  END IF;

  -- COMMITTED requires tx_id
  IF NEW.status = 'COMMITTED' AND NEW.tx_id IS NULL THEN
    RAISE EXCEPTION 'COMMITTED requires tx_id' USING ERRCODE = '23514';
  END IF;

  -- response_json: only writable during commit, then frozen
  IF OLD.status = 'COMMITTED' AND NEW.response_json IS DISTINCT FROM OLD.response_json THEN
    RAISE EXCEPTION 'idempotency.response_json is immutable once COMMITTED' USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS idempotency_guard ON idempotency;
CREATE TRIGGER idempotency_guard
BEFORE UPDATE ON idempotency
FOR EACH ROW
EXECUTE FUNCTION trg_idempotency_guard();

-- Non-bypassable even under session_replication_role=replica
ALTER TABLE idempotency ENABLE ALWAYS TRIGGER idempotency_guard;

-- Controlled mutation API: commit the idempotency row
-- Returns the stored (replay-safe) record.
CREATE OR REPLACE FUNCTION idem_commit(
  _key TEXT,
  _tx_id UUID,
  _response_json JSONB
)
RETURNS TABLE(
  key TEXT,
  request_hash TEXT,
  tx_id UUID,
  response_json JSONB,
  status idempotency_status,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  r idempotency%ROWTYPE;
BEGIN
  SELECT i.* INTO r
  FROM idempotency i
  WHERE i.key = _key
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'idempotency key not found: %', _key USING ERRCODE = '23503';
  END IF;

  IF r.status = 'COMMITTED' THEN
    RETURN QUERY
      SELECT r.key, r.request_hash, r.tx_id, r.response_json, r.status, r.created_at;
    RETURN;
  END IF;

  UPDATE idempotency i
  SET tx_id = _tx_id,
      response_json = _response_json,
      status = 'COMMITTED'
  WHERE i.key = _key
  RETURNING i.key, i.request_hash, i.tx_id, i.response_json, i.status, i.created_at
  INTO key, request_hash, tx_id, response_json, status, created_at;

  RETURN NEXT;
END;
$$;

-- Hardening: function ownership and exposure
-- IMPORTANT: owner must NOT be ledger_app. Adapt if your DB owner role differs.
ALTER FUNCTION idem_commit(TEXT, UUID, JSONB) OWNER TO ledger;
REVOKE ALL ON FUNCTION idem_commit(TEXT, UUID, JSONB) FROM PUBLIC;

-- Ledger transactions
CREATE TABLE IF NOT EXISTS ledger_tx (
    tx_id UUID PRIMARY KEY,
    external_ref TEXT NOT NULL,
    correlation_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_ledger_tx_external_ref_nonempty CHECK (length(btrim(external_ref)) > 0),
    CONSTRAINT ck_ledger_tx_correlation_id_nonempty CHECK (length(btrim(correlation_id)) > 0),
    CONSTRAINT ck_ledger_tx_idemkey_nonempty CHECK (length(btrim(idempotency_key)) > 0)
);

-- Idempotency -> ledger_tx link (must be after ledger_tx exists)
ALTER TABLE idempotency
  DROP CONSTRAINT IF EXISTS fk_idempotency_tx;

ALTER TABLE idempotency
  ADD CONSTRAINT fk_idempotency_tx
  FOREIGN KEY (tx_id) REFERENCES ledger_tx(tx_id);

CREATE INDEX IF NOT EXISTS ix_idempotency_tx_id
  ON idempotency(tx_id);

-- Enforce ledger_tx always references an idempotency key (replay anchor is guaranteed by DB).
ALTER TABLE ledger_tx
  DROP CONSTRAINT IF EXISTS fk_ledger_tx_idem;

ALTER TABLE ledger_tx
  ADD CONSTRAINT fk_ledger_tx_idem
  FOREIGN KEY (idempotency_key) REFERENCES idempotency(key);

CREATE UNIQUE INDEX IF NOT EXISTS uq_ledger_tx_idem
  ON ledger_tx(idempotency_key);

CREATE UNIQUE INDEX IF NOT EXISTS uq_ledger_tx_external_ref
  ON ledger_tx(external_ref);

CREATE INDEX IF NOT EXISTS ix_ledger_tx_correlation_id
  ON ledger_tx(correlation_id);

-- Ledger entries (double-entry)
CREATE TABLE IF NOT EXISTS ledger_entry (
    entry_id UUID PRIMARY KEY,
    tx_id UUID NOT NULL REFERENCES ledger_tx(tx_id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES accounts(account_id),
    direction entry_direction NOT NULL,
    amount_cents BIGINT NOT NULL,
    currency CHAR(3) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_ledger_entry_amount_pos CHECK (amount_cents > 0),
    CONSTRAINT ck_ledger_entry_currency CHECK (currency ~ '^[A-Z]{3}$')
);

CREATE INDEX IF NOT EXISTS ix_ledger_entry_account
  ON ledger_entry(account_id);

CREATE INDEX IF NOT EXISTS ix_ledger_entry_tx
  ON ledger_entry(tx_id);

CREATE INDEX IF NOT EXISTS ix_ledger_entry_account_dir
  ON ledger_entry(account_id, direction);

-- =========================
-- Event log + tamper-evident chain (weapon-grade, reset-based)
-- =========================

DROP TABLE IF EXISTS event_log CASCADE;
DROP TABLE IF EXISTS event_chain_head CASCADE;

CREATE TABLE event_chain_head (
  id SMALLINT PRIMARY KEY CHECK (id = 1),
  last_seq BIGINT NOT NULL,
  last_hash BYTEA NOT NULL
);

INSERT INTO event_chain_head(id, last_seq, last_hash)
VALUES (1, 0, '\x'::bytea);

-- NOTE:
-- - payload_canonical is required and must be RFC 8785 JCS emitted by the application.
-- - DB verifies payload_canonical::jsonb = payload_json (semantic match).
-- - payload_hash is computed from payload_canonical (not from jsonb::text).
CREATE TABLE event_log (
    event_id UUID PRIMARY KEY,
    event_type TEXT NOT NULL,
    aggregate_type TEXT NOT NULL,
    aggregate_id UUID NOT NULL,
    correlation_id TEXT NOT NULL,

    payload_json JSONB NOT NULL,
    payload_canonical TEXT NOT NULL,

    created_at TIMESTAMPTZ NOT NULL,

    seq BIGINT NOT NULL,
    prev_hash BYTEA NOT NULL,
    payload_hash BYTEA NOT NULL,
    hash BYTEA NOT NULL,

    CONSTRAINT ck_event_log_event_type_nonempty CHECK (length(btrim(event_type)) > 0),
    CONSTRAINT ck_event_log_aggregate_type_nonempty CHECK (length(btrim(aggregate_type)) > 0),
    CONSTRAINT ck_event_log_correlation_id_nonempty CHECK (length(btrim(correlation_id)) > 0),

    CONSTRAINT ck_event_log_payload_canonical_nonempty CHECK (length(btrim(payload_canonical)) > 0),
    CONSTRAINT ck_event_log_payload_semantic_match CHECK (payload_canonical::jsonb = payload_json)
);

CREATE UNIQUE INDEX uq_event_log_seq
  ON event_log(seq);

CREATE INDEX ix_event_log_agg
  ON event_log(aggregate_id);

CREATE INDEX ix_event_log_correlation_id
  ON event_log(correlation_id);

CREATE INDEX ix_event_log_type
  ON event_log(event_type);

CREATE INDEX IF NOT EXISTS ix_event_log_payload_hash
  ON event_log(payload_hash);

-- =========================
-- Weapon-grade guarantees
-- =========================

CREATE OR REPLACE FUNCTION enforce_tx_balanced(_tx_id UUID)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  n INT;
  n_debit INT;
  n_credit INT;
  amt_min BIGINT;
  amt_max BIGINT;
  cur_min CHAR(3);
  cur_max CHAR(3);
BEGIN
  SELECT
    COUNT(*),
    COUNT(*) FILTER (WHERE direction = 'DEBIT'),
    COUNT(*) FILTER (WHERE direction = 'CREDIT'),
    MIN(amount_cents),
    MAX(amount_cents),
    MIN(currency),
    MAX(currency)
  INTO n, n_debit, n_credit, amt_min, amt_max, cur_min, cur_max
  FROM ledger_entry
  WHERE tx_id = _tx_id;

  IF n = 0 THEN
    RETURN;
  END IF;

  IF n <> 2 OR n_debit <> 1 OR n_credit <> 1 THEN
    RAISE EXCEPTION 'unbalanced tx_id=%: expected 2 entries (1 DEBIT, 1 CREDIT), got n=% debit=% credit=%',
      _tx_id, n, n_debit, n_credit
    USING ERRCODE = '23514';
  END IF;

  IF amt_min IS NULL OR amt_max IS NULL OR amt_min <> amt_max THEN
    RAISE EXCEPTION 'unbalanced tx_id=%: amounts mismatch min=% max=%',
      _tx_id, amt_min, amt_max
    USING ERRCODE = '23514';
  END IF;

  IF cur_min IS NULL OR cur_max IS NULL OR cur_min <> cur_max THEN
    RAISE EXCEPTION 'unbalanced tx_id=%: currency mismatch min=% max=%',
      _tx_id, cur_min, cur_max
    USING ERRCODE = '23514';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION trg_check_tx_balanced()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  tx UUID;
BEGIN
  tx := COALESCE(NEW.tx_id, OLD.tx_id);
  PERFORM enforce_tx_balanced(tx);
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS ck_tx_balanced ON ledger_entry;
CREATE CONSTRAINT TRIGGER ck_tx_balanced
AFTER INSERT ON ledger_entry
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION trg_check_tx_balanced();

-- Append-only / immutability
CREATE OR REPLACE FUNCTION forbid_update_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'immutability violation: % on %.% is forbidden', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
  USING ERRCODE = '42501';
END;
$$;

DROP TRIGGER IF EXISTS immut_ledger_tx ON ledger_tx;
CREATE TRIGGER immut_ledger_tx
BEFORE UPDATE OR DELETE ON ledger_tx
FOR EACH ROW
EXECUTE FUNCTION forbid_update_delete();

DROP TRIGGER IF EXISTS immut_ledger_entry ON ledger_entry;
CREATE TRIGGER immut_ledger_entry
BEFORE UPDATE OR DELETE ON ledger_entry
FOR EACH ROW
EXECUTE FUNCTION forbid_update_delete();

DROP TRIGGER IF EXISTS immut_event_log ON event_log;
CREATE TRIGGER immut_event_log
BEFORE UPDATE OR DELETE ON event_log
FOR EACH ROW
EXECUTE FUNCTION forbid_update_delete();

-- Make triggers non-bypassable even if someone could set session_replication_role
ALTER TABLE ledger_tx    ENABLE ALWAYS TRIGGER immut_ledger_tx;
ALTER TABLE ledger_entry ENABLE ALWAYS TRIGGER immut_ledger_entry;
ALTER TABLE event_log    ENABLE ALWAYS TRIGGER immut_event_log;

-- =========================
-- Canonical posting API (DB-level)
-- =========================
-- Policy:
-- - Application must not insert directly into ledger_tx/ledger_entry.
-- - Use this function to create a tx + exactly 2 entries (DEBIT + CREDIT) atomically.
-- - Defense in depth: ck_tx_balanced remains enabled.

CREATE OR REPLACE FUNCTION post_balanced_tx(
  _tx_id UUID,
  _external_ref TEXT,
  _correlation_id TEXT,
  _idempotency_key TEXT,
  _debit_account_id UUID,
  _credit_account_id UUID,
  _amount_cents BIGINT,
  _currency CHAR(3),
  _debit_entry_id UUID DEFAULT gen_random_uuid(),
  _credit_entry_id UUID DEFAULT gen_random_uuid()
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF _tx_id IS NULL THEN
    RAISE EXCEPTION 'tx_id must be non-null' USING ERRCODE = '23502';
  END IF;

  IF length(btrim(COALESCE(_external_ref,''))) = 0 THEN
    RAISE EXCEPTION 'external_ref must be non-empty' USING ERRCODE = '23514';
  END IF;

  IF length(btrim(COALESCE(_correlation_id,''))) = 0 THEN
    RAISE EXCEPTION 'correlation_id must be non-empty' USING ERRCODE = '23514';
  END IF;

  IF length(btrim(COALESCE(_idempotency_key,''))) = 0 THEN
    RAISE EXCEPTION 'idempotency_key must be non-empty' USING ERRCODE = '23514';
  END IF;

  IF _debit_account_id IS NULL OR _credit_account_id IS NULL THEN
    RAISE EXCEPTION 'account ids must be non-null' USING ERRCODE = '23502';
  END IF;

  IF _debit_account_id = _credit_account_id THEN
    RAISE EXCEPTION 'debit and credit accounts must differ' USING ERRCODE = '23514';
  END IF;

  IF _amount_cents IS NULL OR _amount_cents <= 0 THEN
    RAISE EXCEPTION 'amount_cents must be > 0' USING ERRCODE = '23514';
  END IF;

  IF _currency IS NULL OR _currency !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'currency must be [A-Z]{3}' USING ERRCODE = '23514';
  END IF;

  INSERT INTO ledger_tx(tx_id, external_ref, correlation_id, idempotency_key)
  VALUES (_tx_id, _external_ref, _correlation_id, _idempotency_key);

  INSERT INTO ledger_entry(entry_id, tx_id, account_id, direction, amount_cents, currency)
  VALUES
    (_debit_entry_id,  _tx_id, _debit_account_id,  'DEBIT',  _amount_cents, _currency),
    (_credit_entry_id, _tx_id, _credit_account_id, 'CREDIT', _amount_cents, _currency);

  RETURN;
END;
$$;

ALTER FUNCTION post_balanced_tx(UUID,TEXT,TEXT,TEXT,UUID,UUID,BIGINT,CHAR(3),UUID,UUID) OWNER TO ledger;
REVOKE ALL ON FUNCTION post_balanced_tx(UUID,TEXT,TEXT,TEXT,UUID,UUID,BIGINT,CHAR(3),UUID,UUID) FROM PUBLIC;



-- =========================
-- Tamper-evident audit chain for event_log
-- =========================

CREATE OR REPLACE FUNCTION lp(_t TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT length(COALESCE(_t,''))::text || ':' || COALESCE(_t,'');
$$;

CREATE OR REPLACE FUNCTION sha256_utf8(_t TEXT)
RETURNS BYTEA
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT digest(convert_to(COALESCE(_t,''), 'UTF8'), 'sha256');
$$;

CREATE OR REPLACE FUNCTION event_chain_material(
  _seq BIGINT,
  _prev_hash BYTEA,
  _event_id UUID,
  _created_at TIMESTAMPTZ,
  _event_type TEXT,
  _aggregate_type TEXT,
  _aggregate_id UUID,
  _correlation_id TEXT,
  _payload_hash BYTEA
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
      lp(_seq::text)
   || lp(encode(COALESCE(_prev_hash,'\x'::bytea), 'hex'))
   || lp(_event_id::text)
   || lp(to_char(_created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'))
   || lp(COALESCE(_event_type,''))
   || lp(COALESCE(_aggregate_type,''))
   || lp(_aggregate_id::text)
   || lp(COALESCE(_correlation_id,''))
   || lp(encode(COALESCE(_payload_hash,'\x'::bytea), 'hex'));
$$;

CREATE OR REPLACE FUNCTION trg_event_log_hash_chain()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  head_seq BIGINT;
  head_hash BYTEA;
BEGIN
  -- created_at must be DB-owned
  IF NEW.created_at IS NOT NULL THEN
    RAISE EXCEPTION 'created_at must be NULL (DB-owned)'
    USING ERRCODE = '23514';
  END IF;

  -- Enforce canonical payload presence (RFC 8785 JCS produced by app).
  IF length(btrim(COALESCE(NEW.payload_canonical,''))) = 0 THEN
    RAISE EXCEPTION 'payload_canonical must be non-empty (RFC 8785 JCS, app-owned)'
    USING ERRCODE = '23514';
  END IF;

  -- Ensure it parses and semantically matches payload_json (Postgres jsonb is semantic).
  IF (NEW.payload_canonical::jsonb <> NEW.payload_json) THEN
    RAISE EXCEPTION 'payload_canonical must parse as JSON and match payload_json'
    USING ERRCODE = '23514';
  END IF;

  SELECT last_seq, last_hash INTO head_seq, head_hash
  FROM event_chain_head
  WHERE id = 1
  FOR UPDATE;

  NEW.seq := head_seq + 1;
  NEW.prev_hash := head_hash;

  NEW.created_at := statement_timestamp();

  -- Hash only the canonical string (no jsonb::text dependency).
  NEW.payload_hash := sha256_utf8(NEW.payload_canonical);

  NEW.hash := sha256_utf8(
    event_chain_material(
      NEW.seq,
      NEW.prev_hash,
      NEW.event_id,
      NEW.created_at,
      NEW.event_type,
      NEW.aggregate_type,
      NEW.aggregate_id,
      NEW.correlation_id,
      NEW.payload_hash
    )
  );

  UPDATE event_chain_head
  SET last_seq = NEW.seq,
      last_hash = NEW.hash
  WHERE id = 1;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS event_log_hash_chain ON event_log;
CREATE TRIGGER event_log_hash_chain
BEFORE INSERT ON event_log
FOR EACH ROW
EXECUTE FUNCTION trg_event_log_hash_chain();

ALTER TABLE event_log ENABLE ALWAYS TRIGGER event_log_hash_chain;

CREATE OR REPLACE FUNCTION verify_event_chain_detail()
RETURNS TABLE(
  ok BOOLEAN,
  break_seq BIGINT,
  reason TEXT,
  head_seq BIGINT,
  head_hash_hex TEXT,
  event_count BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
  r RECORD;
  prev BYTEA := '\x'::bytea;
  v_last_seq BIGINT := 0;
  expected_payload_hash BYTEA;
  expected_hash BYTEA;
  h_seq BIGINT;
  h_hash BYTEA;
  cnt BIGINT := 0;
  last_event_hash BYTEA := '\x'::bytea;
BEGIN
  SELECT h.last_seq, h.last_hash INTO h_seq, h_hash
  FROM event_chain_head h
  WHERE h.id = 1;

  FOR r IN
    SELECT seq, prev_hash, payload_hash, hash,
           event_id, created_at,
           event_type, aggregate_type, aggregate_id, correlation_id,
           payload_json, payload_canonical
    FROM event_log
    ORDER BY seq ASC
  LOOP
    cnt := cnt + 1;

    IF r.seq <> v_last_seq + 1 THEN
      RETURN QUERY SELECT FALSE, r.seq, format('bad seq: got %s expected %s', r.seq, v_last_seq + 1),
                          h_seq, encode(h_hash,'hex'), cnt;
      RETURN;
    END IF;

    IF r.prev_hash <> prev THEN
      RETURN QUERY SELECT FALSE, r.seq, 'prev_hash mismatch',
                          h_seq, encode(h_hash,'hex'), cnt;
      RETURN;
    END IF;

    -- Verify payload canonical invariants.
    IF length(btrim(COALESCE(r.payload_canonical,''))) = 0 THEN
      RETURN QUERY SELECT FALSE, r.seq, 'payload_canonical empty',
                          h_seq, encode(h_hash,'hex'), cnt;
      RETURN;
    END IF;

    IF (r.payload_canonical::jsonb <> r.payload_json) THEN
      RETURN QUERY SELECT FALSE, r.seq, 'payload_canonical != payload_json',
                          h_seq, encode(h_hash,'hex'), cnt;
      RETURN;
    END IF;

    expected_payload_hash := sha256_utf8(r.payload_canonical);
    IF r.payload_hash <> expected_payload_hash THEN
      RETURN QUERY SELECT FALSE, r.seq, 'payload_hash mismatch',
                          h_seq, encode(h_hash,'hex'), cnt;
      RETURN;
    END IF;

    expected_hash := sha256_utf8(
      event_chain_material(
        r.seq, r.prev_hash, r.event_id, r.created_at,
        r.event_type, r.aggregate_type, r.aggregate_id, r.correlation_id, r.payload_hash
      )
    );

    IF r.hash <> expected_hash THEN
      RETURN QUERY SELECT FALSE, r.seq, 'hash mismatch',
                          h_seq, encode(h_hash,'hex'), cnt;
      RETURN;
    END IF;

    prev := r.hash;
    last_event_hash := r.hash;
    v_last_seq := r.seq;
  END LOOP;

  IF v_last_seq <> h_seq THEN
    RETURN QUERY SELECT FALSE, v_last_seq, 'head last_seq mismatch',
                        h_seq, encode(h_hash,'hex'), cnt;
    RETURN;
  END IF;

  IF v_last_seq > 0 AND h_hash <> last_event_hash THEN
    RETURN QUERY SELECT FALSE, v_last_seq, 'head last_hash mismatch',
                        h_seq, encode(h_hash,'hex'), cnt;
    RETURN;
  END IF;

  RETURN QUERY SELECT TRUE, NULL::bigint, NULL::text, h_seq, encode(h_hash,'hex'), cnt;
END;
$$;

CREATE OR REPLACE FUNCTION verify_event_chain()
RETURNS BOOLEAN
LANGUAGE sql
AS $$
  SELECT ok FROM verify_event_chain_detail();
$$;



-- ACCOUNT ALIAS

CREATE TABLE IF NOT EXISTS account_alias (
  alias_type   TEXT NOT NULL,    -- 'IBAN'
  alias_value  TEXT NOT NULL,    -- 'FR76...'
  account_id   UUID NOT NULL REFERENCES accounts(account_id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (alias_type, alias_value)
);

CREATE INDEX IF NOT EXISTS account_alias_account_id_idx
  ON account_alias(account_id);



-- Append-only “value + liquidity” layer with event_log proofs.
-- Must NOT modify 001_init.sql.
--
-- Idempotence contract (snapshots) when using RFC 8785 (JCS):
-- - The application computes payload_hash = SHA-256( JCS(payload_json) + key fields in a fixed app-level shape ).
-- - The DB does NOT canonicalize JSON. It only enforces:
--     * payload_hash is present and is 32 bytes
--     * payload_canonical is present and non-empty (app-owned JCS)
--     * uniqueness across the idempotence key (including payload_hash)
-- - On retry/replay of the exact same snapshot, insertion hits the UNIQUE constraint.
--   This migration intentionally chooses "raise error" (not DO NOTHING) so the
--   event_log proof remains 1:1 with successful snapshot inserts (no parasite events).
--
-- Batch audit contract (risk feed):
-- - ingestion_correlation_id identifies an ingestion batch/run.
-- - event_log.correlation_id is set to ingestion_correlation_id (not snapshot_id::text),
--   so a whole batch can be queried via correlation_id.

-- --------------------------------------------------------------------
-- 1) Tables (append-only)
-- NOTE: NO created_at column. DB-owned time is in event_log only.
-- --------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS valuation_snapshot (
  snapshot_id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ingestion_correlation_id  TEXT NOT NULL,

  asset_type    TEXT NOT NULL,
  asset_id      TEXT NOT NULL,
  as_of         TIMESTAMPTZ NOT NULL,
  price         NUMERIC NOT NULL,
  currency      CHAR(3) NOT NULL,
  source        TEXT NOT NULL,
  confidence    SMALLINT NOT NULL,

  payload_json       JSONB NOT NULL,
  payload_canonical  TEXT NOT NULL,

  -- RFC 8785 (JCS) hash is computed by the application, not by Postgres.
  payload_hash  BYTEA NOT NULL,

  CONSTRAINT valuation_currency_chk
    CHECK (currency ~ '^[A-Z]{3}$'),
  CONSTRAINT valuation_price_chk
    CHECK (price >= 0),
  CONSTRAINT valuation_confidence_chk
    CHECK (confidence >= 0 AND confidence <= 100),
  CONSTRAINT valuation_payload_canonical_nonempty_chk
    CHECK (length(payload_canonical) > 0),
  CONSTRAINT valuation_payload_semantic_match_chk
    CHECK (payload_canonical::jsonb = payload_json),
  CONSTRAINT valuation_payload_hash_len_chk
    CHECK (octet_length(payload_hash) = 32)
);

-- If the table already existed (CREATE TABLE IF NOT EXISTS), ensure new columns exist and are NOT NULL.
ALTER TABLE IF EXISTS valuation_snapshot
  ADD COLUMN IF NOT EXISTS ingestion_correlation_id TEXT;

ALTER TABLE IF EXISTS valuation_snapshot
  ADD COLUMN IF NOT EXISTS payload_canonical TEXT;

UPDATE valuation_snapshot
  SET ingestion_correlation_id = 'legacy'
  WHERE ingestion_correlation_id IS NULL;

UPDATE valuation_snapshot
  SET payload_canonical = payload_json::text
  WHERE payload_canonical IS NULL;

ALTER TABLE IF EXISTS valuation_snapshot
  ALTER COLUMN ingestion_correlation_id SET NOT NULL;

ALTER TABLE IF EXISTS valuation_snapshot
  ALTER COLUMN payload_canonical SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'valuation_payload_canonical_nonempty_chk'
  ) THEN
    ALTER TABLE valuation_snapshot
      ADD CONSTRAINT valuation_payload_canonical_nonempty_chk
      CHECK (length(payload_canonical) > 0);
  END IF;

  -- Important: semantic match requires payload_canonical valid JSON.
  -- Backfill above must have run first.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'valuation_payload_semantic_match_chk'
  ) THEN
    ALTER TABLE valuation_snapshot
      ADD CONSTRAINT valuation_payload_semantic_match_chk
      CHECK (payload_canonical::jsonb = payload_json);
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'valuation_snapshot'
      AND column_name  = 'payload_hash'
  ) THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint WHERE conname = 'valuation_payload_hash_len_chk'
    ) THEN
      ALTER TABLE valuation_snapshot
        ADD CONSTRAINT valuation_payload_hash_len_chk
        CHECK (octet_length(payload_hash) = 32);
    END IF;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS valuation_snapshot_asset_asof_idx
  ON valuation_snapshot(asset_type, asset_id, as_of);

CREATE INDEX IF NOT EXISTS valuation_snapshot_ingestion_corr_idx
  ON valuation_snapshot(ingestion_correlation_id);

-- Idempotence key: same snapshot content cannot be inserted twice.
-- We include source (requested) and payload_hash (content-derived, RFC 8785 by app).
CREATE UNIQUE INDEX IF NOT EXISTS valuation_snapshot_idempotence_uq
  ON valuation_snapshot(asset_type, asset_id, as_of, source, payload_hash);

CREATE TABLE IF NOT EXISTS liquidity_snapshot (
  snapshot_id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ingestion_correlation_id  TEXT NOT NULL,

  asset_type            TEXT NOT NULL,
  asset_id              TEXT NOT NULL,
  as_of                 TIMESTAMPTZ NOT NULL,
  haircut_bps           INT NOT NULL,
  time_to_cash_seconds  INT NOT NULL,
  source                TEXT NOT NULL,

  payload_json       JSONB NOT NULL,
  payload_canonical  TEXT NOT NULL,

  -- RFC 8785 (JCS) hash is computed by the application, not by Postgres.
  payload_hash          BYTEA NOT NULL,

  CONSTRAINT liquidity_haircut_chk
    CHECK (haircut_bps >= 0 AND haircut_bps <= 10000),
  CONSTRAINT liquidity_ttc_chk
    CHECK (time_to_cash_seconds >= 0),
  CONSTRAINT liquidity_payload_canonical_nonempty_chk
    CHECK (length(payload_canonical) > 0),
  CONSTRAINT liquidity_payload_semantic_match_chk
    CHECK (payload_canonical::jsonb = payload_json),
  CONSTRAINT liquidity_payload_hash_len_chk
    CHECK (octet_length(payload_hash) = 32)
);

ALTER TABLE IF EXISTS liquidity_snapshot
  ADD COLUMN IF NOT EXISTS ingestion_correlation_id TEXT;

ALTER TABLE IF EXISTS liquidity_snapshot
  ADD COLUMN IF NOT EXISTS payload_canonical TEXT;

UPDATE liquidity_snapshot
  SET ingestion_correlation_id = 'legacy'
  WHERE ingestion_correlation_id IS NULL;

UPDATE liquidity_snapshot
  SET payload_canonical = payload_json::text
  WHERE payload_canonical IS NULL;

ALTER TABLE IF EXISTS liquidity_snapshot
  ALTER COLUMN ingestion_correlation_id SET NOT NULL;

ALTER TABLE IF EXISTS liquidity_snapshot
  ALTER COLUMN payload_canonical SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'liquidity_payload_canonical_nonempty_chk'
  ) THEN
    ALTER TABLE liquidity_snapshot
      ADD CONSTRAINT liquidity_payload_canonical_nonempty_chk
      CHECK (length(payload_canonical) > 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'liquidity_payload_semantic_match_chk'
  ) THEN
    ALTER TABLE liquidity_snapshot
      ADD CONSTRAINT liquidity_payload_semantic_match_chk
      CHECK (payload_canonical::jsonb = payload_json);
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'liquidity_snapshot'
      AND column_name  = 'payload_hash'
  ) THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint WHERE conname = 'liquidity_payload_hash_len_chk'
    ) THEN
      ALTER TABLE liquidity_snapshot
        ADD CONSTRAINT liquidity_payload_hash_len_chk
        CHECK (octet_length(payload_hash) = 32);
    END IF;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS liquidity_snapshot_asset_asof_idx
  ON liquidity_snapshot(asset_type, asset_id, as_of);

CREATE INDEX IF NOT EXISTS liquidity_snapshot_ingestion_corr_idx
  ON liquidity_snapshot(ingestion_correlation_id);

CREATE UNIQUE INDEX IF NOT EXISTS liquidity_snapshot_idempotence_uq
  ON liquidity_snapshot(asset_type, asset_id, as_of, source, payload_hash);

-- --------------------------------------------------------------------
-- 2) Immutability (reuse forbid_update_delete() from 001)
-- --------------------------------------------------------------------

DO $$
BEGIN
  IF to_regprocedure('forbid_update_delete()') IS NULL THEN
    RAISE EXCEPTION 'forbid_update_delete() is missing. 001_init.sql must define it.';
  END IF;
END $$;

DROP TRIGGER IF EXISTS valuation_snapshot_immutability ON valuation_snapshot;
CREATE TRIGGER valuation_snapshot_immutability
BEFORE UPDATE OR DELETE ON valuation_snapshot
FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();

DROP TRIGGER IF EXISTS liquidity_snapshot_immutability ON liquidity_snapshot;
CREATE TRIGGER liquidity_snapshot_immutability
BEFORE UPDATE OR DELETE ON liquidity_snapshot
FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();

ALTER TABLE valuation_snapshot ENABLE ALWAYS TRIGGER valuation_snapshot_immutability;
ALTER TABLE liquidity_snapshot ENABLE ALWAYS TRIGGER liquidity_snapshot_immutability;

-- --------------------------------------------------------------------
-- 3) event_log proof for each snapshot (compatible with your schema)
--
-- IMPORTANT:
-- - correlation_id = ingestion_correlation_id (batch trace)
-- - aggregate_id   = snapshot_id (row trace)
-- --------------------------------------------------------------------

CREATE OR REPLACE FUNCTION trg_valuation_snapshot_event_log()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  INSERT INTO public.event_log (
    event_id,
    event_type,
    aggregate_type,
    aggregate_id,
    correlation_id,
    payload_json,
    payload_canonical,
    created_at
  )
  VALUES (
    gen_random_uuid(),
    'VALUATION_SNAPSHOT',
    'RISK_SNAPSHOT',
    NEW.snapshot_id,
    NEW.ingestion_correlation_id,
    NEW.payload_json,
    NEW.payload_canonical,
    NULL
  );

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION trg_liquidity_snapshot_event_log()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  INSERT INTO public.event_log (
    event_id,
    event_type,
    aggregate_type,
    aggregate_id,
    correlation_id,
    payload_json,
    payload_canonical,
    created_at
  )
  VALUES (
    gen_random_uuid(),
    'LIQUIDITY_SNAPSHOT',
    'RISK_SNAPSHOT',
    NEW.snapshot_id,
    NEW.ingestion_correlation_id,
    NEW.payload_json,
    NEW.payload_canonical,
    NULL
  );

  RETURN NEW;
END;
$$;

-- Hardening: ownership and exposure (owner must not be ledger_app)
ALTER FUNCTION trg_valuation_snapshot_event_log() OWNER TO ledger;
ALTER FUNCTION trg_liquidity_snapshot_event_log() OWNER TO ledger;
REVOKE ALL ON FUNCTION trg_valuation_snapshot_event_log() FROM PUBLIC;
REVOKE ALL ON FUNCTION trg_liquidity_snapshot_event_log() FROM PUBLIC;

-- Triggers: actually attach the functions to the snapshot tables
DROP TRIGGER IF EXISTS valuation_snapshot_event_log ON valuation_snapshot;
CREATE TRIGGER valuation_snapshot_event_log
AFTER INSERT ON valuation_snapshot
FOR EACH ROW EXECUTE FUNCTION trg_valuation_snapshot_event_log();

DROP TRIGGER IF EXISTS liquidity_snapshot_event_log ON liquidity_snapshot;
CREATE TRIGGER liquidity_snapshot_event_log
AFTER INSERT ON liquidity_snapshot
FOR EACH ROW EXECUTE FUNCTION trg_liquidity_snapshot_event_log();

-- Non-bypassable
ALTER TABLE valuation_snapshot ENABLE ALWAYS TRIGGER valuation_snapshot_event_log;
ALTER TABLE liquidity_snapshot ENABLE ALWAYS TRIGGER liquidity_snapshot_event_log;

-- --------------------------------------------------------------------
-- 4) Optional: read-only role for risk reads
-- --------------------------------------------------------------------


DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ledger_risk_ro') THEN
    CREATE ROLE ledger_risk_ro NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO ledger_risk_ro;
GRANT SELECT ON valuation_snapshot, liquidity_snapshot TO ledger_risk_ro;

-- ============================================================
-- Least-privilege runtime role grants (ledger_app)
-- ============================================================

REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

GRANT USAGE ON SCHEMA public TO ledger_app;

GRANT SELECT, INSERT ON TABLE accounts TO ledger_app;

-- Read-only on ledger tables. Posting must go through post_balanced_tx().
GRANT SELECT ON TABLE ledger_tx TO ledger_app;
GRANT SELECT ON TABLE ledger_entry TO ledger_app;

REVOKE INSERT ON TABLE ledger_tx FROM ledger_app;
REVOKE INSERT ON TABLE ledger_entry FROM ledger_app;

GRANT EXECUTE ON FUNCTION post_balanced_tx(UUID,TEXT,TEXT,TEXT,UUID,UUID,BIGINT,CHAR(3),UUID,UUID) TO ledger_app;

GRANT INSERT ON TABLE event_log TO ledger_app;


-- Idempotency:
-- - No direct UPDATE grant
-- - Commit path via SECURITY DEFINER function
GRANT SELECT, INSERT ON TABLE idempotency TO ledger_app;
REVOKE UPDATE ON TABLE idempotency FROM ledger_app;
GRANT EXECUTE ON FUNCTION idem_commit(TEXT, UUID, JSONB) TO ledger_app;

GRANT EXECUTE ON FUNCTION verify_event_chain() TO ledger_app;
GRANT EXECUTE ON FUNCTION verify_event_chain_detail() TO ledger_app;

REVOKE ALL ON TABLE event_chain_head FROM ledger_app;
GRANT SELECT ON TABLE event_chain_head TO ledger_app;

GRANT SELECT, INSERT ON TABLE account_alias TO ledger_app;

COMMIT;
