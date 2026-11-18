#!/bin/sh
# Launcher for ElegooSlicer, mirroring the workarounds of the upstream
# AppImage launcher (src/dev-utils/platform/unix/build_linux_image.sh.in).
# SPDX-License-Identifier: GPL-3.0-or-later

# The upstream AppImage launcher forces LC_ALL=C as a workaround for crashes
# with unusual locale setups. On Debian that hides the session language and
# makes the slicer quit at first start unless en_US.UTF-8 is generated, so it
# is opt-in here: set ELEGOO_SLICER_C_LOCALE=1 to get the upstream behaviour.
if [ "${ELEGOO_SLICER_C_LOCALE:-}" = "1" ]; then
    export LC_ALL=C
fi

# The statically linked OpenSSL looks for its CA bundle in the build tree;
# point it to the Debian bundle so the slicer does not ask at every start.
if [ -z "${SSL_CERT_FILE:-}" ] && [ -r /etc/ssl/certs/ca-certificates.crt ]; then
    export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
fi

# Upstream: NVIDIA drivers > 555 on Wayland render via Zink instead.
if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] && [ "${ZINK_DISABLE_OVERRIDE:-}" != "1" ] \
   && command -v glxinfo >/dev/null 2>&1 && command -v nvidia-smi >/dev/null 2>&1; then
    if glxinfo 2>/dev/null | grep "OpenGL renderer string:" | grep -qi nvidia; then
        major=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | cut -d. -f1)
        if [ -n "$major" ] && [ "$major" -gt 555 ] 2>/dev/null; then
            export __GLX_VENDOR_LIBRARY_NAME=mesa
            export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
            export MESA_LOADER_DRIVER_OVERRIDE=zink
            export GALLIUM_DRIVER=zink
            export WEBKIT_DISABLE_DMABUF_RENDERER=1
        fi
    fi
fi

exec @BINARY@ "$@"
