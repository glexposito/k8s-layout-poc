#!/usr/bin/env bash
# One-time bootstrap: installs Argo CD into the prod cluster's chaos-prod
# namespace via the official install manifest (same as any real Argo CD
# install, portable beyond this repo), then registers nonprod as a second
# managed cluster.
#
# This can't be pure auto-applied YAML like everything in manifests/ - both
# clusters generate independent, fresh credentials on every boot, so
# bridging nonprod's ServiceAccount token into prod's Argo CD means reading
# a live value and writing it elsewhere. It also has to patch prod's
# CoreDNS with nonprod's current docker-network IP (also not stable across
# restarts) so prod's Argo CD can even reach nonprod's API server by name.
# Run this after `docker compose up -d`, once both clusters are healthy.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

step() { echo "==> $*"; }

step "Waiting for both clusters to be ready..."
docker exec k3s-nonprod kubectl wait --for=condition=ready node --all --timeout=120s
docker exec k3s-prod kubectl wait --for=condition=ready node --all --timeout=120s

step "Teaching prod's CoreDNS how to resolve k3s-nonprod..."
# docker-compose's DNS (which resolves container names like "k3s-nonprod")
# only works from the k3s-prod container's own network namespace, not from
# inside a pod's separate network namespace - so prod's CoreDNS can't
# resolve nonprod's hostname on its own, even though the two containers
# share a docker network. This adds a k3s-supported CoreDNS customization
# (a `coredns-custom` ConfigMap) mapping the hostname to nonprod's current
# docker-network IP, discovered fresh here since it isn't guaranteed stable
# across restarts.
NONPROD_IP=$(docker inspect k3s-nonprod --format '{{(index .NetworkSettings.Networks "k8s-layout-poc_k8s-management").IPAddress}}')
docker exec -i k3s-prod kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  nonprod.override: |
    template IN A {
      match "^k3s-nonprod\."
      answer "{{ .Name }} 60 IN A $NONPROD_IP"
      fallthrough
    }
EOF
docker exec k3s-prod kubectl rollout restart deployment/coredns -n kube-system
docker exec k3s-prod kubectl rollout status deployment/coredns -n kube-system --timeout=60s

step "Installing Argo CD into chaos-prod (official manifest, namespace-relocated via kustomize)..."
# Plain `kubectl apply -n chaos-prod -f install.yaml` is NOT enough here:
# the official manifest hardcodes the "argocd" namespace inside its
# ClusterRoleBindings' subjects, which `-n` does not rewrite. That leaves
# argocd-application-controller with a binding for the wrong identity and
# no real permissions. kustomize's namespace transformer rewrites both
# object namespaces and RBAC subject references correctly.
docker exec k3s-prod mkdir -p /tmp/argocd-kustomize
docker exec -i k3s-prod sh -c 'cat > /tmp/argocd-kustomize/kustomization.yaml' \
  < "$REPO_ROOT/scripts/argocd-kustomize/kustomization.yaml"
docker exec k3s-prod kubectl apply -k /tmp/argocd-kustomize --server-side --force-conflicts
docker exec k3s-prod kubectl rollout status deployment/argocd-server -n chaos-prod --timeout=300s

step "Registering nonprod as a managed cluster..."
NONPROD_TOKEN=$(docker exec k3s-nonprod kubectl -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)

docker exec -i k3s-prod kubectl apply -n chaos-prod -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: nonprod-cluster
  namespace: chaos-prod
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: nonprod
  server: https://k3s-nonprod:6443
  config: |
    {
      "bearerToken": "$NONPROD_TOKEN",
      "tlsClientConfig": {
        "insecure": true
      }
    }
EOF

step "Restarting application-controller so it picks up the nonprod registration..."
# argocd-application-controller started (in the previous step) before the
# nonprod-cluster secret existed. Argo CD is supposed to notice new
# cluster secrets dynamically, but in testing this was unreliable -
# Applications targeting nonprod would sit with empty status forever,
# never even attempted, while prod-targeting ones (known since startup)
# worked fine. Restarting after registration forces a clean connection
# attempt with both clusters known from the start.
docker exec k3s-prod kubectl delete pod -n chaos-prod -l app.kubernetes.io/name=argocd-application-controller
docker exec k3s-prod kubectl rollout status statefulset/argocd-application-controller -n chaos-prod --timeout=120s

step "Applying root Application (app-of-apps)..."
docker exec -i k3s-prod kubectl apply -n chaos-prod -f - < "$REPO_ROOT/argocd/root-app.yaml"

step "Exposing Argo CD UI on the host..."
docker exec -d k3s-prod kubectl port-forward -n chaos-prod svc/argocd-server --address 0.0.0.0 9000:443

ARGOCD_PASS=$(docker exec k3s-prod kubectl -n chaos-prod get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
echo ""
echo "Argo CD:          https://localhost:9000  (admin / $ARGOCD_PASS)"
echo "Managed clusters: prod (in-cluster), nonprod (https://k3s-nonprod:6443)"
