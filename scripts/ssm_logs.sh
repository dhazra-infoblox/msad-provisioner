#!/bin/bash
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-config/environment.yml}"

# ── Parse config ──────────────────────────────────────────────────────────────
extract_field() {
  local section="$1" field="$2"
  awk -v sec="$section" -v key="$field" '
    $0 ~ "^"sec":" { in_sec=1; next }
    in_sec && /^[^[:space:]]/ { in_sec=0 }
    in_sec && $1 == key":" {
      $1=""; sub(/^[[:space:]]+/, ""); print; exit
    }
  ' "$CONFIG_FILE"
}

S3_BUCKET=$(extract_field ssm_logs s3_bucket)
S3_PREFIX=$(extract_field ssm_logs s3_prefix)
AWS_PROFILE=$(extract_field aws profile)

if [[ -z "$S3_BUCKET" || -z "$S3_PREFIX" ]]; then
  echo "Error: ssm_logs.s3_bucket / s3_prefix not set in $CONFIG_FILE" >&2
  exit 1
fi

S3_BASE="s3://${S3_BUCKET}/${S3_PREFIX}"

# ── Phases in pipeline order ─────────────────────────────────────────────────
PHASES=(
  rename-computer
  configure-networking
  install-features
  bootstrap-domain
  dns-forwarder
  join-domain
  credential-setup
  agent-setup
)

# ── Args ──────────────────────────────────────────────────────────────────────
PHASE="${1:-}"
HOST="${2:-}"

usage() {
  echo "Usage: $0 [PHASE] [HOST]"
  echo ""
  echo "  $0                  - list all phases that have logs"
  echo "  $0 PHASE            - list hosts with logs for a phase"
  echo "  $0 PHASE HOST       - show latest stdout+stderr for phase/host"
  echo ""
  echo "Phases: ${PHASES[*]}"
  exit 0
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

AWS_OPTS=(--profile "$AWS_PROFILE")

# ── No args: list phases with log counts ─────────────────────────────────────
if [[ -z "$PHASE" ]]; then
  echo "SSM logs at ${S3_BASE}/"
  echo ""
  printf "%-25s %s\n" "PHASE" "FILES"
  printf "%-25s %s\n" "─────" "─────"
  for p in "${PHASES[@]}"; do
    count=$( (aws s3 ls "${S3_BASE}/${p}/" --recursive "${AWS_OPTS[@]}" 2>/dev/null || true) | wc -l | tr -d ' ')
    if [[ "$count" -gt 0 ]]; then
      printf "%-25s %s\n" "$p" "$count"
    fi
  done
  exit 0
fi

# ── Phase only: list hosts ───────────────────────────────────────────────────
if [[ -z "$HOST" ]]; then
  echo "Hosts with logs for phase: $PHASE"
  echo ""
  aws s3 ls "${S3_BASE}/${PHASE}/" "${AWS_OPTS[@]}" 2>/dev/null \
    | awk '{print $NF}' | sed 's:/$::' | sort
  exit 0
fi

# ── Phase + Host: show latest stdout/stderr ──────────────────────────────────
LOG_PATH="${S3_BASE}/${PHASE}/${HOST}"

# Find the latest command invocation (sorted by timestamp)
LATEST_DIR=$(aws s3 ls "${LOG_PATH}/" "${AWS_OPTS[@]}" --recursive 2>/dev/null \
  | sort -k1,2 | tail -1 | awk '{print $NF}')

if [[ -z "$LATEST_DIR" ]]; then
  echo "No logs found at ${LOG_PATH}/"
  exit 1
fi

# Extract the invocation prefix (everything up to the step name dir)
# e.g. ib-msad/ssm_logs/join-domain/dhcp02/<cmd-id>/<instance-id>/<plugin>/<step>/stdout
INVOCATION_PREFIX=$(echo "$LATEST_DIR" | sed 's|/[^/]*$||')

echo "=== Latest logs for ${PHASE}/${HOST} ==="
echo "    ${S3_BASE%%${S3_PREFIX}*}${INVOCATION_PREFIX}/"
echo ""

for stream in stdout stderr; do
  CONTENT=$(aws s3 cp "s3://${S3_BUCKET}/${INVOCATION_PREFIX}/${stream}" - "${AWS_OPTS[@]}" 2>/dev/null || true)
  if [[ -n "$CONTENT" && "$CONTENT" != "failed to run commands: exit status 1" ]]; then
    echo "── ${stream} ──"
    echo "$CONTENT"
    echo ""
  elif [[ "$stream" == "stderr" && -n "$CONTENT" ]]; then
    echo "── ${stream} ──"
    echo "$CONTENT"
    echo ""
  fi
done
