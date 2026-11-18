#!/usr/bin/env bash
# Build a package locally, the same way the CI does.
# Usage: scripts/local-build.sh <upstream-tag> [suite] [revision]
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

tag="${1:?usage: local-build.sh <upstream-tag> [suite] [revision]}"
suite="${2:-bookworm}"
revision="${3:-1}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if [[ -d src/.git ]]; then
  current="$(git -C src describe --tags --exact-match 2>/dev/null || true)"
  [[ "$current" == "$tag" ]] || {
    echo "src/ contains '${current:-unknown}', not '$tag'. Remove src/ first." >&2
    exit 1
  }
else
  git clone --depth 1 --branch "$tag" --recurse-submodules --shallow-submodules \
    https://github.com/elegooofficial/ElegooSlicer.git src
fi

docker build --build-arg SUITE="$suite" -t "elegoo-builder:$suite" docker
mkdir -p "work/$suite" out
docker run --rm -v "$root:/build" \
  -e UPSTREAM_TAG="$tag" -e DEB_REVISION="$revision" \
  -e ELEGOOLINK_REF="${ELEGOOLINK_REF:-}" -e JOBS="${JOBS:-}" \
  -e ELEGOO_CLOUD="${ELEGOO_CLOUD:-1}" \
  -e WORK_DIR="/build/work/$suite" \
  "elegoo-builder:$suite" /build/scripts/build-deb.sh
