#!/bin/bash
set -euo pipefail

TF_DIR="terraform"
CONFIG_FILE="${CONFIG_FILE:-config/environment.yml}"

extract_aws_field() {
  local field="$1"
  awk -v key="$field" '
    /^aws:/ { in_aws=1; next }
    in_aws && /^[^[:space:]]/ { in_aws=0 }
    in_aws && $1 == key":" {
      $1=""
      sub(/^[[:space:]]+/, "")
      print
      exit
    }
  ' "$CONFIG_FILE"
}

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform not found"
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws cli not found"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found"
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file not found: $CONFIG_FILE"
  exit 1
fi

aws_profile="$(extract_aws_field profile || true)"
aws_region="$(extract_aws_field region || true)"

if [ -z "${aws_profile:-}" ] || [ -z "${aws_region:-}" ]; then
  echo "Could not read aws.profile/aws.region from $CONFIG_FILE"
  exit 1
fi

if ! terraform -chdir="$TF_DIR" output -json phase_association_ids >/dev/null 2>&1; then
  echo "No phase_association_ids output found. Run apply first."
  exit 1
fi

echo "SSM Phase Progress"
echo "=================="
printf "%-24s %-16s %-12s %-12s %s\n" "PHASE" "HOST" "STATUS" "DURATION" "COMPLETED_AT"

terraform -chdir="$TF_DIR" output -json phase_association_ids | jq -r '
  to_entries[] |
  .key as $phase |
  if (.value | type) == "object" then
    .value | to_entries[] | [$phase, .key, .value] | @tsv
  else
    [$phase, "global", .value] | @tsv
  end
' | while IFS=$'\t' read -r phase host assoc_id; do
  exec_json=$(aws --profile "$aws_profile" --region "$aws_region" ssm describe-association-executions --association-id "$assoc_id" --output json 2>/dev/null || true)
  assoc_json=$(aws --profile "$aws_profile" --region "$aws_region" ssm describe-association --association-id "$assoc_id" --output json 2>/dev/null || true)

  if [ -z "$exec_json" ] || [ -z "$assoc_json" ]; then
    printf "%-24s %-16s %-12s %-12s %s\n" "$phase" "$host" "UNKNOWN" "N/A" "N/A"
    continue
  fi

  latest_exec=$(echo "$exec_json" | jq -r '
    (.AssociationExecutions // [])
    | sort_by(.CreatedTime)
    | last
  ')

  if [ -z "$latest_exec" ] || [ "$latest_exec" = "null" ]; then
    printf "%-24s %-16s %-12s %-12s %s\n" "$phase" "$host" "UNKNOWN" "N/A" "N/A"
    continue
  fi

  status=$(echo "$latest_exec" | jq -r '.Status // "UNKNOWN"')
  started_at=$(echo "$latest_exec" | jq -r '.CreatedTime // empty')
  if [ "$status" = "Success" ]; then
    completed_at=$(echo "$assoc_json" | jq -r '.AssociationDescription.LastSuccessfulExecutionDate // empty')
  else
    completed_at=$(echo "$assoc_json" | jq -r '.AssociationDescription.LastExecutionDate // empty')
  fi

  duration="N/A"
  if [ -n "$started_at" ] && [ -n "$completed_at" ]; then
    duration=$(python3 - "$started_at" "$completed_at" <<'PY'
import datetime
import sys

started_at = sys.argv[1]
completed_at = sys.argv[2]

try:
    start = datetime.datetime.fromisoformat(started_at)
    end = datetime.datetime.fromisoformat(completed_at)
except ValueError:
    print("N/A")
    raise SystemExit(0)

seconds = max(0, int((end - start).total_seconds()))
h, rem = divmod(seconds, 3600)
m, s = divmod(rem, 60)
if h > 0:
    print(f"{h}h{m:02d}m{s:02d}s")
elif m > 0:
    print(f"{m}m{s:02d}s")
else:
    print(f"{s}s")
PY
)
  fi

  if [ -z "$status" ] || [ "$status" = "None" ] || [ "$status" = "null" ]; then
    status="UNKNOWN"
  fi

  if [ -z "$completed_at" ] || [ "$completed_at" = "None" ] || [ "$completed_at" = "null" ]; then
    completed_at="N/A"
  fi

  printf "%-24s %-16s %-12s %-12s %s\n" "$phase" "$host" "$status" "$duration" "$completed_at"
done
