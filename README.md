# plex-rar2fs-docker

[![Docker Image CI](https://github.com/TheFitzZZ/plex-rar2fs-docker/actions/workflows/docker-image.yml/badge.svg)](https://github.com/TheFitzZZ/plex-rar2fs-docker/actions/workflows/docker-image.yml)
[![Docker Hub](https://img.shields.io/docker/pulls/fitzzz/plex-rar2fs.svg)](https://hub.docker.com/r/fitzzz/plex-rar2fs)

Plex Media Server in Docker, with **transparent RAR archive access** (via [rar2fs](https://github.com/hasse69/rar2fs)) and **working Intel iGPU hardware transcoding** (VAAPI / iHD driver, musl-clean).

The upstream [`plexinc/pms-docker`](https://hub.docker.com/r/plexinc/pms-docker) base image ships `libva.so.2` but no VAAPI driver — Plex silently falls back to software transcoding there. This image bundles a musl-built iHD driver compatible with Plex's bundled musl loader, so HW transcoding actually works (Alder Lake / UHD 770 verified).

---

## Quick start

```bash
docker run -d \
  --name plex \
  --network=host \
  --device /dev/dri:/dev/dri \
  --cap-add SYS_ADMIN --device /dev/fuse --security-opt apparmor=unconfined \
  -e TZ="Europe/Berlin" \
  -e PLEX_CLAIM="<claimToken>" \
  -v /path/to/config:/config \
  -v /path/to/transcode:/transcode \
  -v /path/to/media:/data \
  fitzzz/plex-rar2fs:latest
```

- RAR archives in `/data` appear unpacked under `/data-unrar` inside the container — point your Plex library there.
- HW transcoding requires Plex Pass.
- On Unraid, `--privileged` is the simplest replacement for the `--cap-add`/`--device fuse` triple.

For all standard Plex networking modes, volume layouts, `PLEX_CLAIM`, `PLEX_UID/GID` etc., refer to the [upstream `plexinc/pms-docker` docs](https://github.com/plexinc/pms-docker#readme) — this image is a transparent superset.

---

## What this image adds over `plexinc/pms-docker`

| | Upstream `plexinc/pms-docker` | This image |
|---|---|---|
| RAR archive access | ❌ | ✅ via `/data-unrar` (rar2fs + libfuse) |
| Intel iGPU VAAPI driver | ❌ (libva only, no `iHD_drv_video.so`) | ✅ musl-built, Plex-bundled-libc compatible |
| `intel-gmmlib` version | n/a | 22.10.0 (self-built; compatible with Plex' runtime-downloaded iHD) |

---

## Build args

| Arg | Default | Source |
|---|---|---|
| `RAR2FS_VERSION` | `v1.29.7` | https://github.com/hasse69/rar2fs/tags |
| `UNRAR_VERSION` | `7.1.10` | https://www.rarlab.com/rar/ |
| `ALPINE_VERSION` | `3.17` | pinned for musl 1.2.3 ABI-compat with Plex's bundled musl 1.2.2 — **do not bump** without re-verifying the VAAPI load chain |

Override at build time, e.g. `docker build --build-arg UNRAR_VERSION=7.0.9 -t plex-rar2fs:test .`

---

## Tags

CI publishes per merge to `master`:

- `:latest` — newest master build
- `:sha-<short>` — pin to a specific commit
- `:YYYYMMDD` — pin to a build date

A daily cron rebuilds when the upstream `plexinc/pms-docker:latest` digest changes, so `:latest` tracks security/PMS updates.

---

## Hardware-accelerated transcoding — verification

After starting the container with `--device /dev/dri:/dev/dri` and triggering a Plex transcode session, the Plex Transcoder process should contain `h264_vaapi` (or `hevc_vaapi`) as the encoder:

```bash
docker exec plex sh -c 'ps auxf | grep -E "h264_vaapi|hevc_vaapi" | grep -v grep'
```

If you see the encoder flag and CPU usage stays moderate (~20–30 % per session, not 600 %+), HW transcoding is live.

For troubleshooting (driver load issues, Plex' runtime DriverDL pipeline, musl/glibc symbol mismatches), the [merged PR history](https://github.com/TheFitzZZ/plex-rar2fs-docker/pulls?q=is%3Apr+is%3Amerged) documents the actual issues encountered and their fixes — each PR description carries the diagnostic notes that led to it.

---

## Acknowledgments

- **[@Pretagonist](https://github.com/Pretagonist)** — original author of [`Pretagonist/plex-rar2fs-docker`](https://github.com/Pretagonist/plex-rar2fs-docker), this image's parent. Pretagonist did the original rar2fs + Plex integration work and graciously named this fork as the active successor when the upstream repo was archived. Thank you. 🙏
- **[hasse69/rar2fs](https://github.com/hasse69/rar2fs)** — the FUSE filesystem that makes transparent RAR access possible.
- **[disaster37/docker-plex](https://github.com/disaster37/docker-plex)** — earlier reference for the s6-overlay rar2fs integration pattern.
- **[plexinc/pms-docker](https://github.com/plexinc/pms-docker)** — upstream Plex container base.

---

## Maintenance & contributions

This repository is maintained by [@TheFitzZZ](https://github.com/TheFitzZZ). PRs are welcome — please run a local build (`docker build .`) and, for VAAPI-related changes, attach a successful transcode log line (`ps` output showing `h264_vaapi` / `hevc_vaapi`) from a real Intel iGPU host.

**Agentic AI disclosure:** routine maintenance of this repository (Dockerfile updates, dependency bumps, VAAPI debugging, README edits, CI tweaks) is performed with the assistance of LLM coding agents under human review and approval. Every commit is reviewed and tested before merge; every Docker image push goes through CI. If you spot an issue, please open one — it's actually being read by a person, even if you see em-dashes ;-).

---

## License

This repository inherits its license from the upstream Plex container base. Plex Media Server itself is proprietary; this image only packages it. RAR support uses unrar which has its own [restrictive license](https://www.rarlab.com/rar/unrarsrc-readme.txt) — please review it before redistribution.
