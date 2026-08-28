#!/bin/bash
# deploy_perf_scripts.sh
#
# Uploads performance testing scripts to S3 and deploys them via SSM:
#   - scripts/bulk_dhcp_load.ps1  → all server hosts, role srv (C:\ProgramData\msad-agent\)
#   - scripts/performance.ps1     → all agent clients, role clt (C:\Users\MSADAgent\)
#
# Usage:
#   SETUP=nstarqa bash scripts/deploy_perf_scripts.sh
#   make deploy-perf-scripts SETUP=nstarqa
#
# Optional:
#   SCOPE_COUNT=500          - number of DHCP scopes (passed to bulk_dhcp_load.ps1)
#   RESERVATIONS_PER_SCOPE=0 - reservations per scope
#   AGENT_SCRIPT_PATH="C:\Users\MSADAgent\performance.ps1"
#   DHCP_SCRIPT_PATH="C:\ProgramData\msad-agent\bulk_dhcp_load.ps1"
#   DRY_RUN=1                - print commands without executing SSM send-command

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ── Config ─────────────────────────────────────────────────────────────────────
SETUP="${SETUP:-default}"
if [ "$SETUP" = "default" ]; then
  CONFIG_FILE="$ROOT_DIR/config/environment.yml"
else
  CONFIG_FILE="$ROOT_DIR/config/${SETUP}.yml"
fi

[ -f "$CONFIG_FILE" ] || { echo "ERROR: config not found: $CONFIG_FILE" >&2; exit 1; }

AWS_PROFILE=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG_FILE'))['aws']['profile'])" 2>/dev/null || echo "dibya-aws")
AWS_REGION=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG_FILE'))['aws'].get('region','us-east-1'))" 2>/dev/null || echo "us-east-1")
S3_BUCKET=$(python3 -c "import yaml; c=yaml.safe_load(open('$CONFIG_FILE')); print(c.get('ssm_logs',{}).get('s3_bucket','cicd-blox'))" 2>/dev/null || echo "cicd-blox")
S3_PREFIX=$(python3 -c "import yaml; c=yaml.safe_load(open('$CONFIG_FILE')); print(c.get('ssm_logs',{}).get('s3_prefix','ib-msad/ssm_logs'))" 2>/dev/null || echo "ib-msad/ssm_logs")

# Script paths on target machines
DHCP_SCRIPT_PATH="${DHCP_SCRIPT_PATH:-C:\\ProgramData\\msad-agent\\bulk_dhcp_load.ps1}"
AGENT_SCRIPT_PATH="${AGENT_SCRIPT_PATH:-C:\\Users\\MSADAgent\\performance.ps1}"

# Bulk load parameters
SCOPE_COUNT="${SCOPE_COUNT:-500}"
RESERVATIONS_PER_SCOPE="${RESERVATIONS_PER_SCOPE:-0}"

DRY_RUN="${DRY_RUN:-0}"

AWS_ARGS="--profile $AWS_PROFILE --region $AWS_REGION"

# S3 staging prefix for perf scripts
SCRIPT_S3_PREFIX="${S3_PREFIX%/ssm_logs*}/perf-scripts"

BULK_SCRIPT="$ROOT_DIR/scripts/bulk_dhcp_load.ps1"
PERF_SCRIPT="$ROOT_DIR/scripts/performance.ps1"

# ── Helpers ────────────────────────────────────────────────────────────────────
log()  { echo "[deploy-perf-scripts] $*"; }
warn() { echo "[deploy-perf-scripts] WARN: $*" >&2; }

ssm_send() {
  local instance_id="$1"
  local comment="$2"
  shift 2
  local cmds_json="$1"
  shift

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN: aws ssm send-command --instance-ids $instance_id --comment '$comment'"
    echo "dry-run-command-id"
    return
  fi

  aws ssm send-command $AWS_ARGS \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunPowerShellScript" \
    --parameters "commands=$cmds_json" \
    --timeout-seconds 120 \
    --comment "$comment" \
    --output text --query 'Command.CommandId'
}

poll_command() {
  local cmd_id="$1"
  local instance_id="$2"
  local label="$3"

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN: would poll command $cmd_id on $instance_id"
    return
  fi

  log "Polling '$label' (cmd=$cmd_id)..."
  local attempts=0
  while true; do
    local out
    out=$(aws ssm get-command-invocation $AWS_ARGS \
      --command-id "$cmd_id" --instance-id "$instance_id" \
      --output text --query '[Status,StandardOutputContent,StandardErrorContent]' 2>&1 || true)

    local status
    status=$(echo "$out" | head -1 | awk '{print $1}')

    case "$status" in
      Success)
        log "  ✓ $label succeeded"
        break
        ;;
      Failed|Cancelled|TimedOut|DeliveryTimedOut|ExecutionTimedOut)
        warn "  ✗ $label status=$status"
        echo "$out"
        return 1
        ;;
      InProgress|Pending|Delayed)
        attempts=$((attempts + 1))
        if [ $((attempts % 10)) -eq 0 ]; then
          log "  ... still $status (${attempts}s)"
        fi
        sleep 3
        ;;
      *)
        attempts=$((attempts + 1))
        sleep 3
        ;;
    esac
  done
}

