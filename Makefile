SHELL := /bin/bash
COMPOSE := docker compose -f compose/docker-compose.yml
BASE_IMAGE ?= ghcr.io/winterchill-trading/oxcaml-base:latest

# Host directory for state that outlives the containers (bind mounts, see
# docs/local.md "Databases"); compose reads the same variable.
WINTERCHILL_DATA_DIR ?= $(HOME)/.winterchill
export WINTERCHILL_DATA_DIR
PG_DATA_DIR := $(WINTERCHILL_DATA_DIR)/postgres
# Every profile, so `down` and `reset-data` reach all of the stack.
ALL_PROFILES := --profile monitoring --profile day-close --profile copy --profile testnet \
	--profile db --profile neobank

.PHONY: base build build-day-close build-copy build-testnet up up-monitoring up-day-close \
	up-copy up-testnet up-db up-memtrace memtrace-pull down reset-data logs ps lint chart pins

base: ## build the OxCaml base image for the host architecture
	docker buildx build --load -t $(BASE_IMAGE) images/oxcaml-base

# repo:binary[:runtime packages] for every image the compose stack runs.
SERVICES := hl-sim:hl-sim binance-sim:binance-sim bybit-sim:bybit-sim \
	market-maker:market-maker market-recorder:market-recorder:rclone
DUCKDB_VERSION ?= 1.5.6

# Images of the `copy` and `testnet` profiles, built only by their targets.
# hl-copy-web is the Dockerfile's web target (a static site, no binary).
COPY_SERVICES := hl-sim:hl-sim market-maker:market-maker hl-leaderboard:hl-leaderboard \
	hl-copy-engine:hl-copy-engine hl-copy-api:hl-copy-api
TESTNET_SERVICES := hl-sim:hl-sim hl-mm:hl-mm market-recorder:market-recorder:rclone

# $(call build-images,repo:binary[:runtime packages] ...)
define build-images
	@set -e; for s in $(1); do \
	  IFS=: read -r repo bin pkgs <<< "$$s"; \
	  BASE_IMAGE=$(BASE_IMAGE) images/service/build.sh "$$repo" "$$bin" \
	    $${pkgs:+--build-arg RUNTIME_PACKAGES=$$pkgs}; \
	done
endef

build: ## build every service image in the compose stack, labelled with its commits
	$(call build-images,$(SERVICES))

build-copy: ## build the copy-trading images (and hl-sim, market-maker)
	$(call build-images,$(COPY_SERVICES))
	BASE_IMAGE=$(BASE_IMAGE) images/service/build.sh hl-copy-web "" --target web

build-testnet: ## build the testnet box images
	$(call build-images,$(TESTNET_SERVICES))

build-day-close: ## build the market-data image (day-close and check, with duckdb)
	BASE_IMAGE=$(BASE_IMAGE) images/service/build.sh market-data market-data \
	  --build-arg DUCKDB_VERSION=$(DUCKDB_VERSION)

up: build ## build the images and start the local stack
	$(COMPOSE) up -d

up-monitoring: up ## also start cadvisor, node-exporter and Prometheus
	$(COMPOSE) --profile monitoring up -d

# Named services only: a bare `--profile copy up` would also start the whole
# default stack. hl-sim (with -leaders) and its market maker come along for
# prices and liquidity.
COPY_UP := postgres hl-sim mm-hyperliquid hl-leaderboard-collect hl-leaderboard \
	hl-copy-api hl-copy-engine hl-copy-web

up-copy: build-copy ## copy trading on hl-sim, web app on :8000 (docs/copytrading.md)
	mkdir -p $(PG_DATA_DIR)
	$(COMPOSE) --profile copy up -d $(COPY_UP)

up-db: ## postgres alone, data in $(WINTERCHILL_DATA_DIR)/postgres (docs/local.md)
	mkdir -p $(PG_DATA_DIR)
	$(COMPOSE) --profile db up -d postgres

TESTNET_UP := testnet-sim testnet-mm-btc testnet-mm-eth testnet-recorder

up-testnet: build-testnet ## Hyperliquid testnet in a box, with monitoring (docs/testnet-box.md)
	$(COMPOSE) --profile testnet --profile monitoring up -d $(TESTNET_UP) \
	  cadvisor node-exporter prometheus

MEMTRACE_FILE := /var/lib/market-recorder/memtrace.ctf
MEMTRACE_RATE ?= 1e-4

up-memtrace: ## restart the recorder with memtrace writing to its volume
	RECORDER_MEMTRACE=$(MEMTRACE_FILE) RECORDER_MEMTRACE_RATE=$(MEMTRACE_RATE) \
	  $(COMPOSE) up -d --force-recreate --no-deps market-recorder

memtrace-pull: ## copy the recorder's trace to ./memtrace.ctf
	$(COMPOSE) cp market-recorder:$(MEMTRACE_FILE) memtrace.ctf

up-day-close: up build-day-close ## also run day-close and market-data check on a loop
	$(COMPOSE) --profile day-close up -d

down: ## stop and remove the containers; volumes and $(WINTERCHILL_DATA_DIR) stay
	$(COMPOSE) $(ALL_PROFILES) down --remove-orphans

# Everything `down` keeps: the named volumes (MinIO, recorder, leaderboard,
# copy-data, copy-journals) and the Postgres directory. Postgres writes its
# files as the container's user, so a container deletes them, not the host.
reset-data: ## stop the stack and DELETE its volumes and Postgres data (CONFIRM=yes)
	@if [ "$(CONFIRM)" != yes ]; then \
	  echo "reset-data deletes every volume of the stack and $(PG_DATA_DIR)."; \
	  echo "Run: make reset-data CONFIRM=yes"; exit 1; \
	fi
	$(COMPOSE) $(ALL_PROFILES) down -v --remove-orphans
	@if [ -d "$(PG_DATA_DIR)" ]; then \
	  docker run --rm -v "$(PG_DATA_DIR):/data" postgres:18-alpine \
	    sh -c 'rm -rf /data/* /data/.[!.]*' && rmdir "$(PG_DATA_DIR)" \
	    && echo "deleted $(PG_DATA_DIR)"; \
	fi

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
