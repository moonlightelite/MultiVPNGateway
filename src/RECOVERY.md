# VPN Host Recovery & Operations Runbook

**Host:** `<user>@<vpn-host>` · **Uplink:** `ens18` (example) · **Default gw:** `<lan-gateway>`
**Status:** ✅ tunnels operational, steering active, boot-persistent (systemd enabled)

This is the single operational runbook for the namespace-based VPN host. It covers
the current deployment state, post-reset recovery, the config-harvest daemon method,
client steering, and troubleshooting.

For the full system design see `IMPLEMENTATION_PLAN.md`.

> **Validated live on <date>** (host <vpn-host>). All five tunnels exit in
> the correct country; policy-based client steering was proven end-to-end with a
> forwarded test client (steer → SG gave a Singapore exit, re-steer → JP gave Tokyo,
> remove cut it off); `validate` / `backup` / `restore` work; a full `down`→`up`
> rebuild and a `systemctl restart` both recover all 5 tunnels and re-apply steering.
> Two real bugs in `vpn_namespaces.sh` were fixed in the process — see
> **Validation notes & fixes** below.

---

## Deployment Status

**Deployed:** <date> — successful.

### Verified exit IPs

| Country | Namespace | Exit IP (at deploy) |
|---------|-----------|---------------------|
| Taiwan | `vpn-tw` | 185.213.82.176 |
| Singapore | `vpn-sg` | 192.166.246.88 |
| Netherlands | `vpn-nl` | 193.142.201.60 |
| Korea | `vpn-kr` | 217.216.125.202 |
| Japan | `vpn-jp` | 86.48.12.5 |

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    VPN Host (<vpn-host>)                  │
│                                                              │
│  Network Namespaces:                                         │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐               │
│  │vpn-tw│ │vpn-sg│ │vpn-nl│ │vpn-kr│ │vpn-jp│               │
│  │wg-tw │ │wg-sg │ │wg-nl │ │wg-kr │ │wg-jp │               │
│  │TW IP │ │SG IP │ │NL IP │ │KR IP │ │JP IP │               │
│  └──────┘ └──────┘ └──────┘ └──────┘ └──────┘               │
│                                                              │
│  Config Location: /etc/vpn/keys/*.conf                       │
│  Backup Location: ~/wireguard_configs_backup/     │
└─────────────────────────────────────────────────────────────┘
```

### What was deployed

1. **Setup script** — `setup_vpn_host.sh` transferred and executed (dependencies,
   directories, config).
2. **Packages** — yq, jq, wireguard-tools, bridge-utils, iptables, NordVPN CLI.
3. **Config harvest** — `vpn_config_daemon.sh` harvested WireGuard configs for 5
   countries and backed them up to `~/wireguard_configs_backup/`.
4. **Namespaces** — 5 namespaces created with WireGuard interfaces, NAT, and routing.
5. **Connectivity** — all 5 namespaces verified against the exit IPs above.

---

## Quick Recovery (5 minutes)

```bash
# 1. Login to VPN host
ssh <user>@<vpn-host>

# 2. Run setup script (installs dependencies, restores configs)
cd ~/code/tunnels/src
sudo bash setup_vpn_host.sh

# 3. Start tunnels
sudo /etc/vpn/vpn_namespaces.sh up

# 4. Verify status
sudo /etc/vpn/vpn_namespaces.sh status
```

---

## Detailed Recovery Steps

### Step 1: Verify host state

```bash
# Check if this is a fresh reset
uname -a
cat /etc/os-release

# Check current IP (uplink interface is ens18 on this host)
ip addr show ens18 | grep inet

# Check if namespaces exist (they shouldn't after reset)
ip netns list

# Check if WireGuard configs exist
ls -la /etc/vpn/keys/*.conf 2>/dev/null || echo "No configs found"

# Check backup location
ls -la ~/wireguard_configs_backup/*.conf 2>/dev/null || echo "No backup found"
```

### Step 2: Run automated setup

```bash
cd ~/code/tunnels/src
sudo bash setup_vpn_host.sh
```

This script will:
- Install required packages (yq, wireguard-tools, bridge-utils, jq, iptables)
- Create the directory structure
- Configure NordVPN settings
- Restore configs from backup (if available)
- Enable IP forwarding
- Create the systemd service

### Step 3: Restore WireGuard configs

**Option A: From backup (fast, if available)**

```bash
ls -la ~/wireguard_configs_backup/

sudo mkdir -p /etc/vpn/keys
sudo cp ~/wireguard_configs_backup/*.conf /etc/vpn/keys/
sudo chmod 600 /etc/vpn/keys/*.conf

ls -la /etc/vpn/keys/
```

**Option B: Re-harvest from NordVPN (~15 minutes)**

```bash
# Start harvest daemon
cd /tmp
sudo bash vpn_config_daemon.sh 2>&1 | tee /var/log/vpn_daemon.log

# Monitor progress
tail -f /var/log/vpn_daemon.log

# Or run manual harvest
sudo bash download_nordvpn_configs.sh
```

> If SSH locks up during harvest, use the **Config Harvest via Auto-Reset Daemon**
> method below.

### Step 4: Start VPN namespaces

```bash
sudo /etc/vpn/vpn_namespaces.sh up
sudo /etc/vpn/vpn_namespaces.sh status

sudo wg show
ip netns list
brctl show br0
```

### Step 5: Test connectivity

```bash
# Single namespace
sudo ip netns exec vpn-tw curl -s api.ip.sb/geo | jq

# All namespaces
for ns in $(yq '.namespaces[].id' /etc/vpn/config.yaml); do
    echo -n "$ns: "
    sudo ip netns exec vpn-$ns curl -s --max-time 3 https://api.ip.sb/ip
done
```

### Step 6: Configure client steering

```bash
# View current steering rules
cat /etc/vpn/steering/rules.yaml

# Add steering rule (example: client 192.168.1.50 → Taiwan)
sudo /etc/vpn/vpn_namespaces.sh steering add 192.168.1.50 tw

# Verify
sudo iptables -t mangle -L PREROUTING -n -v | grep MARK
sudo ip rule show

# Test from client (should show Taiwan exit IP)
ssh user@192.168.1.50 "curl -s api.ip.sb/ip"
```

---

## Config Harvest via Auto-Reset Daemon

**Problem:** the NordVPN CLI locks SSH on <vpn-host> while it connects/disconnects.

**Approach:** run the harvest in a detached background daemon, optionally auto-reset
the host if SSH becomes unreachable, then SSH back in to retrieve the configs.

### On the VPN host (<vpn-host>)

```bash
# 1. Upload daemon script
scp vpn_config_daemon.sh <user>@<vpn-host>:/tmp/

# 2. Login
ssh <user>@<vpn-host>

# 3. Start the daemon detached
cat > /tmp/START_DAEMON.sh << 'SCRIPT'
#!/bin/bash
LOGFILE=/var/log/vpn_daemon.log
CONFIG_DIR=/etc/vpn/keys

sudo touch $LOGFILE
sudo chmod 666 $LOGFILE
mkdir -p $CONFIG_DIR

(
    cd /tmp
    sudo chmod +x vpn_config_daemon.sh
    sudo bash /tmp/vpn_config_daemon.sh 2>&1 | tee $LOGFILE
    nordvpn disconnect >/dev/null 2>&1
    touch /tmp/vpn_daemon_complete
    sleep 120
) &

disown
echo "Daemon started. PID: $!"
SCRIPT

chmod +x /tmp/START_DAEMON.sh
bash /tmp/START_DAEMON.sh

# 4. Exit SSH (daemon continues)
exit
```

### From your local machine

```bash
# Wait 10-15 minutes, then check status
ssh <user>@<vpn-host> "
    if [[ -f /tmp/vpn_daemon_complete ]]; then
        echo '✓ Daemon completed!'
        ls -la /etc/vpn/keys/*.conf
    else
        echo 'Daemon still running or failed'
        tail -20 /var/log/vpn_daemon.log
    fi
"

# If SSH is unreachable, trigger reset, wait ~2 min, then SSH back in
curl -X POST "<reset-endpoint>"
```

### Expected timeline

| Time | Event |
|------|-------|
| 0:00 | Daemon started |
| 0:01 | Connecting to Taiwan |
| 0:03 | Taiwan config harvested |
| 0:05 | Connecting to Singapore |
| ...  | ... |
| 0:15 | All 5 configs done |
| 0:17 | Tunnels started, completion marker created |
| 0:19 | Daemon exits, SSH accessible again (or machine reset) |

### Alternative: harvest from your local machine

```bash
# SSHs in, harvests configs, and downloads them locally
bash local_harvest_and_deploy.sh
```

---

## Troubleshooting

### NordVPN not logged in

```bash
nordvpn account
nordvpn login                 # browser/code flow
nordvpn login --token YOUR_TOKEN
```

### WireGuard module not loaded

```bash
sudo modprobe wireguard
lsmod | grep wireguard
```

### Namespace creation fails

```bash
ip netns list
sudo ip -all netns delete
sudo ip link delete br0 2>/dev/null || true
sudo /etc/vpn/vpn_namespaces.sh up
```

### Client steering not working

```bash
brctl showmacs br0
sudo iptables -t mangle -L PREROUTING -n -v

# Routing tables: 100=TW 101=SG 102=NL 103=KR 104=JP
for t in 100 101 102 103 104; do echo "== table $t =="; sudo ip route show table $t; done

sudo tcpdump -i br0 -n host 192.168.1.50
```

### SSH locks during harvest

Known NordVPN CLI limitation. Use the **Config Harvest via Auto-Reset Daemon**
method above (detached daemon + optional auto-reset), or harvest from your local
machine with `local_harvest_and_deploy.sh`. If SSH is fully locked:

```bash
curl -X POST "<reset-endpoint>"
# Wait ~2 min for reboot, then SSH back in and check:
ssh <user>@<vpn-host> "ls -la /etc/vpn/keys/*.conf"
```

### Config refresh

WireGuard configs expire as NordVPN rotates servers. Re-run the harvest periodically:

```bash
sudo bash ~/code/tunnels/src/vpn_config_daemon.sh
```

---

## Post-Recovery Verification Checklist

- [ ] All 5 namespaces running (`ip netns list`)
- [ ] Bridge created (`brctl show br0`)
- [ ] WireGuard interfaces active (`wg show`)
- [ ] Routing tables configured (`ip rule show`)
- [ ] Steering rules applied (`iptables -t mangle -L PREROUTING`)
- [ ] Each namespace can reach the internet
- [ ] Each namespace shows the correct geo-location
- [ ] Client steering working (test from each client)
- [ ] NAT working (verify source IP translation)
- [ ] No inter-namespace traffic (isolation test)

---

## Commands Reference

### Namespace management

```bash
sudo /etc/vpn/vpn_namespaces.sh up            # start all (or: up tw)
sudo /etc/vpn/vpn_namespaces.sh down          # stop all  (or: down tw)
sudo /etc/vpn/vpn_namespaces.sh status        # status
sudo /etc/vpn/vpn_namespaces.sh validate      # check each netns + wg iface is live

# Execute a command inside a namespace
sudo ip netns exec vpn-{id} {command}
sudo ip netns exec vpn-tw curl -s api.ip.sb/geo | jq
```

### Config backup / restore

```bash
# Copy active configs (/etc/vpn/keys) to the persistent backup dir
sudo /etc/vpn/vpn_namespaces.sh backup

# Restore configs from the backup dir after a reset (before `up`)
sudo /etc/vpn/vpn_namespaces.sh restore
```

### Client steering

```bash
sudo /etc/vpn/vpn_namespaces.sh steering add {client_ip} {namespace_id}
sudo /etc/vpn/vpn_namespaces.sh steering remove {client_ip}
sudo /etc/vpn/vpn_namespaces.sh steering list
```

### Config harvest

```bash
# Harvest all countries
sudo bash ~/code/tunnels/src/vpn_config_daemon.sh

# Harvest a single country manually
sudo nordvpn connect {country}
sudo wg showconf nordlynx > /etc/vpn/keys/{id}.conf
sudo nordvpn disconnect
```

### How client steering works (PBR)

There is **no bridge**. A client (whose gateway is this host) is steered by
marking its packets in `mangle PREROUTING` with the target namespace's
`routing_table` number; the per-namespace fwmark `ip rule` (installed by
`up`) then selects table 10x, whose default route points at that namespace's
veth gateway → WireGuard → country exit. The marks live in a dedicated
`VPN_STEER` chain, managed entirely by `vpn_namespaces.sh steering`:

```bash
# Apply all rules from /etc/vpn/steering/rules.yaml (also run automatically by `up`)
sudo /etc/vpn/vpn_namespaces.sh steering apply

# Ad-hoc: steer one client, move it, or remove it
sudo /etc/vpn/vpn_namespaces.sh steering add 192.168.1.50 tw
sudo /etc/vpn/vpn_namespaces.sh steering add 192.168.1.50 jp   # idempotent re-steer
sudo /etc/vpn/vpn_namespaces.sh steering remove 192.168.1.50
sudo /etc/vpn/vpn_namespaces.sh steering list
```

---

## File Locations

| File / Directory | Purpose |
|------------------|---------|
| `~/code/tunnels/src/setup_vpn_host.sh` | Automated recovery after reset |
| `~/code/tunnels/src/vpn_config_daemon.sh` | WireGuard config harvest daemon |
| `/etc/vpn/vpn_namespaces.sh` | Main namespace lifecycle management |
| `/etc/vpn/generate_config.sh` | Regenerate `config.yaml` from a country list |
| `/etc/vpn/regions.sh` | Region-list helper (sourced; reads `config.yaml`) |
| `/etc/vpn/config.yaml` | YAML config every script reads (generated; regions live here) |
| `/etc/vpn/keys/*.conf` | Active WireGuard configs (0600) |
| `/etc/vpn/steering/rules.yaml` | Client steering rules |
| `~/wireguard_configs_backup/` | Persistent config backup (survives resets) |
| `/run/vpn/namespaces/*.json` | Runtime state (tmpfs, lost on reboot) |
| `/var/log/vpn_daemon.log` | Harvest daemon log |

---

## Lessons Learned

### What works well

- ✅ Config backup to the home directory — survives VM resets
- ✅ Harvest daemon with timeout — handles SSH lockups
- ✅ Auto-reset integration — recovers from stuck states
- ✅ Separate backup directory — keeps configs safe

### Hardened after the reset

- ✅ Dependency installation — automated in `setup_vpn_host.sh`, plus a fail-fast
  `check_deps` guard before `vpn_namespaces.sh up`
- ✅ IP-address hardcoding — updated by `setup_vpn_host.sh`
- ✅ Config backup/restore — `vpn_namespaces.sh backup` / `restore`
- ✅ State validation — `vpn_namespaces.sh validate` checks each netns + wg interface

- ✅ Client steering — `vpn_namespaces.sh steering apply/add/remove/list/clear`,
  and a full `up` auto-applies the rules (so boot via systemd is fully steered)
- ✅ Boot persistence — `systemctl enable vpn-namespaces` (enabled on this host)

### Still planned

- ⚠️ Health monitoring cron — auto-detect/recover failed namespaces
- ⚠️ Pre-apply config validation — verify WireGuard configs before bringing tunnels up
- ⚠️ Scheduled harvest — daily cron to refresh rotating NordVPN endpoints

---

## Validation notes & fixes (<date>)

Live testing on host <vpn-host> uncovered and fixed two bugs in
`vpn_namespaces.sh` that would have broken any post-reset recovery (the
already-running tunnels only survived because they had never been restarted):

1. **`wg setconf` rejected the configs.** Harvested configs are in wg-quick
   format (they carry `Address` / `DNS` lines), which `wg setconf` does not
   accept (`Line unrecognized: 'Address=...'`). Fixed by loading the stripped
   config: `wg setconf "$iface" <(wg-quick strip "$config_file")`.
2. **WireGuard interface left DOWN after the netns move.** Moving an interface
   into a namespace administratively sets it down; the script never brought it
   back up, so the next route command failed with *"Device for nexthop is not
   up."* Fixed by `ip netns exec "$netns" ip link set "$wg_iface" up` after the
   move.

Also added: a handshake **poll** in `up` (a freshly restarted tunnel — new
source port — can be briefly rejected by NordVPN until the prior session expires
server-side; the poll waits and nudges traffic instead of a one-shot `sleep 3`
that produced false `?? Geo` warnings), the `steering` subcommand, `validate` /
`backup` / `restore`, `check_deps`, and auto-steering at the end of a full `up`.

### Operational notes

- **Restart re-handshake lag.** After tearing a tunnel down and back up, NordVPN
  may reject the new handshake for a few minutes until the old session times out
  server-side; the tunnel then recovers on its own. This is expected, not a
  config failure — the keys are still valid.
- **`nordvpn connect` (CLI) was failing on the host** during testing — even a
  generic connect returned *"We couldn't connect you to the VPN."* The static
  tunnels don't need it (they use harvested configs), but a fresh **re-harvest**
  is currently blocked. If configs ever need refreshing, this needs sorting
  first (try `systemctl restart nordvpnd`, check the device-connection limit, or
  use the API downloader `download_nordvpn_configs.sh`).

---

## Known Issues & Next Steps

- SSH may lock during NordVPN connect/disconnect — use the daemon method.
  (During this round, with `firewall disabled`, SSH stayed up throughout.)
- `ip netns exec` requires sudo/capabilities.
- WireGuard configs may expire as NordVPN rotates servers — re-harvest periodically.

**Next steps:** add a health-monitoring cron job, and schedule automatic config
refresh (daily harvest) to keep up with rotating NordVPN endpoints.

---

**Repository:** `~/code/tunnels/` (app lives in `src/`)
