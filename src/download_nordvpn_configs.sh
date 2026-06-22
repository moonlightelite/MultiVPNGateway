#!/bin/bash
# download_nordvpn_configs.sh - Download WireGuard configs using NordVPN API
# Pure bash - no Node.js required!
#
# Usage:
#   export NORDVPN_USERNAME="your@email.com"
#   export NORDVPN_PASSWORD="yourpass"
#   ./download_nordvpn_configs.sh

set -e

OUTPUT_DIR="${OUTPUT_DIR:-./wireguard_configs}"
mkdir -p "$OUTPUT_DIR"

# Only used in the printed "next steps"; set VPN_HOST=user@host to make them
# copy-pasteable for your deployment.
VPN_HOST="${VPN_HOST:-user@vpn-host}"

log() { echo "[NORD-API] $*"; }

# Region list comes from config.yaml (single source of truth) via regions.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/regions.sh"

# Get OAuth token
get_token() {
    log "Authenticating with NordVPN..."
    
    local response
    response=$(curl -s -X POST "https://api.nordvpn.com/oauth2/token" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$NORDVPN_USERNAME\",\"password\":\"$NORDVPN_PASSWORD\",\"grant_type\":\"password\"}")
    
    TOKEN=$(echo "$response" | jq -r '.access_token // empty')
    
    if [[ -z "$TOKEN" ]] || [[ "$TOKEN" == "null" ]]; then
        log "ERROR: Authentication failed"
        echo "Response: $response"
        exit 1
    fi
    
    log "✓ Authenticated successfully"
}

# Get WireGuard credentials
get_credentials() {
    log "Fetching WireGuard credentials..."
    
    local response
    response=$(curl -s -H "Authorization: Bearer $TOKEN" \
        "https://api.nordvpn.com/v1/users/services/credentials")
    
    UNIQUE_IP=$(echo "$response" | jq -r '.unique_ip // empty')
    PRIVATE_KEY=$(echo "$response" | jq -r '.unique_ip_private_key // empty')
    PUBLIC_KEY=$(echo "$response" | jq -r '.unique_ip_public_key // empty')
    
    if [[ -z "$UNIQUE_IP" ]] || [[ -z "$PRIVATE_KEY" ]]; then
        log "ERROR: Failed to get credentials"
        exit 1
    fi
    
    log "✓ Got credentials (IP: $UNIQUE_IP)"
}

# Get country ID
get_country_id() {
    local code="$1"
    local response
    
    response=$(curl -s "https://api.nordvpn.com/v1/servers/countries")
    echo "$response" | jq -r ".[] | select(.code==\"$code\") | .id"
}

# Get recommended server
get_server() {
    local country_id="$1"
    local response
    
    response=$(curl -s -H "Authorization: Bearer $TOKEN" \
        "https://api.nordvpn.com/v1/servers/recommendations?filters[country_id]=${country_id}&limit=1&filters[servers_technologies]=8")
    
    echo "$response" | jq -r '.[0]'
}

# Generate WireGuard config
generate_config() {
    local server_json="$1"
    local country_code="$2"
    local wg_ip="$3"
    
    local hostname=$(echo "$server_json" | jq -r '.hostname')
    local ip=$(echo "$server_json" | jq -r '.ips[] | select(.type=="IPv4") | .ip' | head -1)
    local public_key=$(echo "$server_json" | jq -r '.public_key // empty')
    
    # Fallback to credentials public key if server doesn't have one
    if [[ -z "$public_key" ]] || [[ "$public_key" == "null" ]]; then
        public_key="$PUBLIC_KEY"
    fi
    
    cat <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = ${wg_ip:-10.5.0.2}/32
DNS = 103.86.96.96, 103.86.99.96

[Peer]
PublicKey = $public_key
AllowedIPs = 0.0.0.0/0
Endpoint = ${hostname}:51820
PersistentKeepalive = 25
EOF
}

# Main
log "========================================="
log "NordVPN WireGuard Config Downloader"
log "(Pure Bash - No NordVPN daemon needed)"
log "========================================="
echo ""

# Check dependencies
if ! command -v curl &>/dev/null; then
    log "ERROR: curl is required"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    log "ERROR: jq is required"
    exit 1
fi

# Check credentials
if [[ -z "$NORDVPN_USERNAME" ]] || [[ -z "$NORDVPN_PASSWORD" ]]; then
    log "ERROR: Set NORDVPN_USERNAME and NORDVPN_PASSWORD"
    log "Or use OAuth token: export NORDVPN_TOKEN='...'"
    exit 1
fi

# Load region list from config.yaml (needs yq)
regions_load || exit 1

# Get token and credentials
get_token
get_credentials

log ""
log "Downloading configs for ${#REGION_IDS[@]} countries..."
echo ""

wg_counter=2
for id in "${REGION_IDS[@]}"; do
    code="${REGION_CODE[$id]}"
    name="${REGION_COUNTRY[$id]//_/ }"
    file="${id}.conf"

    log "--- $name ($code) ---"
    
    # Get country ID
    country_id=$(get_country_id "$code")
    if [[ -z "$country_id" ]]; then
        log "ERROR: Country $code not found"
        continue
    fi
    
    # Get server
    server=$(get_server "$country_id")
    if [[ -z "$server" ]] || [[ "$server" == "null" ]]; then
        log "ERROR: No server found for $name"
        continue
    fi
    
    # Generate config
    config=$(generate_config "$server" "$code" "10.5.0.${wg_counter}")
    echo "$config" > "$OUTPUT_DIR/$file"
    chmod 600 "$OUTPUT_DIR/$file"
    
    hostname=$(echo "$server" | jq -r '.hostname')
    log "✓ Saved: $OUTPUT_DIR/$file (endpoint: $hostname)"
    
    ((wg_counter++))
    
    # Rate limiting
    sleep 1
done

log ""
log "========================================="
log "Download Complete!"
log "Configs in: $(realpath "$OUTPUT_DIR")"
log "========================================="
echo ""
echo "Next steps:"
echo "  1. Verify configs: ls -la $OUTPUT_DIR/"
echo "  2. Upload to VPN host: scp $OUTPUT_DIR/*.conf $VPN_HOST:/etc/vpn/keys/"
echo "  3. Set permissions: ssh $VPN_HOST 'sudo chmod 600 /etc/vpn/keys/*.conf'"
echo "  4. Start tunnels: ssh $VPN_HOST 'sudo /etc/vpn/vpn_namespaces.sh up'"
