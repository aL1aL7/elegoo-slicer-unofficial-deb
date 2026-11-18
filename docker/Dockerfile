# Build environment for ElegooSlicer Debian packages.
# SPDX-License-Identifier: GPL-3.0-or-later
ARG SUITE=bookworm
FROM debian:${SUITE}

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# Build dependencies of ElegooSlicer / OrcaSlicer (system part).
# Everything else (boost, wxWidgets, OCCT, CGAL, ...) is built by the
# upstream "deps" CMake project.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      autoconf \
      automake \
      build-essential \
      ca-certificates \
      cmake \
      curl \
      dpkg-dev \
      eglexternalplatform-dev \
      extra-cmake-modules \
      file \
      gettext \
      git \
      libcairo2-dev \
      libcurl4-openssl-dev \
      libdbus-1-dev \
      libegl-dev \
      libgl1-mesa-dev \
      libglew-dev \
      libglu1-mesa-dev \
      libgstreamer-plugins-base1.0-dev \
      libgstreamer1.0-dev \
      libgstreamerd-3-dev \
      libgtk-3-dev \
      libmspack-dev \
      libosmesa6-dev \
      libsecret-1-dev \
      libspnav-dev \
      libssl-dev \
      libtool \
      libudev-dev \
      libwayland-dev \
      libwebkit2gtk-4.1-dev \
      libxkbcommon-dev \
      m4 \
      nasm \
      ninja-build \
      pkgconf \
      python3 \
      texinfo \
      unzip \
      wayland-protocols \
      wget \
      xz-utils \
      zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

# Upstream sources are bind-mounted and owned by a different UID on the host.
RUN git config --system --add safe.directory '*'

WORKDIR /build
