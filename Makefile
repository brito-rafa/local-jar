SHELL := /bin/sh
.DEFAULT_GOAL := help

-include .env
GO ?= go
DOCKER ?= docker
COMPOSE = $(DOCKER) compose --project-directory "$(CURDIR)" --env-file "$(CURDIR)/.env" -f "$(CURDIR)/config/manifests/compose/compose.yaml"
DOCS ?=
DB_PORT ?= 9494
DB_DATA_DIR ?= $(CURDIR)/data
CHAT_PORT ?= 18080
CHAT_HOST ?= 127.0.0.1
CHAT_ALLOW_ANY_HOST ?= false
CHAT_PUBLIC_URL ?=
OPEN_BROWSER ?= true
DB_URL ?= quack:127.0.0.1:$(DB_PORT)
DB_DISABLE_SSL ?= true
CHAT_MODEL ?= mistralai/Ministral-3-8B-Instruct-2512-GGUF:Q4_K_M
EMBEDDING_MODEL ?= bartowski/granite-embedding-278m-multilingual-GGUF:Q8_0
DIMENSIONS ?= 768
FORCE_INDEX ?= false
DOCUMENT_WORKERS ?= 20
EMBEDDING_WORKERS ?= 1
EMBEDDING_BATCH_SIZE ?= 8
EMBEDDING_BUFFER_BATCHES ?= 16
INSERT_BATCH_SIZE ?= 128
export DB_DATA_DIR CHAT_HOST CHAT_ALLOW_ANY_HOST CHAT_PUBLIC_URL CHAT_PORT OPEN_BROWSER FORCE_INDEX DOCUMENT_WORKERS EMBEDDING_WORKERS EMBEDDING_BATCH_SIZE EMBEDDING_BUFFER_BATCHES INSERT_BATCH_SIZE DOCS DB_URL CHAT_MODEL EMBEDDING_MODEL DIMENSIONS DB_TOKEN DB_PORT DB_DISABLE_SSL

##@ Database
.PHONY: local-db-check local-db-init local-db-up local-db-start local-db-down local-db-logs local-db-reset
local-db-check: ## Create DB_DATA_DIR if missing; reject empty paths or files
	@test -n "$$(printf '%s' "$$DB_DATA_DIR" | tr -d '[:space:]')" || { echo 'ERROR: DB_DATA_DIR must be set to a directory.' >&2; exit 2; }
	@mkdir -p "$$DB_DATA_DIR" || { printf 'ERROR: Cannot create DB_DATA_DIR: %s\n' "$$DB_DATA_DIR" >&2; exit 2; }

local-db-init: local-db-check ## Create .env token; preserve settings; create DB_DATA_DIR
	@if [ -e .env ]; then echo '.env already exists; keeping it'; else \
		umask 077; set -C; { printf 'DB_TOKEN='; openssl rand -hex 32; printf 'DB_PORT=9494\n'; } > .env; \
	fi

local-db-up: local-db-init ## Start persistent DuckDB and wait for its TCP endpoint
	@$(MAKE) --no-print-directory local-db-start

local-db-start: local-db-check
	$(COMPOSE) up -d --wait --wait-timeout 90

local-db-down: ## Stop DuckDB; keep the local database file
	$(COMPOSE) down

local-db-logs: ## Follow DuckDB container logs
	$(COMPOSE) logs -f duckdb

local-db-reset: local-db-check ## ERASE local jar.db and its WAL; preserve training/backups; requires CONFIRM=erase
	@test "$(CONFIRM)" = erase || { echo 'This erases jar.db and its WAL in DB_DATA_DIR. Run: make local-db-reset CONFIRM=erase' >&2; exit 2; }
	$(COMPOSE) down
	@rm -f "$${DB_DATA_DIR:?DB_DATA_DIR is required}/jar.db" "$${DB_DATA_DIR:?DB_DATA_DIR is required}/jar.db.wal"
	@$(MAKE) --no-print-directory local-db-up

##@ Application
.PHONY: index metadata status chat chat-web chat-terminal run build cli-help
index: ## Import DOCS recursively (required); load only the embedding model
	@/bin/sh "$(CURDIR)/hack/check-docs.sh"
	$(GO) run ./cmd/jar-index -docs "$$DOCS" -db-url "$$DB_URL" \
		-embedding-model "$$EMBEDDING_MODEL" -dimensions "$$DIMENSIONS" \
		-force="$$FORCE_INDEX" -document-workers "$$DOCUMENT_WORKERS" -embedding-workers "$$EMBEDDING_WORKERS" \
		-embedding-batch-size "$$EMBEDDING_BATCH_SIZE" -embedding-buffer-batches "$$EMBEDDING_BUFFER_BATCHES" -insert-batch-size "$$INSERT_BATCH_SIZE"

metadata: ## Build filename book/date metadata on an existing index; no re-embedding
	$(GO) run ./cmd/jar-index -db-url "$$DB_URL" -metadata

status: ## Show index status, local database directory and file size
	@printf 'Local database directory: %s\n' "$$DB_DATA_DIR"
	@if [ -f "$$DB_DATA_DIR/jar.db" ]; then \
		bytes=$$(wc -c < "$$DB_DATA_DIR/jar.db" | tr -d '[:space:]'); \
		awk -v bytes="$$bytes" 'BEGIN { printf "Local database file: jar.db (%s bytes; %.2f MiB)\n", bytes, bytes / 1048576 }'; \
	else printf 'Local database file: jar.db (not found)\n'; fi
	$(GO) run ./cmd/jar-index -db-url "$$DB_URL" -status

chat: chat-web ## Alias for browser chat

chat-web: ## Start web chat and open a browser (CHAT_PORT=18080)
	$(GO) run ./cmd/jar-chat -db-url "$$DB_URL" -chat-model "$$CHAT_MODEL" -web -host "$$CHAT_HOST" -allow-any-host="$$CHAT_ALLOW_ANY_HOST" -public-url "$$CHAT_PUBLIC_URL" -port "$$CHAT_PORT" -open-browser="$$OPEN_BROWSER"

chat-terminal: ## Chat in the terminal with slash commands and Tab completion
	$(GO) run ./cmd/jar-chat -db-url "$$DB_URL" -chat-model "$$CHAT_MODEL"

run: chat ## Alias for chat (run make index first)

build: ## Build bin/jar-index and bin/jar-chat
	mkdir -p bin
	$(GO) build -o bin/jar-index ./cmd/jar-index
	$(GO) build -o bin/jar-chat ./cmd/jar-chat

cli-help: ## Show index and chat command-line options
	$(GO) run ./cmd/jar-index -help
	$(GO) run ./cmd/jar-chat -help

##@ Development
.PHONY: test vet
test: ## Run tests; converter tests require their local tools
	$(GO) test ./...

vet: ## Run Go static analysis
	$(GO) vet ./...

##@ Help
.PHONY: help
help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make <target>\n"} /^[a-zA-Z0-9_-]+:.*##/ { printf "  %-18s %s\n", $$1, $$2 } /^##@/ { printf "\n%s\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@printf '%s\n' '' 'Start:' \
	  '  make local-db-up' \
	  '  make index DOCS="/path/to/documents"' \
	  '  make chat-web' \
	  '  make chat-terminal' '' \
	  'Settings are documented in .env.example and setup.md.' \
	  'Local Kronk models run on this machine; DuckDB uses DB_URL and DB_TOKEN.' \
	  'For OpenAI-compatible model endpoints, use https://github.com/brito-rafa/jar.'
