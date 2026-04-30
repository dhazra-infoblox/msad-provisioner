#!/bin/bash
# creds.sh — Show VM credentials from local files (no Vault required).
# Sources: config/environment.yml, terraform/secret.tfvars, terraform state.
#
# Usage:
#   ./scripts/creds.sh          # table of all hosts
#   ./scripts/creds.sh dhcp01   # credentials for one host
set -euo pipefail

TF_DIR="terraform"
CONFIG_FILE="${CONFIG_FILE:-config/environment.yml}"
SECRET_TFVARS="${TF_DIR}/secret.tfvars"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$CONFIG_FILE" ]   || die "Config not found: $CONFIG_FILE"
[ -f "$SECRET_TFVARS" ] || die "secret.tfvars not found: $SECRET_TFVARS"

admin_user=$(awk '
  /^domain:/ { in_sec=1; next }
  in_sec && /^[^[:space:]]/ { in_sec=0 }
  in_sec && $1 == "admin_user:" { $1=""; sub(/^[[:space:]]+/,""); gsub(/"/,""); print; exit }
' "$CONFIG_FILE")

admin_password=$(grep -E '^[[:space:]]*admin_password[[:space:]]*=' "$SECRET_TFVARS" \
  | head -1 | sed -E 's/^[^=]+=//; s/^[[:space:]]*"//; s/"[[:space:]]*$//')

[ -n "$admin_user" ]    || die "Could not read domain.admin_user from $CONFIG_FILE"
[ -n "$admin_password" ] || die "Could not read admin_password from $SECRET_TFVARS"

inventory=$(terraform -chdir="$TF_DIR" output -json host_inventory 2>/dev/null) \
  || die "Could not read terraform output — has 'make apply' been run?"

FILTER="${1:-}"

if [ -z "$FILTER" ]; then
  printf "%-14s %-20s %-16s %-30s %s\n" "HOST" "INSTANCE_ID" "PRIVATE_IP" "USERNAME" "PASSWORD"
  printf "%-14s %-20s %-16s %-30s %s\n" "────" "───────────" "──────────" "────────" "────────"
  echo "$inventory" | jq -r 'to_entries[] | [.key, .value.instance_id, .value.private_ip] | @tsv' \
  | while IFS=$'\t' read -r host instance_id private_ip; do
      printf "%-14s %-20s %-16s %-30s %s\n" "$host" "$instance_id" "$private_ip" "$admin_user" "$admin_password"
    done
else
  row=$(echo "$inventory" | jq -r --arg h "$FILTER" '.[$h] | [.instance_id, .private_ip] | @tsv')
  [ -n "$row" ] || die "Host '$FILTER' not found in terraform output"
  IFS=$'\t' read -r instance_id private_ip <<< "$row"
  echo "host:        $FILTER"
  echo "instance_id: $instance_id"
  echo "private_ip:  $private_ip"
  echo "username:    $admin_user"
  echo "password:    $admin_password"
fi
