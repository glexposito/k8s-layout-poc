# Namespace strategy options

This documents the namespace granularity spectrum considered for this repo
— what each option looks like, when it fits, and why we landed where we
did. It's a reference for revisiting the decision later, not instructions
for running the PoC (see the main [README](../README.md) for that).

## Why namespaces exist at all

Every option below is a different answer to the same question: where do you
draw the boundary? It's worth being explicit that **quota and RBAC are the
main reason to draw one at all** — this isn't specific to this repo, it's
what the Kubernetes project itself says namespaces are for:

> Namespaces are intended for use in environments with many users spread
> across multiple teams, or projects... Namespaces are a way to divide
> cluster resources between multiple users (via resource quota).
> — [kubernetes.io, Resource Quotas](https://www.kubernetes.io/docs/concepts/policy/resource-quotas/)

Everything else a namespace happens to give you — DNS scoping, network
policy boundaries, per-namespace admission policy, delete-to-clean-up
lifecycle — rides along on top of whatever boundary you drew for quota/RBAC
reasons. It isn't usually the reason to create the split in the first
place: if you didn't need independent quotas or independent access control
between two things, there'd be little pull to put them in separate
namespaces at all — labels would do. That's the lens every strategy below
should be read through: which axis (environment, pillar, workload) is the
one that actually needs its *own* budget and its *own* access boundary.

Further reading, all consistent with this framing:

- [Namespaces (official Kubernetes docs)](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)
- [Using RBAC Authorization (official Kubernetes docs)](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Kubernetes Namespaces: Security Best Practices (Wiz)](https://www.wiz.io/academy/container-security/kubernetes-namespaces)
- [Kubernetes Multi-Tenancy: Namespace Isolation, RBAC, and Network Policies (DEV Community)](https://dev.to/zop_8abedcc7e12/kubernetes-multi-tenancy-namespace-isolation-rbac-and-network-policies-explained-3jjm)

## The spectrum

| Strategy                        | Example                             | What lives inside                                  | When it fits                                                          | Trade-off                                                                  |
| -------------------------------- | ------------------------------------ | ---------------------------------------------------- | ------------------------------------------------------------------------ | ----------------------------------------------------------------------------- |
| Per environment                  | `dev`, `stg`, `prod`                 | Every workload from every team, grouped by stage only | Small clusters, one team, environment is the only boundary that matters  | No per-team RBAC/quota isolation — one noisy tenant affects everyone          |
| **Pillar/team + environment**    | `consumer-stg`, `core-prod`          | Everything a pillar owns, for one specific stage      | You want team ownership *and* environment risk tier as the boundary       | More namespaces to manage (pillars × stages); still coarse if a pillar owns many independent apps |
| Workload/application + environment | `audience-builder-stg`, `audience-builder-prod` | One app's full stack, for one specific stage           | Strong workload isolation *and* environment separation, at any team-ownership shape | Namespace count grows fast (apps × stages); needs a separate ownership/RBAC mechanism if teams own multiple apps |

## 1. Environment-only

Namespaces are just stages — no pillar/team boundary at all:

```
nonprod cluster
├── dev
└── qa

prod cluster
├── stg
└── prod
```

Applications then live in the *resource names*, not the namespace name:

```
stg
├── audience-builder-api
├── merchant-api
├── status-page
└── activities-api
```

...and pillar ownership moves into labels instead of the namespace boundary:

```yaml
metadata:
  labels:
    app.kubernetes.io/name: status-page
    pillar: core
```

This is the simplest model, but it's also the one that loses the property
we specifically needed: `ResourceQuota` and `RoleBinding` can't target "all
resources labeled `pillar: core`" — they attach to a namespace. With
everything sharing `stg`, there's no independent budget or access boundary
per pillar; one noisy tenant can still starve the others.

## 2. Pillar + environment (what this repo uses)

```
nonprod cluster
├── consumer-dev
├── consumer-qa
├── engagement-dev
├── engagement-qa
├── core-dev
└── core-qa

prod cluster
├── consumer-stg
├── consumer-prod
├── engagement-stg
├── engagement-prod
├── core-stg
└── core-prod
```

Each namespace holds everything that pillar owns for that one stage —
Deployments, Services, ConfigMaps, Secrets — plus its own
`ResourceQuota`/`LimitRange`/`NetworkPolicy`, exactly what's in
`manifests/nonprod/` and `manifests/prod/` today.

This was chosen because the two things that actually *require* a namespace
boundary in Kubernetes — `ResourceQuota` and `RoleBinding` — are both
namespace-scoped objects with no cross-namespace label equivalent. The two
axes that map to real organizational needs here are:

- **Pillar** — who owns it, what their budget/access is (`consumer`,
  `engagement`, `core` are each accountable units).
- **Stage** — blast radius / customer risk. `dev`/`qa` are internal and
  safe to break; `stg`/`prod` are both customer-facing in this org (see the
  main README's "Namespace design rationale" for the full reasoning on why
  `stg` gets prod-grade treatment here).

Multiple independent best-practice sources describe "namespace per
team/pillar per environment" as the recommended production pattern, so this
isn't a one-off choice specific to this repo:

- [Cluster isolation best practices for AKS (official Microsoft Learn docs)](https://learn.microsoft.com/en-us/azure/aks/operator-best-practices-cluster-isolation)
- [Use Namespaces to separate tenant workloads (official AWS EKS Best Practices whitepaper)](https://docs.aws.amazon.com/whitepapers/latest/security-practices-multi-tenant-saas-applications-eks/use-namespaces-to-separate-tenant-workloads.html)
- [Kubernetes Namespace Best Practices (K8s Recipes)](https://kubernetes.recipes/recipes/configuration/kubernetes-namespace-best-practices/)
- [Best Practices for Kubernetes Namespaces (Aptakube)](https://aptakube.com/blog/namespaces-best-practices)
- [Kubernetes Namespace Management for Secure, Scalable Clusters (Atmosly)](https://atmosly.com/blog/kubernetes-namespace-management-best-practices-2025)
- [Best Practices for Kubernetes Namespace Naming Conventions (Cloudfleet)](https://medium.com/@cloudfleet/best-practices-for-kubernetes-namespace-naming-conventions-c1be237e6bd5)

## 3. Workload + environment (the next escalation, not used here yet)

Important distinction: **"per workload" does not mean one namespace per
Deployment.** A workload/application namespace still holds everything that
one app needs — it's just scoped to one app instead of one whole pillar:

```
audience-builder-stg
├── Deployment: api
├── Deployment: worker
├── Deployment: scheduler
├── Deployment: monitoring
├── Service: api
├── ConfigMaps
├── Secrets
└── NetworkPolicies
```

Compare that to how the same app would sit under this repo's current model
— bundled into its pillar's single namespace alongside every other app that
pillar owns:

```
consumer-stg
├── audience-builder  (Deployment: api, worker, scheduler, monitoring; Service: api)
├── status-page       (Deployment: web; Service: web)
└── ...whatever else the consumer pillar owns, all sharing one quota
```

The workload-level split gives `audience-builder` and `status-page`
independent quotas, secrets scopes, and lifecycles from each other, even
though both belong to `consumer`. The cost: namespace count grows to
(pillars × apps × stages) instead of (pillars × stages).

### When to escalate to per-workload

Add a workload axis (`<pillar>-<workload>-<stage>`, e.g.
`consumer-checkout-stg`) once a single pillar owns multiple apps that need
independent blast radius from *each other* — not just from other pillars.
Signs it's time:

- One app's bug/quota exhaustion could take down a sibling app owned by the
  same pillar.
- Different apps under one pillar need different secrets scopes (a CI
  pipeline should be able to touch one app's secrets, not the whole
  pillar's).
- Apps under one pillar have independent release cadences and you want to
  delete/rebuild one without touching siblings.

Don't do this preemptively — this repo currently has one example workload
per pillar (`consumer-dev/hello-web`), so pillar-level and workload-level
namespacing look identical today. It's only worth the added namespace count
once a pillar's actual footprint needs the extra isolation.

## Pool vs. silo: why this repo uses both

AWS's EKS multi-tenancy whitepaper names two opposite ends of an isolation
spectrum:

- **Silo model** — each tenant gets fully dedicated infrastructure (its own
  cluster). Strongest isolation; highest cost and operational overhead per
  tenant.
- **Pool model** — tenants share one cluster's infrastructure, isolated
  from each other logically, via namespaces, RBAC, `ResourceQuota`, and
  `NetworkPolicy` — what AWS calls "soft multi-tenancy."

This repo doesn't pick one — it applies **silo at the environment axis** and
**pool at the pillar axis**, on top of each other:

```
silo boundary (fully separate clusters/control planes)
├── nonprod cluster
│    └── pool boundary (shared cluster, isolated by namespace)
│         ├── consumer-dev
│         ├── engagement-dev
│         └── core-dev
└── prod cluster
     └── pool boundary (shared cluster, isolated by namespace)
          ├── consumer-prod
          ├── engagement-prod
          └── core-prod
```

- **Silo, for environment risk.** `nonprod` and `prod` are two entirely
  separate k3s clusters — not namespaces in one cluster. A bad node, a
  runaway workload, or a control-plane issue in `nonprod` has no path to
  reach `prod`. This is the highest-cost isolation tool, so it's reserved
  for the boundary with the highest stakes: internal/safe-to-break vs.
  customer-facing.
- **Pool, for pillar ownership.** Within one cluster, `consumer`,
  `engagement`, and `core` share the same nodes and control plane, kept
  apart logically — namespace + `ResourceQuota` + `NetworkPolicy` per
  pillar, exactly the pattern in `manifests/*/01-policies.yaml`. Cheaper
  than a cluster per pillar, and sufficient because one pillar's bug
  starving another pillar's quota is a lower-stakes failure than nonprod
  code reaching prod traffic.

Why not silo everything (a cluster per pillar per stage)? Cost and
operational overhead scale with cluster count, not namespace count — 3
pillars × 4 stages would mean 12 clusters to patch, upgrade, and monitor
instead of 2. Why not pool everything (one cluster, namespaces for both
pillar and stage)? Because environment risk is a categorically different,
higher-stakes failure mode than inter-pillar noisy-neighbor — it justifies
paying for the stronger guarantee, while pillar separation doesn't need to.

- [Use Namespaces to separate tenant workloads (official AWS EKS Best Practices whitepaper)](https://docs.aws.amazon.com/whitepapers/latest/security-practices-multi-tenant-saas-applications-eks/use-namespaces-to-separate-tenant-workloads.html)
