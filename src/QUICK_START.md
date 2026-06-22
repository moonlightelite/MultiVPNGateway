# Quick Start

Namespace-based multi-country VPN host: one isolated network namespace per
configured country, each with its own NordVPN WireGuard tunnel, and policy-based
routing to steer LAN clients out a chosen country. The countries are defined in
`config.yaml` (this repo ships Taiwan, Singapore, Netherlands, South Korea, Japan).

- **First-time install:** the [Install](#install-from-scratch) section below.
- **Day-to-day operation:** [Operation](#operation).
- **Recovering a reset host** (configs already harvested): `RECOVERY.md` — faster
  than a full install.

Scripts + docs live in `src/`; on the host they're installed under `/etc/vpn/`.
Run everything as root.

---

## Install (from scratch)

**Target:** Debian host with a single routed uplink (this deployment: `ens18`,
host `<vpn-host>`, LAN gateway `<lan-gateway>`).

### 1. Get the repo onto the host

```bash
git clone <repo> ~/code/tunnels   # or scp the directory over
cd ~/code/tunnels/src              # all scripts + docs live in src/
```

### 2. Base setup (deps, dirs, NordVPN, IP forwarding, systemd unit)

```bash
sudo bash setup_vpn_host.sh
```

Installs `wireguard-tools`, `yq`, `jq`, `bridge-utils`, `iptables`, the NordVPN
CLI; creates `/etc/vpn/{keys,namespaces,steering}` + the backup dir; enables IP
forwarding; and writes the `vpn-namespaces` systemd unit.

### 3. Install the management files

`setup_vpn_host.sh` does **not** place these — install them from `src/`:

```bash
sudo install -m0755 vpn_namespaces.sh /etc/vpn/vpn_namespaces.sh
sudo install -m0755 generate_config.sh /etc/vpn/generate_config.sh
sudo install -m0644 regions.sh        /etc/vpn/regions.sh
sudo install -m0644 config.yaml       /etc/vpn/config.yaml
sudo install -m0644 rules.yaml        /etc/vpn/steering/rules.yaml
```

`config.yaml` drives the whole system — every script reads the region list from it
via `regions.sh` (keep those two side by side, in `src/` and at `/etc/vpn/`).
`rules.yaml` maps client IPs to namespaces.

**Choosing countries:** `config.yaml` is generated from a country list — to use a
different set, regenerate it instead of hand-editing:

```bash
# auto-detects uplink + LAN, resolves ISO codes via NordVPN's API, allocates
# subnets/tables; preview with --dry-run, override host facts with --uplink/--lan
sudo ./generate_config.sh Taiwan Singapore Netherlands South_Korea Japan
```

The shipped `config.yaml` already defines `tw sg nl kr jp` (tables 100–104), so you
can skip this and use it as-is.

### 4. Get WireGuard configs into `/etc/vpn/keys/`

You need `tw.conf sg.conf nl.conf kr.conf jp.conf` (wg-quick format). Pick one:

```bash
# A. Log in to NordVPN, then harvest via the CLI (connects per country)
sudo nordvpn login          # token or browser flow
sudo bash harvest_configs.sh

# B. Restore from a previous backup
sudo /etc/vpn/vpn_namespaces.sh restore
```

> If the NordVPN CLI (A) won't connect, harvest from a clean slate (tunnels down) —
> active tunnels consume NordVPN session slots. See `RECOVERY.md` › *Validation
> notes & fixes*. Validate any config with `wg-quick strip <file>` (keys are
> 44-char base64 ending in `=`).

### 5. Bring it up

```bash
sudo /etc/vpn/vpn_namespaces.sh up        # creates all enabled namespaces + applies steering
sudo /etc/vpn/vpn_namespaces.sh validate  # expect: all healthy, 0 unhealthy
```

### 6. Make it boot-persistent

```bash
sudo systemctl enable vpn-namespaces      # `up` (incl. steering) runs on boot
```

**Verify the install:**

```bash
sudo /etc/vpn/vpn_namespaces.sh status
for ns in $(yq '.namespaces[].id' /etc/vpn/config.yaml); do
  echo -n "$ns: "; sudo ip netns exec vpn-$ns curl -s --max-time 5 https://ipinfo.io/json | jq -r '"\(.ip) \(.country)/\(.city)"'
done
```

Each namespace should report its own country exit. Then point a client's gateway
at this host and confirm it exits via its steered country (see *Client steering*).

---

## Operation

Day-to-day, the single entry point is `/etc/vpn/vpn_namespaces.sh`:

```
up [id]   down [id]   status   validate   enable <id>   disable <id>   backup   restore
steering {apply | add <client> <id> | remove <client> | clear | list}
```

Namespace ids come from `config.yaml` (this repo ships `tw sg nl kr jp` — Taiwan,
Singapore, Netherlands, South Korea, Japan).

### Tunnels

```bash
sudo /etc/vpn/vpn_namespaces.sh up        # bring up all enabled namespaces (also applies steering)
sudo /etc/vpn/vpn_namespaces.sh up tw     # just one
sudo /etc/vpn/vpn_namespaces.sh down      # tear down all (or: down tw)
sudo /etc/vpn/vpn_namespaces.sh status    # handshake + exit IP per namespace
sudo /etc/vpn/vpn_namespaces.sh validate  # each netns + wg interface live? (exit 0 = all healthy)
```

> After a restart a tunnel may take a couple of minutes to re-handshake (NordVPN
> holds the old session briefly); `up` polls for the handshake, and the tunnel
> recovers on its own. Not a failure.

### Client steering

A client whose gateway is this host is sent out a chosen country.

```bash
sudo /etc/vpn/vpn_namespaces.sh steering apply              # load all of rules.yaml
sudo /etc/vpn/vpn_namespaces.sh steering add 192.168.1.50 tw   # one client -> Taiwan
sudo /etc/vpn/vpn_namespaces.sh steering add 192.168.1.50 jp   # re-steer (idempotent)
sudo /etc/vpn/vpn_namespaces.sh steering remove 192.168.1.50
sudo /etc/vpn/vpn_namespaces.sh steering list
```

Persistent client→country mappings live in `/etc/vpn/steering/rules.yaml`; edit
it, then `steering apply` (a full `up` also re-applies it).

### Enable / disable a country

Take a region out of service without losing its slot — `disable` flips `enabled`
in `config.yaml` and tears the namespace down; `up`/boot then skip it.

```bash
sudo /etc/vpn/vpn_namespaces.sh disable kr   # out of service (survives regen)
sudo /etc/vpn/vpn_namespaces.sh enable kr && sudo /etc/vpn/vpn_namespaces.sh up kr
```

To change *which* countries exist (add/remove/reorder), regenerate `config.yaml`
— it preserves your `enabled` choices:

```bash
sudo /etc/vpn/generate_config.sh Taiwan Singapore Netherlands South_Korea Japan
sudo /etc/vpn/vpn_namespaces.sh down && sudo /etc/vpn/vpn_namespaces.sh up
```

### Check exits

```bash
# One namespace
sudo ip netns exec vpn-tw curl -s https://ipinfo.io/json | jq

# All at once
for ns in $(yq '.namespaces[].id' /etc/vpn/config.yaml); do
  echo -n "$ns: "; sudo ip netns exec vpn-$ns curl -s --max-time 5 https://api.ip.sb/ip
done

# From a steered client (should show its country's exit, not your ISP)
ssh user@192.168.1.50 'curl -s https://api.ip.sb/ip'
```

### Run anything through a country

```bash
sudo ip netns exec vpn-kr <command>          # e.g. curl/ping/traceroute via Seoul
```

### Configs: backup / restore

```bash
sudo /etc/vpn/vpn_namespaces.sh backup    # /etc/vpn/keys -> persistent backup dir
sudo /etc/vpn/vpn_namespaces.sh restore   # backup dir -> /etc/vpn/keys (then `up`)
```

### Service (boot persistence)

```bash
sudo systemctl status vpn-namespaces
sudo systemctl restart vpn-namespaces     # = down then up (+ steering)
sudo journalctl -u vpn-namespaces -n 50
```

### If a tunnel is wrong/dead

```bash
sudo /etc/vpn/vpn_namespaces.sh down tw && sudo /etc/vpn/vpn_namespaces.sh up tw
sudo /etc/vpn/vpn_namespaces.sh validate
```

Still broken? The WireGuard config may have expired — re-harvest (Install step 4
above) and `up` again. Full troubleshooting is in `RECOVERY.md`.
