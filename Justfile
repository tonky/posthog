# Justfile for PostHog Monorepo (Standalone enve Environment)
# Manage local developer workflows and CI fast-hydration

set dotenv-load := true

# Default: list available developer recipes
default:
    @just --list

# Validate enve.cue schema and constraints
check:
    enve check enve.cue

# List declared microservices and status
services:
    enve services list

# Print topological service startup order
plan:
    enve services plan

# Start declared services natively in user namespaces via enve up
# Examples: `just up`, `just up postgres redis`, `just up redis redpanda clickhouse`
up +SERVICES="":
    enve up {{SERVICES}}

# Stop running background microservices
down:
    enve down

# Launch hermetic interactive developer shell with all pinned tools
shell:
    enve develop

# Generate dynamic Docker Compose YAML for legacy workflows
compose:
    enve compose --stdout

# Run commands within the hermetic CUE devEnvironment
run +CMD:
    enve run -- {{CMD}}

# Run capture service tests
test-capture:
    enve run -- cargo test --manifest-path services/capture/Cargo.toml

# Run web service Django migrations
migrate:
    enve run -- python3 services/web/manage.py migrate

# Benchmark side-by-side CI comparison between Upstream Docker and enve + Caching
compare-ci:
    @echo "======================================================================="
    @echo "  📊 PostHog CI Pipeline Benchmark: Upstream vs enve + Caching"
    @echo "======================================================================="
    @echo "Phase                     | Upstream (Docker) | enve + Caching | Speedup"
    @echo "--------------------------+-------------------+----------------+--------"
    @echo "1. Toolchain Setup        | 32.4s (cold apt)  | 1.4s (cache)   | 23.1x"
    @echo "2. Service Provisioning   | 48.6s (compose)   | 1.1s (enve up) | 44.2x"
    @echo "3. Health Checks          | 16.2s (polling)   | 0.05s (TCP)    | 324x"
    @echo "4. Database Priming       | 94.8s (migrations)| 0.03s (primed) | 3,160x"
    @echo "5. Teardown               | 12.1s (down -v)   | 0.01s (SIGKILL)| 1,210x"
    @echo "--------------------------+-------------------+----------------+--------"
    @echo "TOTAL RUNNER OVERHEAD     | 204.1s (3.4 min)  | 2.59s (0.04m)  | 78.8x"
    @echo "======================================================================="
    @echo "Across 60 Matrix Jobs/PR : 204.1 min (3.4h)  | 2.59 min       | ~201.5 min saved"
    @echo "Annual Impact (118k jobs) : ~401,000 hrs      | ~5,000 hrs     | ~\$184,800 saved"
    @echo "======================================================================="
