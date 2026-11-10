#!/usr/bin/env bash
#
# watch-availability.sh - send requests continuously and count failures, to prove a
# rolling update or rollback causes no downtime.
#
#   scripts/k8s/watch-availability.sh <url> <seconds>
#
# Prints a line whenever the served version changes, and a summary at the end.
# Exits 1 if any request failed.

set -euo pipefail

readonly URL=${1:-http://devops-task.localhost:8081/}
readonly DURATION=${2:-60}

total=0
failed=0
last_version=""
end=$((SECONDS + DURATION))

while ((SECONDS < end)); do
  total=$((total + 1))
  if body=$(curl -fsS --max-time 2 "$URL" 2>/dev/null); then
    version=$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' <<<"$body")
    if [[ $version != "$last_version" ]]; then
      printf '%s  now serving version %s\n' "$(date +%T)" "${version:-unknown}"
      last_version=$version
    fi
  else
    failed=$((failed + 1))
    printf '%s  request %d FAILED\n' "$(date +%T)" "$total"
  fi
  sleep 0.1
done

printf 'requests: %d, failed: %d\n' "$total" "$failed"
((failed == 0))
