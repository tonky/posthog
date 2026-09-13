# PostHog Monorepo Justfile
# Points directly to showcase/Justfile recipes

set dotenv-load := true

SHOWCASE_JUSTFILE := "showcase/Justfile"

default:
    @just --justfile {{SHOWCASE_JUSTFILE}} --list

# Run only the backend tests impacted by your git diff (via Snob import graph + AST reverse URL routing)
test-affected BASE="origin/master" EXTRA_ARGS="":
    @just --justfile {{SHOWCASE_JUSTFILE}} test-affected "{{BASE}}" "{{EXTRA_ARGS}}"

# List the backend tests impacted by your git diff without running them
list-affected BASE="origin/master":
    @just --justfile {{SHOWCASE_JUSTFILE}} list-affected "{{BASE}}"

# Demonstrate end-to-end PR test acceleration vs upstream CI (98893, 99634, 99520)
demo-pr PR="98893":
    @just --justfile {{SHOWCASE_JUSTFILE}} demo-pr "{{PR}}"

# Convenience aliases for PR demonstrations
demo-pr-signals:
    @just --justfile {{SHOWCASE_JUSTFILE}} demo-pr-signals

demo-pr-temporal:
    @just --justfile {{SHOWCASE_JUSTFILE}} demo-pr-temporal

demo-pr-warehouse:
    @just --justfile {{SHOWCASE_JUSTFILE}} demo-pr-warehouse

# Run a backend CI test shard (1-5) on rootless enve microservices
test-shard SHARD="1" WORKERS="6" FAIL_FAST="true":
    @just --justfile {{SHOWCASE_JUSTFILE}} test-shard "{{SHARD}}" "{{WORKERS}}" "{{FAIL_FAST}}"

# Start rootless microservices via enve (PostgreSQL, ClickHouse, Redis, Kafka, SeaweedFS, Temporal)
services-up:
    @just --justfile {{SHOWCASE_JUSTFILE}} services-up

# Start the web development stack (backend Django + frontend Vite)
web-up:
    enve up postgres redis clickhouse backend frontend

# Start the full polyglot monorepo stack
stack-up:
    enve up

# Stop running rootless microservices
services-down:
    @just --justfile {{SHOWCASE_JUSTFILE}} services-down

# Inspect running microservices status & RSS memory
services-status:
    @just --justfile {{SHOWCASE_JUSTFILE}} services-status
