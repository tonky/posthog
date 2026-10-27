#!/usr/bin/env bash
# The maildev service's node_modules (enve.cue's maildev preStart, under exclusive.sh's lock):
# maildev 2.0.5, docker-compose.base.yml's image's version, as package-lock.json pins it. Installs
# only when the lockfile differs from the one installed, so every later start, and every shard's
# instance, finds it done; `npm ci` takes the packages from npm's cache when it has them.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if cmp -s package-lock.json node_modules/.installed-package-lock.json; then exit 0; fi
npm ci --omit=dev --ignore-scripts --prefer-offline --no-audit --no-fund
cp package-lock.json node_modules/.installed-package-lock.json
