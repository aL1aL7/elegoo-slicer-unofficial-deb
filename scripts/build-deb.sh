#!/usr/bin/env bash
# Build ElegooSlicer from source and package it as a Debian binary package.
# Meant to run inside the container defined in docker/Dockerfile.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Environment:
#   UPSTREAM_TAG    upstream git tag that was checked out (required, e.g. v1.5.3.5)
#   DEB_REVISION    Debian revision (default: 1)
#   ELEGOOLINK_REF  commit of github.com/ELEGOO-3D/elegoo-link to build against.
#                   Upstream tracks origin/main; we pin it so that the deps cache
#                   and the build are reproducible (default: resolved via ls-remote)
#   SRC_DIR         upstream source tree        (default: /build/src)
#   WORK_DIR        scratch dir for build trees (default: /build/work)
#   OUT_DIR         where the .deb is written   (default: /build/out)
#   DEPS_DESTDIR    DESTDIR of the bundled deps build; reused if its stamp
#                   file matches, rebuilt otherwise (default: $WORK_DIR/deps)
#   JOBS            parallel build jobs         (default: nproc)
#   EXTRA_CMAKE_ARGS  additional arguments for the slicer configure step
#   ELEGOO_CLOUD    1 (default): build with ELEGOO cloud features like the
#                   official release. This ships the proprietary Agora RTM SDK.
#                   0: apply patches/no-cloud/ and build without them
#   SKIP_BUILD=1    only package an existing install tree (for debugging)

set -euo pipefail

: "${UPSTREAM_TAG:?UPSTREAM_TAG must be set}"
DEB_REVISION="${DEB_REVISION:-1}"
SRC_DIR="${SRC_DIR:-/build/src}"
WORK_DIR="${WORK_DIR:-/build/work}"
OUT_DIR="${OUT_DIR:-/build/out}"
DEPS_DESTDIR="${DEPS_DESTDIR:-$WORK_DIR/deps}"
# The deps project installs into ${DESTDIR}/usr/local. wxWidgets hardcodes
# that path into wx-config, so the location must stay stable between runs.
DEPS_PREFIX="$DEPS_DESTDIR/usr/local"
JOBS="${JOBS:-$(nproc)}"
ELEGOO_CLOUD="${ELEGOO_CLOUD:-1}"

PKG_NAME="elegoo-slicer"
INSTALL_PREFIX="/opt/elegoo-slicer"
ELEGOOLINK_REPO="https://github.com/ELEGOO-3D/elegoo-link.git"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGING_DIR="$REPO_DIR/packaging"
PATCH_DIR="$REPO_DIR/patches"

DEPS_BUILD="$WORK_DIR/deps-build"
SLICER_BUILD="$WORK_DIR/slicer-build"
STAGE="$WORK_DIR/stage"

# Upstream needs this for some bundled deps with CMake 4 (harmless with 3.x).
export CMAKE_POLICY_VERSION_MINIMUM=3.5

