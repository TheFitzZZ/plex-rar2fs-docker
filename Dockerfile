# syntax=docker/dockerfile:1.7

# ============================================================================
# Stage 1: extract Alpine's musl-built Intel VAAPI driver
# ============================================================================
# WHY Alpine?
#   Plex Media Server's transcoder binary is linked against a bundled musl
#   libc (/usr/lib/plexmediaserver/lib/ld-musl-x86_64.so.1 + libc.so) with a
#   gcompat shim. Ubuntu/Debian's intel-media-va-driver is built against
#   glibc 2.38+ and references symbols (e.g. __isoc23_strtoul) that gcompat
#   does NOT shim, so dlopen() fails with "symbol not found" — regardless of
#   whether the driver is bind-mounted from a host or apt-installed inside
#   the Plex image.
#
# Alpine builds intel-media-driver against musl, so the resulting
# iHD_drv_video.so resolves cleanly when loaded by Plex's bundled ld-musl.
# Verified 2026-06-09 with `plex-bundled-ld-musl --list iHD_drv_video.so`:
# all dependencies (libigdgmm, libstdc++, libgcc_s, libc.musl) resolve
# without symbol errors.
# ============================================================================
ARG ALPINE_VERSION=edge
FROM alpine:${ALPINE_VERSION} AS dri-source
RUN apk add --no-cache intel-media-driver
# Stage output: /usr/lib/dri/iHD_drv_video.so + libigdgmm + Alpine's
# libstdc++ / libgcc_s (the driver depends on Alpine's specific builds).

# ============================================================================
# Stage 2: Plex + rar2fs + Alpine VAAPI driver
# ============================================================================
FROM plexinc/pms-docker:latest

# ----------------------------------------------------------------------------
# Build args (overridable at `docker build --build-arg KEY=VALUE`)
# ----------------------------------------------------------------------------
ARG RAR2FS_VERSION=v1.29.7
ARG UNRAR_VERSION=7.1.10
ARG DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------------------------
# Copy Alpine's musl-built Intel VAAPI driver into Plex's own lib dir.
# Placing it under /usr/lib/plexmediaserver/lib/dri keeps it self-contained
# and matches where Plex's libva looks (paired with the env vars below).
# ----------------------------------------------------------------------------
COPY --from=dri-source /usr/lib/dri/iHD_drv_video.so   /usr/lib/plexmediaserver/lib/dri/
COPY --from=dri-source /usr/lib/libigdgmm.so.12.10.0   /usr/lib/plexmediaserver/lib/
COPY --from=dri-source /usr/lib/libstdc++.so.6.0.34    /usr/lib/plexmediaserver/lib/
COPY --from=dri-source /usr/lib/libgcc_s.so.1          /usr/lib/plexmediaserver/lib/

# Recreate the SONAME symlinks for the versioned libs (libigdgmm.so.12 → .12.10.0,
# libstdc++.so.6 → .6.0.34) AND add the libc.musl-x86_64.so.1 alias to ld-musl.
#
# IMPORTANT: do NOT `COPY` the symlink-named files directly from the Alpine
# stage — `docker COPY` dereferences symlinks and copies the TARGET as a
# regular file. The result is two independent ELF files with the same content
# but different inodes, so `patchelf` only patches one (the .X.Y.Z one) and
# the loader uses the SONAME-named copy (the .X one, unpatched, no RPATH) →
# transitive deps fall back to system glibc → segfault. Verified the hard way
# 2026-06-09 in PR #5.
#
# The libc.musl alias matches Alpine's own layout (libc.musl-x86_64.so.1 is
# always a symlink to ld-musl-x86_64.so.1 on musl systems).
RUN set -eux; \
    cd /usr/lib/plexmediaserver/lib; \
    ln -sf libigdgmm.so.12.10.0 libigdgmm.so.12; \
    ln -sf libstdc++.so.6.0.34  libstdc++.so.6; \
    ln -sf ld-musl-x86_64.so.1  libc.musl-x86_64.so.1

