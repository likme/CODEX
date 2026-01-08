#!/usr/bin/env python3
import hashlib
import os
import random
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import requests
import yaml


@dataclass
class Cfg:
    seed: int
    days: int
    accounts: int
    currency: str
    rates_fedfunds_csv: str
    daily_deposit_prob: float
    daily_transfer_prob: float
    min_amount_cents: int
    max_amount_cents: int
    idem_prefix: str


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def load_cfg(path: Path) -> Cfg:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    return Cfg(**data)


class LedgerClient:
    def __init__(self, base_url: str, timeout: float = 15.0):
        self.base_url = base_url.rstrip("/")
        self.s = requests.Session()
        self.timeout = timeout

    def _post(self, path: str, payload: dict) -> dict:
        url = f"{self.base_url}{path}"
        r = self.s.post(url, json=payload, timeout=self.timeout)
        r.raise_for_status()
        return r.json()

    def create_account(self, label: str, currency: str, idem: str) -> str:
        # Match your API. If your endpoint differs, adjust here.
        # Common pattern:
        # POST /v1/accounts {label,currency,idempotency_key}
        res = self._post("/v1/accounts", {
            "label": label,
            "currency": currency,
            "idempotency_key": idem,
        })
        return res["account_id"]

    def mint(self, account_id: str, amount_cents: int, idem: str) -> str:
        res = self._post("/v1/tx/mint", {
            "account_id": account_id,
            "amount_cents": amount_cents,
            "idempotency_key": idem,
        })
        return res["tx_id"]

    def transfer(self, from_id: str, to_id: str, amount_cents: int, idem: str) -> str:
        res = self._post("/v1/tx/transfer", {
            "from_account_id": from_id,
            "to_account_id": to_id,
            "amount_cents": amount_cents,
            "idempotency_key": idem,
        })
        return res["tx_id"]


def main() -> int:
    cfg_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("config.yaml")
    cfg = load_cfg(cfg_path)

    ledger_url = os.environ.get("LEDGER_URL", "http://127.0.0.1:8080")
    out_dir = Path(os.environ.get("SCENARIO_OUT_DIR", Path.cwd()))
    out_dir.mkdir(parents=True, exist_ok=True)

    # Bind public reference version into the run (for audit)
    rates_path = Path(cfg.rates_fedfunds_csv)
    rates_sha = sha256_file(rates_path) if rates_path.exists() else "<missing>"
    (out_dir / "inputs.txt").write_text(
        f"rates_fedfunds_csv={rates_path}\n"
        f"rates_fedfunds_sha256={rates_sha}\n",
        encoding="utf-8",
    )

    rng = random.Random(cfg.seed)
    lc = LedgerClient(ledger_url)

    # Create accounts deterministically
    account_ids = []
    for i in range(cfg.accounts):
        label = f"Customer-{i:05d}"
        idem = f"{cfg.idem_prefix}:acct:{i:05d}"
        account_id = lc.create_account(label=label, currency=cfg.currency, idem=idem)
        account_ids.append(account_id)

    # Funding pool account (system)
    funding_idem = f"{cfg.idem_prefix}:acct:funding"
    funding_account = lc.create_account(label="FundingPool", currency=cfg.currency, idem=funding_idem)

    # Daily simulation
    for day in range(cfg.days):
        # mint some daily liquidity into FundingPool
        day_mint = rng.randint(cfg.min_amount_cents * 100, cfg.max_amount_cents * 10)
        lc.mint(funding_account, day_mint, f"{cfg.idem_prefix}:mint:day:{day}")

        # deposits (funding -> customer)
        for i, acc in enumerate(account_ids):
            if rng.random() < cfg.daily_deposit_prob:
                amt = rng.randint(cfg.min_amount_cents, cfg.max_amount_cents)
                idem = f"{cfg.idem_prefix}:dep:{day}:{i}"
                lc.transfer(funding_account, acc, amt, idem)

        # transfers (customer -> customer)
        for _ in range(int(cfg.accounts * cfg.daily_transfer_prob)):
            a = rng.randrange(cfg.accounts)
            b = rng.randrange(cfg.accounts)
            if a == b:
                continue
            amt = rng.randint(cfg.min_amount_cents, cfg.max_amount_cents // 10)
            idem = f"{cfg.idem_prefix}:xfer:{day}:{a}:{b}:{amt}"
            lc.transfer(account_ids[a], account_ids[b], amt, idem)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
