#!/bin/bash
# Build and push ubersdr-multicast to Docker Hub and Git

set -e

# Configuration
DOCKER_USERNAME="${DOCKER_USERNAME:-madpsy}"
IMAGE_NAME="ubersdr-multicast"
FULL_IMAGE="${DOCKER_USERNAME}/${IMAGE_NAME}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "UberSDR Multicast - Git & Docker Push"
echo "=========================================="
echo ""

# Get version/tag
if [ -n "$1" ]; then
    TAG="$1"
else
    # Default to 'latest'
    TAG="latest"
fi

# Git operations
echo -e "${YELLOW}Checking git status...${NC}"
if [ -n "$(git status --porcelain)" ]; then
    echo "Changes detected. Committing to git..."
    git add -A

    # Use tag as commit message if provided, otherwise use default
    if [ "$TAG" != "latest" ]; then
        COMMIT_MSG="Release ${TAG}"
    else
        COMMIT_MSG="Update $(date +%Y-%m-%d)"
    fi

    git commit -m "$COMMIT_MSG"
    echo -e "${GREEN}Changes committed: $COMMIT_MSG${NC}"
else
    echo "No changes to commit."
fi

echo ""
echo "Pushing to git remote..."
git push

if [ $? -ne 0 ]; then
    echo -e "${RED}Git push failed!${NC}"
    exit 1
fi

echo -e "${GREEN}Git push successful!${NC}"
echo ""

echo -e "${GREEN}Building image: ${FULL_IMAGE}:${TAG}${NC}"
echo ""

# Build the image
echo "Building Docker image..."
docker build -t "${FULL_IMAGE}:${TAG}" .

if [ $? -ne 0 ]; then
    echo -e "${RED}Build failed!${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}Build successful!${NC}"
echo ""

# Also tag as latest if a specific version was provided
if [ "$TAG" != "latest" ]; then
    echo "Tagging as latest..."
    docker tag "${FULL_IMAGE}:${TAG}" "${FULL_IMAGE}:latest"
fi

# Push to Docker Hub
echo ""
echo "Pushing to Docker Hub..."
echo "  ${FULL_IMAGE}:${TAG}"

docker push "${FULL_IMAGE}:${TAG}"

if [ $? -ne 0 ]; then
    echo -e "${RED}Push failed!${NC}"
    exit 1
fi

# Push latest tag if we created it
if [ "$TAG" != "latest" ]; then
    echo "  ${FULL_IMAGE}:latest"
    docker push "${FULL_IMAGE}:latest"
fi

echo ""
echo -e "${GREEN}=========================================="
echo "Successfully pushed to Docker Hub!"
echo "==========================================${NC}"
echo ""
echo "Image: ${FULL_IMAGE}:${TAG}"
if [ "$TAG" != "latest" ]; then
    echo "Also:  ${FULL_IMAGE}:latest"
fi
echo ""
echo "To use this image:"
echo "  docker pull ${FULL_IMAGE}:${TAG}"
echo ""
echo "Or in docker-compose.yml:"
echo "  image: ${FULL_IMAGE}:${TAG}"
echo ""
