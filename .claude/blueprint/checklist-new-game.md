# New-Game Bring-Up Checklist

Use this when porting [`README.md`](README.md) blueprint to a new Steam dedicated server (Rust, ARK, Valheim, Starrupture, ...).

---

## Phase 0 — Discovery (before writing any code)

- [ ] **Steam app ID — installer**: which app does SteamCMD download? (search SteamDB)
- [ ] **Steam app ID — runtime**: does the engine need `steam_appid.txt` with a different id?
- [ ] **Anonymous download?** — try `steamcmd +login anonymous +app_info_print <ID> +quit` first; if it 401s, you need a real account
- [ ] **Server binary name + path** inside the install dir (e.g. `Mist/Binaries/Linux/MistServer-Linux-Shipping`)
- [ ] **Default ports** — game UDP/TCP + Steam query UDP
- [ ] **Required CLI flags** — copy verbatim from the official server guide; don't paraphrase
- [ ] **Backend / matchmaking URL** — exact hostname (some games need `-production` suffix)
- [ ] **Healthcheck protocol** — Source games = A2S; others may need custom (check `wireshark` on the query port)
- [ ] **Save data directory** to back up (relative to install dir)
- [ ] **Realistic player count + RAM/CPU per slot** — sets compose resource caps
- [ ] **License / EULA** — some games (ARK, Conan) require accepting on first run

---

## Phase 1 — Scaffolding (~30 min)

- [ ] Copy the file tree from [`README.md → Canonical file structure`](README.md#canonical-file-structure)
- [ ] Rename the CLI: `scripts/lo` → `scripts/<game>` (e.g. `scripts/rust`, `scripts/star`)
- [ ] Update internal namespace: `lo::*` → `<game>::*` (sed across `scripts/lib/`)
- [ ] Set `IMAGE` in `Makefile` to `ghcr.io/<org>/<game>-docker`
- [ ] Set GHCR target in `.github/workflows/release.yml` (it auto-derives from `${{ github.repository }}` if the repo name matches)
- [ ] Replace `last-oasis-logo.jpg` with the new game's banner

---

## Phase 2 — Container plumbing

- [ ] **Dockerfile**: change `STEAM_APP_ID` ARG defaults if you want them baked in; keep `HOME=/mnt/steam`, `UID 1000 GID 1001`, `tini`, `python3-minimal`
- [ ] **Add game-specific apt deps** if the engine needs them (e.g. `libsdl2-2.0-0` for some titles)
- [ ] **healthcheck.py**: if not Source-engine, swap the probe payload + reply check
- [ ] **scripts/lib/steam.sh**: confirm `+@ShutdownOnFailedCommand 1`, `+@NoPromptForPassword 1`, `+app_license_request` are present
- [ ] **scripts/lib/server.sh**:
  - [ ] Set the binary path constant
  - [ ] Update the built-in CLI flags to match the official guide
  - [ ] Keep `_link_steamclient` and `LD_LIBRARY_PATH` export (needed for any Steam-SDK engine)
  - [ ] Keep `ulimit -n 65536` and `renice -n -5`
- [ ] **scripts/lib/backup.sh**: point `src=` at the game's save dir

---

## Phase 3 — Config + compose

- [ ] **config/defaults.env**: set `STEAM_APP_ID`, `STEAM_RUNTIME_APP_ID` (rename `STEAM_LINUX_APP_ID` if helpful), `INSTALL_DIR=/mnt/steam/<game>`, `BACKUP_DIR=/mnt/steam/backups`
- [ ] **config/server.example.env**: list every required env var with a comment explaining where to get it (link to the game's admin panel / Steam guide)
- [ ] **compose/docker-compose.yml**: update port mappings + `deploy.resources` to match the game's spec
- [ ] **compose/docker-compose.multi.yml** if multi-server is in scope

---

## Phase 4 — Kubernetes

- [ ] **k8s/secret.example.yaml**: list all env vars from `server.example.env`
- [ ] **k8s/install-job.yaml + deployment.yaml + backup-cronjob.yaml**: update `containerPort` / `hostPort`, resource requests/limits, healthcheck command if changed
- [ ] **k8s/pvc.yaml**: size for the game's install footprint + saves headroom
- [ ] **k8s/README.md**: copy the structure, swap `last-oasis` → `<game>` and update the resource name examples
- [ ] Keep `fix-permissions` initContainer, `SYS_NICE` capability, `hostNetwork: true`, `Recreate` strategy

---

## Phase 5 — CI / release

- [ ] **.github/workflows/ci.yml**: smoke tests pass (`<cli> version`, `<cli> help`)
- [ ] **.github/workflows/release.yml**: tag a `v0.1.0` to dry-run the publish (delete the package after if needed)
- [ ] **README.md**: top-of-repo banner, quick start, configuration table, performance tuning, MyRealm-equivalent admin portal link
- [ ] **LICENSE**: keep MIT or pick something compatible with upstream's license if you derived from one — credit them

---

## Phase 6 — Verification

- [ ] `make build` succeeds locally
- [ ] `docker compose --profile maintenance run --rm install` downloads game files into `/mnt/steam`
- [ ] `docker compose --profile maintenance run --rm --entrypoint=bash install -c "ls /mnt/steam/<game>/<binary-path>/"` confirms the binary exists
- [ ] `docker compose up -d server` starts; `docker compose ps` shows `healthy` within `start_period`
- [ ] External player can connect to `SERVER_IP_ADDRESS:SERVER_PORT`
- [ ] The server appears in the game's matchmaking / browser (this catches backend-URL typos)
- [ ] `docker compose --profile maintenance run --rm backup` produces a tarball
- [ ] On K8s: install Job completes, Deployment becomes Ready, port-forward proves A2S query responds

---

## Common time-sinks (in order of likelihood)

1. **Wrong app ID for `app_update`** — always installer ID, not runtime ID → `Invalid platform`
2. **Backend URL typo / missing suffix** — server runs fine but invisible
3. **Volume path mismatch** — image vs PVC mount; install "succeeds" but binary not found
4. **UID/GID mismatch with existing PVC** — permission errors after first restart
5. **Missing `steam_appid.txt`** — engine refuses to start, "App not registered" in logs
6. **Anonymous download forbidden** — need to switch `STEAM_USER` to an owning account
7. **Forgot `+app_license_request`** — first run fails with "Missing configuration"
8. **shellcheck `source-path=SCRIPTDIR` not set** — CI fails to follow `# shellcheck source=lib/...`
9. **hadolint DL4006** — pipe in `RUN` without `SHELL ... pipefail`
10. **yamllint default rules** — too strict for inline-map k8s style; relax `braces`/`colons`/`commas` in CI
