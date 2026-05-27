# Kubernetes deployment

Production-ready manifests for running one Starrupture dedicated server
on a single Kubernetes node.

## Prerequisites

- A node with at least **4 vCPU / 8 GB RAM / 60 GB free disk**
  (UE5 + Wine — recommend 16 GB RAM for a comfortable margin)
- Public IPv4 reachable from the internet (the Deployment uses `hostNetwork: true`)
- `kubectl` configured against the target cluster
- Optional: `kustomize` (or just use `kubectl apply -k`)

## Bundle contents

| File | Purpose |
|---|---|
| [`pvc.yaml`](pvc.yaml) | 50 Gi persistent volume for game files + saves + Wine prefix |
| [`install-job.yaml`](install-job.yaml) | One-shot Job that runs `steamcmd app_update` (Windows depot) |
| [`deployment.yaml`](deployment.yaml) | The actual game server (replicas: 1, Recreate) |
| [`backup-cronjob.yaml`](backup-cronjob.yaml) | Daily 04:00 UTC `tar.gz` of `StarRupture/Saved/` |
| [`secret.example.yaml`](secret.example.yaml) | Template for the per-server config Secret |
| [`kustomization.yaml`](kustomization.yaml) | Glue for `kubectl apply -k k8s/` |

## Deploy

```bash
# 1. Create the namespace (kept out of the kustomize bundle so the
#    same manifests work with whatever namespace policy you prefer).
kubectl create namespace starrupture

# 2. Render and apply the Secret with your server config.
#    secret.yaml is git-ignored — don't commit it.
cp k8s/secret.example.yaml k8s/secret.yaml
$EDITOR k8s/secret.yaml
kubectl -n starrupture apply -f k8s/secret.yaml

# 3. Apply the rest of the bundle (PVC, install Job, Deployment, CronJob).
kubectl -n starrupture apply -k k8s/

# 4. Watch the install Job finish before the Deployment becomes ready.
kubectl -n starrupture logs -f job/starrupture-install
kubectl -n starrupture get pods -w
```

The Deployment uses `hostNetwork: true`, so the game (7777/udp+tcp) and
Steam query (27015/udp) ports come straight off the node's IP. Make sure
those are open on any firewall in front of the node.

## First boot

Starrupture needs a one-time client-side world creation before the
server can autoload a save (see the main `README.md` "First boot"
section). The shortest k8s recipe:

```bash
# 1. Patch the Secret so the server starts a fresh world.
kubectl -n starrupture patch secret starrupture-config -p \
  '{"stringData":{"START_NEW_GAME":"true","LOAD_SAVED_GAME":"false"}}'
kubectl -n starrupture rollout restart deploy/starrupture-server

# 2. Connect with the Starrupture client, create + save the world,
#    then disconnect.

# 3. Flip back to "load saved" mode.
kubectl -n starrupture patch secret starrupture-config -p \
  '{"stringData":{"START_NEW_GAME":"false","LOAD_SAVED_GAME":"true"}}'
kubectl -n starrupture rollout restart deploy/starrupture-server
```

## Day 2

```bash
# Tail server logs
kubectl -n starrupture logs -f deploy/starrupture-server

# Trigger a manual update (re-runs the same install Job)
kubectl -n starrupture delete job starrupture-install --ignore-not-found
kubectl -n starrupture apply -f k8s/install-job.yaml

# Trigger a manual backup outside the daily schedule
kubectl -n starrupture create job --from=cronjob/starrupture-backup starrupture-backup-manual

# Drop into a shell on the running pod
kubectl -n starrupture exec -it deploy/starrupture-server -- bash
```

## Customising for multiple shards

Each shard needs its own PVC + Deployment + Job + ports + Secret.
Recommended layout: copy this bundle per shard, edit the resource
names, `hostPort` numbers, and `WINEPREFIX` env var (each shard wants
its own Wine prefix to avoid lock contention), then pin each
Deployment to a specific node via `nodeSelector: { starrupture: <name> }`.
See the commented `nodeSelector` block in [`deployment.yaml`](deployment.yaml).

## Teardown

```bash
kubectl -n starrupture delete -k k8s/
kubectl -n starrupture delete secret starrupture-config
kubectl delete namespace starrupture
```

The PVC will go away with the namespace — including your save data.
Run `star backup` (via the CronJob or `kubectl create job --from=...`)
first if you want to keep it.
