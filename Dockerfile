# syntax=docker/dockerfile:1.7

# ============================================================================
# Stage 1: extract Alpine's musl-built Intel VAAPI driver
# ============================================================================
# WHY Alpine 3.17 (not edge)?
#   Plex Media Server's transcoder binary is linked against a bundled musl
#   libc 1.2.2 (verified 2026-06-09 in plexinc/pms-docker:latest:
#   `strings .../ld-musl-x86_64.so.1 | grep -A1 "musl libc"` → 1.2.2).
#
#   Alpine edge ships musl 1.2.5 — an ABI-compatible MINOR bump on paper,
#   but in practice Alpine-built libstdc++/libigdgmm crash with SIGSEGV at
#   address 0x4310 during their C++ runtime init when loaded by Plex's
#   musl 1.2.2 loader. The crash trace shows _dlstart() called from inside
#   the Alpine libs' .init_array — incompatible internal musl state layout.
#
#   Alpine 3.17 ships musl 1.2.3 (small-version-bump from Plex's 1.2.2,
#   verified working) + intel-media-driver 22.6.3 + libigdgmm.so.12.3.0
#   + libstdc++.so.6.0.30. Tested 2026-06-09 against /dev/dri/renderD128
#   on a host without an Intel iGPU: the driver loads, calls
#   __vaDriverInit_1_16, and fails cleanly on the get-chip-id IOCTL —
#   meaning the libc/libstdc++/libgcc_s/iHD chain works end-to-end and
#   only the real Intel hardware is missing. On a host WITH Intel iGPU
#   the IOCTL succeeds and HW transcoding works.
#
#   DO NOT bump ALPINE_VERSION past 3.17 without re-verifying — Alpine
#   3.18+ jumped to musl 1.2.4-1.2.5 which break against Plex's 1.2.2.
# ============================================================================
ARG ALPINE_VERSION=3.17
FROM alpine:${ALPINE_VERSION} AS dri-source
RUN apk add --no-cache intel-media-driver
# Stage output: /usr/lib/dri/iHD_drv_video.so + libigdgmm.so.12.3.0 +
# libstdc++.so.6.0.30 + libgcc_s.so.1 — all built against Alpine 3.17's
# musl 1.2.3, which is binary-compatible with Plex's bundled 1.2.2.

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
COPY --from=dri-source /usr/lib/libigdgmm.so.12.3.0    /usr/lib/plexmediaserver/lib/
COPY --from=dri-source /usr/lib/libstdc++.so.6.0.30    /usr/lib/plexmediaserver/lib/
COPY --from=dri-source /usr/lib/libgcc_s.so.1          /usr/lib/plexmediaserver/lib/

# Recreate the SONAME symlinks for the versioned libs AND add the
# libc.musl-x86_64.so.1 alias to ld-musl. See PR #6 for the COPY/symlink
# dereference trap that made us go through this exercise.
RUN set -eux; \
    cd /usr/lib/plexmediaserver/lib; \
    ln -sf libigdgmm.so.12.3.0 libigdgmm.so.12; \
    ln -sf libstdc++.so.6.0.30 libstdc++.so.6; \
    ln -sf ld-musl-x86_64.so.1 libc.musl-x86_64.so.1

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
        /usr/lib/plexmediaserver/lib/libigdgmm.so.12.3.0 \
        /usr/lib/plexmediaserver/lib/libstdc++.so.6.0.30 \
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
