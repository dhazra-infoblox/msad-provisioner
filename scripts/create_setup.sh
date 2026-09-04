#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Scaffold from config/template.yml when it exists. config/environment.yml is the
# *default setup's* config, not a template — it describes running infrastructure,
# so its AMI and subnet drift out of date and editing them to suit new setups
# would force every instance in that setup to be replaced.
if [ -z "${SOURCE_CONFIG:-}" ] && [ -f "$ROOT_DIR/config/template.yml" ]; then
  SOURCE_CONFIG="$ROOT_DIR/config/template.yml"
fi
SOURCE_CONFIG="${SOURCE_CONFIG:-$ROOT_DIR/config/environment.yml}"
SOURCE_SECRET="${SOURCE_SECRET:-$ROOT_DIR/terraform/secret.tfvars}"
SETUP="${SETUP:-}"
DOMAIN="${DOMAIN:-}"
IP_OFFSET="${IP_OFFSET:-}"
NETBIOS="${NETBIOS:-}"
NAME_PREFIX="${NAME_PREFIX:-}"
PREFIX="${PREFIX:-}"
DCS="${DCS:-}"
SERVERS="${SERVERS:-}"
CLIENTS="${CLIENTS:-}"

# Windows caps a computer (NetBIOS) name at 15 characters. Terraform enforces
# this at plan time too; catching it here means a bad setup is never scaffolded.
HOSTNAME_MAX_LENGTH=15

# Auto-assignment starts at .10 — the low addresses are the AWS-reserved ones
# plus a little headroom — and the last index Terraform will hand out of a /24
# is .253. Larger subnets have more room, but the offset is only ever derived
# here; Terraform validates it against the real subnet mask at plan time, so
# assuming the smallest subnet in use keeps this from generating an offset that
# cannot be planned.
IP_OFFSET_MIN=10
IP_OFFSET_MAX=253
IP_OFFSET_GAP=10

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# Count the hosts in a config file.
host_count() {
  awk '
    /^hosts:/ { in_hosts=1; next }
    in_hosts && /^[^[:space:]]/ { in_hosts=0 }
    in_hosts && /^[[:space:]]*-[[:space:]]*name:/ { count++ }
    END { print count + 0 }
  ' "$1"
}

# Read aws.subnet_id out of a config file.
config_subnet_id() {
  awk '
    /^aws:/ { in_aws=1; next }
    in_aws && /^[^[:space:]]/ { in_aws=0 }
    in_aws && $1 == "subnet_id:" { print $2; exit }
  ' "$1"
}

