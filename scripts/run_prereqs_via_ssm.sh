#!/usr/bin/env bash
#
# Send check-prerequisites.ps1 to a Windows EC2 instance via SSM and stream output.
# Uses only the AWS CLI (no Python dependencies).
#
# Usage (called by Makefile):
#   scripts/run_prereqs_via_ssm.sh \
#       --profile my-profile --region us-east-1 \
#       --instance-id i-0abc123 --role DhcpServer \
#       --script scripts/check-prerequisites.ps1 [--fix]

set -euo pipefail

# --- Parse arguments ---
PROFILE="" REGION="" INSTANCE_ID="" ROLE="" SCRIPT="" FIX=""
TARGETS="" DOMAIN="" SERVICE_USER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)      PROFILE="$2";      shift 2 ;;
    --region)       REGION="$2";       shift 2 ;;
    --instance-id)  INSTANCE_ID="$2";  shift 2 ;;
    --role)         ROLE="$2";         shift 2 ;;
    --script)       SCRIPT="$2";       shift 2 ;;
    --fix)          FIX="-Fix";        shift   ;;
    --targets)      TARGETS="$2";      shift 2 ;;
    --domain)       DOMAIN="$2";       shift 2 ;;
    --service-user) SERVICE_USER="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$PROFILE" || -z "$REGION" || -z "$INSTANCE_ID" || -z "$ROLE" || -z "$SCRIPT" ]] && {
  echo "Missing required arguments" >&2; exit 1
}

# --- Read the PowerShell script ---
SCRIPT_BODY=$(<"$SCRIPT")

# --- Build the parameter string for check-prerequisites.ps1 ---
PS_PARAMS="-Role $ROLE"
[[ -n "$TARGETS" ]]      && PS_PARAMS="$PS_PARAMS -TargetServers \\\"$TARGETS\\\""
[[ -n "$DOMAIN" ]]        && PS_PARAMS="$PS_PARAMS -DomainFqdn \\\"$DOMAIN\\\""
[[ -n "$SERVICE_USER" ]]  && PS_PARAMS="$PS_PARAMS -ServiceUser \\\"$SERVICE_USER\\\""
[[ -n "$FIX" ]]           && PS_PARAMS="$PS_PARAMS -Fix"

# --- Build a JSON payload file for SSM ---
# We write the script to a temp file on the remote host, execute it, then clean up.
TMPJSON=$(mktemp /tmp/ssm-prereqs-XXXXXX.json)
trap 'rm -f "$TMPJSON"' EXIT

# Use python3 (stdlib only) to safely JSON-encode the script body into the commands array
python3 -c "
import json, sys

script_body = sys.stdin.read()
commands = [
    '\$ErrorActionPreference = \"Stop\"',
    '\$scriptPath = \"\$env:TEMP\\\\check-prerequisites.ps1\"',
    'Set-Content -Path \$scriptPath -Encoding UTF8 -Value @\\'',
    script_body,
    '\\'@',
    '& \$scriptPath $PS_PARAMS'.replace('\$PS_PARAMS', '''$PS_PARAMS'''),
    '\$exitCode = \$LASTEXITCODE',
    'Remove-Item -Path \$scriptPath -Force -ErrorAction SilentlyContinue',
    'exit \$exitCode',
]
json.dump({'commands': commands}, sys.stdout)
" <<< "$SCRIPT_BODY" > "$TMPJSON"

# --- Send command ---
echo "Sending command to $INSTANCE_ID..."
COMMAND_ID=$(aws ssm send-command \
  --profile "$PROFILE" --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunPowerShellScript" \
  --parameters "file://$TMPJSON" \
  --timeout-seconds 300 \
  --comment "$([ -n "$FIX" ] && echo fix || echo check)-prereqs ($ROLE)" \
  --output text --query 'Command.CommandId')

echo "Command ID: $COMMAND_ID"
echo "Waiting for completion..."
echo ""

# --- Poll for completion ---
while true; do
  sleep 3
  STATUS=$(aws ssm get-command-invocation \
    --profile "$PROFILE" --region "$REGION" \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --output text --query 'Status' 2>/dev/null || echo "Pending")

  case "$STATUS" in
    Success|Failed|Cancelled|TimedOut) break ;;
    *) printf "." ;;
  esac
done
echo ""

# --- Print output ---
aws ssm get-command-invocation \
  --profile "$PROFILE" --region "$REGION" \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --output text --query 'StandardOutputContent' 2>/dev/null || true

STDERR=$(aws ssm get-command-invocation \
  --profile "$PROFILE" --region "$REGION" \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --output text --query 'StandardErrorContent' 2>/dev/null || true)

if [[ -n "$STDERR" && "$STDERR" != "None" ]]; then
  echo "--- STDERR ---" >&2
  echo "$STDERR" >&2
fi

if [[ "$STATUS" != "Success" ]]; then
  echo "" >&2
  echo "Command finished with status: $STATUS" >&2
  exit 1
else
  echo "Command finished successfully."
fi
