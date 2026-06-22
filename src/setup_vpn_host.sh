#!/bin/bash
#
# setup_vpn_host.sh - Automated setup for VPN Namespace Manager
# After host reset, run this script to prepare the system
#
# Usage: sudo bash setup_vpn_host.sh
#

set -euo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2
}

# Persistent backup dir, derived at runtime from the invoking user's home so it
# isn't tied to a specific username (override with the BACKUP_DIR env var).
default_backup_dir() {
    local home=""
    [[ -n "${SUDO_USER:-}" ]] && home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    printf '%s/wireguard_configs_backup\n' "${home:-${HOME:-/root}}"
}
BACKUP_DIR="${BACKUP_DIR:-$(default_backup_dir)}"

# This host's primary IPv4 address (for log output only).
host_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

# ------------------------------------------------------------------------------
# Install required packages
# ------------------------------------------------------------------------------
install_packages() {
    log "Installing required packages..."
    
    apt update -qq
    
    # WireGuard tools
    if ! command -v wg >/dev/null 2>&1; then
        log "Installing wireguard-tools..."
        apt install -y wireguard-tools
    fi
    
    # YAML processor
    if ! command -v yq >/dev/null 2>&1; then
        log "Installing yq..."
        wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
        chmod +x /usr/local/bin/yq
    fi
    
    # JSON processor (should already be installed)
    if ! command -v jq >/dev/null 2>&1; then
        log "Installing jq..."
        apt install -y jq
    fi
    
    # Bridge utilities
    if ! command -v brctl >/dev/null 2>&1; then
        log "Installing bridge-utils..."
        apt install -y bridge-utils
    fi
    
    # iptables
    if ! command -v iptables >/dev/null 2>&1; then
        log "Installing iptables..."
        apt install -y iptables
    fi
    
    # NordVPN CLI (if not installed)
    if ! command -v nordvpn >/dev/null 2>&1; then
        log_warn "NordVPN CLI not found. Installing..."
        # Download NordVPN repository
        wget -q -O - https://repo.nordvpn.com/gpg/nordvpn-surfshark.gpg | apt-key add -
        echo "deb https://repo.nordvpn.com/deb/nordvpn/debian stable main" | tee /etc/apt/sources.list.d/nordvpn-repo.list
        apt update -qq
        apt install -y nordvpn
    fi
    
    log "✓ All packages installed"
}

# ------------------------------------------------------------------------------
# Create directory structure
# ------------------------------------------------------------------------------
create_directories() {
    log "Creating directory structure..."
    
    mkdir -p /etc/vpn/keys
    mkdir -p /etc/vpn/namespaces
    mkdir -p /etc/vpn/steering
    mkdir -p /run/vpn/namespaces
    mkdir -p /var/log/vpn
    mkdir -p "$BACKUP_DIR"
    
    chmod 700 /etc/vpn/keys
    chmod 755 /etc/vpn/namespaces
    chmod 755 /run/vpn
    chmod 755 /var/log/vpn
    
    log "✓ Directories created"
}

# ------------------------------------------------------------------------------
# Configure NordVPN
# ------------------------------------------------------------------------------
configure_nordvpn() {
    log "Configuring NordVPN..."
    
    # Disable killswitch (interferes with namespace isolation)
    nordvpn set killswitch disabled 2>/dev/null || true
    
    # Set technology to NordLynx (WireGuard)
    nordvpn set technology nordlynx 2>/dev/null || true
    
    # Disable firewall (we manage our own)
    nordvpn set firewall disabled 2>/dev/null || true
    
    # Disable auto-connect (we manage connections)
    nordvpn set auto-connect disabled 2>/dev/null || true
    
    log "✓ NordVPN configured"
}

# ------------------------------------------------------------------------------
# Restore backed up configs (if available)
# ------------------------------------------------------------------------------
restore_configs() {
    log "Checking for backed up configs..."
    
    local backup_dir="$BACKUP_DIR"
    local config_dir="/etc/vpn/keys"
    
    if [[ -d "$backup_dir" ]] && [[ -n "$(ls -A "$backup_dir"/*.conf 2>/dev/null)" ]]; then
        log "Found backup configs in $backup_dir"
        
        # Copy configs
        cp "$backup_dir"/*.conf "$config_dir/" 2>/dev/null || true
        chmod 600 "$config_dir"/*.conf 2>/dev/null || true
        
        log "✓ Configs restored to $config_dir"
        log "  Files:"
        ls -la "$config_dir"/*.conf 2>/dev/null || log_warn "  No configs found"
        
        return 0
    else
        log_warn "No backup configs found. Run harvest first."
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Enable IP forwarding
# ------------------------------------------------------------------------------
enable_ip_forwarding() {
    log "Enabling IP forwarding..."
    
    # Enable immediately
    echo 1 > /proc/sys/net/ipv4/ip_forward
    
    # Persist across reboots
    if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    fi
    
    log "✓ IP forwarding enabled"
}

# ------------------------------------------------------------------------------
# Create systemd service (optional)
# ------------------------------------------------------------------------------
create_systemd_service() {
    log "Creating systemd service..."
    
    cat > /etc/systemd/system/vpn-namespaces.service << 'EOF'
[Unit]
Description=VPN Namespace Manager
After=network.target
Before=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/vpn/vpn_namespaces.sh up
ExecStop=/etc/vpn/vpn_namespaces.sh down
ExecStopPost=/bin/sleep 2

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    
    log "✓ Systemd service created (not enabled)"
    log "  To enable: systemctl enable vpn-namespaces"
}

# ------------------------------------------------------------------------------
# Main setup
# ------------------------------------------------------------------------------
main() {
    log "========================================"
    log "VPN Host Setup Script"
    log "Host IP: $(host_ip)"
    log "========================================"

    # Install packages
    install_packages
    
    # Create directories
    create_directories
    
    # Enable IP forwarding
    enable_ip_forwarding
    
    # Configure NordVPN
    configure_nordvpn
    
    # Try to restore configs
    restore_configs || true
    
    # Create systemd service
    create_systemd_service
    
    log ""
    log "========================================"
    log "Setup Complete!"
    log "========================================"
    log ""
    log "Next steps:"
    log ""
    log "1. If you have backed up configs:"
    log "   sudo /etc/vpn/vpn_namespaces.sh up"
    log ""
    log "2. If configs need to be harvested:"
    log "   sudo bash /tmp/vpn_config_daemon.sh"
    log ""
    log "3. Verify WireGuard configs:"
    log "   ls -la /etc/vpn/keys/*.conf"
    log ""
    log "4. Test a namespace:"
    log "   sudo /etc/vpn/vpn_namespaces.sh status"
    log ""
    log "========================================"
}

# Run main
main "$@"
