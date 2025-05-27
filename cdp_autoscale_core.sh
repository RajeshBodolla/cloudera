#!/bin/bash

################################################################################
# CDP AutoScale Core Script - cdp_autoscale_core.sh
# Executes scale-up or scale-down actions based on static host list or Terraform output
# Supports dry-run and plan modes; supports SSH password or private key authentication
################################################################################

set -euo pipefail

# Track start time
SCRIPT_START_TIME=$(date +%s)

# Load config
CONFIG_FILE="/Users/rajeshreddy/auto-scale/cdp_autoscale.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[ERROR] Config file $CONFIG_FILE not found."
  exit 1
fi
source "$CONFIG_FILE"

# Input parameters
ACTION="$1"            # scaleup or scaledown
#SCALE_COUNT="$2"       # number of nodes (optional for dry run)
AUTH_MODE="${2:-password}"  # password or key
MODE="${3:-run}"
RESUME="${4:-false}"        # run, dry-run, or plan
HOST_FILE="/Users/rajeshreddy/auto-scale/host_list.txt"
STATE_FILE="/Users/rajeshreddy/auto-scale/autoscale.state"
LOG_FILE="/Users/rajeshreddy/auto-scale/cdp.log"
mkdir -p $(dirname "$LOG_FILE")

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $*" | tee -a "$LOG_FILE"
}

log_step_duration() {
  local step="$1"
  local start="$2"
  local end=$(date +%s)
  local duration=$((end - start))
  local minutes=$((duration / 60))
  local seconds=$((duration % 60))
  log "[INFO] Step [$step] took ${minutes} minutes and ${seconds} seconds."
}

fail_exit() {
  log "[ERROR] $1"
  echo "$STEP" > "$STATE_FILE"
  exit 1
}