# ── Verify scripts exist ───────────────────────────────────────────────────────
[ -f "$BULK_SCRIPT" ] || { echo "ERROR: $BULK_SCRIPT not found" >&2; exit 1; }
[ -f "$PERF_SCRIPT" ] || { echo "ERROR: $PERF_SCRIPT not found (expected scripts/performance.ps1)" >&2; exit 1; }

# ── Get Terraform host inventory ───────────────────────────────────────────────
TF_WORKSPACE="$SETUP"
log "Reading Terraform host inventory (workspace=$TF_WORKSPACE)..."

INVENTORY_JSON=$(
  terraform -chdir="$ROOT_DIR/terraform" workspace select "$TF_WORKSPACE" >/dev/null 2>&1 || true
  terraform -chdir="$ROOT_DIR/terraform" output -json host_inventory 2>/dev/null
)

if [ -z "$INVENTORY_JSON" ] || [ "$INVENTORY_JSON" = "null" ]; then
  echo "ERROR: Could not read host_inventory from Terraform. Is the environment deployed?" >&2
  exit 1
fi

# Parse instance IDs by role
SERVER_INSTANCES=$(python3 -c "
import json, sys
inv = json.load(sys.stdin)
for name, h in inv.items():
    if h.get('role') in ('srv', 'dhcp_server'):
        print(f\"{name}={h['instance_id']}\")
" <<< "$INVENTORY_JSON")

AGENT_INSTANCES=$(python3 -c "
import json, sys
inv = json.load(sys.stdin)
for name, h in inv.items():
    if h.get('role') in ('clt', 'agent_client'):
        print(f\"{name}={h['instance_id']}\")
" <<< "$INVENTORY_JSON")

if [ -z "$SERVER_INSTANCES" ]; then
  warn "No server hosts (role srv) found in inventory."
fi
if [ -z "$AGENT_INSTANCES" ]; then
  warn "No agent client hosts (role clt) found in inventory."
fi

log "Server hosts: $(echo "$SERVER_INSTANCES" | xargs)"
log "Agent clients: $(echo "$AGENT_INSTANCES" | xargs)"

# ── Upload scripts to S3 ───────────────────────────────────────────────────────
BULK_S3_URI="s3://$S3_BUCKET/$SCRIPT_S3_PREFIX/bulk_dhcp_load.ps1"
PERF_S3_URI="s3://$S3_BUCKET/$SCRIPT_S3_PREFIX/performance.ps1"

log "Uploading bulk_dhcp_load.ps1 → $BULK_S3_URI"
if [ "$DRY_RUN" != "1" ]; then
  aws s3 cp $AWS_ARGS "$BULK_SCRIPT" "$BULK_S3_URI" --sse AES256 >/dev/null
fi

log "Uploading performance.ps1 → $PERF_S3_URI"
if [ "$DRY_RUN" != "1" ]; then
  aws s3 cp $AWS_ARGS "$PERF_SCRIPT" "$PERF_S3_URI" --sse AES256 >/dev/null
fi

log "Scripts uploaded to s3://$S3_BUCKET/$SCRIPT_S3_PREFIX/"

# ── Deploy bulk_dhcp_load.ps1 to each server host ─────────────────────────────
log ""
log "=== Deploying bulk_dhcp_load.ps1 to server hosts ==="

SERVER_CMD_IDS=()
SERVER_INSTANCE_IDS=()

while IFS='=' read -r host_name instance_id; do
  [ -z "$host_name" ] && continue

  log "  → $host_name ($instance_id)"

  # PowerShell: create target dir, download from S3, verify
  CMD_JSON='["New-Item -Path \"C:\\ProgramData\\msad-agent\" -ItemType Directory -Force | Out-Null","Read-S3Object -BucketName \"'"$S3_BUCKET"'\" -Key \"'"$SCRIPT_S3_PREFIX"'/bulk_dhcp_load.ps1\" -File \"'"${DHCP_SCRIPT_PATH//\\/\\\\}"'\" -ProfileName default -Region '"$AWS_REGION"'","Write-Host \"bulk_dhcp_load.ps1 deployed to '"${DHCP_SCRIPT_PATH//\\/\\\\}"'\"","Write-Host \"Run with: powershell -ExecutionPolicy Bypass -File '''"${DHCP_SCRIPT_PATH//\\/\\\\}"''' -ScopeCount '"$SCOPE_COUNT"' -ReservationsPerScope '"$RESERVATIONS_PER_SCOPE"'\""]'

  # Use aws s3 cp instead (more reliably available than Read-S3Object on non-configured instances)
  CMD_JSON='["$dest = \"'"${DHCP_SCRIPT_PATH//\\/\\\\\\\\}"'\"","New-Item -Path (Split-Path $dest -Parent) -ItemType Directory -Force | Out-Null","$url = (Get-STSCallerIdentity | Out-Null; $null)","& \"C:\\Program Files\\Amazon\\AWSCLIV2\\aws.exe\" s3 cp s3://'"$S3_BUCKET/$SCRIPT_S3_PREFIX"'/bulk_dhcp_load.ps1 $dest","Write-Host \"Deployed bulk_dhcp_load.ps1 to $dest\"","Write-Host \"Run: powershell -ExecutionPolicy Bypass -File $dest -ScopeCount '"$SCOPE_COUNT"' -ReservationsPerScope '"$RESERVATIONS_PER_SCOPE"'\""]'

  cmd_id=$(ssm_send "$instance_id" "deploy bulk_dhcp_load.ps1 to $host_name" "$CMD_JSON")
  SERVER_CMD_IDS+=("$cmd_id")
  SERVER_INSTANCE_IDS+=("$instance_id:$host_name")

done <<< "$SERVER_INSTANCES"

# ── Deploy performance.ps1 to each agent client ────────────────────────────────
log ""
log "=== Deploying performance.ps1 to agent clients ==="

AGENT_CMD_IDS=()
AGENT_INSTANCE_IDS=()

while IFS='=' read -r host_name instance_id; do
  [ -z "$host_name" ] && continue

  log "  → $host_name ($instance_id)"

  CMD_JSON='["$dest = \"'"${AGENT_SCRIPT_PATH//\\/\\\\\\\\}"'\"","New-Item -Path (Split-Path $dest -Parent) -ItemType Directory -Force | Out-Null","& \"C:\\Program Files\\Amazon\\AWSCLIV2\\aws.exe\" s3 cp s3://'"$S3_BUCKET/$SCRIPT_S3_PREFIX"'/performance.ps1 $dest","Write-Host \"Deployed performance.ps1 to $dest\"","Write-Host \"Run: powershell -ExecutionPolicy Bypass -File $dest\""]'

  cmd_id=$(ssm_send "$instance_id" "deploy performance.ps1 to $host_name" "$CMD_JSON")
  AGENT_CMD_IDS+=("$cmd_id")
  AGENT_INSTANCE_IDS+=("$instance_id:$host_name")

done <<< "$AGENT_INSTANCES"

# ── Poll results ───────────────────────────────────────────────────────────────
log ""
log "=== Polling deployment status ==="

all_ok=true

for i in "${!SERVER_CMD_IDS[@]}"; do
  cmd_id="${SERVER_CMD_IDS[$i]}"
  instance_info="${SERVER_INSTANCE_IDS[$i]}"
  instance_id="${instance_info%%:*}"
  label="${instance_info#*:} (bulk_dhcp_load.ps1)"
  poll_command "$cmd_id" "$instance_id" "$label" || all_ok=false
done

for i in "${!AGENT_CMD_IDS[@]}"; do
  cmd_id="${AGENT_CMD_IDS[$i]}"
  instance_info="${AGENT_INSTANCE_IDS[$i]}"
  instance_id="${instance_info%%:*}"
  label="${instance_info#*:} (performance.ps1)"
  poll_command "$cmd_id" "$instance_id" "$label" || all_ok=false
done

# ── Summary ────────────────────────────────────────────────────────────────────
log ""
log "=== Deployment Summary ==="
log "Scripts staged at: s3://$S3_BUCKET/$SCRIPT_S3_PREFIX/"
log ""
log "On each server host:"
log "  Path : $DHCP_SCRIPT_PATH"
log "  Run  : powershell -ExecutionPolicy Bypass -File \"$DHCP_SCRIPT_PATH\" -ScopeCount $SCOPE_COUNT -ReservationsPerScope $RESERVATIONS_PER_SCOPE"
log ""
log "On each agent client:"
log "  Path : $AGENT_SCRIPT_PATH"
log "  Run  : powershell -ExecutionPolicy Bypass -File \"$AGENT_SCRIPT_PATH\""
log ""

if $all_ok; then
  log "All deployments succeeded."
else
  warn "One or more deployments failed. Check output above."
  exit 1
fi
