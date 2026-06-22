#!/bin/bash
# generate_config.sh - Generate config.yaml from a list of countries.
#
# config.yaml is a generated artifact: re-run this any time to rebuild it from
# the country list. The ONLY state carried across regenerations is each
# namespace's `enabled` flag (so a country you disabled stays disabled). Toggle
# that with `vpn_namespaces.sh enable|disable <id>` rather than editing YAML.
#
# Everything else (id, codes, veth subnets, routing tables, gateways, config
# paths, globals) is derived from the country list + the flags below.
#
# Usage:
#   ./generate_config.sh [options] <country> [<country> ...]
#
# <country> may be:
#   a NordVPN country name   e.g.  Taiwan  South_Korea   (code resolved via API)
#   an ISO-3166 alpha-2 code e.g.  TW  KR                (name resolved via API)
#   an explicit CODE:Name    e.g.  KR:South_Korea        (no network needed)
#
# Options:
#   --out FILE          output path (default: <script dir>/config.yaml; '-' = stdout)
#   --uplink IFACE      uplink interface       (default: auto-detect default route)
#   --lan CIDR          client LAN             (default: auto-detect from uplink)
#   --base-subnet CIDR  first veth /24         (default: 172.30.30.0/24)
#   --base-table N      first routing table/fwmark (default: 100)
#   --keys-dir DIR      WireGuard configs dir  (default: /etc/vpn/keys)
#   --rules-file FILE   steering rules path    (default: /etc/vpn/steering/rules.yaml)
#   --mtu N             tunnel MTU             (default: 1420)
#   --no-clamp-mss      set clamp_mss: false   (default: true)
#   --block-ipv6        set block_ipv6: true   (default: false)
#   --dry-run           print to stdout, don't write or back up

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
OUT="$SCRIPT_DIR/config.yaml"
UPLINK=""
LAN=""
BASE_SUBNET="172.30.30.0/24"
BASE_TABLE=100
KEYS_DIR="/etc/vpn/keys"
RULES_FILE="/etc/vpn/steering/rules.yaml"
MTU=1420
CLAMP_MSS=true
BLOCK_IPV6=false
DRY_RUN=false
TOKENS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)         OUT="$2"; shift 2 ;;
        --uplink)      UPLINK="$2"; shift 2 ;;
        --lan)         LAN="$2"; shift 2 ;;
        --base-subnet) BASE_SUBNET="$2"; shift 2 ;;
        --base-table)  BASE_TABLE="$2"; shift 2 ;;
        --keys-dir)    KEYS_DIR="$2"; shift 2 ;;
        --rules-file)  RULES_FILE="$2"; shift 2 ;;
        --mtu)         MTU="$2"; shift 2 ;;
        --no-clamp-mss) CLAMP_MSS=false; shift ;;
        --block-ipv6)  BLOCK_IPV6=true; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)     sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)            die "unknown option: $1" ;;
        *)             TOKENS+=("$1"); shift ;;
    esac
done

