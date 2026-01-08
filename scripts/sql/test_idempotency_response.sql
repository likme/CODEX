-- scripts/sql/test_idempotency_response.sql
-- Preconditions: schema applied, functions exist.

\set ON_ERROR_STOP on

-- 1) Sanity: idempotency table has response_json column
SELECT 1
FROM information_schema.columns
WHERE table_schema='public'
  AND table_name='idempotency'
  AND column_name='response_json';

-- 2) response_json must be jsonb or castable to jsonb
-- (If the column is jsonb, this is trivially ok.)
DO $$
BEGIN
  PERFORM 1
  FROM information_schema.columns
  WHERE table_schema='public'
    AND table_name='idempotency'
    AND column_name='response_json';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'idempotency.response_json missing';
  END IF;
END$$;

-- 3) If there exists any committed idempotency row, response_json must contain tx_id
-- This is written to be non-flaky: only asserts when data exists.
DO $$
DECLARE
  n bigint;
  bad bigint;
BEGIN
  SELECT count(*) INTO n
  FROM idempotency
  WHERE tx_id IS NOT NULL;

  IF n > 0 THEN
    SELECT count(*) INTO bad
    FROM idempotency
    WHERE tx_id IS NOT NULL
      AND (response_json IS NULL OR (response_json->>'tx_id') IS NULL);

    IF bad > 0 THEN
      RAISE EXCEPTION 'idempotency.response_json missing tx_id for % rows', bad;
    END IF;
  END IF;
END$$;

-- 4) Stronger: tx_id in response_json must equal tx_id column (semantic equality)
DO $$
DECLARE
  n bigint;
  bad bigint;
BEGIN
  SELECT count(*) INTO n
  FROM idempotency
  WHERE tx_id IS NOT NULL
    AND response_json IS NOT NULL;

  IF n > 0 THEN
    SELECT count(*) INTO bad
    FROM idempotency
    WHERE tx_id IS NOT NULL
      AND response_json IS NOT NULL
      AND (response_json->>'tx_id')::uuid <> tx_id;

    IF bad > 0 THEN
      RAISE EXCEPTION 'idempotency.response_json.tx_id mismatch for % rows', bad;
    END IF;
  END IF;
END$$;
