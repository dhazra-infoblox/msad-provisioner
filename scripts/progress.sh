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

for cmd in terraform aws jq python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd not found"
    exit 1
  fi
done

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

# Ordered list of phases matching the execution pipeline order.
PHASE_ORDER="rename_computer configure_networking install_windows_features bootstrap_domain configure_dns_forwarder join_domain credential_setup agent_setup"

echo "SSM Phase Progress"
echo "=================="
printf "%-28s %-16s %-10s %-12s %s\n" "PHASE" "HOST" "STATUS" "DURATION" "COMPLETED_AT"
echo "--------------------------------------------------------------------------------------------"

all_ids_json=$(terraform -chdir="$TF_DIR" output -json phase_association_ids)

for phase in $PHASE_ORDER; do
  phase_data=$(echo "$all_ids_json" | jq --arg p "$phase" '.[$p] // empty')
  if [ -z "$phase_data" ] || [ "$phase_data" = "null" ]; then
    continue
  fi

  # Build list of host/assoc_id pairs
  type=$(echo "$phase_data" | jq -r 'type')
  if [ "$type" = "object" ]; then
    pairs=$(echo "$phase_data" | jq -r 'to_entries[] | [.key, .value] | @tsv')
  else
    pairs=$(printf "global\t%s" "$(echo "$phase_data" | jq -r '.')")
  fi

  echo "$pairs" | while IFS=$'\t' read -r host assoc_id; do
    exec_json=$(aws --profile "$aws_profile" --region "$aws_region" \
      ssm describe-association-executions \
      --association-id "$assoc_id" \
      --max-results 20 \
      --output json 2>/dev/null || true)

    assoc_json=$(aws --profile "$aws_profile" --region "$aws_region" \
      ssm describe-association \
      --association-id "$assoc_id" \
      --output json 2>/dev/null || true)

    if [ -z "$exec_json" ]; then
      printf "%-28s %-16s %-10s %-12s %s\n" "$phase" "$host" "UNKNOWN" "N/A" "N/A"
      continue
    fi

    # Use python to parse executions: latest result + attempt count
    python3 - "$phase" "$host" "$exec_json" "$assoc_json" <<'PY'
import json, sys, datetime

phase = sys.argv[1]
host = sys.argv[2]
data = json.loads(sys.argv[3])
assoc_data = json.loads(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else {}

execs = data.get("AssociationExecutions", [])
if not execs:
    print(f"{phase:<28} {host:<16} {'UNKNOWN':<10} {'N/A':<12} N/A")
    raise SystemExit(0)

# Sort by created time descending
execs.sort(key=lambda e: e.get("CreatedTime", ""), reverse=True)

latest = execs[0]
total_attempts = len(execs)
failed_attempts = sum(1 for e in execs if e.get("Status") == "Failed")

status = latest.get("Status", "UNKNOWN")
created = latest.get("CreatedTime", "")

# Compute duration using association-level dates
duration = "N/A"
assoc_desc = assoc_data.get("AssociationDescription", {})
if status == "Success":
    end_time = assoc_desc.get("LastSuccessfulExecutionDate", "")
else:
    end_time = assoc_desc.get("LastExecutionDate", "")

if created and end_time:
    try:
        start = datetime.datetime.fromisoformat(str(created))
        end = datetime.datetime.fromisoformat(str(end_time))
        seconds = max(0, int((end - start).total_seconds()))
        h, rem = divmod(seconds, 3600)
        m, s = divmod(rem, 60)
        if h > 0:
            duration = f"{h}h{m:02d}m{s:02d}s"
        elif m > 0:
            duration = f"{m}m{s:02d}s"
        else:
            duration = f"{s}s"
    except (ValueError, TypeError):
        pass

# Format attempt column
if failed_attempts > 0:
    attempt_str = f"{total_attempts} ({failed_attempts}!)"
else:
    attempt_str = str(total_attempts)

completed = end_time if end_time else (created if created else "N/A")

# Status indicator
if status == "Success":
    status_str = "✓ Success"
elif status == "Failed":
    status_str = "✗ Failed"
elif status == "InProgress":
    status_str = "⟳ Running"
else:
    status_str = status

print(f"{phase:<28} {host:<16} {status_str:<10} {duration:<12} {completed}")
PY
  done
done

# Summary: total time from first instance creation to last phase completion
python3 - "$TF_DIR" "$aws_profile" "$aws_region" "$all_ids_json" <<'SUMMARY'
import json, sys, subprocess, datetime

tf_dir = sys.argv[1]
profile = sys.argv[2]
region = sys.argv[3]
all_ids = json.loads(sys.argv[4])

# Get earliest instance launch time
try:
    inv = subprocess.run(
        ["terraform", f"-chdir={tf_dir}", "output", "-json", "host_inventory"],
        capture_output=True, text=True
    )
    hosts = json.loads(inv.stdout)
    instance_ids = [h["instance_id"] for h in hosts.values()]

    result = subprocess.run(
        ["aws", "ec2", "describe-instances",
         "--instance-ids"] + instance_ids +
        ["--query", "Reservations[].Instances[].LaunchTime",
         "--output", "json", "--profile", profile, "--region", region],
        capture_output=True, text=True
    )
    launch_times = json.loads(result.stdout)
    earliest_launch = min(datetime.datetime.fromisoformat(t) for t in launch_times)
except Exception:
    earliest_launch = None

# Get latest association completion time
latest_end = None
for phase, data in all_ids.items():
    ids = list(data.values()) if isinstance(data, dict) else [data]
    for assoc_id in ids:
        try:
            result = subprocess.run(
                ["aws", "ssm", "describe-association",
                 "--association-id", assoc_id,
                 "--output", "json", "--profile", profile, "--region", region],
                capture_output=True, text=True
            )
            desc = json.loads(result.stdout).get("AssociationDescription", {})
            for key in ("LastSuccessfulExecutionDate", "LastExecutionDate"):
                val = desc.get(key)
                if val:
                    t = datetime.datetime.fromisoformat(str(val))
                    if latest_end is None or t > latest_end:
                        latest_end = t
        except Exception:
            pass

if earliest_launch and latest_end:
    total = max(0, int((latest_end - earliest_launch).total_seconds()))
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    if h > 0:
        total_str = f"{h}h{m:02d}m{s:02d}s"
    elif m > 0:
        total_str = f"{m}m{s:02d}s"
    else:
        total_str = f"{s}s"
    print()
    print(f"Infra created:  {earliest_launch.isoformat()}")
    print(f"Config done:    {latest_end.isoformat()}")
    print(f"Total time:     {total_str}")
else:
    print()
    print("Could not compute total time.")
SUMMARY