# Pick a starting offset for a setup of $2 hosts landing in subnet $1.
#
# Only setups sharing that subnet can collide, so configs pointing elsewhere are
# skipped — counting them made the address space look far more crowded than it
# was and pushed new setups off the end of it.
#
# Placement fills the first gap wide enough for the new setup rather than always
# appending past the highest range in use. Appending is what produced offsets
# beyond the subnet once the setups above added up to more than a /24: setups
# are deleted as often as they are created, so the space below the watermark is
# mostly free.
next_ip_offset() {
  local subnet="$1" need="$2"
  local f offset count cursor start end

  # Each setup reserves [offset, offset + host count), and setups are kept
  # IP_OFFSET_GAP apart so either side can grow a little without a re-plan.
  local blocks=()

  for f in "$ROOT_DIR"/config/*.yml; do
    [ -e "$f" ] || continue
    [ "$(config_subnet_id "$f")" = "$subnet" ] || continue

    offset=$(awk '
      /^network:/ { in_network=1; next }
      in_network && /^[^[:space:]]/ { in_network=0 }
      in_network && $1 == "ip_start_offset:" { print $2; exit }
    ' "$f")
    [[ "$offset" =~ ^[0-9]+$ ]] || continue

    count=$(host_count "$f")
    blocks+=("$offset $((offset + count))")
  done

  cursor=$IP_OFFSET_MIN

  while read -r start end; do
    [ -n "$start" ] || continue
    # Fits in the gap before this block, gap included.
    [ $((cursor + need + IP_OFFSET_GAP)) -le "$start" ] && break
    [ $((end + IP_OFFSET_GAP)) -gt "$cursor" ] && cursor=$((end + IP_OFFSET_GAP))
  done < <(printf '%s\n' "${blocks[@]+"${blocks[@]}"}" | sort -n)
  
  [ $((cursor + need - 1)) -le "$IP_OFFSET_MAX" ] \
    || fail "No free range of $need addresses left in $subnet below index $IP_OFFSET_MAX.
Delete a setup that is no longer in use, pass IP_OFFSET=<n> to place this one by hand, or point SOURCE_CONFIG at a config in another subnet"

  echo "$cursor"
}

# Emit "role<TAB>instance_type<TAB>disk_gb" for every host in a config, so a
# generated setup inherits sizing from the source rather than hardcoding it.
role_sizing() {
  awk '
    function value(line) {
      sub(/^[^:]*:[[:space:]]*/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      return line
    }
    function normalize(r) {
      if (r == "dhcp_server") { return "srv" }
      if (r == "agent_client") { return "clt" }
      if (r == "domain_controller") { return "dc" }
      return r
    }
    # The bootstrap host is a domain controller in fact, whatever the source
    # config calls it — the host transform below rewrites it to dc, so the
    # sizing lookup has to agree or a dc count of 0 falls out of a config whose
    # bootstrap host is still declared srv.
    function emit() { if (seen) { print (boot ? "dc" : normalize(role)) "\t" itype "\t" disk } }
    /^hosts:/ { in_hosts=1; next }
    in_hosts && /^[^[:space:]]/ { in_hosts=0 }
    !in_hosts { next }
    /^[[:space:]]*-[[:space:]]*name:/ { emit(); seen=1; role=""; itype=""; disk=""; boot=0; next }
    /^[[:space:]]*bootstrap:[[:space:]]*true/ { boot=1; next }
    /^[[:space:]]*role:/ { role = value($0); next }
    /^[[:space:]]*instance_type:/ { itype = value($0); next }
    /^[[:space:]]*disk_gb:/ { disk = value($0); next }
    END { emit() }
  ' "$1"
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

# Host counts. Passing any of DCS/SERVERS/CLIENTS switches from "mirror the
# source config's host list" to "generate this many hosts per role"; the ones
# left unset fall back to however many the source config has.
GENERATE_HOSTS=0
if [ -n "$DCS" ] || [ -n "$SERVERS" ] || [ -n "$CLIENTS" ]; then
  GENERATE_HOSTS=1

  source_sizing="$(role_sizing "$SOURCE_CONFIG")"

  count_role() { grep -c "^$1	" <<< "$source_sizing" || true; }
  # SERVERS is the number of server machines in total. DCS says how many of them
  # are domain controllers, so the two do not add up: a dc host runs DNS and DHCP
  # exactly like an srv host, it is just also promoted.
  [ -n "$DCS" ]     || DCS="$(count_role dc)"
  [ -n "$SERVERS" ] || SERVERS="$(( $(count_role dc) + $(count_role srv) ))"
  [ -n "$CLIENTS" ] || CLIENTS="$(count_role clt)"

  for pair in "DCS:$DCS" "SERVERS:$SERVERS" "CLIENTS:$CLIENTS"; do
    name="${pair%%:*}"
    value="${pair#*:}"
    [[ "$value" =~ ^[0-9]+$ ]] || fail "$name must be a number, got: $value"
    # Two digits is all the <prefix>-srvNN form has room for once the 15-char
    # computer name limit and the prefix budget are accounted for.
    [ "$value" -le 99 ] || fail "$name must be 99 or fewer, got: $value"
  done

  [ "$DCS" -ge 1 ] || fail "DCS must be at least 1 — the bootstrap host is a domain controller"
  [ "$DCS" -le "$SERVERS" ] \
    || fail "DCS ($DCS) cannot exceed SERVERS ($SERVERS) — domain controllers are server machines, so SERVERS counts them"

  # Whatever is left over after the domain controllers runs as a plain member
  # server.
  MEMBER_SERVERS=$((SERVERS - DCS))

  # Sizing for each generated role comes from the first host of that role in the
  # source config, so instance types stay defined in one place.
  sizing_for() {
    local role="$1" field="$2"
    awk -F'\t' -v want="$role" -v field="$field" '
      $1 == want && $field != "" { print $field; exit }
    ' <<< "$source_sizing"
  }
