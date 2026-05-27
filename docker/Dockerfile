# syntax=docker/dockerfile:1.7
# ============================================================
#  Starrupture dedicated server image
#  - Multi-stage: pull steamcmd in a downloader stage so the
#    runtime layer cache stays stable across script changes.
#  - tini as PID 1 for clean signal forwarding (no zombies).
#  - Pure-Python A2S healthcheck (no fork/exec overhead).
#  - Starrupture ships only a Windows server binary, so the
#    runtime layer pulls Wine + Xvfb to run it on Linux.
# ============================================================

# ---------- Stage 1: steamcmd downloader ----------
FROM ubuntu:24.04 AS steamcmd

# `pipefail` so a mid-download curl failure fails the whole pipeline
# (otherwise tar may exit 0 on a truncated archive).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates curl

WORKDIR /opt/steamcmd
RUN curl -fsSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
    | tar -xz


# ---------- Stage 2: runtime ----------
FROM ubuntu:24.04 AS runtime

ARG STEAM_UID=1000
ARG STEAM_GID=1001

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    IN_DOCKER=1 \
    HOME=/mnt/steam \
    WINEPREFIX=/mnt/steam/.wine \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    WINEDLLOVERRIDES=mscoree=d;mshtml=d \
    PATH=/opt/starrupture/scripts:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Wine needs i386 packages even for win64 prefixes (loader, plus
# steamcmd itself is a 32-bit ELF binary). Enable the architecture
# before the first apt-get update so the i386 indexes get fetched.
RUN dpkg --add-architecture i386

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      lib32gcc-s1 \
      lib32stdc++6 \
      python3-minimal \
      tini \
      wine \
      wine64 \
      wine32:i386 \
      xauth \
      xvfb && \
    rm -rf /var/lib/apt/lists/*

# Ubuntu 24.04 ships a default `ubuntu` user at UID/GID 1000.
# Reclaim that UID for `steam` so volumes built on earlier
# base images keep matching ownership.
RUN if id ubuntu >/dev/null 2>&1; then userdel --remove ubuntu; fi && \
    if getent group ubuntu >/dev/null;   then groupdel ubuntu;   fi && \
    groupadd --system --gid "${STEAM_GID}" steam && \
    useradd  --system --uid "${STEAM_UID}" --gid steam \
             --home-dir /home/steam --shell /usr/sbin/nologin \
             --create-home steam

# Persistent data volume (game files, saves, steamcmd state, WINEPREFIX).
# HOME is set to /mnt/steam so steamcmd's ~/.steam and the wine prefix
# both land inside the volume. /mnt/steam matches the upstream Deradon
# convention so existing K8s PVCs migrate cleanly.
RUN install -d -o steam -g steam -m 0755 /mnt/steam
VOLUME ["/mnt/steam"]

# steamcmd binary lives in the image (NOT in /mnt/steam) so volume
# mounts don't shadow it.
COPY --from=steamcmd --chown=steam:steam /opt/steamcmd /home/steam/steamcmd

# App files — order matters for layer caching:
#   1. healthcheck (rarely changes)
#   2. config defaults
#   3. libraries
#   4. main CLI (changes most often)
WORKDIR /opt/starrupture
COPY --chown=steam:steam --chmod=0755 docker/healthcheck.py ./healthcheck.py
COPY --chown=steam:steam config/                            ./config/
COPY --chown=steam:steam scripts/lib/                       ./scripts/lib/
COPY --chown=steam:steam --chmod=0755 scripts/star          ./scripts/star

USER steam

# Pre-warm steamcmd: downloads its own bootstrap files now so the
# first runtime `install` only pays for the Starrupture app_update.
RUN /home/steam/steamcmd/steamcmd.sh +quit || true

EXPOSE 7777/udp 7777/tcp 27015/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=300s --retries=3 \
  CMD python3 /opt/starrupture/healthcheck.py || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/starrupture/scripts/star"]
CMD ["help"]
