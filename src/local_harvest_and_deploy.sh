#!/bin/bash
# local_harvest_and_deploy.sh
# Run NordVPN CLI LOCALLY (safe), then upload configs to VPN host

set -e

echo '========================================='
echo 'NordVPN Config Harvester & Deployer'
echo '========================================='
echo ''

# Configuration — set VPN_HOST=user@host for the box to deploy to.
VPN_HOST="${VPN_HOST:-}"
if [[ -z "$VPN_HOST" ]]; then
    echo "ERROR: set VPN_HOST=user@host (the VPN host to deploy configs to)" >&2
    echo "       e.g.  VPN_HOST=admin@10.0.0.5 $0" >&2
    exit 1
fi
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/nordvpn_configs}"

# Region list comes from config.yaml (single source of truth) via regions.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/regions.sh"
regions_load || exit 1

mkdir -p "$OUTPUT_DIR"

# Step 1: Install NordVPN CLI locally if not present
echo '[1/6] Checking NordVPN installation...'
if ! command -v nordvpn &>/dev/null; then
    echo 'Installing NordVPN CLI...'
    
    # Download and install
    curl -o /tmp/nordvpn.deb https://repo.nordvpn.com/deb/nordvpn/debian/pool/main/n/nordvpn/nordvpn_5.0.0_amd64.deb
    
    if sudo dpkg -i /tmp/nordvpn.deb 2>&1 | grep -q "error"; then
        echo 'Fixing dependencies...'
        sudo apt-get install -f -y
    fi
    
    # Verify
    if command -v nordvpn &>/dev/null; then
        echo '✓ NordVPN CLI installed'
    else
        echo '✗ Installation failed'
        exit 1
    fi
else
    echo '✓ NordVPN CLI already installed'
fi

# Step 2: Login
echo ''
echo '[2/6] NordVPN Login'
echo ''
echo 'You will be prompted for NordVPN credentials.'
echo 'Alternatively, use: nordvpn login --token YOUR_TOKEN'
echo ''

nordvpn login

if nordvpn status &>/dev/null | grep -q "Logged in"; then
    echo '✓ Logged in successfully'
else
    echo 'Login status unknown, continuing...'
fi

# Step 3: Safe mode configuration
echo ''
echo '[3/6] Configuring safe mode...'
nordvpn set technology nordlynx
nordvpn set firewall disabled
nordvpn set killswitch disabled
nordvpn set autoconnect disabled

# Step 4: Harvest configs from each country
echo ''
echo '[4/6] Harvesting WireGuard configs...'
echo ''

disconnect() {
    nordvpn disconnect >/dev/null 2>&1 || true
    sleep 2
    # Wait for interface cleanup
    while ip link show nordlynx &>/dev/null; do
        sleep 1
    done
    sleep 1
}

for id in "${REGION_IDS[@]}"; do
    country="${REGION_COUNTRY[$id]}"
    config_file="$OUTPUT_DIR/${id}.conf"
    
    echo "--- $country ($id) ---"
    
    # Connect
    if ! timeout 60 nordvpn connect "$country" 2>&1; then
        echo "✗ Failed to connect to $country"
        continue
    fi
    
    sleep 5
    
    # Get exit IP info
    ext_ip=$(curl -s --max-time 5 https://api.ip.sb/ip 2>/dev/null || echo "unknown")
    geo=$(curl -s --max-time 5 https://ipinfo.io/json 2>/dev/null | jq -r '.country // "?"' 2>/dev/null || echo "?")
    echo "Exit IP: $ext_ip ($geo)"
    
    # Harvest WireGuard config
    if sudo wg showconf nordlynx > /tmp/harvest.conf 2>/dev/null; then
        # Extract and fix values
        priv=$(sudo grep '^PrivateKey' /tmp/harvest.conf | cut -d'=' -f2 | tr -d ' ')
        pub=$(sudo grep '^PublicKey' /tmp/harvest.conf | cut -d'=' -f2 | tr -d ' ')
        endpoint=$(sudo grep '^Endpoint' /tmp/harvest.conf | cut -d'=' -f2 | tr -d ' ')
        wg_ip=$(ip -j addr show nordlynx 2>/dev/null | jq -r '.[0].addr_info[] | select(.family=="inet") | .local' | head -1)
        
        # Fix base64 padding
        while [[ ${#priv} -lt 44 ]]; do priv="${priv}="; done
        while [[ ${#pub} -lt 44 ]]; do pub="${pub}="; done
        
        # Save config
        cat > "$config_file" <<EOF
[Interface]
PrivateKey = $priv
Address = ${wg_ip:-10.5.0.2}/32
DNS = 103.86.96.96, 103.86.99.96

[Peer]
PublicKey = $pub
AllowedIPs = 0.0.0.0/0
Endpoint = $endpoint
PersistentKeepalive = 25
EOF
        
        chmod 600 "$config_file"
        echo "✓ Saved: $config_file"
    else
        echo "✗ Failed to harvest config"
    fi
    
    # Disconnect
    disconnect
    echo ""
    
    # Rate limiting
    sleep 3
done

# Step 5: Upload to VPN host
echo '[5/6] Uploading configs to VPN host...'
echo ''

# Create directory on remote
ssh "$VPN_HOST" "sudo mkdir -p /etc/vpn/keys && sudo chmod 700 /etc/vpn/keys"

# Upload configs
for id in "${REGION_IDS[@]}"; do
    config_file="$OUTPUT_DIR/${id}.conf"
    if [[ -f "$config_file" ]]; then
        echo "Uploading ${id}.conf..."
        scp "$config_file" "$VPN_HOST:/tmp/${id}.conf"
        ssh "$VPN_HOST" "sudo mv /tmp/${id}.conf /etc/vpn/keys/ && sudo chmod 600 /etc/vpn/keys/${id}.conf"
    fi
done

echo ''
echo '✓ Configs uploaded to /etc/vpn/keys/'

# Step 6: Verify and start tunnels on VPN host
echo ''
echo '[6/6] Starting tunnels on VPN host...'
echo ''

ssh "$VPN_HOST" "
    echo 'Validating configs...'
    for id in ${REGION_IDS[*]}; do
        if sudo wg-quick strip /etc/vpn/keys/\$id.conf >/dev/null 2>&1; then
            echo \"  ✓ \$id.conf valid\"
        else
            echo \"  ✗ \$id.conf INVALID\"
        fi
    done
    
    echo ''
    echo 'Starting all tunnels...'
    sudo /etc/vpn/vpn_namespaces.sh up
    
    echo ''
    echo '=== Tunnel Status ==='
    sudo /etc/vpn/vpn_namespaces.sh status
"

echo ''
echo '========================================='
echo 'Complete!'
echo 'Configs saved locally: ~/nordvpn_configs/'
echo 'Configs on VPN host: /etc/vpn/keys/'
echo '========================================='
