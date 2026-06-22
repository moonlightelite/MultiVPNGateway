#!/bin/bash
# vpn_namespaces.sh - Set up the per-country VPN tunnel namespaces
# Uses static WireGuard configs - no NordVPN CLI needed!

set -e

CONFIG_FILE="${CONFIG_FILE:-/etc/vpn/config.yaml}"
KEYS_DIR="/etc/vpn/keys"

log() { echo "[VPN-NS] $*"; }

# Region list (ids, routing tables, global LAN, ...) all come from config.yaml —
# the single source of truth — via this helper. NS_IDS is just an alias so the
# existing loops read naturally.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/regions.sh"
if ! regions_load; then
    log "ERROR: could not load regions from config (need yq + $CONFIG_FILE)"
fi
NS_IDS=("${REGION_IDS[@]}")

# Persistent config backup dir, derived at runtime from the invoking user's home
# (override with BACKUP_DIR). default_backup_dir comes from regions.sh.
BACKUP_DIR="${BACKUP_DIR:-$(default_backup_dir)}"

# Verify required tooling is present before doing anything destructive.
# (setup_vpn_host.sh installs these; this is a fast fail-early guard.)
check_deps() {
    local missing=()
    local dep
    for dep in yq jq wg ip iptables; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "ERROR: missing required commands: ${missing[*]}"
        log "Run: sudo bash setup_vpn_host.sh"
        return 1
    fi
    return 0
}

# Get namespace config
get_ns_field() {
    local id="$1" field="$2"
    yq eval ".namespaces[] | select(.id == \"$id\") | .$field" "$CONFIG_FILE" 2>/dev/null
}

# Check if config file exists and has key
check_config() {
    local id="$1"
    local config_file=$(get_ns_field "$id" "config_file")
    
    if [[ ! -f "$config_file" ]]; then
        log "ERROR: Config file not found: $config_file"
        return 1
    fi
    
    if grep -q "YOUR_PRIVATE_KEY" "$config_file"; then
        log "ERROR: Config $config_file needs real WireGuard keys"
        return 1
    fi
    
    if ! wg-quick strip "$config_file" >/dev/null 2>&1; then
        log "ERROR: Invalid WireGuard config: $config_file"
        return 1
    fi
    
    return 0
}

