SHELL := /bin/bash

.PHONY: infra-up infra-down infra-reset ledger-test e2e

infra-up:
	$(MAKE) -C infra up

infra-down:
	$(MAKE) -C infra down

infra-reset:
	$(MAKE) -C infra reset

ledger-test:
	cd core-ledger && go test ./...

e2e:
	bash ./scripts/e2e_smoke.sh
