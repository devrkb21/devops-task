#!/usr/bin/env bash
#
# rolling-update-demo.sh - demonstrate a zero-downtime rolling update to a new image
# version, then a rollback with `kubectl rollout undo`, while traffic is flowing.
#
# Run scripts/k8s/setup-local-cluster.sh first. Paste the output into the README.

set -euo pipefail

readonly CLUSTER=${CLUSTER:-devops-task}
readonly HOST_PORT=${HOST_PORT:-8081}
readonly NEW_VERSION=${NEW_VERSION:-1.0.1}
readonly NAMESPACE=devops-task
readonly URL="http://devops-task.localhost:${HOST_PORT}/"

cd "$(dirname -- "$0")/../.."
kubectl config use-context "k3d-$CLUSTER" >/dev/null

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "Current state"
kubectl -n "$NAMESPACE" get deployment devops-task -o wide
curl -fsS "$URL"
echo

step "Building and importing devops-task:$NEW_VERSION"
docker build --quiet --build-arg APP_VERSION="$NEW_VERSION" -t "devops-task:$NEW_VERSION" .
k3d image import "devops-task:$NEW_VERSION" --cluster "$CLUSTER"

step "Rolling update to $NEW_VERSION while sending requests for 45s"
scripts/k8s/watch-availability.sh "$URL" 45 &
watcher=$!
sleep 3
kubectl -n "$NAMESPACE" set image deployment/devops-task app="devops-task:$NEW_VERSION"
kubectl -n "$NAMESPACE" annotate deployment/devops-task --overwrite \
  kubernetes.io/change-cause="update image to devops-task:$NEW_VERSION"
kubectl -n "$NAMESPACE" rollout status deployment/devops-task --timeout=180s
wait "$watcher"

step "Rollout history"
kubectl -n "$NAMESPACE" rollout history deployment/devops-task

step "Rollback with kubectl rollout undo while sending requests for 45s"
scripts/k8s/watch-availability.sh "$URL" 45 &
watcher=$!
sleep 3
kubectl -n "$NAMESPACE" rollout undo deployment/devops-task
kubectl -n "$NAMESPACE" rollout status deployment/devops-task --timeout=180s
wait "$watcher"

step "Final state"
kubectl -n "$NAMESPACE" rollout history deployment/devops-task
kubectl -n "$NAMESPACE" get pods -o wide
curl -fsS "$URL"
echo
