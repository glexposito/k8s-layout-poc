# k8s-layout-poc

A tiny, throwaway PoC for showing people how we plan to lay out namespaces,
labels, and per-namespace guardrails in Kubernetes — before we wire up the
real GitOps flow. Anyone can clone this and spin up two local k3s clusters
to poke around.

## What this shows

Two independent single-node k3s clusters running as Docker containers:

- **nonprod** (`localhost:6444`)
- **prod** (`localhost:6445`)

Each cluster gets the same namespace layout (`manifests/<cluster>/`).
Those directories are bind-mounted into each container's
`/var/lib/rancher/k3s/server/manifests/custom` (a subdirectory, so k3s can
still write its own required manifests like `coredns.yaml`/`traefik.yaml`
alongside ours), and k3s auto-applies everything under `server/manifests`
recursively — `docker compose up -d` alone is enough to get a fully-seeded
cluster, no separate apply step needed.

| Namespace      | Cluster | Purpose                                                |
| -------------- | ------- | ------------------------------------------------------- |
| `marines-dev`  | nonprod | Internal, safe to break, catches issues early            |
| `marines-qa`   | nonprod | Internal, pre-promotion validation                       |
| `necrons-dev`  | nonprod | Internal, safe to break, catches issues early            |
| `necrons-qa`   | nonprod | Internal, pre-promotion validation                       |
| `chaos-dev`    | nonprod | Internal, safe to break, catches issues early            |
| `chaos-qa`     | nonprod | Internal, pre-promotion validation                       |
| `marines-stg`  | prod    | Customer-facing canary gate for `marines-prod`           |
| `marines-prod` | prod    | Customer-facing, full production traffic                 |
| `necrons-stg`  | prod    | Customer-facing canary gate for `necrons-prod`           |
| `necrons-prod` | prod    | Customer-facing, full production traffic                 |
| `chaos-stg`    | prod    | Platform tooling canary gate for `chaos-prod`            |
| `chaos-prod`   | prod    | Platform tooling, full production (Argo CD lives here)   |

Every namespace carries `environment`, `pillar`, `cost-center`, and
`managed-by` labels; the pillar-stage namespaces also carry a `stage` label
(`dev`/`qa`/`stg`/`prod`), so you can filter along either axis:

```bash
docker exec k3s-nonprod kubectl get ns -l pillar=marines
docker exec k3s-prod kubectl get ns -l stage=prod
```

Every `<pillar>-<stage>` namespace also has its own `ResourceQuota`, a
`LimitRange`, and a default-deny-except-same-namespace `NetworkPolicy`, so
you can see namespace boundaries actually enforced, not just declared.
Quotas are graduated by stage: `dev` is smallest, `qa`/`stg` are mid-sized,
`prod` is largest — `chaos` follows the same pattern as `marines` and
`necrons`, since it's a pillar too (platform tooling is still a tenant
with its own budget and access boundary, just not customer-facing).

## Namespace design rationale

Why `<pillar>-<stage>` specifically (not flat stages, not per-workload),
why `chaos` is a pillar too, and how this compares to the other namespace
strategies considered: see [docs/namespace-strategies.md](docs/namespace-strategies.md).

## Prerequisites

- Docker + Docker Compose

That's it — no `kubectl` needed on your host. Each k3s container ships its
own `kubectl`, already pointed at itself, so you explore via `docker exec`
instead of setting up a local kubeconfig.

## Usage

```bash
docker compose up -d   # starts both clusters, auto-applies manifests/nonprod and manifests/prod
./scripts/bootstrap-argocd.sh   # installs Argo CD into chaos-prod, registers nonprod as a managed cluster
```

`bootstrap-argocd.sh` is the one step that isn't auto-applied YAML like
everything else — installing Argo CD itself, and bridging a cross-cluster
credential from `nonprod` into `prod`, both require reading live values
generated at boot, not just dropping a static file in `manifests/`. See
[docs/namespace-strategies.md](docs/namespace-strategies.md) if you want
the full reasoning.

The `argocd/` directory holds the app-of-apps bootstrap:

- `root-app.yaml` — applied once by the script; everything else here is
  then picked up and synced automatically.
- `clusters-appset.yaml` — one `Application` per cluster, syncing
  `manifests/<cluster>/` (namespaces, quotas, RBAC, network policies) via
  GitOps instead of k3s's own auto-deploy mount.
- `intercessor-appset.yaml`, `immortal-appset.yaml`, `havoc-appset.yaml` —
  one `ApplicationSet` per pillar's example app (`marines`/`necrons`/`chaos`
  respectively), each deploying across that pillar's four stage namespaces
  on both clusters. One file per app, so adding/removing an app's rollout
  is a self-contained change.

All of these reference this repo by `repoURL` — replace the `REPLACE_ME`
placeholder in each file with this repo's real remote URL before they'll
actually sync (until then, the root `Application` shows as errored, which
is expected). For the full file-by-file breakdown and how the cross-cluster
credential bridging actually connects everything, see
[docs/argocd-setup.md](docs/argocd-setup.md).

Each app under `charts/` is a small, generic Helm chart (not tied to any
real app or company) — one `values.yaml` with shared defaults plus
`values-dev.yaml`/`values-qa.yaml`/`values-stg.yaml`/`values-prod.yaml`
overrides, matching this repo's four stages.

Then explore (pick the container for the cluster you want: `k3s-nonprod` or
`k3s-prod`):

```bash
docker exec k3s-nonprod kubectl get ns --show-labels
docker exec k3s-prod kubectl get ns --show-labels
docker exec k3s-nonprod kubectl -n marines-dev get pods -o wide
docker exec k3s-nonprod kubectl -n marines-dev get resourcequota,limitrange
docker exec k3s-prod kubectl -n marines-prod get resourcequota,limitrange
docker exec k3s-prod kubectl -n chaos-prod get pods                     # Argo CD components
docker exec k3s-prod kubectl -n chaos-prod get secrets -l argocd.argoproj.io/secret-type=cluster  # managed clusters
```

Tear down:

```bash
docker compose down            # keep volumes (cluster state persists)
docker compose down -v         # also wipe cluster state
```
