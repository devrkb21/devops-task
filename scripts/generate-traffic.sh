#!/usr/bin/env bash
#
# generate-traffic.sh - send steady traffic to the app, with an optional error spike,
# so the Grafana dashboards and alerts have something to show.
#
#   scripts/generate-traffic.sh [seconds] [base-url]
#
# If DEBUG_TOKEN is set (it is read from .env when present), roughly one request in
# five hits /debug/error (HTTP 500) and some hit /debug/slow, which makes the error-rate
# panel spike and, if kept up for 5 minutes, fires the AppHighErrorRate alert.

set -euo pipefail

readonly DURATION=${1:-300}
readonly BASE_URL=${2:-http://localhost:8080}

cd "$(dirname -- "$0")/.."
if [[ -z ${DEBUG_TOKEN:-} && -f .env ]]; then
  DEBUG_TOKEN=$(sed -n 's/^DEBUG_TOKEN=//p' .env | tail -n 1)
fi
token=${DEBUG_TOKEN:-}

if [[ -z $token ]]; then
  echo "DEBUG_TOKEN not set: sending normal traffic only (no error spike)."
fi

end=$((SECONDS + DURATION))
count=0
while ((SECONDS < end)); do
  count=$((count + 1))
  curl -s -o /dev/null "$BASE_URL/" || true
  curl -s -o /dev/null "$BASE_URL/not-a-real-page" || true
  if [[ -n $token ]]; then
    if ((count % 5 == 0)); then
      curl -s -o /dev/null -H "X-Debug-Token: $token" "$BASE_URL/debug/error" || true
    fi
    if ((count % 7 == 0)); then
      curl -s -o /dev/null -H "X-Debug-Token: $token" "$BASE_URL/debug/slow?ms=$((RANDOM % 900 + 100))" || true
    fi
  fi
  sleep 0.2
done
echo "Sent traffic for ${DURATION}s (${count} iterations)."