# Create namespace with WireGuard tunnel
create_namespace() {
    local id="$1"
    
    local country=$(get_ns_field "$id" "country")
    local gateway_ip=$(get_ns_field "$id" "gateway_ip")
    local host_veth_ip=$(get_ns_field "$id" "host_veth_ip")
    local routing_table=$(get_ns_field "$id" "routing_table")
    local config_file=$(get_ns_field "$id" "config_file")
    
    local netns="vpn-${id}"
    local veth_host="veth-${id}"
    local veth_ns="veth0"
    local wg_iface="wg-${id}"
    
    log "=== Creating $netns ($country) ==="
    
    # Clean up if exists
    ip netns del "$netns" 2>/dev/null || true
    ip link del "$veth_host" 2>/dev/null || true
    ip link del "$wg_iface" 2>/dev/null || true
    
    # Create namespace
    ip netns add "$netns"
    log "  Created netns: $netns"
    
    # Create veth pair
    ip link add "$veth_host" type veth peer name "$veth_ns"
    ip link set "$veth_ns" netns "$netns"
    
    # Host side IP
    ip addr add "$host_veth_ip/24" dev "$veth_host"
    ip link set "$veth_host" up
    
    # Namespace side IP
    ip netns exec "$netns" ip addr add "$gateway_ip/24" dev "$veth_ns"
    ip netns exec "$netns" ip link set "$veth_ns" up
    ip netns exec "$netns" ip link set lo up
    
    # Create WireGuard interface IN HOST namespace first
    # (socket binds to creating namespace for proper egress)
    ip link add "$wg_iface" type wireguard
    ip link set "$wg_iface" mtu 1420
    
    # Apply WireGuard config in host namespace.
    # Configs are stored in wg-quick format (they carry Address/DNS lines, which
    # `wg setconf` rejects), so strip those keys before loading. Address/DNS are
    # applied separately below / via the netns resolv.conf.
    wg setconf "$wg_iface" <(wg-quick strip "$config_file")
    
    # Get WireGuard IP from config (Address field)
    local wg_ip
    wg_ip=$(grep -i '^Address' "$config_file" 2>/dev/null | cut -d'=' -f2 | tr -d ' ,')
    
    if [[ -n "$wg_ip" ]] && [[ "$wg_ip" != "10.5.0.2/32" ]]; then
        # Config has Address, use it
        local wg_addr="${wg_ip%/*}"
        ip addr add "$wg_addr/32" dev "$wg_iface" 2>/dev/null || true
    fi
    
    ip link set "$wg_iface" up
    
    # Move WireGuard to namespace
    ip link set "$wg_iface" netns "$netns"
    # Moving an interface between netns administratively sets it DOWN, so bring
    # it back up inside the namespace before routing through it. (The config and
    # the underlay socket — bound to the host netns for egress — survive the move.)
    ip netns exec "$netns" ip link set "$wg_iface" up
    log "  WireGuard interface created and moved"

    # Default route through WireGuard
    ip netns exec "$netns" ip route add default dev "$wg_iface"
    
    # LAN return route
    ip netns exec "$netns" ip route add "${REGION_CLIENT_LAN:-192.168.1.0/24}" via "$host_veth_ip" dev "$veth_ns"
    
    # NAT masquerade (inside namespace only)
    ip netns exec "$netns" iptables -t nat -A POSTROUTING -o "$wg_iface" -j MASQUERADE
    ip netns exec "$netns" iptables -A FORWARD -i "$veth_ns" -o "$wg_iface" -j ACCEPT
    ip netns exec "$netns" iptables -A FORWARD -i "$wg_iface" -o "$veth_ns" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    
    # MSS clamping
    ip netns exec "$netns" iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    
    # Routing table for PBR
    ip route replace default via "$gateway_ip" dev "$veth_host" table "$routing_table" || {
        ip route del default table "$routing_table" 2>/dev/null || true
        ip route add default via "$gateway_ip" dev "$veth_host" table "$routing_table"
    }
    
    # IP rule for marked traffic
    local rule_pref=$((1000 + routing_table))
    ip rule del fwmark "$routing_table" lookup "$routing_table" 2>/dev/null || true
    ip rule add fwmark "$routing_table" lookup "$routing_table" priority "$rule_pref"
    
    # DNS
    mkdir -p "/etc/netns/$netns"
    echo "nameserver 1.1.1.1" > "/etc/netns/$netns/resolv.conf"
    
    # Wait for the WireGuard handshake. A freshly (re)started tunnel needs a few
    # seconds; and after a restart NordVPN may briefly reject the new session
    # (new source port) until the previous one expires server-side, so poll and
    # nudge it with traffic rather than checking just once.
    local hs="" status="NO HANDSHAKE YET" i
    for i in $(seq 1 10); do
        ip netns exec "$netns" ping -c1 -W1 1.1.1.1 >/dev/null 2>&1
        hs=$(ip netns exec "$netns" wg show "$wg_iface" latest-handshakes 2>/dev/null | awk '{print $2}')
        if [[ -n "$hs" ]] && [[ "$hs" -gt 0 ]]; then
            status="$(( $(date +%s) - hs ))s ago"
            break
        fi
        sleep 2
    done

    log "  Status: Handshake $status"
    
    # Test geo
    log "  Testing geo location..."
    local geo_result
    geo_result=$(timeout 15 ip netns exec "$netns" curl -s --max-time 10 https://ipinfo.io/json 2>/dev/null || echo '{}')
    local actual_cc=$(echo "$geo_result" | jq -r '.country // "??"' 2>/dev/null)
    local ip=$(echo "$geo_result" | jq -r '.ip // "?"' 2>/dev/null)
    local city=$(echo "$geo_result" | jq -r '.city // "?"' 2>/dev/null)
    
    local expected=$(get_ns_field "$id" "expected_country_code")
    if [[ "$actual_cc" == "$expected" ]]; then
        log "  ✓ Geo: $actual_cc ($city) - IP: $ip"
    else
        log "  ✗ Geo: Expected $expected, got $actual_cc ($city) - IP: $ip"
    fi
    
    log "  $netns is UP"
    return 0
}

destroy_namespace() {
    local id="$1"
    local netns="vpn-${id}"
    local veth_host="veth-${id}"
    local wg_iface="wg-${id}"
    local routing_table=$(get_ns_field "$id" "routing_table")
    
    log "Destroying $netns..."
    
    # Remove routing
    ip route del default table "$routing_table" 2>/dev/null || true
    ip rule del fwmark "$routing_table" lookup "$routing_table" 2>/dev/null || true
    
    # Remove namespace (deletes interfaces inside)
    ip netns del "$netns" 2>/dev/null || true
    
    # Clean up host side
    ip link del "$veth_host" 2>/dev/null || true
    ip link del "$wg_iface" 2>/dev/null || true
    
    rm -rf "/etc/netns/$netns"
    
    log "  $netns destroyed"
}

status_all() {
    echo "=== VPN Namespace Status ==="
    echo ""

    for id in "${NS_IDS[@]}"; do
        local netns="vpn-${id}"
        local country=$(get_ns_field "$id" "country")
        
        if ip netns list 2>/dev/null | grep -q "^${netns}"; then
            echo "✓ $netns ($country)"
            
            local hs=$(ip netns exec "$netns" wg show "wg-${id}" latest-handshakes 2>/dev/null | awk '{print $2}')
            if [[ -n "$hs" ]] && [[ "$hs" -gt 0 ]]; then
                local age=$(( $(date +%s) - hs ))
                echo "    Handshake: ${age}s ago"
                
                # Quick geo check
                local ip=$(timeout 5 ip netns exec "$netns" curl -s --max-time 3 https://api.ip.sb/ip 2>/dev/null || echo "?")
                echo "    Exit IP: $ip"
            else
                echo "    Handshake: Never"
            fi
        else
            echo "✗ $netns ($country) - NOT CREATED"
        fi
    done
    
    echo ""
    echo "=== Routing Tables ==="
    for id in "${NS_IDS[@]}"; do
        local table="${REGION_TABLE[$id]}"
        local routes=$(ip route show table "$table" 2>/dev/null | head -1)
        echo "Table $table ($id): ${routes:-empty}"
    done

    echo ""
    echo "=== IP Rules ==="
    # `ip rule` prints fwmarks in hex (0x64); match both hex and decimal so the
    # table numbers from config line up regardless of iproute2 version.
    local marks=() id m
    for id in "${NS_IDS[@]}"; do
        m="${REGION_TABLE[$id]}"
        marks+=("$m" "0x$(printf '%x' "$m")")
    done
    local re; re=$(IFS='|'; echo "${marks[*]}")
    ip rule list | grep -iE "fwmark (${re:-none})" || echo "(none)"
}

# Copy active configs to the persistent backup dir (survives VM reset).
backup_configs() {
    mkdir -p "$BACKUP_DIR"
    if ! ls "$KEYS_DIR"/*.conf >/dev/null 2>&1; then
        log "ERROR: no configs in $KEYS_DIR to back up"
        return 1
    fi
    cp "$KEYS_DIR"/*.conf "$BACKUP_DIR/"
    chmod 600 "$BACKUP_DIR"/*.conf 2>/dev/null || true
    log "✓ Backed up $(ls "$KEYS_DIR"/*.conf | wc -l) config(s) to $BACKUP_DIR"
}

# Restore configs from the persistent backup dir into the active keys dir.
restore_configs() {
    if ! ls "$BACKUP_DIR"/*.conf >/dev/null 2>&1; then
        log "ERROR: no backup configs in $BACKUP_DIR"
        return 1
    fi
    mkdir -p "$KEYS_DIR"
    cp "$BACKUP_DIR"/*.conf "$KEYS_DIR/"
    chmod 600 "$KEYS_DIR"/*.conf 2>/dev/null || true
    log "✓ Restored $(ls "$BACKUP_DIR"/*.conf | wc -l) config(s) to $KEYS_DIR"
}

# Toggle a namespace's `enabled` flag in config.yaml. This is the one piece of
# state generate_config.sh preserves across regenerations, so flip it here rather
# than hand-editing YAML. Disabling also tears down the live namespace; the next
# `up` (and boot) skips it because regions_load filters on enabled.
set_enabled() {
    local id="$1" val="$2"
    if [[ -z "$id" ]]; then
        log "ERROR: usage: $0 ${val/false/disable}${val/true/enable} <id>"; return 1
    fi
    local exists
    exists=$(yq eval ".namespaces[] | select(.id == \"$id\") | .id" "$CONFIG_FILE" 2>/dev/null)
    if [[ -z "$exists" || "$exists" == "null" ]]; then
        log "ERROR: no namespace '$id' in $CONFIG_FILE"; return 1
    fi
    yq eval -i "(.namespaces[] | select(.id == \"$id\") | .enabled) = $val" "$CONFIG_FILE"
    log "✓ set $id enabled=$val in $CONFIG_FILE"
    if [[ "$val" == "false" ]]; then
        destroy_namespace "$id" 2>/dev/null || true
        log "  (tore down vpn-$id; it is skipped until re-enabled)"
    else
        log "  run: $0 up $id"
    fi
}

# Validate that each managed namespace is actually live: the netns exists and
# its WireGuard interface is present. Returns non-zero if anything is missing,
# so callers can decide whether to (re)build.
validate_all() {
    local ok=0 bad=0 id
    for id in "${NS_IDS[@]}"; do
        local netns="vpn-${id}" wg_iface="wg-${id}"
        if ! ip netns list 2>/dev/null | grep -q "^${netns}\b"; then
            log "✗ $netns: namespace missing"
            bad=$((bad + 1)); continue
        fi
        if ! ip netns exec "$netns" ip link show "$wg_iface" >/dev/null 2>&1; then
            log "✗ $netns: WireGuard interface $wg_iface missing"
            bad=$((bad + 1)); continue
        fi
        log "✓ $netns: healthy"
        ok=$((ok + 1))
    done
    log "Validation: $ok healthy, $bad unhealthy"
    [[ $bad -eq 0 ]]
}

# ------------------------------------------------------------------------------
# Client steering (policy-based routing)
#
# A client LAN host (gateway = this host) is steered to a namespace by marking
# its packets in mangle PREROUTING with that namespace's routing_table number.
# The fwmark ip rule (installed by create_namespace) then selects table 10x,
# whose default route points at the namespace's veth gateway.
#
# All marks live in a dedicated VPN_STEER chain so they can be listed/flushed
# without touching anything else in mangle PREROUTING.
# ------------------------------------------------------------------------------
STEER_CHAIN="VPN_STEER"

steering_ensure_chain() {
    iptables -t mangle -N "$STEER_CHAIN" 2>/dev/null || true
    if ! iptables -t mangle -C PREROUTING -j "$STEER_CHAIN" 2>/dev/null; then
        iptables -t mangle -A PREROUTING -j "$STEER_CHAIN"
    fi
}

# Delete every existing mark for a client (keeps add/remove idempotent).
steering_del_client() {
    local client="$1" rule
    while rule=$(iptables -t mangle -S "$STEER_CHAIN" 2>/dev/null | grep -m1 -- "-s ${client}/32 "); do
        [[ -z "$rule" ]] && break
        # shellcheck disable=SC2086
        iptables -t mangle ${rule/-A/-D}
    done
}

steering_add() {
    local client="$1" id="$2"
    if [[ -z "$client" || -z "$id" ]]; then
        log "ERROR: usage: steering add <client_ip> <namespace_id>"; return 1
    fi
    local mark
    mark=$(get_ns_field "$id" "routing_table")
    if [[ -z "$mark" || "$mark" == "null" ]]; then
        log "ERROR: unknown namespace id '$id' (not in $CONFIG_FILE)"; return 1
    fi
    # Don't steer clients into a disabled namespace — its routing table is gone,
    # so marked packets would fall through to the host's normal exit.
    if [[ "$(get_ns_field "$id" "enabled")" == "false" ]]; then
        log "skip steering: $client -> $id (namespace disabled)"; return 1
    fi
    steering_ensure_chain
    steering_del_client "$client"
    iptables -t mangle -A "$STEER_CHAIN" -s "$client" -j MARK --set-mark "$mark"
    log "✓ steering: $client -> vpn-$id (mark $mark)"
}

steering_remove() {
    local client="$1"
    [[ -z "$client" ]] && { log "ERROR: usage: steering remove <client_ip>"; return 1; }
    steering_ensure_chain
    steering_del_client "$client"
    log "✓ removed steering for $client"
}

steering_clear() {
    iptables -t mangle -F "$STEER_CHAIN" 2>/dev/null || true
    log "✓ cleared all steering marks"
}

steering_list() {
    steering_ensure_chain
    echo "=== Steering marks (mangle $STEER_CHAIN) ==="
    iptables -t mangle -S "$STEER_CHAIN" | grep -- '-s ' || echo "(none)"
}

# Apply all enabled rules from the steering rules file (declarative).
steering_apply() {
    local rules_file
    rules_file=$(yq eval '.client_steering.rules_file' "$CONFIG_FILE" 2>/dev/null)
    [[ -z "$rules_file" || "$rules_file" == "null" ]] && rules_file="/etc/vpn/steering/rules.yaml"
    if [[ ! -f "$rules_file" ]]; then
        log "ERROR: rules file not found: $rules_file"; return 1
    fi
    steering_ensure_chain
    steering_clear
    local count i=0
    count=$(yq eval '.rules | length' "$rules_file")
    while [[ $i -lt $count ]]; do
        local client id enabled
        client=$(yq eval ".rules[$i].client" "$rules_file")
        id=$(yq eval ".rules[$i].namespace" "$rules_file")
        enabled=$(yq eval ".rules[$i].enabled" "$rules_file")
        if [[ "$enabled" == "true" ]]; then
            steering_add "$client" "$id" || log "  (skipped $client -> $id)"
        else
            log "skip (disabled): $client -> $id"
        fi
        i=$((i + 1))
    done
    log "✓ applied steering rules from $rules_file"
}

# Main command
case "${1:-status}" in
    up)
        check_deps || exit 1
        if [[ -n "$2" ]]; then
            create_namespace "$2"
        else
            for id in "${NS_IDS[@]}"; do
                if ! check_config "$id"; then
                    log "Skipping $id due to config error"
                    continue
                fi
                create_namespace "$id" || log "Failed to create $id"
            done
            # Apply client steering after a full bring-up so the system is
            # functional end-to-end (also covers boot via the systemd service).
            steering_apply || log "steering apply skipped (no rules / error)"
        fi
        ;;
    down)
        if [[ -n "$2" ]]; then
            destroy_namespace "$2"
        else
            for id in "${NS_IDS[@]}"; do
                destroy_namespace "$id" 2>/dev/null || true
            done
        fi
        ;;
    status)
        status_all
        ;;
    validate)
        validate_all
        ;;
    enable)
        check_deps || exit 1
        set_enabled "$2" true
        ;;
    disable)
        check_deps || exit 1
        set_enabled "$2" false
        ;;
    backup)
        backup_configs
        ;;
    restore)
        restore_configs
        ;;
    steering)
        check_deps || exit 1
        case "${2:-list}" in
            apply)  steering_apply ;;
            add)    steering_add "$3" "$4" ;;
            remove) steering_remove "$3" ;;
            clear)  steering_clear ;;
            list)   steering_list ;;
            *) echo "Usage: $0 steering {apply|add <client> <id>|remove <client>|clear|list}"; exit 1 ;;
        esac
        ;;
    *)
        echo "Usage: $0 {up [id]|down [id]|status|validate|enable <id>|disable <id>|backup|restore|steering ...}"
        echo ""
        echo "Commands:"
        echo "  up        - Create all namespaces (or specific: up ${NS_IDS[0]:-<id>})"
        echo "  down      - Destroy all namespaces (or specific: down ${NS_IDS[0]:-<id>})"
        echo "  status    - Show status of all namespaces"
        echo "  validate  - Check each namespace + WireGuard interface is live"
        echo "  enable    - Mark a namespace enabled in config (enable <id>)"
        echo "  disable   - Mark a namespace disabled + tear it down (disable <id>)"
        echo "  backup    - Copy active configs to the persistent backup dir"
        echo "  restore   - Restore configs from the persistent backup dir"
        echo "  steering  - Manage client steering: apply | add <client> <id> |"
        echo "              remove <client> | clear | list"
        exit 1
        ;;
esac