cm_api_call() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  # Determine API version prefix based on endpoint
  local versioned_endpoint

  case "$endpoint" in
    /cm/*) versioned_endpoint="/api/v31${endpoint}" ;;
    /hosts/*|/commands/*) versioned_endpoint="/api/v56${endpoint}" ;;  # <-- Fix here
    /clusters/*) versioned_endpoint="/api/v56${endpoint}" ;;
    *) versioned_endpoint="/api/v41${endpoint}" ;;
  esac


  local url="$CM_PROTOCOL://$CM_HOST:$CM_PORT$versioned_endpoint"

  if [[ "$MODE" == "dry-run" || "$MODE" == "plan" ]]; then
    log "[DRY-RUN] $method $url"
    if [[ -n "$data" ]]; then
      echo "$data" | jq .
    fi
    return 0
  fi

  if [[ "$method" == "GET" ]]; then
    curl -s -u "$CM_USER:$CM_PASS" -X GET "$url"
  else
    curl -s -u "$CM_USER:$CM_PASS" -H 'Content-Type: application/json' -X "$method" -d "$data" "$url"
  fi
}

check_command_status() {
  [[ "$MODE" == "dry-run" || "$MODE" == "plan" ]] && return 0
  local cmd_id=$1
  local result
  for i in {1..30}; do
    result=$(cm_api_call GET "/commands/$cmd_id")
    success=$(echo "$result" | jq -r '.success')
    message=$(echo "$result" | jq -r '.resultMessage')
    if [[ "$success" == "true" ]]; then
      log "[SUCCESS] Command $cmd_id: $message"
      return 0
    elif [[ "$success" == "false" ]]; then
      fail_exit "Command $cmd_id failed: $message"
    fi
    sleep 10
  done
  fail_exit "Command $cmd_id timed out."
}

read_hosts_from_file() {
  if [[ ! -f "$HOST_FILE" ]]; then
    fail_exit "Host file $HOST_FILE not found."
  fi
  HOSTS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    HOSTS+=("$line")
  done < "$HOST_FILE"
}

wait_for_parcel_activation() {
  STEP="wait_for_parcels"
  local timeout=60  # Max retries
  local wait_time=10
  local attempt=1
  log "[INFO] Waiting for parcel activation on all new hosts..."

  while (( attempt <= timeout )); do
    parcels=$(cm_api_call GET "/clusters/$CLUSTER_NAME/parcels")
    activated_count=$(echo "$parcels" | jq '[.items[] | select(.stage == "ACTIVATED")] | length')
    total_count=$(echo "$parcels" | jq '[.items[]] | length')

    if [[ "$activated_count" -eq 1 && "$total_count" -gt 0 ]]; then
      log "[INFO] All parcels are activated. Proceeding."
      STEP=""
      return
    fi

    log "[INFO] Parcel activation in progress. [$activated_count/$total_count activated]. Attempt $attempt of $timeout..."
    ((attempt++))
    sleep "$wait_time"
  done

  fail_exit "Parcel activation timeout after $((timeout * wait_time)) seconds"
}

scale_up() {
  read_hosts_from_file
  [[ "$MODE" == "plan" ]] && return 0

  STEP_START=$(date +%s)

  if [[ -z "$STEP" || "$STEP" == "install_hosts" ]]; then
    STEP="install_hosts"
    install_payload=$(jq -n \
      --argjson hosts "$(printf '%s\n' "${HOSTS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
      --arg sshPort "$SSH_PORT" \
      --arg userName "$SSH_USER" \
      --arg password "${SSH_PASS:-}" \
      --arg privateKey "${SSH_KEY:-}" \
      --arg passphrase "${SSH_KEY_PASSPHRASE:-}" \
      --arg cmRepoUrl "${CM_REPO_URL:-}" '
      def base: {
        hostNames: $hosts,
        sshPort: ($sshPort|tonumber),
        userName: $userName,
        cmRepoUrl: $cmRepoUrl
      };
      if $password != "" then
        base + {password: $password}
      else
        base + {privateKey: $privateKey, passphrase: $passphrase}
      end')

    response=$(cm_api_call POST "/cm/commands/hostInstall" "$install_payload")
    cmd_id=$(echo "$response" | jq -r '.id')
    check_command_status "$cmd_id"
    STEP=""
  fi

  log_step_duration "install_hosts" "$STEP_START"

  STEP_START=$(date +%s)

  if [[ -z "$STEP" || "$STEP" == "register_in_cluster" ]]; then
    STEP="register_in_cluster"
    all_hosts_response=$(cm_api_call GET "/hosts")
    host_map=$(echo "$all_hosts_response" | jq --argjson hosts "$(printf '%s\n' "${HOSTS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')" '
      [ .items[] | {hostId, hostname} ] | map(select(.hostname as $h | $hosts | index($h)))')
    payload=$(jq -n --argjson items "$host_map" '{items: $items}')
    cm_api_call POST "/clusters/$CLUSTER_NAME/hosts" "$payload"
    STEP=""
  fi

  log_step_duration "register_in_cluster" "$STEP_START"

  STEP_START=$(date +%s)

  if [[ -z "$STEP" || "$STEP" == "verify_commission" ]]; then
    STEP="verify_commission"
    cluster_hosts=$(cm_api_call GET "/clusters/$CLUSTER_NAME/hosts")
    not_commissioned=$(echo "$cluster_hosts" | jq -r --argjson host_list "$(printf '%s\n' "${HOSTS[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')" '
      .items[] | select(.hostname as $h | ($host_list | index($h)) and .commissionState != "COMMISSIONED") | .hostname')
    if [[ -n "$not_commissioned" ]]; then
      fail_exit "Some hosts not commissioned: $not_commissioned"
    fi
    STEP=""
  fi

  log_step_duration "verify_commission" "$STEP_START"

  STEP_START=$(date +%s)

  if [[ -z "$STEP" || "$STEP" == "wait_for_parcels" ]]; then
    wait_for_parcel_activation
  fi

  log_step_duration "wait_for_parcel_activation" "$STEP_START"

  STEP_START=$(date +%s)

  if [[ -z "$STEP" || "$STEP" == "apply_host_template" ]]; then
    STEP="apply_host_template"
    host_names_json=$(printf '%s\n' "${HOSTS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
    apply_response=$(cm_api_call POST "/clusters/$CLUSTER_NAME/hostTemplates/$HOST_TEMPLATE/commands/applyHostTemplate?runConfigRules=false&startRoles=true" "{\"items\": $host_names_json}")
    cmd_id=$(echo "$apply_response" | jq -r '.id')
    check_command_status "$cmd_id"
    STEP=""
  fi

  log_step_duration "apply_host_template" "$STEP_START"

  STEP_START=$(date +%s)

  if [[ -z "$STEP" || "$STEP" == "verify_tags" ]]; then
    STEP="verify_tags"
    cluster_hosts=$(cm_api_call GET "/clusters/$CLUSTER_NAME/hosts")
    tag_mismatch=$(echo "$cluster_hosts" | jq -r --argjson host_list "$(printf '%s\n' "${HOSTS[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')" --arg template "$HOST_TAG" '
      .items[] | select(.hostname as $h | ($host_list | index($h))) | 
      select((.tags[]? | select(.name == "_cldr_cm_host_template_name").value != $template)) | .hostname')
    if [[ -n "$tag_mismatch" ]]; then
      fail_exit "Some hosts missing correct tag: $tag_mismatch"
    fi
    STEP=""
  fi

  log_step_duration "verify_tags" "$STEP_START"

  STEP_START=$(date +%s)

  if [[ -z "$STEP" || "$STEP" == "apply_stale_configs" ]]; then
    STEP="apply_stale_configs"
    host_names_json=$(printf '%s\n' "${HOSTS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
    apply_response=$(cm_api_call POST "/clusters/$CLUSTER_NAME/commands/deployClientConfigsAndRefresh")
    cmd_id=$(echo "$apply_response" | jq -r '.id')
    check_command_status "$cmd_id"
    STEP=""
  fi

  log "[INFO] Scale up completed successfully."
  echo "done" > "$STATE_FILE"

  # Log script duration

  log_step_duration "apply_stale_configs" "$STEP_START"


}



# ------------------------ SCALE DOWN ----------------------
  
scale_down() {

  STEP_START=$(date +%s)
  read_hosts_from_file
  [[ "$MODE" == "plan" ]] && return 0

  if [[ -z "$STEP" || "$STEP" == "remove_hosts" ]]; then
    STEP="remove_hosts"
    echo "$STEP" > "$STATE_FILE"

    payload=$(printf '%s\n' "${HOSTS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0)) | {hostsToRemove: ., deleteHosts: true}')
    response=$(cm_api_call POST "/hosts/removeHostsFromCluster" "$payload")
    if [[ -z "$response" ]]; then
      fail_exit "Empty response received from removeHostsFromCluster API."
    fi

    cmd_id=$(echo "$response" | jq -r '.id') 
    if [[ -z "$cmd_id" || "$cmd_id" == "null" ]]; then
      fail_exit "Failed to retrieve command ID from API response: $response"
    fi
  
    check_command_status "$cmd_id"
    STEP=""
  fi

  if [[ -z "$STEP" || "$STEP" == "apply_stale_configs" ]]; then
    STEP="apply_stale_configs"
    host_names_json=$(printf '%s\n' "${HOSTS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
    apply_response=$(cm_api_call POST "/clusters/$CLUSTER_NAME/commands/deployClientConfigsAndRefresh")
    cmd_id=$(echo "$apply_response" | jq -r '.id')
    check_command_status "$cmd_id"
    STEP=""
  fi

  log "[INFO] Scale down completed."
  echo "done" > "$STATE_FILE"

  # Log script duration
  log_step_duration "remove_hosts" "$STEP_START"

} 
  

main() {
  if [[ "$RESUME" == "true" && -f "$STATE_FILE" ]]; then
    STEP=$(cat "$STATE_FILE")
    log "[INFO] Resuming from step: $STEP"
  else
    STEP=""
  fi
  log "[INFO] Mode: $MODE | Action: $ACTION | Auth Mode: $AUTH_MODE"
  if [[ "$MODE" == "plan" ]]; then
    log "[PLAN] The following hosts will be processed:"
    cat "$HOST_FILE"
  fi

  if [[ "$ACTION" == "scaleup" ]]; then
    scale_up
  elif [[ "$ACTION" == "scaledown" ]]; then
    scale_down
  else
    echo "Usage: $0 scaleup|scaledown [password|key] [run|dry-run|plan] [true|false for resume]"
    exit 1
  fi

  if [[ -f "$STATE_FILE" && $(cat "$STATE_FILE") == "done" ]]; then
    rm -f "$STATE_FILE"
  fi
}

main

SCRIPT_END_TIME=$(date +%s)
TOTAL_DURATION=$((SCRIPT_END_TIME - SCRIPT_START_TIME))
MINUTES=$((TOTAL_DURATION / 60))
SECONDS=$((TOTAL_DURATION % 60))
log "[INFO] Total script execution time: ${MINUTES} minutes and ${SECONDS} seconds."

