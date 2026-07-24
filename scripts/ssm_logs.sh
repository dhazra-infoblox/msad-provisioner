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
RUN="${3:-}"

usage() {
  echo "Usage: $0 [PHASE] [HOST] [RUN]"
  echo ""
  echo "  $0                     - list all phases that have logs"
  echo "  $0 PHASE               - list hosts with logs for a phase"
  echo "  $0 PHASE HOST          - list all runs with timestamps, show latest"
  echo "  $0 PHASE HOST N        - show run N (1=oldest, use 'all' to list only)"
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
    | awk '{print $NF}' | sed 's:/$::' \
    | grep -v '^[0-9a-f]\{8\}-[0-9a-f]\{4\}-' \
    | sort
  exit 0
fi

# ── Phase + Host: show runs with timestamps ──────────────────────────────────
LOG_PATH="${S3_BASE}/${PHASE}/${HOST}"

# Collect all command invocation dirs (each command-id is a separate run)
ALL_FILES=$(aws s3 ls "${LOG_PATH}/" "${AWS_OPTS[@]}" --recursive 2>/dev/null \
  | sort -k1,2)

if [[ -z "$ALL_FILES" ]]; then
  echo "No logs found at ${LOG_PATH}/"
  exit 1
fi

# Extract unique invocation prefixes (up to the step dir) with their timestamps
# Each line: <date> <time> <size> <path>
# Group by command-id to get unique runs
declare -a RUN_PREFIXES=()
declare -a RUN_TIMESTAMPS=()
PREV_CMD_ID=""

while IFS= read -r line; do
  filepath=$(echo "$line" | awk '{print $NF}')
  timestamp=$(echo "$line" | awk '{print $1 " " $2}')
  # Extract command-id: .../phase/host/<cmd-id>/...
  # The path after host/ starts with the command-id
  after_host="${filepath#${S3_PREFIX}/${PHASE}/${HOST}/}"
  cmd_id="${after_host%%/*}"
  if [[ "$cmd_id" != "$PREV_CMD_ID" ]]; then
    prefix=$(echo "$filepath" | sed 's|/[^/]*$||')
    RUN_PREFIXES+=("$prefix")
    RUN_TIMESTAMPS+=("$timestamp")
    PREV_CMD_ID="$cmd_id"
  fi
done <<< "$ALL_FILES"

TOTAL_RUNS=${#RUN_PREFIXES[@]}

# If RUN=all, just list runs and exit
if [[ "$RUN" == "all" ]]; then
  echo "Runs for ${PHASE}/${HOST}: ($TOTAL_RUNS total)"
  echo ""
  printf "  %-5s %-20s %s\n" "RUN" "TIMESTAMP" "COMMAND_ID"
  printf "  %-5s %-20s %s\n" "───" "─────────" "──────────"
  for i in "${!RUN_PREFIXES[@]}"; do
    after_host="${RUN_PREFIXES[$i]#${S3_PREFIX}/${PHASE}/${HOST}/}"
    cmd_id="${after_host%%/*}"
    printf "  %-5s %-20s %s\n" "$((i+1))" "${RUN_TIMESTAMPS[$i]}" "$cmd_id"
  done
  exit 0
fi

# Determine which run to show
if [[ -n "$RUN" && "$RUN" =~ ^[0-9]+$ ]]; then
  RUN_IDX=$((RUN - 1))
  if [[ $RUN_IDX -lt 0 || $RUN_IDX -ge $TOTAL_RUNS ]]; then
    echo "Run $RUN out of range (1-$TOTAL_RUNS)" >&2
    exit 1
  fi
else
  RUN_IDX=$((TOTAL_RUNS - 1))  # latest
fi

INVOCATION_PREFIX="${RUN_PREFIXES[$RUN_IDX]}"
RUN_TS="${RUN_TIMESTAMPS[$RUN_IDX]}"
RUN_NUM=$((RUN_IDX + 1))

# Print run index header
echo "=== ${PHASE}/${HOST} — run ${RUN_NUM}/${TOTAL_RUNS} @ ${RUN_TS} ==="
after_host="${INVOCATION_PREFIX#${S3_PREFIX}/${PHASE}/${HOST}/}"
cmd_id="${after_host%%/*}"
echo "    cmd: ${cmd_id}"
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