fi

# Derived here rather than with the other defaults above because the gap it has
# to fit in depends on how many hosts the setup ends up with.
if [ -z "$IP_OFFSET" ]; then
  if [ "$GENERATE_HOSTS" = 1 ]; then
    ip_offset_hosts=$((SERVERS + CLIENTS))
  else
    ip_offset_hosts=$(host_count "$SOURCE_CONFIG")
  fi

  source_subnet="$(config_subnet_id "$SOURCE_CONFIG")"
  [ -n "$source_subnet" ] || fail "No aws.subnet_id in $SOURCE_CONFIG — pass IP_OFFSET=<n>"

  IP_OFFSET="$(next_ip_offset "$source_subnet" "$ip_offset_hosts")"
fi
[[ "$IP_OFFSET" =~ ^[0-9]+$ ]] || fail "IP_OFFSET must be a number"
[ "$IP_OFFSET" -ge 2 ] || fail "IP_OFFSET must be >= 2"
[ "$IP_OFFSET" -le "$IP_OFFSET_MAX" ] \
  || fail "IP_OFFSET must be <= $IP_OFFSET_MAX to stay inside a /24"

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

if [ "$GENERATE_HOSTS" = 1 ]; then
  # Keep everything the transform produced down to the `hosts:` key — including
  # the role documentation above it — and replace the host list itself.
  awk '/^hosts:/ { print; exit } { print }' "$TARGET_CONFIG" > "$TARGET_CONFIG.tmp"

  emit_host() {
    local name="$1" role="$2" bootstrap="$3" itype disk
    itype="$(sizing_for "$role" 2)"
    disk="$(sizing_for "$role" 3)"

    printf '  - name: %s\n    role: %s\n' "$name" "$role"
    [ "$bootstrap" = "yes" ] && printf '    bootstrap: true\n'
    [ -n "$itype" ] && printf '    instance_type: %s\n' "$itype"
    [ -n "$disk" ] && printf '    disk_gb: %s\n' "$disk"
    return 0
  }

  {
    for ((i = 1; i <= DCS; i++)); do
      if [ "$i" -eq 1 ]; then
        emit_host "$(printf '%s-dc%02d' "$PREFIX" "$i")" dc yes
      else
        emit_host "$(printf '%s-dc%02d' "$PREFIX" "$i")" dc no
      fi
    done
    for ((i = 1; i <= MEMBER_SERVERS; i++)); do
      emit_host "$(printf '%s-srv%02d' "$PREFIX" "$i")" srv no
    done
    for ((i = 1; i <= CLIENTS; i++)); do
      emit_host "$(printf '%s-clt%02d' "$PREFIX" "$i")" clt no
    done
  } >> "$TARGET_CONFIG.tmp"

  mv "$TARGET_CONFIG.tmp" "$TARGET_CONFIG"
fi

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
if [ "$GENERATE_HOSTS" = 1 ]; then
  echo "Generated hosts: ${SERVERS} servers (${DCS} dc + ${MEMBER_SERVERS} srv) + ${CLIENTS} clt = $((SERVERS + CLIENTS)) instances"
fi
echo "Derived ip_start_offset: ${IP_OFFSET}"
echo "Next steps:"
echo "  1. Review config/${SETUP}.yml"
echo "  2. Verify terraform/secret.${SETUP}.tfvars"
echo "  3. Run: make plan ${SETUP}"
