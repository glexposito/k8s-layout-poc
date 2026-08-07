# Argo CD setup: what each file does and why

This documents the Argo CD / multi-cluster GitOps layer — one Argo CD
instance, running in `prod`, managing both `prod` and `nonprod`. It's a
reference for understanding the pieces and how they connect, not
instructions for running the PoC (see the main [README](../README.md) for
that).

## The goal

A single Argo CD instance in `prod`'s `chaos-prod` namespace watches this
repo and keeps both clusters in sync with it — replacing the k3s auto-apply
mechanism (`manifests/<cluster>/` bind-mounts) with real GitOps: git
history, rollback via `git revert`, drift detection, and one source of
truth managing two clusters instead of each cluster only knowing about
itself.

## Why prod, not nonprod

Argo CD isn't just another workload — it's the thing with deploy authority
over everything it manages, including `prod` itself. That flips the usual
"nonprod is safe to break" logic on its head:

- **Nonprod's whole purpose is "we accept it can break, no customer
  harm."** Argo CD breaking isn't a contained event like that — it's the
  control plane for the entire deployment pipeline. If it lived in
  nonprod, an intentionally lower-reliability environment would hold
  control over the customer-facing one. Prod's actual reliability would
  become hostage to nonprod's.
- **Argo CD holds broad, near-`cluster-admin`-equivalent power over what
  it manages** — see `argocd-manager`'s `ClusterRoleBinding` below.
  Wherever Argo CD runs is the highest-trust location in the whole setup,
  because compromising it means compromising everything downstream. That
  belongs in the environment with the strongest access control and change
  discipline already — `prod`/`stg` get "prod-grade rigor" in this repo's
  design, `dev`/`qa` don't.
- **Blast radius asymmetry.** A compromised or misconfigured nonprod
  workload is contained to nonprod. A compromised or misconfigured Argo CD
  instance can touch every cluster it's registered to manage — in a real
  org, potentially many, not just two. That severity demands the
  highest-trust home, by definition.

## How one Argo CD instance manages two clusters

Every Argo CD `Application` has a `destination.server` field. That can be
`https://kubernetes.default.svc` (the special value meaning "wherever I'm
running") **or any other cluster's real API address**, as long as Argo CD
has been given a credential for it — registered via a `Secret` in Argo
CD's own namespace, labeled `argocd.argoproj.io/secret-type: cluster`,
holding that server's URL plus a bearer token valid there.

Once registered, Argo CD's reconciliation loop (compare git's desired
state to the live cluster, apply the diff) runs identically against a
remote cluster as it does against itself — same code path, just talking
over the network instead of locally. In this repo, `prod`'s Argo CD has
two registered destinations: itself (`prod`) and `nonprod` (via the token
bridged in `bootstrap-argocd.sh`, see below) — so every
`Application`/`ApplicationSet` in `argocd/` picks one of those two, and
both get reconciled continuously from the same git history, from one
place.

## Why this needs a bootstrap script at all

Everything in `manifests/` is static YAML k3s auto-applies with zero
external dependencies. Argo CD's install and cross-cluster registration
can't work that way, for two separate reasons:

- **Installing Argo CD** is `kubectl apply -f <official install.yaml>` —
  an imperative command, not a resource k3s's manifest watcher can trigger
  on its own.
- **Registering `nonprod` as a managed cluster** requires a real, working
  bearer token. Both clusters generate independent, fresh self-signed
  credentials on every boot — a token can't be pre-written into a
  git-committed file, since it doesn't exist until the cluster is actually
  running. Something has to read a live value out of one cluster and write
  it into the other.

That "something" is `scripts/bootstrap-argocd.sh`, run once after
`docker compose up -d`.

## File by file

### `manifests/nonprod/20-argocd-manager.yaml`

Lives in `nonprod`, applied automatically by k3s like everything else in
that directory — no Argo CD or bootstrap script involved yet. Creates:

- **`ServiceAccount argocd-manager`** — the identity Argo CD will
  authenticate as.
