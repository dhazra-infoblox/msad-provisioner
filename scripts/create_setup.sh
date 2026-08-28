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
PREFIX="${PREFIX:-}"

# Windows caps a computer (NetBIOS) name at 15 characters. Terraform enforces
# this at plan time too; catching it here means a bad setup is never scaffolded.
HOSTNAME_MAX_LENGTH=15

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

# Derive a short host-name prefix from the setup name. The abbreviation grows
# with the input: 2 characters up to a 6-character name, 3 up to 9, 4 up to 12 —
# one character per 3 characters of input. The name is split into that many
# chunks and the first letter of each is taken, so:
#
#   stgwin       → sw    (stg|win)
#   nstarqa      → nar   (nst|ar|qa)
#   b1ddimigrate → bdia  (b1d|dim|igr|ate)
#
# Names under 6 characters are already short enough to use whole (hari → hari).
# Pass PREFIX=<value> to override the derivation entirely.
derive_prefix() {
  local name len chunks base rem pos size i out=""

  name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')"
  len=${#name}

  if [ "$len" -lt 6 ]; then
    printf '%s' "$name"
    return
  fi

  chunks=$(((len + 2) / 3))
  base=$((len / chunks))
  rem=$((len % chunks))
  pos=0

  for ((i = 0; i < chunks; i++)); do
    size=$base
    [ "$i" -lt "$rem" ] && size=$((size + 1))
    out="${out}${name:$pos:1}"
    pos=$((pos + size))
  done

  printf '%s' "$out"
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

if [ -z "$PREFIX" ]; then
  PREFIX="$(derive_prefix "$SETUP")"
fi
[ -n "$PREFIX" ] || fail "Could not derive a host prefix from SETUP=$SETUP — pass PREFIX=<short-name>"
[[ "$PREFIX" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] \
  || fail "PREFIX must be letters, digits and inner hyphens only, got: $PREFIX"

# '<prefix>-srv01' is the longest name this script generates, so checking the
# prefix budget up front beats scaffolding a config that cannot be applied.
prefix_budget=$((HOSTNAME_MAX_LENGTH - 6))
[ "${#PREFIX}" -le "$prefix_budget" ] \
  || fail "PREFIX '$PREFIX' is ${#PREFIX} chars; max $prefix_budget so that <prefix>-srv01 fits the $HOSTNAME_MAX_LENGTH-char Windows computer name limit"

if [ -z "$NAME_PREFIX" ]; then
  NAME_PREFIX="${SETUP}_msad"
fi

TARGET_CONFIG="$ROOT_DIR/config/${SETUP}.yml"
TARGET_SECRET="$ROOT_DIR/terraform/secret.${SETUP}.tfvars"

[ ! -e "$TARGET_CONFIG" ] || fail "Target config already exists: $TARGET_CONFIG"
[ ! -e "$TARGET_SECRET" ] || fail "Target secret already exists: $TARGET_SECRET"

# The bootstrap host becomes the first domain controller, so it is named dcNN
# with role dc whatever the source config called it. Its name is needed before
# rendering because `bootstrap: true` appears after the name and role lines.
bootstrap_src=$(awk '
  /^hosts:/ { in_hosts = 1; next }
  in_hosts && /^[^[:space:]]/ { in_hosts = 0 }
  !in_hosts { next }
  /^[[:space:]]*-[[:space:]]*name:/ {
    name = $0
    sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", name)
    gsub(/[[:space:]]+$/, "", name)
  }
  /^[[:space:]]*bootstrap:[[:space:]]*true/ { print name; exit }
' "$SOURCE_CONFIG")

awk \
  -v prefix="$PREFIX" \
  -v bootstrap_src="$bootstrap_src" \
  -v domain="$DOMAIN" \
  -v netbios="$NETBIOS" \
  -v name_prefix="$NAME_PREFIX" \
  -v ip_offset="$IP_OFFSET" '
function trim_left(value) {
  sub(/^[[:space:]]+/, "", value)
  return value
}
# Reduce a source host name to "<prefix>-<suffix>", keeping only the last
# dash-separated segment so a name already scoped to another setup does not
# accumulate prefixes. Legacy service-specific suffixes are mapped to the
# generic forms: dhcp01 → srv01, client01 → clt01.
function render_host_name(original, normalized, parts, count, base) {
  if (original == bootstrap_src) { return prefix "-dc01" }
  normalized = original
  gsub(/_/, "-", normalized)
  count = split(normalized, parts, "-")
  base = parts[count]
  sub(/^dhcp/, "srv", base)
  sub(/^client/, "clt", base)
  return prefix "-" base
}
# Role names are the short generic forms; the long ones are legacy aliases.
function render_role(original, role) {
  if (current_src == bootstrap_src) { return "dc" }
  role = trim_left(original)
  if (role == "dhcp_server") { return "srv" }
  if (role == "agent_client") { return "clt" }
  if (role == "domain_controller") { return "dc" }
  return role
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
    current_src = host
    print "  - name: " render_host_name(host)
    next
  }

  if (section == "hosts" && $0 ~ /^[[:space:]]+role:/) {
    role_value = $0
    sub(/^[[:space:]]+role:[[:space:]]*/, "", role_value)
    print "    role: " render_role(role_value)
    next
  }

  # Never inherit pinned IPs: they belong to the source setup and would collide
  # on apply. The new setup auto-assigns from its own ip_start_offset instead.
  if (section == "hosts" && $0 ~ /^[[:space:]]+ip:/) {
    next
  }

  print
}
' "$SOURCE_CONFIG" > "$TARGET_CONFIG"

# Final guards: the source config may carry suffixes longer than the dc01/srv01/
# clt01 forms this script assumes, or names that collapse into a duplicate once
# the bootstrap host is renamed. Measure what was actually written.
generated_names=$(awk '
  /^hosts:/ { in_hosts=1; next }
  in_hosts && /^[^[:space:]]/ { in_hosts=0 }
  in_hosts && $1 == "-" && $2 == "name:" { print $3 }
' "$TARGET_CONFIG")

too_long=$(awk -v max="$HOSTNAME_MAX_LENGTH" 'length($0) > max { print $0 " (" length($0) " chars)" }' <<< "$generated_names")

if [ -n "$too_long" ]; then
  rm -f "$TARGET_CONFIG"
  fail "Generated host name(s) exceed the $HOSTNAME_MAX_LENGTH-char Windows computer name limit:
$too_long
Pass a shorter PREFIX= or trim the host suffixes in $SOURCE_CONFIG"
fi

duplicates=$(sort <<< "$generated_names" | uniq -d)

if [ -n "$duplicates" ]; then
  rm -f "$TARGET_CONFIG"
  fail "Generated host name(s) are not unique:
$duplicates
Rename the conflicting hosts in $SOURCE_CONFIG"
fi

cp "$SOURCE_SECRET" "$TARGET_SECRET"

echo "Created config/${SETUP}.yml"
echo "Created terraform/secret.${SETUP}.tfvars"
echo "Copied secrets from: ${SOURCE_SECRET}"
echo "Derived domain: ${DOMAIN}"
echo "Derived host prefix: ${PREFIX} (e.g. ${PREFIX}-dc01, ${PREFIX}-srv01, ${PREFIX}-clt01)"
echo "Derived ip_start_offset: ${IP_OFFSET}"
echo "Next steps:"
echo "  1. Review config/${SETUP}.yml"
echo "  2. Verify terraform/secret.${SETUP}.tfvars"
echo "  3. Run: make plan ${SETUP}"
