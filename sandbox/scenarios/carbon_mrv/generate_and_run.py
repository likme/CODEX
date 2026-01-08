#!/usr/bin/env python3
import hashlib
import os
import random
import sys
from dataclasses import dataclass
from pathlib import Path

import requests
import yaml


@dataclass
class Cfg:
    seed: int
    days: int
    orgs: int
    currency: str
    factors_uk_flat_xlsx: str
    daily_activity_prob: float
    min_kgco2: int
    max_kgco2: int
    idem_prefix: str


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def load_cfg(path: Path) -> Cfg:
    return Cfg(**yaml.safe_load(path.read_text(encoding="utf-8")))


class LedgerClient:
    def __init__(self, base_url: str, timeout: float = 15.0):
        self.base_url = base_url.rstrip("/")
        self.s = requests.Session()
        self.timeout = timeout

    def _post(self, path: str, payload: dict) -> dict:
        r = self.s.post(f"{self.base_url}{path}", json=payload, timeout=self.timeout)
        r.raise_for_status()
        return r.json()

    def create_account(self, label: str, currency: str, idem: str) -> str:
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

    factors_path = Path(cfg.factors_uk_flat_xlsx)
    factors_sha = sha256_file(factors_path) if factors_path.exists() else "<missing>"
    (out_dir / "inputs.txt").write_text(
        f"factors_uk_flat_xlsx={factors_path}\n"
        f"factors_uk_flat_sha256={factors_sha}\n",
        encoding="utf-8",
    )

    rng = random.Random(cfg.seed)
    lc = LedgerClient(ledger_url)

    # Accounts
    sink = lc.create_account("CARBON_SINK", cfg.currency, f"{cfg.idem_prefix}:acct:sink")
    funding = lc.create_account("CarbonFundingPool", cfg.currency, f"{cfg.idem_prefix}:acct:funding")
    lc.mint(funding, 10_000_000_00, f"{cfg.idem_prefix}:mint:bootstrap")  # bootstrap liquidity

    org_ids = []
    for i in range(cfg.orgs):
        org = lc.create_account(f"Org-{i:05d}", cfg.currency, f"{cfg.idem_prefix}:acct:org:{i:05d}")
        org_ids.append(org)
        # seed each org with some budget
        amt = rng.randint(50_00, 5000_00)
        lc.transfer(funding, org, amt, f"{cfg.idem_prefix}:seed:{i}")

    # Emission events: kgCO2 -> cents proxy (1 kgCO2 == 1 cent here, purely for flow volume)
    for day in range(cfg.days):
        for i, org in enumerate(org_ids):
            if rng.random() < cfg.daily_activity_prob:
                kg = rng.randint(cfg.min_kgco2, cfg.max_kgco2)
                cents = kg  # proxy
                idem = f"{cfg.idem_prefix}:emit:{day}:{i}:{kg}:{factors_sha[:8]}"
                lc.transfer(org, sink, cents, idem)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