# Tell libva where to find the driver and which driver to load.
# Without these, libva uses its compile-time default path (a non-existent
# /home/runner/_work/... rpath baked into Plex's libva by the Plex CI build).
ENV LIBVA_DRIVERS_PATH=/usr/lib/plexmediaserver/lib/dri \
    LIBVA_DRIVER_NAME=iHD

# ----------------------------------------------------------------------------
# Single RUN layer: build deps -> patch driver RPATH -> build rar2fs -> cleanup.
# Build deps live and die in the same layer so they aren't cached in a
# lower layer (which would bloat the final image even after `apt remove`).
# ----------------------------------------------------------------------------
RUN set -eux; \
    BUILD_DEPS="libfuse-dev autoconf automake autopoint build-essential git wget ca-certificates patchelf"; \
    RUNTIME_DEPS="fuse libfuse2t64"; \
    apt-get update; \
    apt-get install -y --no-install-recommends $BUILD_DEPS $RUNTIME_DEPS; \
    \
    # --- Patch driver + transitive dep RPATHs so they resolve to Plex's lib dir ---
    # The Alpine-built iHD_drv_video.so depends on libigdgmm.so.12, libstdc++.so.6,
    # libgcc_s.so.1 — but Plex's transcoder process-wide dynamic linker does NOT
    # search /usr/lib/plexmediaserver/lib/ by default. Without RPATH the driver
    # loads, then segfaults at 0x4310 (NULL function pointer call) when it tries
    # to call a libigdgmm function whose .so wasn't resolved.
    #
    # IMPORTANT: it's not enough to patch only the driver — libigdgmm.so.12 itself
    # ALSO has DT_NEEDED entries for libstdc++.so.6 / libgcc_s.so.1 / libc.musl
    # and without its own RPATH it picks the GLIBC versions from /usr/lib/x86_64-
    # linux-gnu/, which the musl-built driver+libigdgmm cannot interop with →
    # same 0x4310 segfault. Patch EVERY Alpine .so we copied in.
    # Verified 2026-06-09 on Unraid (UHD 770) — libigdgmm without RPATH was the
    # last surviving symlink-resolution mismatch after PR #3 + #4.
    for so in \
        /usr/lib/plexmediaserver/lib/dri/iHD_drv_video.so \
        /usr/lib/plexmediaserver/lib/libigdgmm.so.12.10.0 \
        /usr/lib/plexmediaserver/lib/libstdc++.so.6.0.34 \
        /usr/lib/plexmediaserver/lib/libgcc_s.so.1 \
    ; do \
        patchelf --set-rpath '/usr/lib/plexmediaserver/lib' "$so"; \
        echo "RPATH on $so: $(patchelf --print-rpath "$so")"; \
    done; \
    \
    # --- Build rar2fs ---
    cd /tmp; \
    git clone --depth 1 --branch "${RAR2FS_VERSION}" https://github.com/hasse69/rar2fs.git; \
    cd rar2fs; \
    wget -q "https://www.rarlab.com/rar/unrarsrc-${UNRAR_VERSION}.tar.gz"; \
    tar -xzf "unrarsrc-${UNRAR_VERSION}.tar.gz"; \
    cd unrar; \
    make -j"$(nproc)" lib; \
    make install-lib; \
    cd ..; \
    autoreconf -f -i; \
    ./configure; \
    make -j"$(nproc)"; \
    make install; \
    \
    # --- Cleanup: remove build deps, keep runtime deps ---
    cd /; \
    apt-get purge -y --auto-remove $BUILD_DEPS; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*; \
    \
    # --- Create mount point for rar2fs ---
    mkdir /data-unrar

# Add start script (s6-overlay v2 cont-init.d)
COPY rar2fs-assets/30-rar2fs-mount /etc/cont-init.d/

# Volumes
VOLUME /config
VOLUME /data
VOLUME /transcode
