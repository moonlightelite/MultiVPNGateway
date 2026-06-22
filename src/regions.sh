# regions.sh - Single source of truth for the VPN region list.
#
# This is a *sourceable* helper (not executable on its own). It reads the region
# definitions from config.yaml so that no script has to hardcode the country
# list. config.yaml is the one place regions are defined; every script derives
# its list from here via `regions_load`.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/regions.sh"
#   regions_load || exit 1
#   for id in "${REGION_IDS[@]}"; do
#       echo "$id -> ${REGION_COUNTRY[$id]} (${REGION_CODE[$id]})"
#   done
#
# After regions_load these are populated (enabled namespaces only, in file order):
#   REGION_IDS            ordered array of ids        e.g. (tw sg nl kr jp)
#   REGION_COUNTRY[id]    NordVPN connect name        e.g. South_Korea
#   REGION_CODE[id]       ISO country code            e.g. KR
#   REGION_TABLE[id]      policy-routing table        e.g. 103
#   REGION_CONFIG[id]     WireGuard config path       e.g. /etc/vpn/keys/kr.conf
#   REGION_CLIENT_LAN     global.client_lan           e.g. 192.168.1.0/24
#   REGION_UPLINK         global.uplink_iface         e.g. ens18
#   REGION_MTU            global.mtu                  e.g. 1420
#   REGIONS_CONFIG_FILE   the config.yaml that was read

# Always defined, so callers can reference them even if regions_load fails.
REGION_IDS=()
declare -gA REGION_COUNTRY REGION_CODE REGION_TABLE REGION_CONFIG 2>/dev/null || true

# Persistent backup dir for WireGuard configs, computed at runtime from the
# invoking (sudo) user's home so nothing hardcodes a specific user. Override with
# the BACKUP_DIR env var.
default_backup_dir() {
    local home=""
    if [[ -n "${SUDO_USER:-}" ]]; then
        home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    fi
    [[ -z "$home" ]] && home="${HOME:-/root}"
    printf '%s/wireguard_configs_backup\n' "$home"
}

# Directory holding this file; config.yaml is installed alongside it (true in the
# repo's src/ and on the host at /etc/vpn/), which is what makes co-location work.
_REGIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Locate config.yaml: explicit $CONFIG_FILE first, then next to this script,
# then the installed location.
_regions_find_config() {
    local c
    for c in "${CONFIG_FILE:-}" "$_REGIONS_DIR/config.yaml" /etc/vpn/config.yaml; do
        if [[ -n "$c" && -f "$c" ]]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

# Populate the REGION_* variables from config.yaml. Returns non-zero (with a
# message on stderr) if yq is missing, the config can't be found, or no region
# is enabled.
regions_load() {
    if ! command -v yq >/dev/null 2>&1; then
        echo "[regions] ERROR: yq not found (needed to read config.yaml)" >&2
        return 1
    fi

    local cfg
    if ! cfg=$(_regions_find_config); then
        echo "[regions] ERROR: cannot locate config.yaml (set CONFIG_FILE to override)" >&2
        return 1
    fi
    REGIONS_CONFIG_FILE="$cfg"

    REGION_IDS=()
    declare -gA REGION_COUNTRY REGION_CODE REGION_TABLE REGION_CONFIG

    local id
    while IFS= read -r id; do
        [[ -z "$id" || "$id" == "null" ]] && continue
        REGION_IDS+=("$id")
        REGION_COUNTRY["$id"]=$(yq eval ".namespaces[] | select(.id == \"$id\") | .country" "$cfg")
        REGION_CODE["$id"]=$(yq eval ".namespaces[] | select(.id == \"$id\") | .expected_country_code" "$cfg")
        REGION_TABLE["$id"]=$(yq eval ".namespaces[] | select(.id == \"$id\") | .routing_table" "$cfg")
        REGION_CONFIG["$id"]=$(yq eval ".namespaces[] | select(.id == \"$id\") | .config_file" "$cfg")
    done < <(yq eval '.namespaces[] | select(.enabled != false) | .id' "$cfg")

    # Global network settings (best-effort; blank if unset).
    REGION_CLIENT_LAN=$(yq eval '.global.client_lan // ""' "$cfg")
    REGION_UPLINK=$(yq eval '.global.uplink_iface // ""' "$cfg")
    REGION_MTU=$(yq eval '.global.mtu // ""' "$cfg")

    if [[ ${#REGION_IDS[@]} -eq 0 ]]; then
        echo "[regions] ERROR: no enabled namespaces in $cfg" >&2
        return 1
    fi
    return 0
}
