#!/bin/bash
set -euo pipefail

TF_DIR="terraform"
CONFIG_FILE="${CONFIG_FILE:-config/environment.yml}"
TF_WORKSPACE="${TF_WORKSPACE:-default}"

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

# Exporting TF_WORKSPACE is enough to target the workspace for every terraform
# call below. Do not use `workspace select` here: terraform refuses to run it
# while TF_WORKSPACE is set and exits non-zero, which reads as "not found".
export TF_WORKSPACE
terraform -chdir="$TF_DIR" workspace list 2>/dev/null | sed 's/^[* ]*//' | grep -qx "$TF_WORKSPACE" \
  || { echo "Workspace '$TF_WORKSPACE' not found — run 'make apply SETUP=$TF_WORKSPACE' first"; exit 1; }

# Emits one "phase<TAB>host<TAB>association_id" row per host/phase the pipeline is
# expected to run, association_id empty when it has not been created yet.
#
# The expected host set comes from the config, not from the associations that
# happen to exist: an apply that fails partway never creates the later phases, so
# reading only what exists silently drops every host still waiting on them — the
# table then looks complete while most of the fleet is missing from it.
#
# Association IDs come from the state file rather than the phase_association_ids
# output. Terraform only recomputes outputs at the end of a *successful* apply, so
# after a partial failure the output still describes the previous run. The state
# is written as each resource completes, so it sees the whole fleet.
phase_rows() {
  python3 -c '
import json, re, subprocess, sys

config_file, tf_dir = sys.argv[1], sys.argv[2]

# Phases in pipeline execution order.
PHASE_ORDER = [
    "rename_computer", "configure_networking", "install_windows_features",
    "bootstrap_domain", "configure_dns_forwarder", "join_domain",
    "promote_dc", "configure_promoted_dc", "credential_setup", "agent_setup",
]

# --- hosts from the config -------------------------------------------------
# Parsed by hand rather than with PyYAML, which is not a dependency of this
# repo; the hosts block is a flat list of scalars, same as lock_ips.py assumes.
hosts, cur, in_hosts = [], None, False
with open(config_file) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if re.match(r"^hosts:\s*$", line):
            in_hosts = True
            continue
        if in_hosts and re.match(r"^\S", line):
            break
        if not in_hosts:
            continue
        m = re.match(r"^\s+-\s+name:\s*(\S+)", line)
        if m:
            cur = {"name": m.group(1), "role": None, "bootstrap": False}
            hosts.append(cur)
            continue
        if cur is None:
            continue
        m = re.match(r"^\s+role:\s*(\S+)", line)
        if m:
            cur["role"] = m.group(1)
            continue
        m = re.match(r"^\s+bootstrap:\s*(\S+)", line)
        if m:
            cur["bootstrap"] = m.group(1).strip().lower() in ("true", "yes")

# Same aliases main.tf accepts, so a config on the old schema still resolves.
ALIASES = {"dhcp_server": "srv", "agent_client": "clt", "domain_controller": "dc"}
roles = {h["name"]: ALIASES.get(h["role"], h["role"]) for h in hosts}
names = [h["name"] for h in hosts]

bootstraps = [h["name"] for h in hosts if h["bootstrap"]]
bootstrap = bootstraps[0] if len(bootstraps) == 1 else None

servers = [n for n in names if roles.get(n) in ("srv", "dc")]
promotable = [n for n in names if roles.get(n) == "dc" and n != bootstrap]
clients = [n for n in names if roles.get(n) == "clt"]

# Mirrors the for_each on each aws_ssm_association in terraform/main.tf.
expected = {
    "rename_computer": names,
    "configure_networking": names,
    "install_windows_features": names,
    "bootstrap_domain": ["global"],
    "configure_dns_forwarder": ["global"],
    "join_domain": [n for n in names if n != bootstrap],
    "promote_dc": promotable,
    "configure_promoted_dc": promotable,
    "credential_setup": [n for n in names if n in servers or n == bootstrap],
    "agent_setup": clients,
}

# --- association IDs from state -------------------------------------------
found = {}
proc = subprocess.run(
    ["terraform", "-chdir=" + tf_dir, "show", "-json"],
    capture_output=True, text=True,
)
try:
    doc = json.loads(proc.stdout)
except ValueError:
    doc = {}

for res in doc.get("values", {}).get("root_module", {}).get("resources", []):
    if res.get("type") != "aws_ssm_association":
        continue
    # An association whose create timed out is left tainted with only its
    # primary key persisted: association_id is null but id holds the same
    # value. Preferring id keeps that host reporting the pending execution
    # that caused the timeout instead of looking absent.
    vals = res.get("values", {})
    assoc_id = vals.get("association_id") or vals.get("id") or ""
    index = res.get("index")
    host = "global" if index is None else str(index)
    found.setdefault(res["name"], {})[host] = assoc_id

for phase in PHASE_ORDER:
    in_state = found.get(phase, {})
    # Anything in state but not expected — a host dropped from the config whose
    # association has not been reaped yet — still gets a row, so it stays visible.
    order = sorted(expected.get(phase, [])) + sorted(set(in_state) - set(expected.get(phase, [])))
    for host in order:
        print("\t".join([phase, host, in_state.get(host, "")]))
' "$1" "$2"
}

rows=$(phase_rows "$CONFIG_FILE" "$TF_DIR" || true)

if [ -z "$rows" ]; then
  echo "No hosts found in $CONFIG_FILE."
  exit 1
fi

echo "SSM Phase Progress"
echo "=================="
printf "%-28s %-16s %-10s %-12s %s\n" "PHASE" "HOST" "STATUS" "DURATION" "COMPLETED_AT"
echo "--------------------------------------------------------------------------------------------"

echo "$rows" | while IFS=$'\t' read -r phase host assoc_id; do
  # No association in state: the apply has not reached this phase for this host.
  if [ -z "$assoc_id" ]; then
    printf "%-28s %-16s %-10s %-12s %s\n" "$phase" "$host" "- waiting" "N/A" "not started"
    continue
  fi

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

# Summary: total time from first instance creation to last phase completion
python3 - "$TF_DIR" "$aws_profile" "$aws_region" "$rows" <<'SUMMARY'
import json, sys, subprocess, datetime

tf_dir = sys.argv[1]
profile = sys.argv[2]
region = sys.argv[3]

# Association IDs out of the phase/host/id rows built above, skipping the phases
# that have not been created yet.
assoc_ids = [
    parts[2]
    for parts in (line.split("\t") for line in sys.argv[4].splitlines())
    if len(parts) == 3 and parts[2]
]

# Get earliest instance launch time
try:
    # From state, not the host_inventory output, for the same reason as the
    # association IDs above: a partial apply leaves the output a run behind.
    show = subprocess.run(
        ["terraform", f"-chdir={tf_dir}", "show", "-json"],
        capture_output=True, text=True
    )
    doc = json.loads(show.stdout)
    instance_ids = [
        r["values"]["id"]
        for r in doc.get("values", {}).get("root_module", {}).get("resources", [])
        if r.get("type") == "aws_instance" and r.get("values", {}).get("id")
    ]

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
for assoc_id in assoc_ids:
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