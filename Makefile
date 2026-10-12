COMPOSE := docker compose -f compose/docker-compose.yml
BASE_IMAGE ?= ghcr.io/winterchill-trading/oxcaml-base:latest

.PHONY: base build up down logs ps lint chart

base: ## build the OxCaml base image for the host architecture
	docker buildx build --load -t $(BASE_IMAGE) images/oxcaml-base

build: ## build every service image in the compose stack
	BASE_IMAGE=$(BASE_IMAGE) $(COMPOSE) build

up: ## start the local stack
	BASE_IMAGE=$(BASE_IMAGE) $(COMPOSE) up -d --build

down: ## stop the stack and drop its volumes
	$(COMPOSE) down -v --remove-orphans

logs:
	$(COMPOSE) logs -f --tail=100

ps:
	$(COMPOSE) ps

lint:
	hadolint images/oxcaml-base/Dockerfile images/service/Dockerfile
	shellcheck images/service/build.sh
	helm lint charts/winterchill
	helm lint charts/winterchill -f charts/winterchill/values-dev.yaml

chart: ## re-render the reviewed example manifest
	helm template winterchill charts/winterchill -f charts/winterchill/values-dev.yaml > charts/rendered-example.yaml