log() { printf '\n==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- version ---------------------------------------------------------------

# Upstream tags look like "v1.5.3.5". Debian versions must start with a digit;
# a "-" in the upstream part would be read as the Debian revision separator,
# and pre-release suffixes have to sort before the final release.
upstream_version="${UPSTREAM_TAG#[vV]}"
upstream_version="${upstream_version//-/\~}"
[[ "$upstream_version" =~ ^[0-9][A-Za-z0-9.+~]*$ ]] \
  || die "cannot derive a Debian version from tag '$UPSTREAM_TAG'"

# shellcheck disable=SC1091
. /etc/os-release
suite="${VERSION_CODENAME:?no VERSION_CODENAME in /etc/os-release}"
# The suite suffix keeps packages for different releases distinguishable and
# makes the newer distribution's build sort higher.
deb_version="${upstream_version}-${DEB_REVISION}~deb${VERSION_ID}"
arch="$(dpkg --print-architecture)"

[[ "$ELEGOO_CLOUD" == 0 || "$ELEGOO_CLOUD" == 1 ]] || die "ELEGOO_CLOUD must be 0 or 1"
[[ -d "$SRC_DIR" ]] || die "source dir $SRC_DIR does not exist"
mkdir -p "$WORK_DIR" "$OUT_DIR"

# --- source preparation ----------------------------------------------------

# Patches for the selected variant, in the order they are applied.
active_patches() {
  local patch
  shopt -s nullglob
  for patch in "$PATCH_DIR"/*.patch; do echo "$patch"; done
  if [[ "$ELEGOO_CLOUD" == 0 ]]; then
    for patch in "$PATCH_DIR"/no-cloud/*.patch; do echo "$patch"; done
  fi
  shopt -u nullglob
}

apply_patches() {
  # Start from the pristine tag so that switching variants or patch sets
  # works in an existing checkout. Untracked files (web assets) are kept.
  log "Resetting tracked files in $SRC_DIR"
  git -C "$SRC_DIR" checkout -- .
  local patch
  while IFS= read -r patch; do
    log "Applying patch: ${patch#"$PATCH_DIR"/}"
    git -C "$SRC_DIR" apply "$patch" || die "patch ${patch#"$PATCH_DIR"/} does not apply"
  done < <(active_patches)
}

pin_elegoolink() {
  local cmake_file="$SRC_DIR/deps/elegoolink/elegoolink.cmake"
  [[ -f "$cmake_file" ]] || return 0
  if [[ -z "${ELEGOOLINK_REF:-}" ]]; then
    ELEGOOLINK_REF="$(git ls-remote "$ELEGOOLINK_REPO" refs/heads/main | cut -f1)"
    [[ -n "$ELEGOOLINK_REF" ]] || die "cannot resolve elegoo-link main"
  fi
  if grep -q 'GIT_TAG *origin/main' "$cmake_file"; then
    log "Pinning elegoo-link to $ELEGOOLINK_REF"
    sed -i "s|GIT_TAG *origin/main|GIT_TAG             $ELEGOOLINK_REF|" "$cmake_file"
  elif ! grep -q "GIT_TAG *$ELEGOOLINK_REF" "$cmake_file"; then
    log "NOTE: elegoo-link is no longer tracked via origin/main upstream; leaving it as is"
  fi
}

download_web_assets() {
  # The printer web UI (LAN/cloud panels) is downloaded from a separate repo.
  local web_dir="$SRC_DIR/resources/plugins/elegoolink/web"
  [[ -f "$SRC_DIR/scripts/download_web_dep.sh" ]] || return 0
  if [[ -d "$web_dir/lan_service_web" ]]; then
    log "Web assets already present"
    return
  fi
  log "Downloading web assets"
  (cd "$SRC_DIR" && bash scripts/download_web_dep.sh)
}

# --- build -----------------------------------------------------------------

deps_stamp() {
  local tree patches docker
  tree="$(git -C "$SRC_DIR" rev-parse HEAD:deps 2>/dev/null || echo unknown)"
  # Only patches that touch deps/ invalidate the dependency build.
  patches="$(active_patches | xargs -r grep -l '^+++ b/deps/' | xargs -r cat \
    | sha256sum | cut -c1-16)"
  docker="$(sha256sum "$REPO_DIR/docker/Dockerfile" | cut -c1-16)"
  echo "$tree-$patches-$docker-${ELEGOOLINK_REF:-none}-$suite"
}

build_deps() {
  local stamp="$DEPS_DESTDIR/.deps-stamp"
  local want
  want="$(deps_stamp)"
  if [[ -f "$stamp" && "$(cat "$stamp")" == "$want" ]]; then
    log "Reusing prebuilt dependencies in $DEPS_PREFIX"
    return
  fi

  if [[ -f "$stamp" ]]; then
    # A finished build for different inputs: start from scratch.
    log "Dependency inputs changed, rebuilding from scratch"
    rm -rf "$DEPS_BUILD" "$DEPS_DESTDIR"
  elif [[ -d "$DEPS_BUILD" ]]; then
    # An interrupted build: let ninja continue where it stopped.
    log "Resuming interrupted dependency build"
  fi

  log "Building bundled dependencies (this takes a while)"
  cmake -S "$SRC_DIR/deps" -B "$DEPS_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DDEP_WX_GTK3=ON \
    -DDESTDIR="$DEPS_DESTDIR"
  # Like upstream: one external project at a time, each one built in parallel.
  CMAKE_BUILD_PARALLEL_LEVEL="$JOBS" cmake --build "$DEPS_BUILD" -j1

  [[ -d "$DEPS_PREFIX" ]] || die "deps build did not produce $DEPS_PREFIX"
  rm -rf "$DEPS_BUILD"
  echo "$want" > "$stamp"
}

fixup_deps() {
  # elegoo-link exports absolute paths to the Agora SDK inside its source tree
  # (deps build dir), which is deleted after the deps build and not cached.
  # The same libraries are installed into $DEPS_PREFIX/bin; point there.
  local targets="$DEPS_PREFIX/lib/cmake/elegoolink/elegoolink_targets.cmake"
  [[ -f "$targets" ]] || return 0
  if grep -q '/thirdparty/agora/linux/' "$targets"; then
    log "Redirecting elegoo-link's Agora SDK paths to $DEPS_PREFIX/bin"
    sed -i -E "s#[^;\"]*/thirdparty/agora/linux/#$DEPS_PREFIX/bin/#g" "$targets"
  fi
}

build_slicer() {
  log "Configuring ElegooSlicer"
  # The executable gets RPATH=$ORIGIN (not RUNPATH, hence --disable-new-dtags):
  # the proprietary libagora_rtm_sdk.so next to it needs libaosl.so but has no
  # search path of its own, and only RPATH also applies to indirect libraries.
  local -a extra=()
  if [[ -n "${EXTRA_CMAKE_ARGS:-}" ]]; then
    read -r -a extra <<< "$EXTRA_CMAKE_ARGS"
  fi
  cmake -S "$SRC_DIR" -B "$SLICER_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$DEPS_PREFIX" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
    -DSLIC3R_STATIC=1 \
    -DSLIC3R_GTK=3 \
    -DSLIC3R_PCH=ON \
    -DBBL_RELEASE_TO_PUBLIC=1 \
    -DBBL_INTERNAL_TESTING=0 \
    -DELEGOO_INTERNAL_TESTING=0 \
    -DCMAKE_INSTALL_RPATH="\$ORIGIN" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,--disable-new-dtags" \
    "${extra[@]}"

  log "Building ElegooSlicer"
  cmake --build "$SLICER_BUILD" --parallel "$JOBS"

  log "Compiling translations"
  (cd "$SRC_DIR" && sh ./scripts/run_gettext.sh)
}

install_slicer() {
  log "Installing into staging area"
  rm -rf "$STAGE"
  DESTDIR="$STAGE" cmake --install "$SLICER_BUILD"
}

# --- packaging -------------------------------------------------------------

find_main_binary() {
  local bin="$STAGE$INSTALL_PREFIX/bin/elegoo-slicer"
  [[ -x "$bin" ]] || die "main binary not found at ${bin#"$STAGE"}"
  echo "$bin"
}

install_desktop_integration() {
  local desktop="$SRC_DIR/src/dev-utils/platform/unix/com.elegoo3d.elegoo-slicer.desktop"
  [[ -f "$desktop" ]] || die "upstream desktop file not found: $desktop"
  install -D -m 0644 "$desktop" "$STAGE/usr/share/applications/$(basename "$desktop")"

  # The desktop file uses Icon=ElegooSlicer.
  local images="$SRC_DIR/resources/images" size found=0
  for size in 32 64 128 192; do
    if [[ -f "$images/ElegooSlicer_${size}px.png" ]]; then
      install -D -m 0644 "$images/ElegooSlicer_${size}px.png" \
        "$STAGE/usr/share/icons/hicolor/${size}x${size}/apps/ElegooSlicer.png"
      found=1
    fi
  done
  if [[ -f "$images/ElegooSlicer.svg" ]]; then
    install -D -m 0644 "$images/ElegooSlicer.svg" \
      "$STAGE/usr/share/icons/hicolor/scalable/apps/ElegooSlicer.svg"
    found=1
  fi
  [[ $found == 1 ]] || log "WARNING: no application icon found"
}

shlib_depends() {
  # dpkg-shlibdeps needs a debian/control in the working directory.
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/debian"
  printf 'Source: %s\n\nPackage: %s\nArchitecture: any\n' \
    "$PKG_NAME" "$PKG_NAME" > "$tmp/debian/control"

  local -a elfs
  mapfile -t elfs < <(find "$STAGE" -type f -exec sh -c \
    'file -b "$1" | grep -q "^ELF" && echo "$1"' _ {} \;)
  [[ ${#elfs[@]} -gt 0 ]] || die "no ELF files found in staging area"

  # -l: private libraries (Agora SDK) live next to the binary.
  (cd "$tmp" && dpkg-shlibdeps -O --ignore-missing-info \
      -l"$STAGE$INSTALL_PREFIX/bin" "${elfs[@]}") \
    | sed -n 's/^shlibs:Depends=//p'
  rm -rf "$tmp"
}

package() {
  log "Assembling package $PKG_NAME $deb_version ($arch)"
  local main_bin
  main_bin="$(find_main_binary)"

  local agora
  agora="$(find "$STAGE" \( -name 'libagora*' -o -name 'libaosl*' \) -print -quit)"
  if [[ "$ELEGOO_CLOUD" == 1 && -z "$agora" ]]; then
    die "cloud build, but the Agora SDK libraries were not installed"
  elif [[ "$ELEGOO_CLOUD" == 0 && -n "$agora" ]]; then
    die "cloud-free build, but Agora SDK libraries found in the install tree"
  fi

  # Strip debug info; the static build is huge otherwise.
  find "$STAGE" -type f -exec sh -c \
    'file -b "$1" | grep -q "^ELF.*not stripped" && strip --strip-unneeded "$1"' _ {} \;

  # Launcher in PATH.
  install -D -m 0755 "$PACKAGING_DIR/elegoo-slicer.sh" "$STAGE/usr/bin/$PKG_NAME"
  sed -i "s|@BINARY@|${main_bin#"$STAGE"}|" "$STAGE/usr/bin/$PKG_NAME"

  install_desktop_integration

  # Documentation, license, changelog.
  local doc="$STAGE/usr/share/doc/$PKG_NAME"
  install -d "$doc"
  local variant=cloud
  [[ "$ELEGOO_CLOUD" == 1 ]] || variant=no-cloud
  cat "$PACKAGING_DIR/copyright" "$PACKAGING_DIR/copyright.$variant" \
    | sed -e "s|@UPSTREAM_TAG@|$UPSTREAM_TAG|g" \
          -e "s|@ELEGOOLINK_REF@|${ELEGOOLINK_REF:-unknown}|g" > "$doc/copyright"
  [[ -f "$SRC_DIR/LICENSE.txt" ]] && install -m 0644 "$SRC_DIR/LICENSE.txt" "$doc/LICENSE"
  {
    printf '%s (%s) %s; urgency=medium\n\n' "$PKG_NAME" "$deb_version" "$suite"
    printf '  * Automated build of upstream release %s.\n\n' "$UPSTREAM_TAG"
    printf ' -- %s  %s\n' "${DEB_MAINTAINER:-elegoo-slicer-debian <noreply@github.com>}" \
      "$(date -R -u)"
  } | gzip -9n > "$doc/changelog.Debian.gz"

  # Control file.
  local depends installed_size
  depends="$(shlib_depends)"
  [[ -n "$depends" ]] || die "dpkg-shlibdeps returned no dependencies"
  rm -rf "$STAGE/DEBIAN"
  installed_size="$(du -sk "$STAGE" | cut -f1)"

  install -d "$STAGE/DEBIAN"
  sed -e "s|@PACKAGE@|$PKG_NAME|g" \
      -e "s|@VERSION@|$deb_version|g" \
      -e "s|@ARCH@|$arch|g" \
      -e "s|@DEPENDS@|$depends|g" \
      -e "s|@INSTALLED_SIZE@|$installed_size|g" \
      -e "s|@MAINTAINER@|${DEB_MAINTAINER:-elegoo-slicer-debian <noreply@github.com>}|g" \
      "$PACKAGING_DIR/control.in" > "$STAGE/DEBIAN/control"
  cat "$PACKAGING_DIR/description.$variant" >> "$STAGE/DEBIAN/control"

  # Normalise permissions so the package does not depend on the build umask.
  find "$STAGE" -type d -exec chmod 0755 {} +
  find "$STAGE" -type f -perm -u+x -exec chmod 0755 {} +
  find "$STAGE" -type f ! -perm -u+x -exec chmod 0644 {} +

  local deb="$OUT_DIR/${PKG_NAME}_${deb_version}_${arch}.deb"
  dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$deb"
  log "Built $deb"
  dpkg-deb --info "$deb"
}

main() {
  log "ElegooSlicer $UPSTREAM_TAG -> $PKG_NAME $deb_version on Debian $suite (cloud: $ELEGOO_CLOUD)"
  if [[ "${SKIP_BUILD:-0}" != 1 ]]; then
    apply_patches
    pin_elegoolink
    download_web_assets
    build_deps
    fixup_deps
    build_slicer
    install_slicer
  fi
  package
}

main "$@"
