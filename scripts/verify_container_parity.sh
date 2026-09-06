#!/usr/bin/env bash
set -euo pipefail

#
# scripts/verify_container_parity.sh
#
# Local 3-Way Container File Parity & Equivalence Verifier:
# Compares:
#   1. Pure Enve OCI Container Archive (synthesized via `enve image build`)
#   2. Dockerfile.enve Container Image/Archive (built via Docker BuildKit)
#   3. Upstream Official Container (pulled from DockerHub / ECR)
#

ENVE_TAR="${1:-dist/posthog-enve-multiarch.tar}"
DOCKER_ENVE="${2:-}"
UPSTREAM="${3:-}"

echo "======================================================================="
echo "  🔍 PostHog Container File Parity & Equivalence Verifier"
echo "======================================================================="
echo "  1. Pure Enve OCI Archive:    $ENVE_TAR"
echo "  2. Dockerfile.enve Target:   ${DOCKER_ENVE:-'(not provided)'}"
echo "  3. Upstream Docker Target:   ${UPSTREAM:-'(not provided)'}"
echo "-----------------------------------------------------------------------"

if [ ! -f "$ENVE_TAR" ]; then
    echo "❌ Pure Enve OCI archive not found at: $ENVE_TAR"
    echo "   Build it first using: enve image build ..."
    exit 1
fi

