.DEFAULT_GOAL := help
SHELL := /bin/bash

VERSION ?= 1.0.0-local
IMAGE   ?= devops-task:$(VERSION)

.PHONY: help
help: ## Show available targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# --- Application -------------------------------------------------------------

.PHONY: install
install: ## Install runtime and dev dependencies into the active Python environment
	python -m pip install --require-hashes -r requirements.txt
	python -m pip install -r requirements-dev.txt

.PHONY: test
test: ## Run unit tests with coverage
	python -m pytest

.PHONY: lint
lint: ## Lint Python, shell scripts and the Dockerfile
	ruff check .
	ruff format --check .
	shellcheck scripts/*.sh scripts/ci/*.sh scripts/k8s/*.sh terraform/app/templates/deploy-app.sh
	@if command -v hadolint >/dev/null; then hadolint Dockerfile; \
	else docker run --rm -i hadolint/hadolint:v2.15.1 < Dockerfile; fi

.PHONY: build
build: ## Build the container image
	docker build --build-arg APP_VERSION=$(VERSION) -t $(IMAGE) .
	@docker image inspect $(IMAGE) --format 'Image size: {{.Size}} bytes'

# --- Local stack -------------------------------------------------------------

.env:
	cp .env.example .env
	@echo "Created .env. Set GRAFANA_ADMIN_PASSWORD (and optionally DEBUG_TOKEN), then run 'make up' again."
	@exit 1

.PHONY: up
up: .env ## Start the app and the monitoring stack
	docker compose --profile monitoring up -d --build
	@echo "App:     http://localhost:8080"
	@echo "Grafana: http://localhost:3000"

.PHONY: down
down: ## Stop everything (keeps data volumes)
	docker compose --profile monitoring down

.PHONY: clean
clean: ## Stop everything and delete data volumes
	docker compose --profile monitoring down --volumes

.PHONY: ps
ps: ## Show container status and health
	docker compose --profile monitoring ps

.PHONY: traffic
traffic: ## Send 5 minutes of traffic (with an error spike if DEBUG_TOKEN is set)
	scripts/generate-traffic.sh 300

.PHONY: health
health: ## Run the host health script
	scripts/system_health.sh

# --- Kubernetes (k3d) --------------------------------------------------------

.PHONY: k8s-up
k8s-up: ## Create a local k3d cluster and deploy the app
	scripts/k8s/setup-local-cluster.sh

.PHONY: k8s-demo
k8s-demo: ## Rolling update to 1.0.1 and rollback, with availability check
	scripts/k8s/rolling-update-demo.sh

.PHONY: k8s-down
k8s-down: ## Delete the local k3d cluster
	k3d cluster delete devops-task

# --- Terraform ---------------------------------------------------------------

.PHONY: tf-check
tf-check: ## terraform fmt check and validate (no AWS credentials needed)
	terraform fmt -check -recursive terraform
	terraform -chdir=terraform/bootstrap init -backend=false -input=false >/dev/null
	terraform -chdir=terraform/bootstrap validate
	terraform -chdir=terraform/app init -backend=false -input=false >/dev/null
	terraform -chdir=terraform/app validate
