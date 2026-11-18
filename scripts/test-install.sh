#!/bin/sh
# Install the built package into a clean Debian system and run basic checks.
# Usage: test-install.sh <dir-with-deb>
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

dir="${1:?usage: test-install.sh <dir>}"
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
# apt resolves the Depends: line, so missing/unknown dependencies fail here.
apt-get install -y --no-install-recommends "$dir"/*.deb

test -x /usr/bin/elegoo-slicer || { echo "launcher missing" >&2; exit 1; }
test -f /usr/share/applications/com.elegoo3d.elegoo-slicer.desktop || { echo "desktop file missing" >&2; exit 1; }

bin=/opt/elegoo-slicer/bin/elegoo-slicer
test -x "$bin" || { echo "main binary missing" >&2; exit 1; }
echo "Main binary: $bin"
missing="$(ldd "$bin" | grep 'not found' || true)"
if [ -n "$missing" ]; then
  echo "Unresolved shared libraries:" >&2
  echo "$missing" >&2
  exit 1
fi

test -d "$(dirname "$bin")/../resources" || { echo "resources directory missing" >&2; exit 1; }
echo "Installation test passed."
