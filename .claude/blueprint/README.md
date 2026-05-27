# Game-Server-on-Docker Blueprint

Battle-tested patterns extracted from the [last-oasis-docker](https://github.com/steam-dedicated-server/last-oasis-docker) build. Reuse this as the starting point for any Steam-based dedicated server (Rust, ARK, Valheim, V Rising, Palworld, Starrupture, ...) running on Docker / Kubernetes.

> Companion: [`checklist-new-game.md`](checklist-new-game.md) — bring-up checklist when starting a new game.

---

## Philosophy

1. **One image, three deploy targets.** The same image runs bare Docker, Compose, and Kubernetes. Differences are configuration, not separate images.
2. **The container is the binary.** Game files, steamcmd state, saves, and backups all live on one persistent volume — easy to back up, easy to migrate.
3. **A single CLI inside the image.** `install`, `update`, `run`, `backup`, `health`, `login`, `shell` — same dispatcher whether you're on Compose or K8s.
4. **Fail loudly.** SteamCMD is happy to return 0 on a truncated download or wrong platform. Use `+@ShutdownOnFailedCommand 1`, `set -o pipefail`, healthchecks, and proper exit codes.
5. **Performance defaults that are obvious.** seccomp:unconfined, tini PID 1, `nofile=1048576`, `SYS_NICE` for renice, pre-warmed steamcmd — every choice has a one-line "why" in the code or compose file.

---

## Canonical file structure

```
.
├── docker/
│   ├── Dockerfile             # multi-stage; downloader → runtime
│   └── healthcheck.py         # protocol probe (A2S for Source-engine games)
├── scripts/
│   ├── <cli-name>             # main dispatcher — e.g. `lo`, `rust`, `valheim`
│   └── lib/
│       ├── common.sh          # logging, retry, traps, help
│       ├── config.sh          # env loading + required-var validation
│       ├── steam.sh           # steamcmd wrappers (install / update / login)
│       ├── server.sh          # lifecycle (run, start, runtime prep)
│       └── backup.sh          # tar.gz of save dir
├── config/
│   ├── defaults.env           # baked-into-image defaults
│   └── server.example.env     # user template (copy to server.env)
├── compose/
│   ├── docker-compose.yml         # single-server, production-tuned
│   └── docker-compose.multi.yml   # multi-map skeleton
├── k8s/
│   ├── README.md              # deploy guide
│   ├── kustomization.yaml
│   ├── pvc.yaml
│   ├── install-job.yaml       # one-shot steamcmd Job
│   ├── deployment.yaml        # the actual server
│   ├── backup-cronjob.yaml
│   └── secret.example.yaml
├── .github/workflows/
│   ├── ci.yml                 # shellcheck + hadolint + yamllint + smoke test
│   └── release.yml            # GHCR on v*.*.* tags, SBOM + provenance
├── Makefile                   # task runner
├── README.md
├── LICENSE
├── .dockerignore .gitignore .editorconfig .shellcheckrc .hadolint.yaml
└── <game>-logo.jpg            # optional banner for the README
```

---

## Build patterns

### Multi-stage Dockerfile

```
┌─ Stage 1: steamcmd ────────────┐    Downloads + extracts steamcmd_linux.tar.gz.
│   FROM ubuntu:24.04            │    Cached separately from the runtime stage
│   curl | tar -xz               │    so code changes don't refetch steamcmd.
└────────────────────────────────┘

┌─ Stage 2: runtime ─────────────┐    Minimal apt deps + tini, COPY steamcmd
│   FROM ubuntu:24.04            │    from stage 1, COPY scripts + config,
│   apt: tini ca-certs lib32     │    pre-warm `steamcmd.sh +quit`, then USER
│   COPY --from=steamcmd ...     │    steam.
│   COPY scripts/ config/ ...    │
└────────────────────────────────┘
```

Key flags:

| Flag | Why |
|---|---|
| `# syntax=docker/dockerfile:1.7` | Enables `--mount=type=cache` and `--chmod` |
| `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` (in pipe stages) | Truncated `curl \| tar` would otherwise return 0 — hadolint DL4006 |
| `--mount=type=cache,target=/var/cache/apt` | Re-builds skip apt re-download |
| `COPY --chmod=0755 ...` | Linux exec bit on scripts authored on Windows |
| `ENV HOME=/mnt/steam` | steamcmd's `~/.steam` lands inside the volume |
| `VOLUME ["/mnt/steam"]` | Single canonical mount point — matches the upstream/K8s convention |
| `tini` as PID 1 | Clean signal forwarding, zombie reaping |
| `HEALTHCHECK CMD python3 /opt/.../healthcheck.py` | Pure stdlib, ~5 ms/probe |
| `USER steam` (UID 1000, GID 1001) | Match upstream convention — see [`patterns.md → UID/GID`](#uidgid) |

### Healthcheck — Steam A2S protocol

```python
A2S_INFO = b"\xff\xff\xff\xffTSource Engine Query\x00"
sock.sendto(A2S_INFO, (host, query_port))
data, _ = sock.recvfrom(2048)
ok = data[:4] == b"\xff\xff\xff\xff" and data[4:5] in (b"I", b"A")
```

Works for any Source-engine game. For non-Source games (Rust uses a similar query format; Valheim uses its own protocol) — swap the probe payload but keep the structure.

### tini + exec

Inside the container the `lo run` script ends with `exec "$bin" "${args[@]}"` so the engine becomes the direct child of tini. Without `exec`, a bash wrapper holds PID and SIGTERM never reaches the engine — `terminationGracePeriodSeconds` then elapses and SIGKILL truncates saves.

---

## Script patterns

### Modular CLI

```
scripts/<cli-name>          ← entrypoint, sources libs, dispatches subcommand
scripts/lib/common.sh       ← log, die, retry, require, help
scripts/lib/config.sh       ← load defaults.env + server.env (allexport)
scripts/lib/steam.sh        ← steamcmd wrappers (install/update/login)
scripts/lib/server.sh       ← run + runtime prep (steamclient symlinks, ulimit, renice)
scripts/lib/backup.sh       ← tar -czf with timestamp
```

Why split:

- Each lib has one responsibility — easy to swap (e.g., replace `steam.sh` with `epic.sh` for Epic Online Services games)
- Sourced libs share `lo::*` namespace, no global pollution
- Strict mode (`set -euo pipefail`) only in the entry script — libs stay sourceable

### Logging

```bash
lo::log::info()  { lo::log::_write INFO  "$LO_BLUE"   "$*"; }
lo::log::warn()  { lo::log::_write WARN  "$LO_YELLOW" "$*"; }
lo::log::error() { lo::log::_write ERROR "$LO_RED"    "$*"; }
lo::log::ok()    { lo::log::_write OK    "$LO_GREEN"  "$*"; }
```

ISO timestamp, level, message, color only on TTY. Writes to stderr so command output stays clean on stdout.

### Retry with exponential backoff

```bash
lo::retry()   # wraps any command; honors LO_RETRY_MAX, LO_RETRY_DELAY
```

Used for every steamcmd call — Steam's CMS occasionally fails the first attempt on a fresh anonymous license cache.

### Config loading precedence

```
defaults.env  (lowest)  →  config/server.env  →  shell env  (highest)
```

Two-line implementation: `set -o allexport; . file; set +o allexport`. Re-export so child processes inherit the values.

---

## Deployment patterns

### Docker Compose

| Knob | Where | Effect |
|---|---|---|
| `seccomp:unconfined` | `security_opt` | steamcmd uses blocked syscalls (mandatory) |
| `ulimits.nofile: 1048576` | service | many concurrent player connections |
| `tmpfs: /tmp:size=256m` | service | avoid volume churn |
| `stop_grace_period: 60s` | service | flush saves before SIGKILL |
| `deploy.resources.{limits,reservations}` | service | cap a runaway server |
| `logging.options.max-size: 20m, max-file: 5` | service | log rotation |
| `--profile maintenance` | install/update/backup services | one-shot ops don't auto-start |
| Anchors (`x-image`, `x-common`, `x-env`) | top-level | DRY for multi-server |
| `init: false` | service | tini is already inside the image |

### Kubernetes

| Resource | Notes |
|---|---|
| `Namespace` | Created **out-of-band** via `kubectl create namespace` — not in the kustomize bundle, leaves namespace policy to the operator |
| `PVC` | RWO, sized for the game (e.g. Last Oasis = 30 Gi) |
| `Secret` | All env vars; never committed; `secret.example.yaml` is the template |
| `Job` (install) | One-shot steamcmd run, `restartPolicy: Never`, `backoffLimit: 0` so a failed attempt surfaces fast |
| `Deployment` (server) | `replicas: 1`, `strategy: Recreate`, `hostNetwork: true`, `terminationGracePeriodSeconds: 60` |
| `CronJob` (backup) | Daily, `concurrencyPolicy: Forbid` |
| `initContainer` (fix-permissions) | busybox `chown 1000:1001` — PVCs often provision root-owned |
| Pod `securityContext` | `runAsUser: 1000`, `runAsGroup: 1001`, `fsGroup: 1001` |
| Container `securityContext` | `seccompProfile: Unconfined`, `capabilities.add: [SYS_NICE]` for renice |
| Probes | startup / liveness / readiness — all `exec` the same healthcheck.py |

### UID/GID

**UID 1000, GID 1001.** This is the upstream Deradon convention. Many K8s clusters have existing PVCs owned 1000:1001 — using 1000:1000 means migration headaches.

Ubuntu 24.04 ships a default `ubuntu` user at UID 1000 — `userdel --remove ubuntu` first, then create `steam` at 1000:1001.

---

## CI / CD

```yaml
# .github/workflows/ci.yml
env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: "true"   # opt in early to Node 24

jobs:
  lint:
    - shellcheck (scripts/)
    - hadolint   (docker/Dockerfile)
    - yamllint   (relaxed: allow inline maps + aligned columns)
  build:
    - docker/build-push-action with type=gha cache, push: false, smoke-test `cli version` and `cli help`

# .github/workflows/release.yml
on: push: tags: [v*.*.*]
- docker/metadata-action → semver tags + latest
- docker/build-push-action → push to GHCR with provenance + SBOM
```

`.shellcheckrc` essentials:
```
shell=bash
external-sources=true
source-path=SCRIPTDIR    ← lets shellcheck follow `# shellcheck source=lib/common.sh`
```

`.hadolint.yaml`:
```yaml
ignored: [DL3008, DL3009]   # don't pin apt versions; cache mounts replace `rm -rf /var/lib/apt/lists`
```

yamllint inline config (allow k8s/compose inline-map style):
```yaml
rules:
  braces:  { max-spaces-inside: 1 }
  colons:  { max-spaces-after: -1 }
  commas:  { max-spaces-after: -1 }
```

---

## SteamCMD gotchas (bug history)

These all bit me building last-oasis-docker. Skip the same pain in the next project.

### 1. Two app IDs per game — installer vs runtime

Many Steam dedicated servers expose **two** app IDs:

- **Installer app** — what SteamCMD downloads (e.g. Last Oasis: `920720`)
- **Runtime app** — written to `Mist/Binaries/Linux/steam_appid.txt` so the running server identifies itself to matchmaking (e.g. `903950`)

If you use the runtime ID for `+app_update`, SteamCMD returns **`Invalid platform`** because the runtime app has no downloadable depot. Use the installer ID for download, then write the runtime ID into `steam_appid.txt` post-install:

```bash
+force_install_dir "$INSTALL_DIR" \
+login "$STEAM_USER" \
+app_license_request "$STEAM_APP_ID" \
+app_update "$STEAM_APP_ID" validate \
+quit

# After install:
echo "$STEAM_RUNTIME_APP_ID" > "$INSTALL_DIR/<game-dir>/Binaries/Linux/steam_appid.txt"
```

### 2. SteamCMD silently returns 0 on failure

Without `+@ShutdownOnFailedCommand 1`, a failing `app_update` can still exit 0. Always set:

```
+@ShutdownOnFailedCommand 1     ← exit non-zero on first failed step
+@NoPromptForPassword 1         ← don't block waiting for an interactive password
+app_license_request <APP_ID>   ← pre-warm license cache (avoids "Missing configuration")
```

### 3. UE4 dedicated servers need steamclient.so symlinks

Engines built with the Steam SDK `dlopen` `steamclient.so` from `~/.steam/sdk32/steamclient.so` and `~/.steam/sdk64/steamclient.so`. steamcmd drops the runtime under various paths depending on version — symlink the first hit:

```bash
for arch in 32 64; do
  target=""
  for c in \
    "$HOME/.steam/steamcmd/linux${arch}/steamclient.so" \
    "$HOME/Steam/steamcmd/linux${arch}/steamclient.so" \
    "$HOME/.steam/steam/linux${arch}/steamclient.so" \
    "$HOME/.steam/Steam/linux${arch}/steamclient.so" \
    "/home/steam/steamcmd/linux${arch}/steamclient.so"; do
    [[ -e "$c" ]] && { target="$c"; break; }
  done
  [[ -n "$target" ]] && ln -sfT "$target" "$HOME/.steam/sdk${arch}/steamclient.so"
done

export LD_LIBRARY_PATH="$HOME/.steam/sdk64:$HOME/.steam/sdk32${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

Also pass `-force_steamclient_link` to the engine CLI.

### 4. Anonymous downloads don't always work

`STEAM_USER=anonymous` works for many dedicated servers, but some (Last Oasis, ARK, Conan Exiles) require the SteamCMD account to **own the game**. If install fails with `Invalid Password` / `Login Failure`, switch to a real account:

```bash
docker compose --profile maintenance run --rm -it install
# enter password + 2FA on first run; cached for subsequent runs
```

### 5. Backend URL exactness

Some games proxy through a production-suffixed backend host — e.g. Last Oasis needs `backend-production.last-oasis.com`, not `backend.last-oasis.com`. The unsuffixed host often resolves but the realm never registers with matchmaking. **Server starts fine, healthcheck passes, but no player can see it.**

When porting to a new game, find the official setup guide and copy the backend URL verbatim — don't guess.

### 6. Volume / UID mismatch

If the image uses `/data` but the K8s PVC mounts at `/mnt/steam`, the install writes into a tmpfs that vanishes between commands. The next `run` looks at an empty install dir and reports "binary not found." Pick **one** path, document it in the Dockerfile `VOLUME` directive and in `defaults.env`, and use it everywhere.

---

## Performance levers (in order of impact)

1. **`cpus`/`memory` limits + reservations** — prevents the engine from starving the host and vice versa.
2. **`ulimits.nofile=1048576`** — UE4 servers + Steam SDK eat FDs.
3. **`renice -n -5` (needs `SYS_NICE`)** — game thread wins scheduler conflicts.
4. **`tmpfs: /tmp:size=256m`** — UE4 caches in /tmp; tmpfs avoids volume IO.
5. **`-USEALLAVAILABLECORES`** (UE4 only) — task graph schedules across all visible CPUs.
6. **Pre-warmed steamcmd in the build** — first runtime `install` doesn't pay for bootstrap.
7. **Multi-stage build with BuildKit cache** — rebuild times drop from minutes to seconds when only scripts change.

---

## Things to revisit per-game

When porting this blueprint to a new game, expect to change:

- **App IDs** (installer + runtime) and how `steam_appid.txt` is laid out
- **Binary name and path** (Linux vs Windows binary, executable filename)
- **Server CLI flags** — every game has its own; check the official server guide
- **Backend / matchmaking URL** — must be exact
- **Required env vars** — game-specific keys (CustomerKey/ProviderKey for LO, RCON pass for Rust, etc.)
- **Healthcheck protocol** — A2S works for Source games; others may need a custom probe
- **Resource sizing** — modern UE5 games (Starrupture etc.) need more RAM than UE4
- **Anonymous download support** — verify on Steam store page or community forums

Everything else (file structure, CLI shape, Compose layout, K8s patterns, CI/CD) should stay the same.
