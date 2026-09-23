# This Justfile belongs to the unpacked PostHog checkout. Replay management is in tests/replay.
set positional-arguments

# List commands available inside this checkout: just --list
default:
    @just --list

# Install locked project dependencies and generated inputs: just setup frontend | backend | all
setup target="frontend":
    enve run --locked -- bash showcase/scripts/python_runtime.sh -- bash showcase/scripts/node_runtime.sh -- bash showcase/scripts/setup.sh "$@"

# Run enact on local edits; pass normal enact options: just test --files products/persons/frontend/pages/PersonScene.tsx
test *args:
    enact run "$@"

# Inspect the execution plan for local edits: just plan [--files <source_path>]
plan *args:
    enact dry-run "$@"

# Start selected rootless showcase services: just services-up postgres redis
services-up +services:
    enve up "$@"

# Stop services owned by this checkout: just services-down
services-down:
    enve down

# Inspect declared/running service status: just services-status
services-status:
    enve services list
