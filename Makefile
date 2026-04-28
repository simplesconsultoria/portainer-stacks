SHELL := /bin/bash
.DEFAULT_GOAL := help

# Auto-discover templates: any top-level dir containing a docker-compose.yml
TEMPLATES := $(patsubst %/docker-compose.yml,%,$(wildcard */docker-compose.yml))

YAMLLINT_CONFIG := {extends: default, rules: {line-length: disable, truthy: {check-keys: false}}}

.PHONY: help lint lint-json lint-yaml check-env validate new-template all

help:  ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: lint-json lint-yaml  ## Run JSON + YAML linters

lint-json:  ## Validate templates.json with jq
	@jq . templates.json > /dev/null && echo "templates.json: OK"

lint-yaml:  ## yamllint each template's docker-compose.yml
	@for tpl in $(TEMPLATES); do \
		echo "==> $$tpl/docker-compose.yml"; \
		uvx yamllint -d '$(YAMLLINT_CONFIG)' $$tpl/docker-compose.yml || exit 1; \
	done

check-env:  ## Cross-check templates.json env entries vs $${VAR} references in each compose
	@status=0; \
	for tpl in $(TEMPLATES); do \
		echo "==> $$tpl"; \
		stackfile="$$tpl/docker-compose.yml"; \
		compose_vars=$$(grep -oE '\$$\{[A-Z_]+(:-[^}]*)?\}' $$stackfile | sed 's/\$${//;s/}//;s/:-.*//' | sort -u); \
		json_vars=$$(jq -r --arg f "$$stackfile" '.templates[] | select(.repository.stackfile == $$f) | .env[].name' templates.json | sort -u); \
		missing=$$(comm -23 <(echo "$$compose_vars") <(echo "$$json_vars")); \
		extra=$$(comm -13 <(echo "$$compose_vars") <(echo "$$json_vars")); \
		if [ -n "$$missing" ]; then \
			echo "  MISSING in templates.json env[] (operator cannot set these via the form):"; \
			echo "$$missing" | sed 's/^/    /'; \
			status=1; \
		fi; \
		if [ -n "$$extra" ]; then \
			echo "  EXTRA in templates.json env[] (form collects input the compose never reads):"; \
			echo "$$extra" | sed 's/^/    /'; \
			status=1; \
		fi; \
		if [ -z "$$missing" ] && [ -z "$$extra" ]; then \
			echo "  OK"; \
		fi; \
	done; \
	exit $$status

validate:  ## docker compose config per template (requires <id>/.env.sample)
	@for tpl in $(TEMPLATES); do \
		envfile="$$tpl/.env.sample"; \
		if [ ! -f $$envfile ]; then \
			echo "skip $$tpl: no $$envfile"; \
			continue; \
		fi; \
		echo "==> $$tpl"; \
		docker compose --env-file $$envfile -f $$tpl/docker-compose.yml config > /dev/null && echo "  OK"; \
	done

new-template:  ## Scaffold a new template directory (usage: make new-template id=<id>)
	@test -n "$(id)" || { echo "Usage: make new-template id=<template-id>"; exit 1; }
	@test ! -d "$(id)" || { echo "Error: $(id)/ already exists"; exit 1; }
	@mkdir -p $(id)
	@: > $(id)/docker-compose.yml
	@printf '%s\n' \
	  '# Sample env values for `make validate` (`docker compose config`).' \
	  '# Fill one entry per $${VAR} referenced in docker-compose.yml.' \
	  '# Placeholder values only — never put real secrets here.' \
	  > $(id)/.env.sample
	@printf '%s\n' \
	  '# $(id) — Portainer template' \
	  '' \
	  '> **TODO:** describe what this template deploys.' \
	  '' \
	  '## Services' \
	  '' \
	  '| Service | Replicas | Public | Notes |' \
	  '|---------|----------|--------|-------|' \
	  '| _TBD_   | _TBD_    | _TBD_  | _TBD_ |' \
	  '' \
	  '## Environment variables' \
	  '' \
	  '> Keep `templates.json env[]` in sync with every $${VAR} referenced in' \
	  '> `docker-compose.yml` — `make check-env` enforces this.' \
	  '' \
	  '## Storage layout' \
	  '' \
	  '> **TODO:** NFS / named volumes / ephemeral.' \
	  '' \
	  '## Webhook plan' \
	  '' \
	  '> **TODO:** which services expose Portainer service webhooks.' \
	  '' \
	  '## Known limitations' \
	  '' \
	  '> **TODO:**' \
	  > $(id)/README.md
	@echo "Scaffolded $(id)/. Next steps:"
	@echo "  1. Fill $(id)/docker-compose.yml"
	@echo "  2. Append a templates.json entry"
	@echo "  3. Add a row to the 'Available templates' table in README.md"
	@echo "  4. Drop a logo.png in $(id)/"
	@echo "  5. Run 'make all' to validate"

all: lint check-env validate  ## Run every check
