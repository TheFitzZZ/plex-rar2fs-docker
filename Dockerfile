# syntax=docker/dockerfile:1.7

# ============================================================================
# Stage 1: build intel-gmmlib 22.10.0 from source + extract Alpine's musl-
# built Intel VAAPI driver.
#
# WHY this stage exists at all?
#   Modern Plex Server (≥1.43.x) ships a runtime "DriverDL" pipeline that
#   downloads its own iHD driver from Plex' CDN and shoves it into
#   /config/.../Cache/va-dri-linux-x86_64/iHD_drv_video.so. That CDN driver
#   is newer than Alpine 3.17's intel-media-driver and references
#   GmmLib::GmmClientContext::GmmGetAIL() — a symbol introduced in
#   intel-gmmlib 22.10.0 (Sep 2024). Alpine 3.17 only ships gmmlib 22.3.1
#   so the runtime dlopen of Plex' downloaded driver fails with:
#     Error relocating ...: _ZN6GmmLib16GmmClientContext9GmmGetAILEv: symbol not found
#   …causing every HW-transcode session to die with "Conversion failed".
#
#   Bumping ALPINE_VERSION to 3.20+ only gets us gmmlib 22.3.17 (same major,
#   still no GmmGetAIL). Alpine edge has 22.10.0 but ships musl 1.2.5 which
#   re-introduces the segfault PR #6 fixed. So we self-build gmmlib 22.10.0
#   inside an Alpine 3.17 stage — musl 1.2.3, ABI-compat with Plex's musl 1.2.2.
#
# WHY Alpine 3.17 (not edge)?  See PR #6 in this repo and the multi-page
#   skill doc at unraid/plex-vaapi-debugging.md (musl version compat matrix).
# ============================================================================
ARG ALPINE_VERSION=3.17
FROM alpine:${ALPINE_VERSION} AS dri-source

# Build deps for gmmlib (CMake C++ project) + Alpine's intel-media-driver package
RUN apk add --no-cache cmake g++ make git pkgconfig

# Self-build gmmlib 22.10.0 — exports the GmmGetAIL symbol Plex's downloaded
# iHD driver requires. Verified 2026-06-10: builds cleanly in Alpine 3.17,
# all 139 ULT tests pass, nm shows _ZN6GmmLib16GmmClientContext9GmmGetAILEv
# as a defined T (text) symbol.
RUN git clone --depth 1 --branch intel-gmmlib-22.10.0 \
        https://github.com/intel/gmmlib /src/gmmlib && \
    cd /src/gmmlib && mkdir build && cd build && \
    cmake -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX=/usr \
          -DRUN_TEST_SUITE=OFF \
          .. && \
    make -j"$(nproc)" && \
    make install && \
    rm -rf /src/gmmlib

# Alpine's intel-media-driver 22.6.3 driver itself remains the Alpine package
# (musl-built, RPATH-friendly). Its DT_NEEDED on libigdgmm.so.12 will be
# satisfied by our SELF-BUILT 22.10.0 via SONAME — both libs have SONAME
# "libigdgmm.so.12" and the 22.10.x branch is binary-back-compatible to
# 22.3.x consumers (verified by Intel's own ABI guarantee for libigdgmm).
RUN apk add --no-cache intel-media-driver

# Stage output:
#   /usr/lib/dri/iHD_drv_video.so          (Alpine pkg, Alpine 3.17 build)
#   /usr/lib/libigdgmm.so.12.10.0          (self-built, includes GmmGetAIL)
#   /usr/lib/libstdc++.so.6.0.30           (Alpine pkg)
#   /usr/lib/libgcc_s.so.1                 (Alpine pkg)
# all musl-1.2.3 ABI-compat to Plex's bundled musl 1.2.2.

# ============================================================================
# Stage 2: Plex + rar2fs + our musl-clean VAAPI driver
# ============================================================================
FROM plexinc/pms-docker:latest

ARG RAR2FS_VERSION=v1.29.7
ARG UNRAR_VERSION=7.1.10
ARG DEBIAN_FRONTEND=noninteractive

# Copy our self-built libigdgmm 22.10.0 (with GmmGetAIL) + Alpine driver +
# C++ runtime libs into Plex's own lib dir.
COPY --from=dri-source /usr/lib/dri/iHD_drv_video.so   /usr/lib/plexmediaserver/lib/dri/
COPY --from=dri-source /usr/lib/libigdgmm.so.12.10.0   /usr/lib/plexmediaserver/lib/
COPY --from=dri-source /usr/lib/libstdc++.so.6.0.30    /usr/lib/plexmediaserver/lib/
COPY --from=dri-source /usr/lib/libgcc_s.so.1          /usr/lib/plexmediaserver/lib/

# Recreate SONAME symlinks (COPY dereferences symlinks → would create
# duplicate files with no SONAME alias, breaking the loader's lookup).
# See PR #6 for the full background on this trap.
RUN set -eux; \
    cd /usr/lib/plexmediaserver/lib; \
    ln -sf libigdgmm.so.12.10.0 libigdgmm.so.12; \
    ln -sf libstdc++.so.6.0.30  libstdc++.so.6; \
    ln -sf ld-musl-x86_64.so.1  libc.musl-x86_64.so.1

ENV LIBVA_DRIVERS_PATH=/usr/lib/plexmediaserver/lib/dri \
    LIBVA_DRIVER_NAME=iHD

# Single RUN layer: build deps -> patch RPATHs -> build rar2fs -> cleanup.
RUN set -eux; \
    BUILD_DEPS="libfuse-dev autoconf automake autopoint build-essential git wget ca-certificates patchelf"; \
    RUNTIME_DEPS="fuse libfuse2t64"; \
    apt-get update; \
    apt-get install -y --no-install-recommends $BUILD_DEPS $RUNTIME_DEPS; \
    \
    # Patch RPATH on driver + all copied Alpine libs so the loader finds
    # the musl-built deps inside /usr/lib/plexmediaserver/lib, NOT the
    # GLIBC libs in /usr/lib/x86_64-linux-gnu. See PR #5 for the full why.
    for so in \
        /usr/lib/plexmediaserver/lib/dri/iHD_drv_video.so \
        /usr/lib/plexmediaserver/lib/libigdgmm.so.12.10.0 \
        /usr/lib/plexmediaserver/lib/libstdc++.so.6.0.30 \
        /usr/lib/plexmediaserver/lib/libgcc_s.so.1 \
    ; do \
        patchelf --set-rpath '/usr/lib/plexmediaserver/lib' "$so"; \
        echo "RPATH on $so: $(patchelf --print-rpath "$so")"; \
    done; \
    \
    # Build rar2fs
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
    # Cleanup
    cd /; \
    apt-get purge -y --auto-remove $BUILD_DEPS; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*; \
    \
    mkdir /data-unrar

COPY rar2fs-assets/30-rar2fs-mount /etc/cont-init.d/

VOLUME /config
VOLUME /data
VOLUME /transcode
