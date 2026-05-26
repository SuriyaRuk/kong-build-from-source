#!/usr/bin/env bash
set -euo pipefail


BUILDER=multiarch

# Create the multi-arch builder once; the plain "docker" driver can't do
# multi-platform --push builds, so we need a docker-container builder.
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  docker buildx create --name "$BUILDER" --driver docker-container --bootstrap
fi

docker buildx build --builder "$BUILDER" \
   --platform linux/arm64,linux/amd64 \
   -f Dockerfile \
   -t suriyaruk/kong-build-from-source:3.9.1-1.29.2.5 \
   --push \
   .
