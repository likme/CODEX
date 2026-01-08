SHELL := /bin/bash

ENV_FILE ?= .env

.PHONY: up down reset logs ps

up:
	./scripts/bootstrap_env.sh
	docker compose --env-file $(ENV_FILE) up -d
	@docker compose ps

down:
	docker compose --env-file $(ENV_FILE) down

reset:
	docker compose --env-file $(ENV_FILE) down -v
	docker compose --env-file $(ENV_FILE) up -d

logs:
	docker compose --env-file $(ENV_FILE) logs -f --tail=200

ps:
	docker compose --env-file $(ENV_FILE) ps
