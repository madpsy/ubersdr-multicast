#!/usr/bin/env bash
# docker.sh — build the ubersdr-multicast Docker image
#
# All binaries are built from source inside the Docker image.
# No host binaries are required.
#
# Usage:
#   ./docker.sh [build|arm64|push|run|nocache]
#
#   build    — build the image for linux/amd64 (default) and load into local daemon
#   arm64    — build the image for linux/arm64 and load into local daemon
#   push     — build multi-arch manifest (amd64 + arm64) and push to registry
#   run      — run the image locally (set env vars below)
#   nocache  — same as build but passes --no-cache to bypass the layer cache
#
# Environment variables (build):
#   IMAGE      Docker image name/tag   (default: madpsy/ubersdr-multicast:latest)
#   PLATFORM   Docker --platform flag  (default: linux/amd64)
#   BUILDER    buildx builder name     (default: ubersdr-builder)
#   NO_CACHE   Set to 1 to pass --no-cache (e.g. NO_CACHE=1 ./docker.sh build)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="${IMAGE:-madpsy/ubersdr-multicast:latest}"
PLATFORM="${PLATFORM:-linux/amd64}"
BUILDER="${BUILDER:-ubersdr-builder}"
NO_CACHE="${NO_CACHE:-0}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() { echo "error: $*" >&2; exit 1; }

check_deps() {
    command -v docker >/dev/null || die "docker not found in PATH"
    docker buildx version >/dev/null 2>&1 || die "docker buildx not available (Docker 19.03+ required)"
}

# Ensure a buildx builder that supports multi-platform builds exists.
ensure_builder() {
    if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
        echo "Creating buildx builder '$BUILDER'..."
        docker buildx create --name "$BUILDER" --driver docker-container --bootstrap
    fi
}

stage_context() {
    TMPCTX="$(mktemp -d)"
    trap 'rm -rf "$TMPCTX"' EXIT
    echo "Staging build context in $TMPCTX..."
    rsync -a --exclude='.git' "$SCRIPT_DIR/" "$TMPCTX/"
}

# build_local — single-platform build loaded into the local Docker daemon.
build_local() {
    check_deps
    ensure_builder
    stage_context

    local no_cache_flag=""
    [ "$NO_CACHE" = "1" ] && no_cache_flag="--no-cache"

    echo "Building image $IMAGE (platform=$PLATFORM${no_cache_flag:+, no-cache})..."
    docker buildx build \
        --builder "$BUILDER" \
        --platform "$PLATFORM" \
        --tag "$IMAGE" \
        --load \
        $no_cache_flag \
        "$TMPCTX"

    echo "Built: $IMAGE"
}

# push_multiarch — build amd64 + arm64 and push a combined manifest to the registry.
push_multiarch() {
    check_deps
    ensure_builder
    stage_context

    local platforms="linux/amd64,linux/arm64"
    echo "Building multi-arch image $IMAGE (platforms=$platforms) and pushing..."
    docker buildx build \
        --builder "$BUILDER" \
        --platform "$platforms" \
        --tag "$IMAGE" \
        --push \
        "$TMPCTX"

    echo "Pushed multi-arch manifest: $IMAGE"
    echo "Committing and pushing git repository..."
    git add -A
    git diff --cached --quiet || git commit -m "Release $IMAGE"
    git push
}

run_image() {
    docker run --rm -it \
        --platform "$PLATFORM" \
        "$IMAGE" \
        "$@"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "${1:-build}" in
    build)   build_local ;;
    arm64)   PLATFORM=linux/arm64 build_local ;;
    push)    push_multiarch ;;
    run)     shift; run_image "$@" ;;
    nocache) NO_CACHE=1 build_local ;;
    *)
        echo "Usage: $0 [build|arm64|push|run|nocache [args...]]" >&2
        exit 1
        ;;
esac
