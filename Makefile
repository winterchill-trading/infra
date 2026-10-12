SHELL := /bin/bash
COMPOSE := docker compose -f compose/docker-compose.yml
BASE_IMAGE ?= ghcr.io/winterchill-trading/oxcaml-base:latest

.PHONY: base build build-day-close up up-monitoring down logs ps lint chart pins

base: ## build the OxCaml base image for the host architecture
	docker buildx build --load -t $(BASE_IMAGE) images/oxcaml-base

# repo:binary[:runtime packages] for every image the compose stack runs.
SERVICES := hl-sim:hl-sim binance-sim:binance-sim bybit-sim:bybit-sim \
	market-maker:market-maker market-recorder:market-recorder:rclone
DUCKDB_VERSION ?= 1.5.6

build: ## build every service image in the compose stack, labelled with its commits
	@set -e; for s in $(SERVICES); do \
	  IFS=: read -r repo bin pkgs <<< "$$s"; \
	  BASE_IMAGE=$(BASE_IMAGE) images/service/build.sh "$$repo" "$$bin" \
	    $${pkgs:+--build-arg RUNTIME_PACKAGES=$$pkgs}; \
	done

build-day-close: ## build the market-data image (day-close and check, with duckdb)
	BASE_IMAGE=$(BASE_IMAGE) images/service/build.sh market-data market-data \
	  --build-arg DUCKDB_VERSION=$(DUCKDB_VERSION)

up: build ## build the images and start the local stack
	$(COMPOSE) up -d

up-monitoring: up ## also start cadvisor, node-exporter and Prometheus
	$(COMPOSE) --profile monitoring up -d

down: ## stop the stack and drop its volumes
	$(COMPOSE) --profile monitoring down -v --remove-orphans

logs:
	$(COMPOSE) logs -f --tail=100

ps: ## compose ps plus each image's commit and sibling pins
	scripts/ps.sh

lint:
	hadolint images/oxcaml-base/Dockerfile images/service/Dockerfile
	shellcheck -x images/service/build.sh scripts/*.sh test-actions/*.sh
	scripts/test-check-pins.sh
	helm lint charts/winterchill
	helm lint charts/winterchill -f charts/winterchill/values-dev.yaml

chart: ## re-render the reviewed example manifest
	helm template winterchill charts/winterchill -f charts/winterchill/values-dev.yaml > charts/rendered-example.yaml

pins: ## check every sibling checkout's CI pins against its dune-project
	scripts/check-pins.sh -a
