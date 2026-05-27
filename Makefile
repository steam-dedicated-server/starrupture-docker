# Starrupture dedicated server — task runner
SHELL := /bin/bash
.DEFAULT_GOAL := help

IMAGE     ?= ghcr.io/steam-dedicated-server/starrupture-docker
VERSION   ?= dev
PLATFORMS ?= linux/amd64
COMPOSE   ?= docker compose
COMPOSE_F ?= -f compose/docker-compose.yml

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Targets:\n"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# -------- Build --------
.PHONY: build buildx
build: ## Build the Docker image locally
	DOCKER_BUILDKIT=1 docker build \
	  -f docker/Dockerfile \
	  -t $(IMAGE):$(VERSION) \
	  -t $(IMAGE):latest \
	  .

buildx: ## Multi-arch build + push via buildx
	docker buildx build \
	  --platform $(PLATFORMS) \
	  -f docker/Dockerfile \
	  -t $(IMAGE):$(VERSION) \
	  -t $(IMAGE):latest \
	  --push \
	  .

# -------- Compose (single-server) --------
.PHONY: install update backup up down logs ps shell config-print
install: ## One-shot install (downloads game files)
	$(COMPOSE) $(COMPOSE_F) --profile maintenance run --rm install

update: ## Update game files
	$(COMPOSE) $(COMPOSE_F) --profile maintenance run --rm update

backup: ## Backup save data
	$(COMPOSE) $(COMPOSE_F) --profile maintenance run --rm backup

up: ## Start the server in the background
	$(COMPOSE) $(COMPOSE_F) up -d server

down: ## Stop everything
	$(COMPOSE) $(COMPOSE_F) down

logs: ## Tail server logs
	$(COMPOSE) $(COMPOSE_F) logs -f server

ps: ## Show container status / health
	$(COMPOSE) $(COMPOSE_F) ps

shell: ## Drop into a shell in the running container
	$(COMPOSE) $(COMPOSE_F) exec server bash

config-print: ## Render the merged compose config
	$(COMPOSE) $(COMPOSE_F) config

# -------- Lint --------
.PHONY: lint shellcheck hadolint
lint: shellcheck hadolint ## Run all linters

shellcheck: ## shellcheck scripts/
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed"; exit 1; }
	shellcheck scripts/star scripts/lib/*.sh

hadolint: ## hadolint docker/Dockerfile
	@command -v hadolint >/dev/null || { echo "hadolint not installed"; exit 1; }
	hadolint docker/Dockerfile
