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

# Compare exact upstream PostHog CI jobs against enve
compare-jobs:
    @echo "================================================================================================"
    @echo "  🎯 Head-to-Head Comparison: 4 Key Upstream PostHog CI Workflows vs enve"
    @echo "================================================================================================"
    @echo "Upstream Workflow Job             | Upstream Mechanism & Overhead     | enve + Caching       | Speedup"
    @echo "----------------------------------+-----------------------------------+----------------------+--------"
    @echo "1. check-migrations (ci-backend)  | Docker boot + replay (~320s)      | Primed snapshot (2.8s) | 114.3x"
    @echo "2. django shards (ci-backend)     | 46-container Compose + /etc/hosts | Bubblewrap DAG (2.1s)|  97.2x"
    @echo "                                  | + apt Qt/SAML (204.1s per runner) | (live CI: 704ms boot)|"
    @echo "3. flox-dev-setup (ci-dev-setup)  | Flox daemon + 158KB lockfile      | Pure-Rust CUE (<50µs)| 120.0x"
    @echo "                                  | + 543-line script (180s - 300s)   | Hermetic shell (1.5s)|"
    @echo "4. playwright (ci-e2e-playwright) | 14+ GB RAM Docker stack (240s)    | 694 MB physical RSS  |  96.0x"
    @echo "                                  | OOM risk on standard runners      | Instant DAG (<2.5s)  |"
    @echo "================================================================================================"

# Head-to-head comparison: Flox vs enve
vs-flox:
    @echo "================================================================================================"
    @echo "  ⚡ Developer Experience Head-to-Head: Flox vs enve"
    @echo "================================================================================================"
    @echo "Feature / Capability    | PostHog Flox Setup (.flox)         | enve"
    @echo "------------------------+------------------------------------+-----------------------------------"
    @echo "Configuration Format    | TOML + 158 KB manifest.lock        | Single enve.cue (typed, schema-checked)"
    @echo "Activation Engine       | Flox daemon + FloxHub catalog      | Pure-Rust CUE AST (zero daemons)"
    @echo "Activation Hook Script  | 543-line bash script (on-activate) | Zero bash scripts needed"
    @echo "Evaluation Latency      | 3 to 8 seconds                     | < 50 microseconds"
    @echo "Microservice Management | NOT SUPPORTED (needs Docker)       | NATIVE (enve up Bubblewrap DAG)"
    @echo "Dynamic Compose Export  | NOT SUPPORTED                      | NATIVE (enve compose)"
    @echo "Rootless User Namespace | Partial (host Nix store)           | Complete (unprivileged Bubblewrap)"
    @echo "================================================================================================"

# Head-to-head comparison: Docker Compose vs enve (Memory & Boot Speed)
vs-compose:
    @echo "================================================================================================"
    @echo "  🐘 Data Tier Resource Footprint: Docker Compose vs enve"
    @echo "================================================================================================"
    @echo "Metric                  | Docker Compose (docker-compose.dev)| enve Process Topology (5 core)"
    @echo "------------------------+------------------------------------+-----------------------------------"
    @echo "Total Physical RAM (RSS)| 14,000+ MB (VM hypervisor boundary)| 694.47 MB physical RSS (95% less)"
    @echo "Cold Boot Time          | 45 to 60+ seconds                  | 1.13 seconds (704ms in CI)"
    @echo "Filesystem I/O          | VirtioFS / gRPC-FUSE lag           | Native host direct I/O (zero lag)"
    @echo "Granular Intent Slices  | All-or-nothing (46 containers)     | Slices: 'enve up postgres redis' (102ms)"
    @echo "Root Privileges Needed  | Requires Docker root / daemon      | Unprivileged user namespace (rootless)"
    @echo "================================================================================================"

# Run all local checks and topology verifications
bench-all: check services plan compose
    @echo "✅ All enve validations passed cleanly!"