[[ ${#TOKENS[@]} -gt 0 ]] || die "no countries given (try: $0 Taiwan Singapore ...)"
command -v jq >/dev/null 2>&1 || die "jq is required"

# ------------------------------------------------------------------------------
# Host facts (auto-detected unless overridden)
# ------------------------------------------------------------------------------
detect_uplink() {
    ip -o route show default 2>/dev/null \
        | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

detect_lan() {
    local ifc="$1" cidr
    cidr=$(ip -o -f inet addr show "$ifc" 2>/dev/null | awk '{print $4; exit}')
    [[ -n "$cidr" ]] || return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$cidr"
    else
        echo "${cidr%.*}.0/24"   # fallback assumes a /24
    fi
}

[[ -n "$UPLINK" ]] || UPLINK=$(detect_uplink) || true
[[ -n "$UPLINK" ]] || die "could not auto-detect uplink interface (pass --uplink IFACE)"
if [[ -z "$LAN" ]]; then
    LAN=$(detect_lan "$UPLINK") || die "could not auto-detect client LAN (pass --lan CIDR)"
fi

# ------------------------------------------------------------------------------
# Country resolution: name <-> ISO code via NordVPN's own country list.
# Fetched lazily and only if some token isn't already in CODE:Name form.
# ------------------------------------------------------------------------------
COUNTRIES_JSON=""
fetch_countries() {
    [[ -n "$COUNTRIES_JSON" ]] && return 0
    command -v curl >/dev/null 2>&1 || die "curl needed to resolve country codes (or use CODE:Name form)"
    COUNTRIES_JSON=$(curl -s --max-time 15 https://api.nordvpn.com/v1/servers/countries) \
        || die "failed to reach api.nordvpn.com (use CODE:Name form to skip the lookup)"
    [[ -n "$COUNTRIES_JSON" && "$COUNTRIES_JSON" != "null" ]] \
        || die "empty country list from NordVPN API"
}

# Echo "CODE<TAB>Name" (Name with spaces) for one token, or fail.
resolve_token() {
    local tok="$1" code name
    if [[ "$tok" == *:* ]]; then                      # explicit CODE:Name
        code="${tok%%:*}"; name="${tok#*:}"
        printf '%s\t%s\n' "${code^^}" "${name//_/ }"; return 0
    fi
    fetch_countries
    if [[ "$tok" =~ ^[A-Za-z]{2}$ ]]; then            # looks like a code
        jq -er --arg c "${tok^^}" \
            '[.[] | select((.code|ascii_upcase)==$c)][0] | .code + "\t" + .name' \
            <<<"$COUNTRIES_JSON" 2>/dev/null \
            || die "no NordVPN country with code '$tok'"
    else                                              # treat as a name
        jq -er --arg n "${tok//_/ }" \
            '[.[] | select((.name|ascii_downcase)==($n|ascii_downcase))][0] | .code + "\t" + .name' \
            <<<"$COUNTRIES_JSON" 2>/dev/null \
            || die "no NordVPN country named '$tok' (try the ISO code, or CODE:Name)"
    fi
}

# ------------------------------------------------------------------------------
# Preserve `enabled` from an existing config (keyed by id).
# ------------------------------------------------------------------------------
declare -A PREV_ENABLED
if [[ "$OUT" != "-" && -f "$OUT" ]] && command -v yq >/dev/null 2>&1; then
    # `!= false` so a missing/true flag is "true" and only an explicit false is
    # carried as false (yq's `//` treats false as empty, so it can't be used here).
    while read -r pid pen; do
        [[ -n "$pid" ]] && PREV_ENABLED["$pid"]="$pen"
    done < <(yq eval '.namespaces[] | .id + " " + ((.enabled != false) | tostring)' "$OUT" 2>/dev/null || true)
fi

# ------------------------------------------------------------------------------
# Build the namespace entries.
# ------------------------------------------------------------------------------
# Split the base /24 into octets so we can step the third octet per namespace.
base_ip="${BASE_SUBNET%/*}"
IFS=. read -r OCT_A OCT_B OCT_C _ <<<"$base_ip"

namespaces_yaml=""
i=0
declare -A seen_id
for tok in "${TOKENS[@]}"; do
    IFS=$'\t' read -r code name < <(resolve_token "$tok")
    [[ -n "$code" && -n "$name" ]] || die "could not resolve '$tok'"

    id="${code,,}"
    [[ -z "${seen_id[$id]:-}" ]] || die "duplicate country '$code' — each country maps to one namespace"
    seen_id[$id]=1

    # Third octet with carry into the second octet (handles long lists).
    third=$(( OCT_C + i )); b=$(( OCT_B + third / 256 )); c=$(( third % 256 ))
    subnet="${OCT_A}.${b}.${c}.0/24"
    gw_ip="${OCT_A}.${b}.${c}.1"
    host_ip="${OCT_A}.${b}.${c}.2"
    table=$(( BASE_TABLE + i ))
    country="${name// /_}"
    enabled="${PREV_ENABLED[$id]:-true}"

    namespaces_yaml+="  - id: ${id}
    country: ${country}
    expected_country_code: ${code}
    gateway_subnet: ${subnet}
    gateway_ip: ${gw_ip}
    host_veth_ip: ${host_ip}
    routing_table: ${table}
    enabled: ${enabled}
    config_file: ${KEYS_DIR}/${id}.conf

"
    i=$(( i + 1 ))
done

# ------------------------------------------------------------------------------
# Assemble the document.
# ------------------------------------------------------------------------------
read -r -d '' CONFIG <<EOF || true
# /etc/vpn/config.yaml - VPN Namespace Manager Configuration
#
# GENERATED by generate_config.sh — re-run it to rebuild from the country list.
# Don't hand-edit: the only state preserved across regenerations is each
# namespace's \`enabled\` flag. Toggle it with:
#   vpn_namespaces.sh disable <id>   /   vpn_namespaces.sh enable <id>
#
# Generated: $(date '+%Y-%m-%d %H:%M:%S') from: ${TOKENS[*]}

global:
  uplink_iface: ${UPLINK}
  client_lan: ${LAN}
  mtu: ${MTU}
  clamp_mss: ${CLAMP_MSS}

namespaces:
${namespaces_yaml}client_steering:
  rules_file: ${RULES_FILE}
  block_ipv6: ${BLOCK_IPV6}
EOF

# ------------------------------------------------------------------------------
# Output.
# ------------------------------------------------------------------------------
if [[ "$DRY_RUN" == true || "$OUT" == "-" ]]; then
    printf '%s\n' "$CONFIG"
    exit 0
fi

if [[ -f "$OUT" ]]; then
    bak="${OUT}.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$OUT" "$bak"
    echo "[generate] backed up existing config -> $bak" >&2
fi
printf '%s\n' "$CONFIG" > "$OUT"
echo "[generate] wrote $i namespace(s) to $OUT" >&2

# Validate the result if yq is available.
if command -v yq >/dev/null 2>&1; then
    yq eval '.' "$OUT" >/dev/null && echo "[generate] YAML OK" >&2 \
        || die "generated YAML failed to parse: $OUT"
fi
