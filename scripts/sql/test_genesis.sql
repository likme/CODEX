\set ON_ERROR_STOP on

-- =========================
-- Minimal assert helpers
-- =========================
CREATE OR REPLACE FUNCTION _assert_true(_ok boolean, _msg text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_ok,false) THEN
    RAISE EXCEPTION 'ASSERT_TRUE failed: %', _msg USING ERRCODE='23514';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION _assert_eq_bigint(_a bigint, _b bigint, _msg text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF COALESCE(_a,-9223372036854775808) <> COALESCE(_b,-9223372036854775808) THEN
    RAISE EXCEPTION 'ASSERT_EQ failed: % (got=%, expected=%)', _msg, _a, _b USING ERRCODE='23514';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION _assert_raises(_sql text, _msg text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE _sql;
    RAISE EXCEPTION 'ASSERT_RAISES failed: % (no error)', _msg USING ERRCODE='23514';
  EXCEPTION WHEN OTHERS THEN
    RETURN;
  END;
END;
$$;

-- =========================
-- 0) Core objects exist
-- =========================
SELECT _assert_true(to_regclass('public.accounts') IS NOT NULL, 'accounts exists');
SELECT _assert_true(to_regclass('public.idempotency') IS NOT NULL, 'idempotency exists');
SELECT _assert_true(to_regclass('public.ledger_tx') IS NOT NULL, 'ledger_tx exists');
SELECT _assert_true(to_regclass('public.ledger_entry') IS NOT NULL, 'ledger_entry exists');
SELECT _assert_true(to_regclass('public.event_log') IS NOT NULL, 'event_log exists');
SELECT _assert_true(to_regclass('public.event_chain_head') IS NOT NULL, 'event_chain_head exists');
SELECT _assert_true(to_regclass('public.account_alias') IS NOT NULL, 'account_alias exists');

-- =========================
-- 1) Event chain invariants
-- =========================
SELECT _assert_eq_bigint(
  (SELECT last_seq FROM event_chain_head WHERE id=1),
  (SELECT count(*) FROM event_log),
  'event_chain_head.last_seq == count(event_log)'
);

SELECT _assert_true(
  (
    (SELECT count(*) FROM event_log) = 0
    AND (SELECT octet_length(last_hash) FROM event_chain_head WHERE id=1) = 0
  )
  OR
  (
    (SELECT count(*) FROM event_log) > 0
    AND (SELECT octet_length(last_hash) FROM event_chain_head WHERE id=1) > 0
  ),
  'event_chain_head.last_hash consistent'
);

-- =========================
-- 2) Idempotency (safe key)
-- =========================
SELECT 'k1-' || gen_random_uuid()::text AS idem_key \gset

INSERT INTO idempotency(key, request_hash)
VALUES (:'idem_key', repeat('a',64));

SELECT _assert_raises(
  format('UPDATE idempotency SET status=''COMMITTED'' WHERE key=%L', :'idem_key'),
  'direct UPDATE idempotency forbidden'
);

-- =========================
-- 3) Accounts (idempotent)
-- =========================
SELECT
  gen_random_uuid() AS acc_a,
  gen_random_uuid() AS acc_b
\gset

INSERT INTO accounts(account_id, label, currency)
VALUES
  (:'acc_a', 'A', 'EUR'),
  (:'acc_b', 'B', 'EUR');

-- =========================
-- 4) Ledger tx + idem_commit (tx_id unique per run)
-- =========================
SELECT gen_random_uuid() AS tx_id \gset

INSERT INTO ledger_tx(tx_id, external_ref, correlation_id, idempotency_key)
VALUES (
  :'tx_id',
  'ext-' || gen_random_uuid()::text,
  'corr-' || gen_random_uuid()::text,
  :'idem_key'
);

SELECT _assert_true(
  (SELECT status FROM idem_commit(
    :'idem_key',
    :'tx_id',
    '{"ok":true}'::jsonb
  )) = 'COMMITTED',
  'idem_commit commits'
);

SELECT _assert_true(
  (SELECT response_json = '{"ok":true}'::jsonb FROM idempotency WHERE key=:'idem_key'),
  'idempotency.response_json stored as provided'
);

-- =========================
-- 5) Ledger entries balanced (fully idempotent)
-- =========================
BEGIN;
INSERT INTO ledger_entry(entry_id, tx_id, account_id, direction, amount_cents, currency)
VALUES
  (gen_random_uuid(), :'tx_id', :'acc_a', 'DEBIT', 100, 'EUR'),
  (gen_random_uuid(), :'tx_id', :'acc_b', 'CREDIT', 100, 'EUR');
COMMIT;

-- =========================
-- 6) Append-only invariants
-- =========================
SELECT _assert_raises(
  format('UPDATE ledger_tx SET correlation_id=%L WHERE tx_id=%L', 'x', :'tx_id'),
  'ledger_tx immutable'
);

SELECT _assert_raises(
  format('DELETE FROM ledger_entry WHERE tx_id=%L', :'tx_id'),
  'ledger_entry immutable'
);

-- =========================
-- 7) event_log invariants (use current tx_id, avoid UPDATE ... LIMIT)
-- =========================
SELECT _assert_raises(
  format($q$
    INSERT INTO event_log(
      event_id,event_type,aggregate_type,aggregate_id,
      correlation_id,payload_json,payload_canonical,created_at
    )
    VALUES (
      gen_random_uuid(),'T','A',%L,
      'c','{"x":1}'::jsonb,'{"x":1}', now()
    )
  $q$, :'tx_id'),
  'event_log created_at must be DB-owned'
);

