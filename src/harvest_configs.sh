#!/bin/bash
# harvest_configs.sh - Automatically harvest WireGuard configs from NordVPN
# This script connects to each country, extracts the WireGuard config, and saves it.
# IMPORTANT: Firewall and killswitch are disabled to prevent SSH lockout.

set -e

KEYS_DIR="/etc/vpn/keys"

log() { echo "[HARVEST] $*"; }

# Region list comes from config.yaml (single source of truth) via regions.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/regions.sh"

# Ensure NordVPN is configured safely (no firewall!)
setup_safe_mode() {
    log "Setting up NordVPN in safe mode (firewall disabled)..."
    
    # Disable NordVPN firewall to prevent SSH lockout
    nordvpn set firewall disabled >/dev/null 2>&1 || true
    nordvpn set killswitch disabled >/dev/null 2>&1 || true
    nordvpn set technology nordlynx >/dev/null 2>&1 || true
    
    # Verify settings
    local fw=$(nordvpn settings 2>/dev/null | grep '^Firewall:' | awk '{print $2}')
    if [[ "$fw" == "enabled" ]]; then
        log "ERROR: NordVPN firewall is still enabled! This could lock us out."
        log "Run: nordvpn set firewall disabled"
        exit 1
    fi
    
    log "Safe mode confirmed: Firewall=$fw"
}

disconnect() {
    nordvpn disconnect >/dev/null 2>&1 || true
    sleep 2
    # Wait for interface to fully clean up
    while ip link show nordlynx >/dev/null 2>&1; do
        sleep 1
    done
    sleep 1
}

harvest_country() {
    local id="$1"
    local country="$2"
    local config_file="$KEYS_DIR/${id}.conf"
    
    log "=== Harvesting: $country ($id) ==="
    
    # Disconnect any existing connection
    disconnect
    
    # Connect
    log "Connecting to $country..."
    if ! timeout 45 nordvpn connect "$country" >/dev/null 2>&1; then
        log "ERROR: Failed to connect to $country"
        nordvpn disconnect >/dev/null 2>&1 || true
        return 1
    fi
    
    log "Connected!"
    
    # Wait for tunnel to stabilize
    sleep 3
    
    # Get external IP and verify we're connected
    local ext_ip geo
    ext_ip=$(curl -s --max-time 5 https://api.ip.sb/ip 2>/dev/null || echo "unknown")
    geo=$(curl -s --max-time 5 https://ipinfo.io/json 2>/dev/null | jq -r '.country // "?"' 2>/dev/null)
    
    log "Exit IP: $ext_ip (Geo: $geo)"
    
    # Harvest WireGuard config
    if ! sudo wg showconf nordlynx >/dev/null 2>&1; then
        log "ERROR: Cannot read WireGuard config from nordlynx interface"
        disconnect
        return 1
    fi
    
    local raw_config
    raw_config=$(sudo wg showconf nordlynx)
    
    # Extract values
    local priv pub endpoint
    priv=$(echo "$raw_config" | grep '^PrivateKey' | cut -d'=' -f2 | tr -d ' ')
    pub=$(echo "$raw_config" | grep '^PublicKey' | cut -d'=' -f2 | tr -d ' ')
    endpoint=$(echo "$raw_config" | grep '^Endpoint' | cut -d'=' -f2 | tr -d ' ')
    
    # Get WireGuard IP from interface
    local wg_ip
    wg_ip=$(ip -j addr show nordlynx 2>/dev/null | jq -r '.[0].addr_info[] | select(.family=="inet") | .local' | head -1)
    
    # Fix base64 padding (NordVPN sometimes omits it)
    while [[ ${#priv} -lt 44 ]]; do priv="${priv}="; done
    while [[ ${#pub} -lt 44 ]]; do pub="${pub}="; done
    
    # Save sanitized config (no ListenPort/FwMark)
    sudo bash -c "cat > '$config_file' <<EOF
[Interface]
PrivateKey = $priv
Address = ${wg_ip:-10.5.0.2}/32

[Peer]
PublicKey = $pub
AllowedIPs = 0.0.0.0/0
Endpoint = $endpoint
PersistentKeepalive = 25
EOF
chmod 600 '$config_file'"
    
    log "Config saved to: $config_file"
    log "  WG IP: $wg_ip"
    log "  Endpoint: $endpoint"
    
    # Disconnect
    disconnect
    
    log "✓ $country harvested successfully"
    echo ""
    
    return 0
}

# Main
log "========================================="
log "NordVPN WireGuard Config Harvester"
log "========================================="
echo ""

# Check if running as root or with sudo
if [[ $EUID -ne 0 ]]; then
    log "ERROR: This script must be run with sudo"
    exit 1
fi

# Verify NordVPN is installed
if ! command -v nordvpn &>/dev/null; then
    log "ERROR: NordVPN CLI not found"
    exit 1
fi

# Check login status
if ! nordvpn status &>/dev/null | grep -q "Connected"; then
    if ! nordvpn account &>/dev/null; then
        log "ERROR: Not logged in to NordVPN"
        log "Run: nordvpn login --token YOUR_TOKEN"
        exit 1
    fi
fi

# Load region list from config.yaml
regions_load || exit 1

# Setup safe mode
setup_safe_mode

# Create keys directory
sudo mkdir -p "$KEYS_DIR"

# Clear any existing configs
sudo rm -f "$KEYS_DIR"/*.conf 2>/dev/null || true

# Harvest each country
success=0
failed=0

for id in "${REGION_IDS[@]}"; do
    country="${REGION_COUNTRY[$id]}"

    if harvest_country "$id" "$country"; then
        ((success++))
        # Small delay between harvests (NordVPN rate limiting)
        sleep 2
    else
        ((failed++))
        log "Failed to harvest $id, continuing..."
    fi
done

# Summary
log "========================================="
log "Harvesting Complete!"
log "  Success: $success"
log "  Failed: $failed"
log "========================================="

if [[ $success -eq ${#REGION_IDS[@]} ]]; then
    echo ""
    log "All ${#REGION_IDS[@]} configs harvested successfully!"
    echo ""
    echo "Next steps:"
    echo "  sudo /etc/vpn/vpn_namespaces.sh up"
    echo ""
    
    # Automatically bring up tunnels
    read -p "Bring up all tunnels now? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo /etc/vpn/vpn_namespaces.sh up
    fi
else
    log "Some configs failed. Check errors above."
    exit 1
fi