- **`ClusterRoleBinding`** — grants that identity `cluster-admin` within
  `nonprod` (PoC simplicity; a real deployment would scope this down).
- **`Secret argocd-manager-token`** — because of its
  `kubernetes.io/service-account.name: argocd-manager` annotation,
  Kubernetes' token controller automatically populates this Secret's
  `.data.token` field with a real, working bearer token once the cluster
  is up.

This has to be applied to `nonprod` directly, the same simple way as
everything else there, and *before* Argo CD exists at all — it's the
prerequisite the bootstrap script depends on, not something Argo CD itself
could sync (that would be circular: Argo CD would need `nonprod` already
registered to sync a file into `nonprod` that creates the credential
needed to register `nonprod`).

### `scripts/bootstrap-argocd.sh`

Run once, after both clusters are up. In order:

1. Waits for both clusters to be ready.
2. Installs Argo CD into `chaos-prod` via the official install manifest
   (`kubectl apply --server-side --force-conflicts -f
   https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml`)
   — standard, portable Argo CD, not a k3s-specific shortcut.
3. Reads the real token from `20-argocd-manager.yaml`'s Secret in
   `nonprod`, and writes it into a new Secret in `prod`'s `chaos-prod`
   namespace, labeled `argocd.argoproj.io/secret-type: cluster` — the
   label Argo CD's controller watches for to recognize a registered
   cluster.
4. Applies `argocd/root-app.yaml` — the one manual `kubectl apply` needed
   to bootstrap the whole app-of-apps chain.
5. Starts a background port-forward so the Argo CD UI is reachable on the
   host at `localhost:9000`.

### `argocd/root-app.yaml`

The single `Application` applied manually by the script. Points at the
`argocd/` directory itself. Once this exists, Argo CD picks up and syncs
everything else in `argocd/` automatically — no further manual `kubectl
apply` needed.

### `argocd/clusters-appset.yaml`

One `Application` per cluster, syncing `manifests/nonprod/` and
`manifests/prod/` (namespaces, quotas, RBAC, network policies) via GitOps
instead of k3s's own auto-deploy mount. This is the governance layer.

### `argocd/intercessor-appset.yaml`, `immortal-appset.yaml`, `havoc-appset.yaml`

One `ApplicationSet` per pillar's example app (`marines`/`necrons`/`chaos`
respectively), each deploying across that pillar's four stage namespaces
on both clusters — `charts/intercessor`, `charts/immortal`, `charts/havoc`.
One file per app so adding or removing an app's rollout is a self-contained
change, rather than editing a shared file.

## How it all connects (the actual join key)

The mechanical link between `20-argocd-manager.yaml` and everything in
`argocd/` is a literal string match — the cluster's server URL,
`https://k3s-nonprod:6443` — plus the token that backs it:

```
20-argocd-manager.yaml (nonprod)
  → ServiceAccount + Secret, token auto-populated by Kubernetes
      │
      ▼
bootstrap-argocd.sh
  → reads that token
  → writes it into a Secret in chaos-prod:
      labels: {argocd.argoproj.io/secret-type: cluster}
      server: https://k3s-nonprod:6443
      config: {"bearerToken": "<the token>"}
      │
      ▼
argocd/clusters-appset.yaml, argocd/*-appset.yaml
  → generate Applications with destination.server: https://k3s-nonprod:6443
  → Argo CD matches that URL against the registered cluster Secret above
  → authenticates using its bearerToken
```

Remove `20-argocd-manager.yaml` and the chain breaks at the first link:
the bootstrap script would have no real token to read, the cluster Secret
it builds would be invalid, and every `Application` targeting `nonprod`
would fail to authenticate even though the URL still matches.

## Status

`argocd/root-app.yaml`, `argocd/clusters-appset.yaml`, and all three
`argocd/*-appset.yaml` files reference this repo's real remote
(`https://github.com/glexposito/k8s-layout-poc.git`) as `repoURL` — they
sync as-is once `scripts/bootstrap-argocd.sh` has run.
