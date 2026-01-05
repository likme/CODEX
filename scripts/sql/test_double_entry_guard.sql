BEGIN;

-- Setup
INSERT INTO accounts(account_id,label,currency)
VALUES
  ('00000000-0000-0000-0000-000000000010','Cash','USD'),
  ('00000000-0000-0000-0000-000000000020','Revenue','USD')
ON CONFLICT DO NOTHING;

INSERT INTO idempotency(key, request_hash)
VALUES ('idem-test-1', repeat('b',64))
ON CONFLICT DO NOTHING;

SET ROLE ledger_app;

-- 1) Direct INSERT into ledger_tx must fail
DO $$
BEGIN
  BEGIN
    INSERT INTO ledger_tx(tx_id, external_ref, correlation_id, idempotency_key)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','ext','corr','idem-test-1');
    RAISE EXCEPTION 'BUG: ledger_app could INSERT into ledger_tx (expected insufficient_privilege)';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END $$;

-- 2) Posting via function must succeed
SELECT post_balanced_tx(
  'cccccccc-cccc-cccc-cccc-cccccccccccc',
  'ext-ok-1',
  'corr-ok-1',
  'idem-test-1',
  '00000000-0000-0000-0000-000000000010',
  '00000000-0000-0000-0000-000000000020',
  100,
  'USD'
);

-- 3) Verify invariant persisted
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM ledger_entry WHERE tx_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  IF n <> 2 THEN
    RAISE EXCEPTION 'BUG: expected 2 ledger_entry rows, got %', n;
  END IF;
END $$;

RESET ROLE;

COMMIT;
