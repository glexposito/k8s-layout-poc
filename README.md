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

| Namespace         | Cluster | Purpose                                             |
| ----------------- | ------- | ---------------------------------------------------- |
| `consumer-dev`     | nonprod | Internal, safe to break, catches issues early         |
| `consumer-qa`      | nonprod | Internal, pre-promotion validation                    |
| `engagement-dev`   | nonprod | Internal, safe to break, catches issues early         |
| `engagement-qa`    | nonprod | Internal, pre-promotion validation                    |
| `core-dev`         | nonprod | Internal, safe to break, catches issues early         |
| `core-qa`          | nonprod | Internal, pre-promotion validation                    |
| `consumer-stg`     | prod    | Customer-facing canary gate for `consumer-prod`       |
| `consumer-prod`    | prod    | Customer-facing, full production traffic              |
| `engagement-stg`   | prod    | Customer-facing canary gate for `engagement-prod`     |
| `engagement-prod`  | prod    | Customer-facing, full production traffic              |
| `core-stg`         | prod    | Platform tooling canary gate for `core-prod`          |
| `core-prod`        | prod    | Platform tooling, full production (Argo CD goes here) |

Every namespace carries `environment`, `pillar`, `cost-center`, and
`managed-by` labels; the pillar-stage namespaces also carry a `stage` label
(`dev`/`qa`/`stg`/`prod`), so you can filter along either axis:

```bash
docker exec k3s-nonprod kubectl get ns -l pillar=consumer
docker exec k3s-prod kubectl get ns -l stage=prod
```

Every `<pillar>-<stage>` namespace also has its own `ResourceQuota`, a
`LimitRange`, and a default-deny-except-same-namespace `NetworkPolicy`, so
you can see namespace boundaries actually enforced, not just declared.
Quotas are graduated by stage: `dev` is smallest, `qa`/`stg` are mid-sized,
`prod` is largest — `core` follows the same pattern as `consumer` and
`engagement`, since it's a pillar too (platform tooling is still a tenant
with its own budget and access boundary, just not customer-facing).

`manifests/nonprod/10-example-app.yaml` deploys a trivial `hello-web` app
into `consumer-dev`, so there's something running to look at. Prod
intentionally has no hand-applied workload yet — once Argo CD lands there,
prod's apps should arrive via GitOps instead of `kubectl apply`.

## Namespace design rationale

Why `<pillar>-<stage>` specifically (not flat stages, not per-workload),
why `core` is a pillar too, and how this compares to the other namespace
strategies considered: see [docs/namespace-strategies.md](docs/namespace-strategies.md).

## Prerequisites

- Docker + Docker Compose

That's it — no `kubectl` needed on your host. Each k3s container ships its
own `kubectl`, already pointed at itself, so you explore via `docker exec`
instead of setting up a local kubeconfig.

## Usage

```bash
docker compose up -d   # starts both clusters, auto-applies manifests/nonprod and manifests/prod
```

Then explore (pick the container for the cluster you want: `k3s-nonprod` or
`k3s-prod`):

```bash
docker exec k3s-nonprod kubectl get ns --show-labels
docker exec k3s-prod kubectl get ns --show-labels
docker exec k3s-nonprod kubectl -n consumer-dev get pods -o wide
docker exec k3s-nonprod kubectl -n consumer-dev get resourcequota,limitrange
docker exec k3s-prod kubectl -n consumer-prod get resourcequota,limitrange
```

Tear down:

```bash
docker compose down            # keep volumes (cluster state persists)
docker compose down -v         # also wipe cluster state
```
