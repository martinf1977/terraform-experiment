#!/usr/bin/env bash
set -euo pipefail

WEB_TG_NAME="docker-web-tg"
YACHT_TG_NAME="docker-yacht-tg"
ASG_NAME="docker-asg"
CHECK_TIMEOUT_SECONDS="${CHECK_TIMEOUT_SECONDS:-420}"
CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-15}"
VERBOSE="${POST_APPLY_VERBOSE:-0}"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found in PATH." >&2
    exit 1
  fi
}

log() {
  printf '[post-check] %s\n' "$*"
}

usage() {
  cat <<'USAGE'
Usage: ./post_apply_check.sh [--verbose|-v]

Options:
  -v, --verbose   Print target health details during each polling cycle.
  -h, --help      Show this help.

Environment variables:
  POST_APPLY_VERBOSE=1     Enable verbose mode.
  CHECK_TIMEOUT_SECONDS    Max wait time for healthy targets (default: 420).
  CHECK_INTERVAL_SECONDS   Poll interval in seconds (default: 15).
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose)
        VERBOSE=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Error: unknown option '$1'" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

print_target_health_snapshot() {
  local tg_arn="$1"
  aws elbv2 describe-target-health \
    --target-group-arn "$tg_arn" \
    --query 'TargetHealthDescriptions[].{Id:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}' \
    --output table || true
}

get_target_group_arn() {
  local tg_name="$1"
  aws elbv2 describe-target-groups \
    --names "$tg_name" \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text
}

wait_for_healthy_targets() {
  local tg_name="$1"
  local tg_arn="$2"
  local deadline=$(( $(date +%s) + CHECK_TIMEOUT_SECONDS ))

  while true; do
    local healthy_count
    healthy_count=$(aws elbv2 describe-target-health \
      --target-group-arn "$tg_arn" \
      --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" \
      --output text)

    local registered_count
    registered_count=$(aws elbv2 describe-target-health \
      --target-group-arn "$tg_arn" \
      --query 'length(TargetHealthDescriptions)' \
      --output text)

    if [[ "$healthy_count" -ge 1 ]]; then
      log "Target group '$tg_name' has healthy target(s): $healthy_count/$registered_count"
      if [[ "$VERBOSE" == "1" ]]; then
        log "Verbose target-health snapshot for '$tg_name':"
        print_target_health_snapshot "$tg_arn"
      fi
      return 0
    fi

    if [[ "$VERBOSE" == "1" ]]; then
      log "Verbose target-health snapshot for '$tg_name' while waiting:"
      print_target_health_snapshot "$tg_arn"
    fi

    if (( $(date +%s) >= deadline )); then
      log "Target group '$tg_name' did not become healthy within ${CHECK_TIMEOUT_SECONDS}s"
      print_target_health_snapshot "$tg_arn"
      return 1
    fi

    log "Waiting for '$tg_name' healthy target(s)... current healthy: $healthy_count/$registered_count"
    sleep "$CHECK_INTERVAL_SECONDS"
  done
}

get_primary_asg_instance() {
  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId | [0]' \
    --output text
}

run_ssm_diagnostics() {
  local instance_id="$1"

  if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
    log "No InService instance found in ASG '$ASG_NAME'; skipping SSM diagnostics."
    return
  fi

  local ping
  ping=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$instance_id" --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)

  if [[ "$ping" != "Online" ]]; then
    log "Instance '$instance_id' is not SSM online (PingStatus='$ping'); skipping diagnostics."
    return
  fi

  log "Collecting SSM diagnostics from instance '$instance_id'"

  local cmd_id
  cmd_id=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --comment "post-apply diagnostics" \
    --parameters commands='sudo tail -n 120 /var/log/user-data.log; echo ====; sudo docker ps -a; echo ====; sudo systemctl status docker --no-pager -l | head -n 80' \
    --query 'Command.CommandId' \
    --output text)

  sleep 5

  aws ssm get-command-invocation \
    --command-id "$cmd_id" \
    --instance-id "$instance_id" \
    --query '{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
    --output json || true
}

check_endpoint() {
  local name="$1"
  local url="$2"

  if [[ -z "$url" ]]; then
    log "Endpoint URL for '$name' is empty."
    return 1
  fi

  local status
  status=$(curl -sS -o /dev/null -w '%{http_code}' "$url" || true)

  if [[ "$status" != "200" && "$status" != "301" && "$status" != "302" ]]; then
    log "Endpoint '$name' check failed for $url (HTTP $status)"
    return 1
  fi

  log "Endpoint '$name' is reachable at $url (HTTP $status)"
  return 0
}

main() {
  parse_args "$@"

  require_cmd tofu
  require_cmd aws
  require_cmd curl

  local web_url yacht_url
  web_url=$(tofu output -raw website_url 2>/dev/null || true)
  yacht_url=$(tofu output -raw yacht_url 2>/dev/null || true)

  local web_tg_arn yacht_tg_arn
  web_tg_arn=$(get_target_group_arn "$WEB_TG_NAME")
  yacht_tg_arn=$(get_target_group_arn "$YACHT_TG_NAME")

  local health_failed=0 endpoint_failed=0

  wait_for_healthy_targets "$WEB_TG_NAME" "$web_tg_arn" || health_failed=1
  wait_for_healthy_targets "$YACHT_TG_NAME" "$yacht_tg_arn" || health_failed=1

  check_endpoint "website" "$web_url" || endpoint_failed=1
  check_endpoint "yacht" "$yacht_url" || endpoint_failed=1

  if [[ "$health_failed" -ne 0 || "$endpoint_failed" -ne 0 ]]; then
    log "Health checks failed; pulling user-data and Docker diagnostics."
    run_ssm_diagnostics "$(get_primary_asg_instance)"
    exit 1
  fi

  log "All post-apply checks passed."
}

main "$@"
