#!/usr/bin/env bash
set -euo pipefail

# 0. Stage container application assets
echo "• 0. Staging container application assets..."
./scripts/build_container_assets.sh dist/container-root

# 1. Pull the official upstream production image from DockerHub / GHCR
echo "• 1. Pulling official upstream production image..."
docker pull posthog/posthog:latest

# 2. Build the Dockerfile.enve image locally (Path 2)
echo "• 2. Building Dockerfile.enve image locally..."
docker build -f Dockerfile.enve \
    --build-context frontend-build=dist/container-root \
    -t posthog:docker-enve .

# 3. Synthesize the Pure Enve OCI archive (Path 1, takes ~3-8s)
echo "• 3. Synthesizing Pure Enve OCI archive..."
enve image build \
    --app-dir dist/container-root \
    --tag "posthog:enve-pure" \
    --out dist/posthog-enve-multiarch.tar

# 4. Run the 3-way container parity verifier
echo "• 4. Running 3-way container parity verifier..."
./scripts/verify_container_parity.sh \
    dist/posthog-enve-multiarch.tar \
    posthog:docker-enve \
    posthog/posthog:latest
