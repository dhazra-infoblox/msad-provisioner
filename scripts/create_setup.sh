#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_CONFIG="${SOURCE_CONFIG:-$ROOT_DIR/config/environment.yml}"
SOURCE_SECRET="${SOURCE_SECRET:-$ROOT_DIR/terraform/secret.tfvars}"
SETUP="${SETUP:-}"
DOMAIN="${DOMAIN:-}"
IP_OFFSET="${IP_OFFSET:-}"
NETBIOS="${NETBIOS:-}"
NAME_PREFIX="${NAME_PREFIX:-}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

next_ip_offset() {
  local max_offset

  max_offset=$(awk '
    /^network:/ { in_network=1; next }
    in_network && /^[^[:space:]]/ { in_network=0 }
    in_network && $1 == "ip_start_offset:" { print $2 }
  ' "$ROOT_DIR"/config/*.yml 2>/dev/null | awk '
    BEGIN { max = 0 }
    /^[0-9]+$/ && $1 > max { max = $1 }
    END { print max }
  ')

  if [ -z "$max_offset" ] || [ "$max_offset" -lt 10 ]; then
    echo 10
  else
    echo $((max_offset + 20))
  fi
}

[ -n "$SETUP" ] || fail "SETUP is required"
[ "$SETUP" != "default" ] || fail "SETUP=default is reserved"
[ -n "$DOMAIN" ] || DOMAIN="${SETUP}.local"
[ -n "$IP_OFFSET" ] || IP_OFFSET="$(next_ip_offset)"
[[ "$IP_OFFSET" =~ ^[0-9]+$ ]] || fail "IP_OFFSET must be a number"
[ "$IP_OFFSET" -ge 2 ] || fail "IP_OFFSET must be >= 2"
[ -f "$SOURCE_CONFIG" ] || fail "Source config not found: $SOURCE_CONFIG"
[ -f "$SOURCE_SECRET" ] || fail "Source secret not found: $SOURCE_SECRET"

if [ -z "$NETBIOS" ]; then
  domain_label="${DOMAIN%%.*}"
  NETBIOS="$(printf '%s' "$domain_label" | tr -cd '[:alnum:]' | tr '[:lower:]' '[:upper:]' | cut -c1-15)"
fi
[ -n "$NETBIOS" ] || fail "Could not derive NETBIOS from DOMAIN"

if [ -z "$NAME_PREFIX" ]; then
  NAME_PREFIX="${SETUP}_msad_dhcp"
fi

TARGET_CONFIG="$ROOT_DIR/config/${SETUP}.yml"
TARGET_SECRET="$ROOT_DIR/terraform/secret.${SETUP}.tfvars"

[ ! -e "$TARGET_CONFIG" ] || fail "Target config already exists: $TARGET_CONFIG"
[ ! -e "$TARGET_SECRET" ] || fail "Target secret already exists: $TARGET_SECRET"

awk \
  -v setup="$SETUP" \
  -v domain="$DOMAIN" \
  -v netbios="$NETBIOS" \
  -v name_prefix="$NAME_PREFIX" \
  -v ip_offset="$IP_OFFSET" '
function trim_left(value) {
  sub(/^[[:space:]]+/, "", value)
  return value
}
function render_host_name(original, normalized) {
  normalized = original
  gsub(/_/, "-", normalized)
  if (index(normalized, setup "-") == 1) {
    return normalized
  }
  return setup "-" normalized
}
{
  if ($0 ~ /^[^[:space:]][^:]*:/) {
    section = $0
    sub(/:.*/, "", section)
  }

  if (section == "aws" && $0 ~ /^[[:space:]]+name_prefix:/) {
    print "  name_prefix: " name_prefix
    next
  }

  if (section == "domain" && $0 ~ /^[[:space:]]+fqdn:/) {
    print "  fqdn: " domain
    next
  }
  if (section == "domain" && $0 ~ /^[[:space:]]+netbios:/) {
    print "  netbios: " netbios
    next
  }
  if (section == "domain" && $0 ~ /^[[:space:]]+admin_user:/) {
    print "  admin_user: " netbios "\\Administrator"
    next
  }

  if (section == "network" && $0 ~ /^[[:space:]]+ip_start_offset:/) {
    print "  ip_start_offset: " ip_offset
    next
  }

  if (section == "hosts" && $0 ~ /^[[:space:]]+- name:/) {
    host = $0
    sub(/^[[:space:]]+- name:[[:space:]]*/, "", host)
    host = trim_left(host)
    print "  - name: " render_host_name(host)
    next
  }

  print
}
' "$SOURCE_CONFIG" > "$TARGET_CONFIG"

cp "$SOURCE_SECRET" "$TARGET_SECRET"

echo "Created config/${SETUP}.yml"
echo "Created terraform/secret.${SETUP}.tfvars"
echo "Copied secrets from: ${SOURCE_SECRET}"
echo "Derived domain: ${DOMAIN}"
echo "Derived ip_start_offset: ${IP_OFFSET}"
echo "Next steps:"
echo "  1. Review config/${SETUP}.yml"
echo "  2. Verify terraform/secret.${SETUP}.tfvars"
echo "  3. Run: make plan ${SETUP}"
