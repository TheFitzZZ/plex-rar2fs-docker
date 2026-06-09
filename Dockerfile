FROM plexinc/pms-docker:latest

# ----------------------------------------------------------------------------
# Build args (overridable at `docker build --build-arg KEY=VALUE`)
# ----------------------------------------------------------------------------
ARG RAR2FS_VERSION=v1.29.7
ARG UNRAR_VERSION=7.1.10
ARG DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------------------------
# Single RUN layer:
#   1. Install build deps
#   2. Install Intel VAAPI driver (intel-media-va-driver-non-free, va-driver-all)
#      → required for HW-accelerated transcoding on Intel iGPUs (UHD 6xx/7xx, Arc, ...).
#        The upstream plexinc/pms-docker image does NOT ship any VAAPI driver,
#        only libva itself. Without this package Plex falls back to SW transcoding.
#   3. Build rar2fs from source (pinned version, parallel make)
#   4. Remove build deps and clean apt cache
# Doing all of this in one RUN keeps the build artifacts out of the final
# image layer (previously a separate `RUN apt remove` left files cached in
# the lower layer, bloating the image).
# ----------------------------------------------------------------------------
RUN set -eux; \
    BUILD_DEPS="libfuse-dev autoconf automake autopoint build-essential git wget ca-certificates"; \
    RUNTIME_DEPS="fuse libfuse2t64 intel-media-va-driver-non-free va-driver-all"; \
    apt-get update; \
    apt-get install -y --no-install-recommends $BUILD_DEPS $RUNTIME_DEPS; \
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
