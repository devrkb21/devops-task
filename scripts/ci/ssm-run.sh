#!/usr/bin/env bash
#
# ssm-run.sh - run a shell command on an EC2 instance through AWS Systems Manager
# Run Command, wait for it to finish, print its output and exit with its status.
#
# Usage: ssm-run.sh <instance-id> <command...>
#
# Used by the deploy workflow so no SSH key or open port 22 is needed.

set -euo pipefail

readonly TIMEOUT_SECONDS=${SSM_TIMEOUT_SECONDS:-600}
readonly POLL_SECONDS=5

if (($# < 2)); then
  printf 'Usage: %s <instance-id> <command...>\n' "${0##*/}" >&2
  exit 2
fi

instance_id=$1
shift
command=$*

parameters=$(jq -n --arg cmd "$command" --arg timeout "$TIMEOUT_SECONDS" \
  '{commands: [$cmd], executionTimeout: [$timeout]}')

command_id=$(aws ssm send-command \
  --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript \
  --comment "devops-task: ${command:0:80}" \
  --parameters "$parameters" \
  --query 'Command.CommandId' \
  --output text)
printf 'SSM command %s sent to %s: %s\n' "$command_id" "$instance_id" "$command"

deadline=$((SECONDS + TIMEOUT_SECONDS + 60))
status=Pending
while ((SECONDS < deadline)); do
  sleep "$POLL_SECONDS"
  # The invocation may not exist for the first few seconds; treat that as pending.
  status=$(aws ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --query 'Status' \
    --output text 2>/dev/null || printf 'Pending')
  case $status in
    Pending | InProgress | Delayed) continue ;;
    *) break ;;
  esac
done

printf '\n----- output from %s -----\n' "$instance_id"
aws ssm get-command-invocation \
  --command-id "$command_id" \
  --instance-id "$instance_id" \
  --query '[StandardOutputContent, StandardErrorContent]' \
  --output text || true
printf -- '----- status: %s -----\n' "$status"

[[ $status == Success ]]
