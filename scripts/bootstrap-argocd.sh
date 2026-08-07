#!/usr/bin/env bash
# One-time bootstrap: installs Argo CD into the prod cluster's chaos-prod
# namespace via the official install manifest (same as any real Argo CD
# install, portable beyond this repo), then registers nonprod as a second
# managed cluster.
#
# This can't be pure auto-applied YAML like everything in manifests/ - both
# clusters generate independent, fresh credentials on every boot, so
# bridging nonprod's ServiceAccount token into prod's Argo CD means reading
# a live value and writing it elsewhere. Run this after `docker compose up
# -d`, once both clusters are healthy.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

step() { echo "==> $*"; }

step "Waiting for both clusters to be ready..."
docker exec k3s-nonprod kubectl wait --for=condition=ready node --all --timeout=120s
docker exec k3s-prod kubectl wait --for=condition=ready node --all --timeout=120s

step "Installing Argo CD into chaos-prod (official manifest, server-side apply)..."
docker exec k3s-prod kubectl apply -n chaos-prod --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
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

step "Applying root Application (app-of-apps)..."
docker exec -i k3s-prod kubectl apply -n chaos-prod -f - < "$REPO_ROOT/argocd/root-app.yaml"
echo "    Note: this will show as errored until argocd/root-app.yaml and"
echo "    argocd/clusters-appset.yaml have a real repoURL (currently a"
echo "    REPLACE_ME placeholder) pushed to a real remote."

step "Exposing Argo CD UI on the host..."
docker exec -d k3s-prod kubectl port-forward -n chaos-prod svc/argocd-server --address 0.0.0.0 9000:443

ARGOCD_PASS=$(docker exec k3s-prod kubectl -n chaos-prod get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
echo ""
echo "Argo CD:          https://localhost:9000  (admin / $ARGOCD_PASS)"
echo "Managed clusters: prod (in-cluster), nonprod (https://k3s-nonprod:6443)"
