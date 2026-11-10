#!/usr/bin/env bash
#
# setup-local-cluster.sh - create a local k3d cluster and deploy the app with kustomize.
#
# Requires: docker, k3d (https://k3d.io), kubectl. Safe to re-run.
#
#   scripts/k8s/setup-local-cluster.sh            # cluster + image 1.0.0 + deploy
#   CLUSTER=demo HOST_PORT=9090 scripts/k8s/setup-local-cluster.sh

set -euo pipefail

readonly CLUSTER=${CLUSTER:-devops-task}
readonly HOST_PORT=${HOST_PORT:-8081}
readonly VERSION=${VERSION:-1.0.0}
readonly NAMESPACE=devops-task
readonly OVERLAY=k8s/overlays/local

cd "$(dirname -- "$0")/../.."

for cmd in docker k3d kubectl curl; do
  command -v "$cmd" >/dev/null 2>&1 || {
    printf 'error: %s is required\n' "$cmd" >&2
    exit 1
  }
done

if k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
  echo "==> k3d cluster '$CLUSTER' already exists"
else
  echo "==> Creating k3d cluster '$CLUSTER' (ingress on localhost:$HOST_PORT)"
  # k3s includes Traefik (ingress) and metrics-server (needed by the HPA).
  k3d cluster create "$CLUSTER" --agents 1 --port "${HOST_PORT}:80@loadbalancer" --wait
fi
kubectl config use-context "k3d-$CLUSTER" >/dev/null

echo "==> Building image devops-task:$VERSION"
docker build --build-arg APP_VERSION="$VERSION" -t "devops-task:$VERSION" .

echo "==> Importing the image into the cluster (no registry needed)"
k3d image import "devops-task:$VERSION" --cluster "$CLUSTER"

if [[ ! -f $OVERLAY/secret.env ]]; then
  echo "==> Creating $OVERLAY/secret.env with a random DEBUG_TOKEN (git-ignored)"
  printf 'DEBUG_TOKEN=%s\n' "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" >"$OVERLAY/secret.env"
fi

echo "==> Applying manifests"
kubectl apply -k "$OVERLAY"
kubectl -n "$NAMESPACE" rollout status deployment/devops-task --timeout=180s

echo "==> Resources"
kubectl -n "$NAMESPACE" get deployment,pods,svc,ingress,hpa,pdb -o wide

echo "==> Calling the app through the ingress"
for _ in $(seq 1 30); do
  if curl -fsS "http://devops-task.localhost:${HOST_PORT}/"; then
    echo
    exit 0
  fi
  sleep 2
done
echo "Ingress not answering yet. Alternative: kubectl -n $NAMESPACE port-forward svc/devops-task 8082:80" >&2
exit 1
