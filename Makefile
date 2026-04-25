SHELL := /bin/bash
.DEFAULT_GOAL := help

# Auto-discover templates: any top-level dir containing a docker-compose.yml
TEMPLATES := $(patsubst %/docker-compose.yml,%,$(wildcard */docker-compose.yml))

YAMLLINT_CONFIG := {extends: default, rules: {line-length: disable, truthy: {check-keys: false}}}

.PHONY: help lint lint-json lint-yaml check-env validate all

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

all: lint check-env validate  ## Run every check