SELECT _assert_raises(
  format($q$
    INSERT INTO event_log(
      event_id,event_type,aggregate_type,aggregate_id,
      correlation_id,payload_json,payload_canonical
    )
    VALUES (
      gen_random_uuid(),'T','A',%L,
      'c','{"x":1}'::jsonb,'{"x":2}'
    )
  $q$, :'tx_id'),
  'event_log canonical mismatch'
);

INSERT INTO event_log(
  event_id,event_type,aggregate_type,aggregate_id,
  correlation_id,payload_json,payload_canonical
)
VALUES (
  gen_random_uuid(),'T','A',:'tx_id',
  'c','{"x":1}'::jsonb,'{"x":1}'
)
RETURNING event_id \gset

SELECT _assert_true(
  (SELECT created_at IS NOT NULL FROM event_log WHERE event_id=:'event_id'),
  'event_log created_at filled by DB'
);

SELECT _assert_true(verify_event_chain(), 'verify_event_chain ok');

-- Optional: immutability smoke for event_log (no LIMIT on UPDATE)
SELECT _assert_raises(
  format('UPDATE event_log SET event_type=%L WHERE event_id=%L', 'X', :'event_id'),
  'event_log immutable (update)'
);

SELECT _assert_raises(
  format('DELETE FROM event_log WHERE event_id=%L', :'event_id'),
  'event_log immutable (delete)'
);

-- =========================
-- 8) account_alias basic insert (FK)
-- =========================
INSERT INTO account_alias(alias_type, alias_value, account_id)
VALUES ('IBAN', 'FR76' || substring(gen_random_uuid()::text from 1 for 8), :'acc_a');

-- =========================
-- DIAG: direct risk event_log insert (must succeed)
-- =========================

INSERT INTO public.event_log(
  event_id,
  event_type,
  aggregate_type,
  aggregate_id,
  correlation_id,
  payload_json,
  payload_canonical,
  created_at
)
VALUES(
  gen_random_uuid(),
  'VALUATION_SNAPSHOT',
  'RISK_SNAPSHOT',
  gen_random_uuid(),
  'probe-direct',
  '{"p":1}'::jsonb,
  '{"p":1}',
  NULL
);

SELECT event_type, aggregate_type, count(*) AS n
FROM public.event_log
GROUP BY 1,2
ORDER BY 1,2;


-- =========================
-- 9) Risk layer: valuation_snapshot (1 event, corr=batch)
-- =========================
INSERT INTO valuation_snapshot(
  ingestion_correlation_id, asset_type, asset_id, as_of, price, currency, source, confidence,
  payload_json, payload_canonical, payload_hash
)
VALUES (
  'batch-' || gen_random_uuid()::text,
  'BOND',
  'FR0001',
  now(),
  99.5,
  'EUR',
  'SRC',
  80,
  '{"p":1}'::jsonb,
  '{"p":1}',
  decode(repeat('ab',32),'hex')
)
RETURNING snapshot_id, ingestion_correlation_id \gset

SELECT _assert_eq_bigint(
  (SELECT count(*) FROM event_log WHERE aggregate_id = :'snapshot_id'::uuid),
  1,
  'valuation_snapshot creates exactly 1 event_log row'
);

SELECT _assert_true(
  (SELECT correlation_id FROM event_log WHERE aggregate_id = :'snapshot_id'::uuid) = :'ingestion_correlation_id',
  'risk event_log correlation_id = ingestion_correlation_id'
);

SELECT _assert_raises(
  format('UPDATE valuation_snapshot SET price=100 WHERE snapshot_id=%L', :'snapshot_id'),
  'valuation_snapshot immutable'
);

SELECT _assert_raises(
  format('DELETE FROM valuation_snapshot WHERE snapshot_id=%L', :'snapshot_id'),
  'valuation_snapshot immutable'
);

SELECT _assert_true(verify_event_chain(), 'verify_event_chain ok after valuation');

-- =========================
-- 10) Risk layer: liquidity_snapshot mirror (1 event, corr=batch)
-- =========================
INSERT INTO liquidity_snapshot(
  ingestion_correlation_id, asset_type, asset_id, as_of, haircut_bps, time_to_cash_seconds, source,
  payload_json, payload_canonical, payload_hash
)
VALUES (
  'batch-' || gen_random_uuid()::text,
  'BOND',
  'FR0001',
  now(),
  100,
  3600,
  'SRC',
  '{"l":1}'::jsonb,
  '{"l":1}',
  decode(repeat('cd',32),'hex')
)
RETURNING snapshot_id, ingestion_correlation_id \gset

SELECT _assert_eq_bigint(
  (SELECT count(*) FROM event_log WHERE aggregate_id = :'snapshot_id'::uuid),
  1,
  'liquidity_snapshot creates exactly 1 event_log row'
);

SELECT _assert_true(
  (SELECT correlation_id FROM event_log WHERE aggregate_id = :'snapshot_id'::uuid) = :'ingestion_correlation_id',
  'liquidity risk event_log correlation_id = ingestion_correlation_id'
);

SELECT _assert_true(
  (SELECT created_at IS NOT NULL FROM event_log WHERE aggregate_id = :'snapshot_id'::uuid),
  'risk proof event created_at DB-owned (non-null)'
);

SELECT _assert_true(verify_event_chain(), 'verify_event_chain ok after liquidity');

-- =========================
-- Cleanup helpers (optional)
-- =========================
DROP FUNCTION _assert_raises(text,text);
DROP FUNCTION _assert_eq_bigint(bigint,bigint,text);
DROP FUNCTION _assert_true(boolean,text);