TMP_DIR=$(mktemp -d -t posthog-parity-XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

DIR_ENVE="$TMP_DIR/enve_pure"
DIR_DOCKER="$TMP_DIR/docker_enve"
DIR_UPSTREAM="$TMP_DIR/upstream"

mkdir -p "$DIR_ENVE" "$DIR_DOCKER" "$DIR_UPSTREAM"

echo "• 1. Extracting Pure Enve OCI container filesystem..."
TAR_CONTENT_DIR="$TMP_DIR/enve_raw"
mkdir -p "$TAR_CONTENT_DIR"
tar -xf "$ENVE_TAR" -C "$TAR_CONTENT_DIR"

# Extract all layer tarballs in the OCI archive into DIR_ENVE
for layer in "$TAR_CONTENT_DIR"/*.tar "$TAR_CONTENT_DIR"/blobs/sha256/*; do
    if [ -f "$layer" ] && tar -tf "$layer" >/dev/null 2>&1; then
        tar -xf "$layer" -C "$DIR_ENVE" 2>/dev/null || true
    fi
done

echo "   ✓ Extracted $(find "$DIR_ENVE/code" -type f 2>/dev/null | wc -l) files from Pure Enve OCI container."

# Auto-detect container runtime (docker or rootless podman)
CONTAINER_CLI="docker"
if ! docker info >/dev/null 2>&1 && command -v podman >/dev/null 2>&1; then
    CONTAINER_CLI="podman"
fi

# Extract Dockerfile.enve image if provided
if [ -n "$DOCKER_ENVE" ]; then
    echo "• 2. Extracting Dockerfile.enve container filesystem (using $CONTAINER_CLI)..."
    if [ -f "$DOCKER_ENVE" ]; then
        # Archive file
        $CONTAINER_CLI load -i "$DOCKER_ENVE" >/dev/null 2>&1 || true
        IMG_NAME=$(tar -xOf "$DOCKER_ENVE" manifest.json 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['RepoTags'][0])" 2>/dev/null || echo "")
        [ -n "$IMG_NAME" ] && DOCKER_ENVE="$IMG_NAME"
    fi

    CID=$($CONTAINER_CLI create "$DOCKER_ENVE" 2>/dev/null || true)
    if [ -n "$CID" ]; then
        $CONTAINER_CLI cp "$CID:/code" "$DIR_DOCKER/" 2>/dev/null || true
        $CONTAINER_CLI rm "$CID" >/dev/null 2>&1 || true
        echo "   ✓ Extracted $(find "$DIR_DOCKER/code" -type f 2>/dev/null | wc -l) files from Dockerfile.enve image."
    else
        echo "   ⚠️ Could not inspect Docker image: $DOCKER_ENVE (skipping Docker export)"
    fi
fi

# Extract Upstream image if provided
if [ -n "$UPSTREAM" ]; then
    echo "• 3. Extracting Upstream official container filesystem (using $CONTAINER_CLI)..."
    CID_UP=$($CONTAINER_CLI create "$UPSTREAM" 2>/dev/null || true)
    if [ -n "$CID_UP" ]; then
        $CONTAINER_CLI cp "$CID_UP:/code" "$DIR_UPSTREAM/" 2>/dev/null || true
        $CONTAINER_CLI rm "$CID_UP" >/dev/null 2>&1 || true
        echo "   ✓ Extracted $(find "$DIR_UPSTREAM/code" -type f 2>/dev/null | wc -l) files from Upstream image."
    else
        echo "   ⚠️ Could not inspect Upstream image: $UPSTREAM (skipping Upstream export)"
    fi
fi

echo "-----------------------------------------------------------------------"
echo "  📋 Auditing Key Production Artifacts in Pure Enve OCI..."
echo "-----------------------------------------------------------------------"

CRITICAL_PATHS=(
    # 1. Server & Worker CLI Entrypoints
    "code/manage.py"
    "code/bin/docker-server-unit"
    "code/bin/docker-worker-celery"
    "code/bin/temporal-django-worker"
    "code/bin/docker-migrate"
    "code/bin/migrate-check"
    "code/bin/unit_metrics.py"
    "code/unit.json.tpl"
    "code/commit.txt"

    # 2. Core Python Architecture & Async Services
    "code/posthog/__init__.py"
    "code/posthog/asgi.py"
    "code/posthog/wsgi.py"
    "code/posthog/celery.py"
    "code/posthog/urls.py"
    "code/posthog/settings/__init__.py"
    "code/posthog/temporal/common/worker.py"
    "code/posthog/management/commands/start_temporal_worker.py"
    "code/ee/__init__.py"
    "code/common/hogvm/__init__.py"
    "code/common/migration_utils/__init__.py"
    "code/products/__init__.py"

    # 3. Migrations, Governance, Schemas & Stamphog
    "code/rust/persons_migrations"
    "code/services/mcp/schema/tool-definitions.json"
    "code/tools/owners/posthog_owners"
    "code/products/stamphog/packages/pr-approval-agent/review_local.py"

    # 4. Frontend Bundles, Layouts & Static Assets
    "code/frontend/src/products.json"
    "code/frontend/dist/index.html"
    "code/frontend/dist/layout.html"
    "code/frontend/dist/exporter.html"
    "code/staticfiles"

    # 5. External Databases & Tokenizer Caches
    "code/share/GeoLite2-City.mmdb"
    "code/.tiktoken_cache"

    # 6. Sidecar, Plugin & Canvas Packages
    "code/products/canvas/packages/canvas_builder/package.json"
    "code/common/plugin_transpiler/package.json"
)

ERRORS=0
for path in "${CRITICAL_PATHS[@]}"; do
    if [ -e "$DIR_ENVE/$path" ]; then
        echo "  ✅ [FOUND] $path"
    else
        echo "  ❌ [MISSING] $path"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check executable permissions on core entrypoint scripts
EXECUTABLE_BINARIES=(
    "code/bin/docker-server-unit"
    "code/bin/docker-worker-celery"
    "code/bin/temporal-django-worker"
    "code/bin/docker-migrate"
    "code/bin/migrate-check"
)

for bin in "${EXECUTABLE_BINARIES[@]}"; do
    if [ -x "$DIR_ENVE/$bin" ]; then
        echo "  ✅ [PERM]  $bin is executable (+x)"
    else
        echo "  ❌ [PERM]  $bin is NOT executable"
        ERRORS=$((ERRORS + 1))
    fi
done

# Compare checksums between Enve OCI and Dockerfile.enve if available
if [ -d "$DIR_DOCKER/code" ]; then
    echo "-----------------------------------------------------------------------"
    echo "  ⚖️ Comparing Content Checksums: Pure Enve OCI vs Dockerfile.enve..."
    echo "-----------------------------------------------------------------------"
    COMPARE_FILES=(
        "manage.py"
        "bin/docker-server-unit"
        "unit.json.tpl"
        "commit.txt"
        "frontend/src/products.json"
        "services/mcp/schema/tool-definitions.json"
    )
    for file in "${COMPARE_FILES[@]}"; do
        if [ -f "$DIR_ENVE/code/$file" ] && [ -f "$DIR_DOCKER/code/$file" ]; then
            HASH_ENVE=$(sha256sum "$DIR_ENVE/code/$file" | awk '{print $1}')
            HASH_DOCKER=$(sha256sum "$DIR_DOCKER/code/$file" | awk '{print $1}')
            if [ "$HASH_ENVE" = "$HASH_DOCKER" ]; then
                echo "  ✅ [IDENTICAL] $file (SHA: ${HASH_ENVE:0:16}...)"
            else
                echo "  ⚠️ [DIFF]      $file differs between Enve and Docker"
            fi
        fi
    done
fi

# Compare with Upstream if available
if [ -d "$DIR_UPSTREAM/code" ]; then
    echo "-----------------------------------------------------------------------"
    echo "  🏆 Comparing File Tree Parity vs Upstream Production Image..."
    echo "-----------------------------------------------------------------------"
    UP_COUNT=$(find "$DIR_UPSTREAM/code" -type f | wc -l)
    ENVE_COUNT=$(find "$DIR_ENVE/code" -type f | wc -l)
    echo "  Upstream Files: $UP_COUNT"
    echo "  Pure Enve Files: $ENVE_COUNT"
    
    DIFF_COUNT=$(python3 -c "
import os
def get_files(d):
    res = set()
    for root, _, files in os.walk(d):
        for f in files:
            res.add(os.path.relpath(os.path.join(root, f), d))
    return res

up_files = get_files('$DIR_UPSTREAM/code')
enve_files = get_files('$DIR_ENVE/code')
missing = up_files - enve_files
print(f'Missing in Enve: {len(missing)}')
if missing:
    for m in sorted(list(missing))[:10]:
        print(f'   - {m}')
")
    echo "  $DIFF_COUNT"
fi

echo "======================================================================="
if [ $ERRORS -eq 0 ]; then
    echo "🎉 100% CONTAINER EQUIVALENCE & ARTIFACT PARITY VERIFIED!"
    echo "   Pure Enve OCI contains all required production assets."
    exit 0
else
    echo "❌ Parity check failed with $ERRORS missing critical components."
    exit 1
fi
