#!/bin/bash
# vpn_config_daemon.sh v2 - Persist configs to survive VM reset

set -e

PIDFILE="/tmp/vpn_daemon.pid"
LOGFILE="/var/log/vpn_daemon.log"
CONFIG_DIR="/etc/vpn/keys"
COMPLETE_MARKER="/tmp/vpn_daemon_complete"
TIMEOUT_MINUTES=${TIMEOUT_MINUTES:-15}

# Region list comes from config.yaml (single source of truth) via regions.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/regions.sh"

# Persistent backup dir, derived at runtime from the invoking user's home
# (override with BACKUP_DIR). default_backup_dir comes from regions.sh.
BACKUP_DIR="${BACKUP_DIR:-$(default_backup_dir)}"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" 2>/dev/null || echo "$msg"
    echo "$msg" | sudo tee -a "$LOGFILE" 2>/dev/null || echo "$msg"
}

disconnect_vpn() {
    nordvpn disconnect >/dev/null 2>&1 || true
    sleep 3
    while ip link show nordlynx >/dev/null 2>&1; do
        sleep 1
    done
    sleep 1
}

persist_configs() {
    log "=== PERSISTING CONFIGS TO SURVIVE RESET ==="
    mkdir -p "$BACKUP_DIR"
    
    # Copy configs to home directory (survives reset)
    sudo cp /etc/vpn/keys/*.conf "$BACKUP_DIR/" 2>/dev/null || true
    sudo chmod 644 "$BACKUP_DIR"/*.conf 2>/dev/null || true
    
    # Create consolidated backup file
    sudo bash -c "cat > $BACKUP_DIR/ALL_CONFIGS.tar.gz" << 'TARBALL'
$(tar -czf - -C /etc/vpn keys/ 2>/dev/null || tar -czf - -C "$BACKUP_DIR" *.conf 2>/dev/null || echo "No configs")
TARBALL
    
    # Create manifest
    cat > "$BACKUP_DIR/MANIFEST.txt" << MANIFEST
WireGuard Configs Backup
========================
Date: $(date)
Purpose: Survive VM reset

Files:
$(ls -la "$BACKUP_DIR"/*.conf 2>/dev/null || echo "No configs found")

RESTORE INSTRUCTIONS:
After VM reset, run:

    sudo mkdir -p /etc/vpn/keys
    sudo cp $BACKUP_DIR/*.conf /etc/vpn/keys/
    sudo chmod 600 /etc/vpn/keys/*.conf
    sudo /etc/vpn/vpn_namespaces.sh up

MANIFEST

    # Create restore script
    cat > "$BACKUP_DIR/restore_configs.sh" << RESTORE
#!/bin/bash
# Restore WireGuard configs after VM reset
sudo mkdir -p /etc/vpn/keys
sudo cp $BACKUP_DIR/*.conf /etc/vpn/keys/
sudo chmod 600 /etc/vpn/keys/*.conf
echo "✓ Configs restored to /etc/vpn/keys/"
sudo /etc/vpn/vpn_namespaces.sh up
RESTORE
    chmod +x "$BACKUP_DIR/restore_configs.sh"
    
    log "✓ Configs persisted to: $BACKUP_DIR"
    log "✓ Manifest: $BACKUP_DIR/MANIFEST.txt"
    log "✓ Restore script: $BACKUP_DIR/restore_configs.sh"
    
    # List what we saved
    ls -la "$BACKUP_DIR"/*.conf 2>/dev/null || log "Warning: No configs to persist"
}

harvest_country() {
    local id="$1"
    local country="$2"
    local config_file="$CONFIG_DIR/${id}.conf"
    
    log "=== Harvesting: $country ($id) ==="
    
    disconnect_vpn
    
    log "Connecting to $country..."
    if timeout 60 nordvpn connect "$country" >/dev/null 2>&1; then
        sleep 5
        
        # Get exit info
        local ext_ip=$(curl -s --max-time 5 https://api.ip.sb/ip 2>/dev/null || echo "unknown")
        local geo=$(curl -s --max-time 5 https://ipinfo.io/json 2>/dev/null | jq -r '.country // "?"' 2>/dev/null || echo "?")
        log "Exit IP: $ext_ip ($geo)"
        
        # Harvest config
        if sudo wg showconf nordlynx > "/tmp/${id}.conf" 2>/dev/null; then
            local priv=$(sudo grep '^PrivateKey' "/tmp/${id}.conf" | cut -d'=' -f2 | tr -d ' ')
            local pub=$(sudo grep '^PublicKey' "/tmp/${id}.conf" | cut -d'=' -f2 | tr -d ' ')
            local endpoint=$(sudo grep '^Endpoint' "/tmp/${id}.conf" | cut -d'=' -f2 | tr -d ' ')
            local wg_ip=$(ip -j addr show nordlynx 2>/dev/null | jq -r '.[0].addr_info[] | select(.family=="inet") | .local' | head -1)
            
            # Fix base64 padding
            while [[ ${#priv} -lt 44 ]]; do priv="${priv}="; done
            while [[ ${#pub} -lt 44 ]]; do pub="${pub}="; done
            
            # Save config
            sudo bash -c "cat > '$config_file' <<EOF
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
chmod 600 '$config_file'"
            
            log "✓ Saved: $config_file"
            
            # IMMEDIATELY persist after each country (survive interruption)
            persist_configs
        else
            log "✗ Failed to harvest config"
            return 1
        fi
        
        disconnect_vpn
        log "✓ $country done"
        sleep 2
        return 0
    else
        log "✗ Failed to connect to $country"
        disconnect_vpn
        return 1
    fi
}

# Main daemon logic
log "========================================="
log "VPN Config Harvester Daemon v2"
log "With Persistent Backup"
log "========================================="

# Check if already running
if [[ -f "$PIDFILE" ]] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
    log "ERROR: Daemon already running (PID: $(cat $PIDFILE))"
    exit 1
fi
echo $$ > "$PIDFILE"

# Ensure dirs exist
sudo mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
sudo chmod 700 "$CONFIG_DIR"

# Safe NordVPN config
log "Configuring NordVPN safe mode..."
nordvpn set firewall disabled >/dev/null 2>&1 || true
nordvpn set killswitch disabled >/dev/null 2>&1 || true
nordvpn set technology nordlynx >/dev/null 2>&1 || true

# Check login
if ! nordvpn account >/dev/null 2>&1; then
    log "ERROR: Not logged in to NordVPN"
    exit 1
fi

# Load region list from config.yaml
regions_load || exit 1

# Harvest all countries
success=0
for id in "${REGION_IDS[@]}"; do
    country="${REGION_COUNTRY[$id]}"

    if harvest_country "$id" "$country"; then
        ((success++))
    fi

    sleep 3
done

# Final summary
log "========================================="
log "Harvesting Complete"
log "Success: $success / ${#REGION_IDS[@]}"
log "========================================="

if [[ $success -eq ${#REGION_IDS[@]} ]]; then
    log "✓ All configs harvested and persisted"
    
    # Final persist
    persist_configs
    
    # Start tunnels if possible (may fail after reset)
    log ""
    log "Attempting to start tunnels..."
    if sudo /etc/vpn/vpn_namespaces.sh up 2>&1; then
        log "✓ Tunnels started"
        sudo /etc/vpn/vpn_namespaces.sh status
    else
        log "Note: Tunnels not started (may need to run restore after reset)"
    fi
    
    # Mark complete
    touch "$COMPLETE_MARKER"
    
    log ""
    log "SUCCESS! Configs are saved in:"
    log "  /etc/vpn/keys/*.conf (active)"
    log "  $BACKUP_DIR/*.conf (persistent backup)"
    log ""
    log "After VM reset, run:"
    log "  ssh <user>@<vpn-host> 'bash $BACKUP_DIR/restore_configs.sh'"
    
    exit 0
else
    log "✗ Incomplete ($success/${#COUNTRIES[@]})"
    persist_configs
    exit 1
fi
