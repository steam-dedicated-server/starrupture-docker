<p align="center">
  <img src="starrupture-logo.jpg" alt="Starrupture" width="460" />
</p>

# Starrupture Dedicated Server

Container-first dedicated server for **Starrupture** (Steam App ID `3809400`).

- Multi-stage Docker image (Ubuntu 24.04 + Wine + Xvfb to run the Windows-only server binary)
- Pre-warmed steamcmd → first `install` only pays for the Starrupture `app_update`
- `tini` as PID 1 → clean signal forwarding, no zombies, real graceful shutdown
- Pure-Python A2S healthcheck → ~5 ms per probe, no fork/exec overhead
- Single modular `star` CLI (`install` / `update` / `run` / `backup` / `health`)
- Production-tuned Docker Compose for a single VPS (4 vCPU / 8–16 GB RAM)
- Kustomize-based Kubernetes bundle (single-node tested)

> Inspired by the original
> [indifferentbroccoli/starrupture-server-docker](https://github.com/indifferentbroccoli/starrupture-server-docker)
> — full credit for figuring out the Wine + DSSettings + first-boot flow.
> This is a clean-slate rewrite around the [`last-oasis-docker`](https://github.com/steam-dedicated-server/last-oasis-docker)
> structure (multi-stage image, modular CLI, A2S healthcheck, K8s bundle, CI/CD).
> **Notable difference:** password generation does **not** call any
> third-party API — see [Passwords](#passwords) below.
>
> Not affiliated with the Starrupture developers. Use at your own risk.

---

## Quick start — Docker Compose (single server)

```bash
# 1. Grab the compose file
curl -fLO https://raw.githubusercontent.com/steam-dedicated-server/starrupture-docker/main/compose/docker-compose.yml

# 2. Replace every <REPLACE_*> placeholder in the `environment` block
$EDITOR docker-compose.yml

# 3. Download game files (one-shot, anonymous Steam — no 2FA)
docker compose --profile maintenance run --rm install

# 4. First boot — see "First boot" section below
$EDITOR docker-compose.yml    # set START_NEW_GAME=true, LOAD_SAVED_GAME=false
docker compose up -d server
# (join with a client, create + save the world, then stop)
docker compose down

# 5. Flip back and run normally
$EDITOR docker-compose.yml    # set START_NEW_GAME=false, LOAD_SAVED_GAME=true
docker compose up -d server

# Day-to-day
docker compose ps                                    # health
docker compose logs -f server                        # tail
docker compose --profile maintenance run --rm update # update game
docker compose --profile maintenance run --rm backup # tar.gz of save data
docker compose down                                  # stop
```

Or use the bundled `Makefile`:

```bash
make install   # download / install
make up        # start
make logs      # tail
make backup    # backup
make down      # stop
```

---

## Repo layout

```
.
├── docker/
│   ├── Dockerfile             # multi-stage Ubuntu 24.04 + Wine + Xvfb
│   └── healthcheck.py         # Steam A2S query (pure Python)
├── scripts/
│   ├── star                   # main CLI dispatcher
│   └── lib/
│       ├── common.sh          # logging, retry, traps
│       ├── config.sh          # env loading / validation
│       ├── steam.sh           # steamcmd wrappers (Windows depot)
│       ├── server.sh          # Wine + Xvfb launch + DSSettings render
│       └── backup.sh          # save backup
├── config/
│   ├── defaults.env           # baked-in defaults
│   └── server.example.env     # user config template
├── compose/
│   ├── docker-compose.yml         # single-server (primary)
│   └── docker-compose.multi.yml   # multi-shard skeleton
├── k8s/                       # kustomize bundle
│   ├── kustomization.yaml
│   ├── pvc.yaml
│   ├── install-job.yaml
│   ├── deployment.yaml
│   ├── backup-cronjob.yaml
│   ├── secret.example.yaml
│   └── README.md
├── .github/workflows/
│   ├── ci.yml                 # shellcheck + hadolint + build smoke test
│   └── release.yml            # GHCR publish on v*.*.* tags
├── Makefile
├── LICENSE
└── README.md
```

---

## Configuration

| Variable               | Required | Default                  | Notes                                        |
|------------------------|:--------:|--------------------------|----------------------------------------------|
| `SERVER_NAME`          |   ✅    | `starrupture-server`     | display name in matchmaking                  |
| `SERVER_PORT`          |   ✅    | `7777`                   | game UDP/TCP port                            |
| `SERVER_QUERY_PORT`    |   ✅    | `27015`                  | Steam A2S query (UDP)                        |
| `USE_DSSETTINGS`       |         | `true`                   | render `DSSettings.txt` from env (recommended) |
| `SESSION_NAME`         |         | `StarRuptureServer`      | in-game session display name                 |
| `SAVE_GAME_INTERVAL`   |         | `300`                    | autosave interval, seconds                   |
| `START_NEW_GAME`       |         | `false`                  | see "First boot" below                       |
| `LOAD_SAVED_GAME`      |         | `true`                   | see "First boot" below                       |
| `SAVE_GAME_NAME`       |         | `AutoSave0.sav`          | which save file to resume                    |
| `MULTIHOME`            |         | —                        | bind to a specific NIC IP                    |
| `STEAM_USER`           |         | `anonymous`              | non-anonymous needs `star login` once        |
| `STEAM_APP_ID`         |         | `3809400`                | do not change unless the depot changes       |
| `SERVER_OPTIONS`       |         | —                        | extra UE CLI flags, appended verbatim        |
| `INSTALL_DIR`          |         | `/mnt/steam/starrupture` | install path inside the volume               |
| `BACKUP_DIR`           |         | `/mnt/steam/backups`     | tarball destination                          |
| `WINEPREFIX`           |         | `/mnt/steam/.wine`       | Wine prefix on the persistent volume         |
| `HEALTHCHECK_TIMEOUT`  |         | `3`                      | seconds for A2S probe                        |
| `STAR_LOG_LEVEL`       |         | `info`                   | `debug` for verbose                          |

Sources of values, in increasing precedence:

1. `config/defaults.env` (baked into image)
2. `config/server.env` or `$STAR_CONFIG_FILE` (if present)
3. Compose `environment:` block / k8s `Secret` / shell env

---

## First boot

Starrupture's dedicated server cannot autocreate a world from the CLI —
the world must be created by a player in-game first, then the server
can reload it on subsequent boots.

1. Start the server with **`START_NEW_GAME=true`**, **`LOAD_SAVED_GAME=false`**,
   **`USE_DSSETTINGS=true`** (the default in this image already sets
   `USE_DSSETTINGS=true`; only the two flags above need to flip).
2. Launch the Starrupture client → **Manage Server** → enter your
   server's public IP + port → **Create World** → **Save**.
3. Stop the server: `make down` (or `docker compose down`).
4. Flip back: **`START_NEW_GAME=false`**, **`LOAD_SAVED_GAME=true`**.
5. Start the server again: `make up`. It will load `AutoSave0.sav`
   automatically and the in-game world will persist across restarts.

After this handshake the server can be restarted, updated, and
backed up without re-doing the first-boot flow — saves live under
`/mnt/steam/starrupture/StarRupture/Saved/`.

---

## Passwords

Starrupture reads admin / player passwords from game-encrypted JSON
files (`Password.json`, `PlayerPassword.json`) next to the install.
The encryption is game-specific and not publicly documented, so
plaintext passwords cannot be turned into the JSON files locally.

The community provides a web tool that produces the encrypted blob:
[`starrupture-utilities.com/passwords`](https://starrupture-utilities.com/passwords/).

**This image does NOT call that API.** Some other community Docker
images POST your plaintext admin/player passwords to that endpoint on
every container start — we don't. The trade-off: you generate the
encrypted blob yourself, once, and drop it onto the volume.

```bash
# 1. Generate the encrypted JSON via the web tool above.
# 2. Drop the files onto the persistent volume:
docker compose --profile maintenance run --rm --entrypoint=bash install -c \
  'cat > /mnt/steam/starrupture/Password.json'       # paste the JSON, then Ctrl-D
docker compose --profile maintenance run --rm --entrypoint=bash install -c \
  'cat > /mnt/steam/starrupture/PlayerPassword.json' # same

# 3. Restart the server.
```

On Kubernetes, mount the files via a Secret + projected volume into
the install dir, or shell into the running pod and write them once
(see [`k8s/README.md`](k8s/README.md)).

---

## Performance tuning at a glance

| Knob                          | Where                          | Effect                                              |
|-------------------------------|--------------------------------|-----------------------------------------------------|
| `seccomp:unconfined`          | compose `security_opt`         | mandatory — steamcmd uses blocked syscalls          |
| `nofile=1048576`              | compose `ulimits`              | high-FD UE5 server + Wine                           |
| `tmpfs /tmp` (512 MB)         | compose `tmpfs`                | avoids volume churn from temp files                 |
| `cpus`, `memory` limits       | compose `deploy.resources`     | caps a runaway server, keeps host responsive        |
| Pre-warmed steamcmd           | `Dockerfile` build stage       | first runtime `install` is much faster              |
| Wine prefix on volume         | `WINEPREFIX=/mnt/steam/.wine`  | cold init paid once; cached across restarts         |
| `WINEDEBUG=-all`              | env / Dockerfile               | silences Wine's per-call trace logs                 |
| Multi-stage build             | `Dockerfile`                   | image stays slim despite the Wine + i386 deps       |
| BuildKit `cache mounts`       | `Dockerfile`                   | re-builds skip apt + steamcmd download              |
| Pure-Python A2S healthcheck   | `docker/healthcheck.py`        | ~5 ms per probe                                     |
| `tini` as PID 1               | `Dockerfile` ENTRYPOINT        | proper signal forwarding, no zombies                |
| `stop_grace_period: 60s`      | compose                        | server gets time to flush saves on shutdown         |

Recommended VPS for one shard: **4 vCPU / 8–16 GB RAM / 60 GB SSD / 400 Mbps**.

---

## Healthcheck

`docker/healthcheck.py` sends a UDP `A2S_INFO` packet to
`HEALTHCHECK_HOST:SERVER_QUERY_PORT` (default `127.0.0.1:27015`) with a
3-second timeout. The container is marked **unhealthy** after three
consecutive failures — paired with `restart: unless-stopped`, Docker
will recycle a hung server automatically.

If your Starrupture build doesn't respond to A2S queries (unlikely —
it uses the Steam SDK), override `HEALTHCHECK_TIMEOUT` higher or swap
the probe for a `pgrep wine` check via the `healthcheck` block.

---

## Multi-shard on one host

Use [`compose/docker-compose.multi.yml`](compose/docker-compose.multi.yml)
as a starting point. Each `server-NN` runs on a distinct port pair and
**its own Wine prefix** (`WINEPREFIX=/mnt/steam/.wine-NN`) to avoid
lock contention, sharing the same `starrupture-data` volume.

---

## Kubernetes

```bash
# 1. Create the namespace
kubectl create namespace starrupture

# 2. Render your Secret from the template
cp k8s/secret.example.yaml k8s/secret.yaml
$EDITOR k8s/secret.yaml
kubectl -n starrupture apply -f k8s/secret.yaml

# 3. Apply the bundle
kubectl -n starrupture apply -k k8s/

# 4. Watch
kubectl -n starrupture logs -f job/starrupture-install
kubectl -n starrupture get pods -w
kubectl -n starrupture logs -f deploy/starrupture-server
```

`Deployment` runs with `hostNetwork: true` so the game ports come
straight off the node's IP. Startup probe gets a long grace
(500 s default) so the Wine prefix init + UE5 cold start don't
trip liveness.

See [`k8s/README.md`](k8s/README.md) for the full guide (first-boot
handshake on k8s, day-2 ops, multi-shard layouts, teardown).

---

## Releases

Cut a SemVer release and `release.yml` publishes to GHCR:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Published tags: `0.1.0`, `0.1`, `latest`. Images include SBOM and
SLSA provenance attestation.

---

## Credits

- [indifferentbroccoli/starrupture-server-docker](https://github.com/indifferentbroccoli/starrupture-server-docker)
  — the upstream community image that figured out the Wine launch
  recipe, the `DSSettings.txt` format, the first-boot client-side
  world-creation flow, and the `StarRuptureServerEOS-Win64-Shipping.exe`
  CLI flags. Many of the operational decisions here trace back to
  reading their `scripts/start.sh`.
- [last-oasis-docker](https://github.com/steam-dedicated-server/last-oasis-docker)
  — the structural ancestor: multi-stage Dockerfile, modular `star` CLI
  layout, A2S healthcheck, Compose anchors, kustomize bundle, CI/CD.

## License

MIT — see [LICENSE](LICENSE).
