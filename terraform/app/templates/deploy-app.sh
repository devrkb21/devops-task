#!/usr/bin/env bash
#
# deploy-app - deploy or roll back the application container on this host.
#
# Installed to /usr/local/bin/deploy-app by the EC2 user data and run by the CI pipeline
# through AWS Systems Manager (no SSH).
#
#   deploy-app deploy <image>   pull and start <image>, health-check it, and roll back
#                               to the previous image automatically if it is unhealthy
#   deploy-app rollback         start the previously deployed image again
#   deploy-app status           print the current and previous image
#
# Exit codes: 0 success, 1 deploy failed (rolled back), 2 deploy and rollback failed,
# 3 usage error.

set -euo pipefail

readonly CONTAINER=devops-task
readonly STATE_DIR=/var/lib/devops-task
readonly CONF=/etc/devops-task/deploy.conf
readonly APP_ENV_FILE=/etc/devops-task/app.env
readonly HEALTH_ATTEMPTS=30
readonly HEALTH_INTERVAL=2

# shellcheck source=/dev/null
source "$CONF"
: "${AWS_REGION:?missing in $CONF}" "${LOG_GROUP:?missing in $CONF}" "${APP_PORT:?missing in $CONF}"

log() {
  printf '%s deploy-app: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

current_image() {
  docker inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true
}

start_container() {
  local image=$1
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run --detach \
    --name "$CONTAINER" \
    --restart unless-stopped \
    --publish "${APP_PORT}:8080" \
    --env-file "$APP_ENV_FILE" \
    --read-only --tmpfs /tmp \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --memory 384m --cpus 1 \
    --stop-timeout 30 \
    --log-driver awslogs \
    --log-opt awslogs-region="$AWS_REGION" \
    --log-opt awslogs-group="$LOG_GROUP" \
    --log-opt tag='{{.Name}}/{{.ID}}' \
    --log-opt mode=non-blocking \
    --log-opt max-buffer-size=4m \
    "$image" >/dev/null
}

wait_healthy() {
  local attempt
  for ((attempt = 1; attempt <= HEALTH_ATTEMPTS; attempt++)); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${APP_PORT}/health" >/dev/null 2>&1; then
      log "health check passed (attempt $attempt)"
      return 0
    fi
    sleep "$HEALTH_INTERVAL"
  done
  log "health check failed after $((HEALTH_ATTEMPTS * HEALTH_INTERVAL))s"
  docker logs --tail 50 "$CONTAINER" 2>&1 || true
  return 1
}

deploy() {
  local image=$1 previous
  log "pulling $image"
  # A failed pull leaves the running container untouched.
  docker pull --quiet "$image" >/dev/null

  previous=$(current_image)
  log "previous image: ${previous:-<none>}"
  start_container "$image"

  if wait_healthy; then
    if [[ -n $previous && $previous != "$image" ]]; then
      printf '%s\n' "$previous" >"$STATE_DIR/previous_image"
    fi
    printf '%s\n' "$image" >"$STATE_DIR/current_image"
    docker image prune --force >/dev/null || true
    log "deployed $image"
    return 0
  fi

  if [[ -z $previous ]]; then
    log "no previous image to roll back to"
    return 2
  fi
  log "rolling back to $previous"
  start_container "$previous"
  if wait_healthy; then
    log "rollback to $previous succeeded"
    return 1
  fi
  log "rollback FAILED; manual intervention needed"
  return 2
}

rollback() {
  local previous running
  if [[ ! -s $STATE_DIR/previous_image ]]; then
    log "no previous image recorded"
    return 2
  fi
  previous=$(<"$STATE_DIR/previous_image")
  running=$(current_image)
  log "rolling back from ${running:-<none>} to $previous"
  start_container "$previous"
  if wait_healthy; then
    # Swap the records, so running rollback again returns to where we started.
    printf '%s\n' "$previous" >"$STATE_DIR/current_image"
    if [[ -n $running ]]; then
      printf '%s\n' "$running" >"$STATE_DIR/previous_image"
    fi
    log "rollback succeeded"
    return 0
  fi
  return 2
}

usage() {
  printf 'Usage: %s deploy <image> | rollback | status\n' "${0##*/}" >&2
  exit 3
}

main() {
  mkdir -p "$STATE_DIR"
  case ${1:-} in
    deploy)
      [[ $# -eq 2 ]] || usage
      deploy "$2"
      ;;
    rollback)
      rollback
      ;;
    status)
      printf 'running:  %s\n' "$(current_image)"
      printf 'previous: %s\n' "$(cat "$STATE_DIR/previous_image" 2>/dev/null || echo '<none>')"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
