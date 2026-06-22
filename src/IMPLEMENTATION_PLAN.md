# VPN Namespace Manager - Implementation Plan

**Version:** 2.0.0
**Date:** 2026-06-09
**Author:** Security Research Infrastructure Team
**Status:** Draft for Review (rev 2 — routed/PBR architecture)

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Architecture Overview](#2-architecture-overview)
3. [Configuration Specifications](#3-configuration-specifications)
4. [Component Design](#4-component-design)
5. [Implementation Details](#5-implementation-details)
6. [CLI Reference](#6-cli-reference)
7. [Testing Strategy](#7-testing-strategy)
8. [Deployment Guide](#8-deployment-guide)
9. [Troubleshooting](#9-troubleshooting)
10. [Future Enhancements](#10-future-enhancements)
11. [Appendices](#11-appendices)

---

## 1. Executive Summary

### 1.1 Purpose

This document provides a comprehensive implementation plan for a **VPN Namespace
Manager** — a host-native solution for managing multiple simultaneous VPN
connections in isolated Linux network namespaces. The system enables researchers
to test connectivity from different geographic locations by steering specific
test clients through specific VPN exit nodes.

### 1.2 Problem Statement

Current limitations of the existing `vpn.sh` / `update.sh` scripts:

- **Hardcoded configuration**: Country list, IP addresses, and interface names are embedded in code
- **No client steering**: All traffic uses default routing; cannot direct specific clients to specific VPN exits
- **Limited visibility**: No health monitoring, status reporting, or connection verification
- **Single provider**: Tightly coupled to NordVPN CLI; no support for other providers
- **No configuration validation**: Configs are not validated before use; stale configs cause failures
- **Poor error handling**: Failures leave system in inconsistent state; no rollback mechanism
- **No operational tooling**: Manual namespace management; no unified CLI

### 1.3 Changes from v1.0.0

Version 1.0.0 described two incompatible steering models simultaneously (L2
bridging of the uplink with namespace veths, and L3 fwmark-based policy
routing). Version 2.0.0 adopts a **pure routed (L3) architecture**:

| Area | v1.0.0 | v2.0.0 |
|------|--------|--------|
| Topology | `br0` bridge enslaving `ens20` + all veths | **No bridge.** Routed veth pairs; host IP stays on `ens20` |
| Steering | fwmark PBR *and* bridged client addressing (conflicting) | fwmark PBR only; clients use the VPN host as default gateway |
| Return path | Unspecified (packets would exit `wg` interface) | Explicit LAN route inside each namespace via host-side veth IP |
| Host-side veth | No IP, enslaved to bridge, used as route device (invalid) | Carries `.2` of each gateway subnet; valid route nexthop |
| Discovery | Private key never captured; geo lookup ran after disconnect | Full `wg showconf` captured (key file, mode 0600); geo verified **before** disconnect |
| Key storage | Private key embedded in world-readable JSON in `/run` | Keys in `/var/lib/vpn/keys/*.conf` (root, 0600); state JSON references the path |
| Persistence | Everything in `/run` (tmpfs, lost at boot) despite restore service | Discovered configs in `/var/lib/vpn` (persistent); only runtime status in `/run` |
| Health loop | Interval configured but nothing executed it | `vpn-health.timer` systemd unit drives checks and DEGRADED recovery |
| DNS | Unaddressed | Per-namespace `resolv.conf`; optional client DNS redirect into tunnel |
| IPv6 | "Skipped" with no leak handling | v6 forwarding blocked for steered clients + deployment guidance |
| MSS/MTU | MTU only | MTU 1420 + TCP MSS clamping in each namespace |
| rp_filter | Unaddressed (strict mode drops PBR return traffic) | Loose mode (`rp_filter=2`) set explicitly |
| Missing sections | 5.2.5–5.2.9 referenced but absent | All libraries fully specified |

### 1.4 Solution Overview

A modular, configuration-driven system with:

- **Declarative configuration**: YAML-based config for namespaces, providers, and client steering
- **Dynamic discovery**: Automatic extraction of WireGuard parameters from VPN connections
- **Policy-Based Routing**: Client steering via iptables marks and per-namespace routing tables
- **Multi-provider support**: Pluggable provider architecture (NordVPN, custom WireGuard)
- **State management**: Persistent discovered configs + ephemeral runtime state, with validation
- **Health monitoring**: Connectivity and geo-location verification, driven by a systemd timer
- **Unified CLI**: Single command interface for all operations

### 1.5 Key Features

| Feature | Status | Priority |
|---------|--------|----------|
| Network namespace isolation | Planned | P0 |
| Policy-Based Routing (PBR) | Planned | P0 |
| Client steering by IP | Planned | P0 |
| Dynamic WireGuard config discovery | Planned | P0 |
| Credential lifetime validation (Phase 0 spike) | Planned | P0 |
| Multi-provider support | Planned | P1 |
| State persistence & validation | Planned | P1 |
| Health monitoring (geo-IP, multi-service fallback) | Planned | P1 |
| Automatic repair (re-discover + restart) | Planned | P1 |
| DNS leak mitigation | Planned | P1 |
| IPv6 leak blocking | Planned | P1 |
| SSL inspection (stub) | Future | P3 |
| QoS/traffic shaping (stub) | Future | P3 |
| Prometheus metrics (stub) | Future | P3 |

### 1.6 Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Topology | Routed veth pairs, **no bridge** | Bridge added L2 exposure and could not coexist with PBR; routing is the only model that supports dynamic steering |
| Client gateway | Clients use the VPN host as default gateway | Required for host PBR to see client traffic; router policy-routes are the documented alternative |
| Configuration format | YAML | Human-readable, supports comments, widely adopted |
| YAML parser | `yq` (mikefarah v4) | Lightweight, CLI-friendly, no Python dependency |
| Namespace naming | `vpn-{id}` (e.g., `vpn-tw`) | Clear, consistent, avoids conflicts |
| Interface naming | `veth-{id}` (host), `veth0` (in ns), `wg-{id}` | Short (≤15 chars), wildcard-matchable (`veth-+`) in iptables |
| Routing tables / marks | Fixed mapping, table == mark (100–104) | Predictable, debuggable, no allocation logic |
| WireGuard socket | Interface created in **host** netns, then moved | The WG UDP socket stays in the creating netns, so encrypted traffic egresses via the host's normal default route — this is the load-bearing trick that gives namespaces internet without an uplink veth |
| ListenPort handling | Stripped from harvested configs | All five WG sockets live in the host netns; identical ListenPorts would collide. Kernel picks ephemeral ports |
| Key storage | `/var/lib/vpn/keys/{id}.conf`, root:root 0600 | Secrets never enter JSON state or `/run` |
| Persistence split | `/var/lib/vpn` (discovered) vs `/run/vpn` (runtime) | Survives reboot without re-discovery; tmpfs holds only ephemeral status |
| rp_filter | Loose (`2`) on all + veth interfaces | Strict reverse-path filtering drops the asymmetric PBR return traffic |
| MSS clamping | `--clamp-mss-to-pmtu` in each namespace | PMTUD frequently fails through consumer NAT; prevents TCP stalls |
| IPv6 support | No v6 transport; v6 **forwarding blocked** for steered clients | Prevents silent geo-test invalidation via v6 bypass |
| Health check method | HTTP geo-IP API with fallback services | Verifies actual exit location, not just connectivity; no single-service dependency |
| Steering persistence | Saved to config file | Survives reboot; auditable |
| Error handling | Continue + summary | Partial functionality better than none |
| Concurrency | Sequential operations | Simpler debugging; no race conditions; respects provider connect limits |

### 1.7 Critical Assumption: NordLynx Credential Reuse

The architecture depends on harvested NordLynx (WireGuard) credentials remaining
valid after `nordvpn disconnect`, for up to `config_max_age` (default 24 h),
with up to five concurrent sessions from one host IP. NordVPN may rotate keys or
deregister peers server-side at any time. Therefore:

1. **Phase 0 of implementation is a validation spike** (Section 7.0) that
   measures actual credential lifetime before any other work proceeds.
2. Re-discovery on handshake failure is a **first-class recovery path**
   (`vpn_ctl repair`, Section 5.2.9 / 6.2), not an afterthought.
3. `config_max_age` must be set below the empirically measured lifetime.

### 1.8 Scope Boundaries

**In Scope:**
- Network namespace creation and lifecycle management
- WireGuard configuration discovery from NordVPN and static config files
- Policy-Based Routing for client steering
- Persistent state management and validation
- Health monitoring via geo-IP APIs, with automatic repair
- DNS and IPv6 leak mitigation for steered clients
- CLI interface for all operations
- Multi-provider plugin architecture

**Out of Scope (Future Phases):**
- Container-based deployment (Docker/Podman)
- Open vSwitch integration
- SSL/TLS deep packet inspection
- QoS/traffic shaping
- Prometheus/Grafana monitoring stack
- REST API for remote management
- Automatic VPN server selection/load balancing
- IPv6 transport through the tunnels

---

## 2. Architecture Overview

### 2.1 High-Level Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                              HOST SYSTEM                                  │
│                                                                           │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │                        MANAGEMENT PLANE                            │  │
│  │                                                                    │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌────────────────────────┐   │  │
│  │  │  vpn_ctl     │  │  Config      │  │  State                 │   │  │
│  │  │  (CLI)       │  │  Manager     │  │  Manager               │   │  │
│  │  │              │  │              │  │                        │   │  │
│  │  │  up/down     │  │  /etc/vpn/   │  │  /var/lib/vpn/  (keys, │   │  │
│  │  │  discover    │  │  config.yaml │  │    discovered configs) │   │  │
│  │  │  steering    │  │  steering/   │  │  /run/vpn/      (run-  │   │  │
│  │  │  health      │  │              │  │    time status only)   │   │  │
│  │  │  repair      │  │              │  │                        │   │  │
│  │  └──────────────┘  └──────────────┘  └────────────────────────┘   │  │
│  │                                                                    │  │
│  │  ┌──────────────────────────────────────────────┐                  │  │
│  │  │         Provider Abstraction Layer           │                  │  │
│  │  │   ┌───────────┐   ┌───────────────────────┐  │                  │  │
│  │  │   │ NordVPN   │   │ Custom (static WG     │  │                  │  │
│  │  │   │ (CLI)     │   │ config files)         │  │                  │  │
│  │  │   └───────────┘   └───────────────────────┘  │                  │  │
│  │  └──────────────────────────────────────────────┘                  │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │                          DATA PLANE                                │  │
│  │                                                                    │  │
│  │   ens20 (192.168.1.10/24) ── host main routing table               │  │
│  │     │                                                              │  │
│  │     │  mangle PREROUTING: VPN_STEER chain                          │  │
│  │     │    -s 192.168.1.0/24 -d 192.168.1.0/24  → RETURN (LAN)       │  │
│  │     │    -s 192.168.1.50  → MARK 100                               │  │
│  │     │    -s 192.168.1.51  → MARK 101                               │  │
│  │     │                                                              │  │
│  │     │  ip rules: fwmark 100 → table 100, fwmark 101 → table 101 …  │  │
│  │     │                                                              │  │
│  │     ▼                                                              │  │
│  │   ┌─────────────────────────┐   ┌─────────────────────────┐        │  │
│  │   │ veth-tw  172.30.30.2/24 │   │ veth-sg  172.30.31.2/24 │  ...   │  │
│  │   │  table 100: default via │   │  table 101: default via │        │  │
│  │   │  172.30.30.1 dev veth-tw│   │  172.30.31.1 dev veth-sg│        │  │
│  │   └───────────┬─────────────┘   └───────────┬─────────────┘        │  │
│  │               │ veth pair                   │ veth pair            │  │
│  │   ┌───────────▼─────────────┐   ┌───────────▼─────────────┐        │  │
│  │   │ netns vpn-tw            │   │ netns vpn-sg            │        │  │
│  │   │  veth0  172.30.30.1/24  │   │  veth0  172.30.31.1/24  │        │  │
│  │   │  wg-tw  (10.5.0.x/32)   │   │  wg-sg  (10.5.0.x/32)   │        │  │
│  │   │  default dev wg-tw      │   │  default dev wg-sg      │        │  │
│  │   │  192.168.1.0/24 via .2  │   │  192.168.1.0/24 via .2  │        │  │
│  │   │  MASQUERADE → wg-tw     │   │  MASQUERADE → wg-sg     │        │  │
│  │   └───────────┬─────────────┘   └───────────┬─────────────┘        │  │
│  │               │ encrypted UDP (socket lives │                      │  │
│  │               │ in HOST netns → egresses    │                      │  │
│  │               │ via ens20 default route)    │                      │  │
│  └───────────────┼─────────────────────────────┼──────────────────────┘  │
└──────────────────┼─────────────────────────────┼─────────────────────────┘
                   ▼                             ▼
            Taiwan VPN server             Singapore VPN server
```

There is **no bridge**. `ens20` keeps the host's IP and remains a normal routed
interface. Each namespace connects to the host through a dedicated routed veth
pair, and the only path from a client to a namespace is an L3 routing decision
on the host — which is exactly what the steering marks control.

**Why the tunnels work without an uplink:** each `wg-{id}` interface is created
in the **host** namespace and then moved into `vpn-{id}`. A WireGuard
interface's UDP socket is permanently bound to the namespace in which the
interface was *created*, so encrypted packets to the VPN server egress through
the host's main routing table via `ens20`, while the cleartext side of the
tunnel lives inside the namespace. Implementers must not "fix" the bring-up
order by creating the interface inside the namespace — that breaks endpoint
reachability.

### 2.2 Network Topology and Addressing Plan

```
Internet ──► [Router 192.168.1.1] ──► 192.168.1.0/24 LAN
                                          │
                  ┌───────────────────────┼──────────────────────┐
                  │                       │                      │
            Test clients          VPN Host (ens20)         Other hosts
          192.168.1.50-54           192.168.1.10          (not steered)
          default gw = .10
          (see Section 2.6)
```

| id | netns | Country | Gateway subnet | ns gateway (veth0) | host veth IP | host veth | WG iface | table/mark |
|----|-------|---------|----------------|--------------------|--------------|-----------|----------|------------|
| tw | vpn-tw | Taiwan | 172.30.30.0/24 | 172.30.30.1 | 172.30.30.2 | veth-tw | wg-tw | 100 |
| sg | vpn-sg | Singapore | 172.30.31.0/24 | 172.30.31.1 | 172.30.31.2 | veth-sg | wg-sg | 101 |
| nl | vpn-nl | Netherlands | 172.30.32.0/24 | 172.30.32.1 | 172.30.32.2 | veth-nl | wg-nl | 102 |
| us | vpn-us | United States | 172.30.33.0/24 | 172.30.33.1 | 172.30.33.2 | veth-us | wg-us | 103 |
| jp | vpn-jp | Japan | 172.30.34.0/24 | 172.30.34.1 | 172.30.34.2 | veth-jp | wg-jp | 104 |

All interface names are ≤ 15 characters (IFNAMSIZ) and the `veth-` prefix
allows `iptables -i veth-+` wildcard matching for the isolation rules.

The gateway subnets are pure transit links between the host and each namespace.
Clients never hold addresses in them (that was the v1 Model A leftover; the
`client_range` field is removed).

### 2.3 Data Flow

#### 2.3.1 Outbound (Client → Internet via Taiwan)

```
1. Client 192.168.1.50 sends packet to 8.8.8.8:443
   (client's default gateway is the VPN host, 192.168.1.10)
        │
2. Host receives on ens20; mangle PREROUTING → VPN_STEER chain
   - dst is not in 192.168.1.0/24, so LAN bypass does not match
   - rule "-s 192.168.1.50 -j MARK --set-mark 100" fires
        │
3. Routing decision: ip rule "fwmark 100 lookup 100"
   table 100: "default via 172.30.30.1 dev veth-tw"
   (valid nexthop: host owns 172.30.30.2/24 on veth-tw)
        │
4. Host filter FORWARD (VPN_FWD chain) permits ens20 → veth-+
        │
5. Packet crosses the veth pair into netns vpn-tw (arrives on veth0)
        │
6. Namespace FORWARD: veth0 → wg-tw permitted; TCP SYN gets
   MSS clamped to PMTU
        │
7. Namespace nat POSTROUTING: "-o wg-tw -j MASQUERADE"
   source rewritten 192.168.1.50 → 10.5.0.x  (the WireGuard
   interface address — NOT the veth gateway IP)
        │
8. Namespace routing: "default dev wg-tw" → WireGuard encrypts
        │
9. Encrypted UDP egresses from the HOST netns (socket trick,
   Section 2.1) via ens20 → router → Taiwan VPN server
        │
10. VPN server decrypts and forwards; source appears as Taiwan exit IP
```

#### 2.3.2 Inbound (Return traffic)

```
1. Reply 8.8.8.8:443 → Taiwan exit IP reaches the VPN server,
   which encrypts it back over the tunnel
        │
2. Encrypted UDP arrives at the host (ens20), is delivered to the
   WG socket, decrypted, and the cleartext packet appears on wg-tw
   INSIDE netns vpn-tw:  8.8.8.8:443 → 10.5.0.x
        │
3. Namespace conntrack reverses the MASQUERADE:
   destination 10.5.0.x → 192.168.1.50
        │
4. Namespace routing: "192.168.1.0/24 via 172.30.30.2 dev veth0"
   (explicit LAN return route — without it the packet would be
   sent back out wg-tw and lost)
        │
5. Packet crosses the veth pair to the host (arrives on veth-tw,
   src 8.8.8.8). Host rp_filter is LOOSE (=2): under strict mode
   this packet would be dropped, because the main table does not
   route 8.8.8.8 via veth-tw
        │
6. Host main table: 192.168.1.0/24 dev ens20 → delivered to client
```

Note the deliberate asymmetry: outbound is steered by fwmark into table 100;
return traffic uses the main table. This is correct and stateless on the host —
only the namespace performs NAT.

### 2.4 Steering Rule Semantics

The mangle `VPN_STEER` chain is evaluated in this order:

1. **(optional, when `dns_redirect: true`)** per-client DNS capture:
   `-s {client} -p udp --dport 53 -j MARK --set-mark {mark}` (and TCP 53).
   This intentionally precedes the LAN bypass so DNS queries addressed to the
   LAN resolver (e.g., the router) are pulled into the tunnel and DNAT-ed to a
   tunnel-side resolver inside the namespace (Section 5.2.6).
2. **LAN bypass:** `-s {lan} -d {lan} -j RETURN`. Client↔client, client↔host,
   and client↔router traffic is never steered. This also protects traffic
   destined to the VPN host itself from being misrouted into table {mark}
   (those tables contain only a default route).
3. **Per-client marks:** `-s {client} -j MARK --set-mark {mark}`.

ip rules use priority `1000 + mark` so they sit predictably between the
kernel's default rules.

**Conntrack caveat:** established flows keep their existing path until their
conntrack entries expire. `steering add`/`remove` therefore flushes the
client's conntrack entries (best-effort, if `conntrack(8)` is installed) so
steering changes take effect immediately.

### 2.5 Isolation Model

- Namespaces are **not** L2-adjacent (no shared bridge). The only inter-namespace
  path would be host routing, which is blocked by the `VPN_FWD` filter chain:
  `-i veth-+ -o veth-+ -j DROP`.
- Gateway subnets are not reachable from the LAN: `VPN_FWD` only permits
  `ens20 → veth-+` for *steered, marked* flows and the corresponding
  return traffic (conntrack ESTABLISHED).
- IPv6: the host does not advertise v6 routes; `ip6tables` drops any forwarded
  v6 traffic from steered clients as a backstop. See Section 8.6 for the LAN-side
  requirement (no rogue RAs reaching steered clients).

### 2.6 Client Gateway Requirement

Host PBR can only steer traffic that the host actually routes. Two supported
deployment options:

- **Option 1 (recommended):** steered clients use `192.168.1.10` (the VPN host)
  as their default gateway — via static config or per-host DHCP option 3
  reservations on the router.
- **Option 2:** clients keep the router as gateway, and the **router** is
  configured with policy routes sending traffic *from* each steered client IP
  to `192.168.1.10` as next-hop. (Requires a router that supports source-based
  routing; the VPN host configuration is identical.)

Either way, non-steered hosts on the LAN are unaffected.

### 2.7 State Machine

```
                 ┌─────────────┐
                 │  CREATED    │  (config loaded, nothing discovered)
                 └──────┬──────┘
                        │ discover()
                        ▼
                 ┌─────────────┐   failure (retry w/ backoff)
                 │ DISCOVERING ├──────────► back to CREATED
                 └──────┬──────┘
                        │ success: key file + state JSON written
                        ▼
                 ┌─────────────┐
        ┌───────►│ DISCOVERED  │  (persistent; survives reboot)
        │        └──────┬──────┘
        │               │ up()
        │               ▼
        │        ┌─────────────┐
        │        │  STARTING   │  (netns/veth/wg/routes/PBR applied)
        │        └──────┬──────┘
        │               │ health OK
        │               ▼
        │        ┌─────────────┐  health_check fails 3x  ┌─────────────┐
   repair():     │   ACTIVE    ├────────────────────────►│  DEGRADED   │
   re-discover   └──────┬──────┘                         └──────┬──────┘
   + restart            │ down()        recover: restart with   │
        │               │               cached config; if that  │
        │               │               fails → repair()        │
        │               ▼                        │              │
        │        ┌─────────────┐                 └──────────────┤
        │        │  STOPPING   │ ◄──── repair gives up (3x) ────┘
        │        └──────┬──────┘
        │               │ cleanup complete
        │               ▼
        │        ┌─────────────┐    up(): if cached config still
        └────────┤   STOPPED   │    valid → STARTING, else → CREATED
                 └─────────────┘
```

The ACTIVE→DEGRADED→recover transitions are executed by the health timer
(Section 8.5), not by the oneshot CLI; the CLI's `repair` command is the same
code path invoked manually.

---

## 3. Configuration Specifications

### 3.1 Directory Structure

```
/etc/vpn/                          (root:root 0755)
├── config.yaml                    # Main configuration file (0644)
├── providers/
│   ├── nordvpn.yaml               # NordVPN provider settings
│   └── custom.yaml                # Custom WireGuard provider settings
└── steering/
    └── rules.yaml                 # Client steering rules

/usr/local/lib/vpn/                (root:root 0755)
├── vpn_ctl                        # Main CLI entry point (0755; symlinked
│                                  #   from /usr/local/sbin/vpn_ctl)
├── lib/
│   ├── log.sh                     # Logging library
│   ├── config.sh                  # Configuration management
│   ├── state.sh                   # State file management
│   ├── provider.sh                # Provider abstraction
│   ├── discover.sh                # Configuration discovery
│   ├── namespace.sh               # Namespace lifecycle
│   ├── routing.sh                 # Policy-based routing
│   ├── steering.sh                # Client steering
│   └── health.sh                  # Health checks & repair
├── providers/
│   ├── nordvpn.sh                 # NordVPN provider plugin
│   └── custom.sh                  # Custom WireGuard provider plugin
└── tests/
    ├── unit.sh
    └── integration.sh

/var/lib/vpn/                      (root:root 0700)  — PERSISTENT
├── keys/
│   └── {id}.conf                  # Sanitized wg setconf files (0600,
│                                  #   contain PrivateKey)
└── namespaces/
    └── {id}.json                  # Discovered config metadata (0600,
                                   #   no secrets; references key file)

/run/vpn/                          (root:root 0700)  — EPHEMERAL (tmpfs)
└── status/
    └── {id}.json                  # Runtime status (state machine phase,
                                   #   health counters, applied rules)

/var/log/vpn/                      (root:root 0750)
└── vpn.log

/etc/systemd/system/
├── vpn-namespace.service          # Bring-up/teardown at boot
├── vpn-health.service             # Oneshot health pass
└── vpn-health.timer               # Drives vpn-health.service
```

Rationale for the split: `/run` is tmpfs and is wiped at boot. Discovered
WireGuard credentials must survive a reboot or every boot would require five
sequential NordVPN connect/disconnect cycles before any namespace could start.

### 3.2 Main Configuration File

**Path:** `/etc/vpn/config.yaml`

```yaml
# =============================================================================
# VPN Namespace Manager - Main Configuration
# =============================================================================

global:
  # Uplink interface (the host's LAN-facing routed interface).
  # 'auto' = detect default-route interface.
  uplink_iface: auto

  # LAN subnet containing steered clients. Used for:
  #  - the LAN bypass rule in the steering chain
  #  - the return route installed inside each namespace
  client_lan: 192.168.1.0/24

  # MTU for WireGuard interfaces
  mtu: 1420

  # Clamp TCP MSS to PMTU inside each namespace (recommended: true)
  clamp_mss: true

  # Timeout for provider connect + handshake wait (seconds).
  # Consumed by provider plugins (NORDVPN_TIMEOUT default, Section 5.3.1).
  connection_timeout: 30

  # Log level: debug, info, warn, error
  log_level: info
  log_file: /var/log/vpn/vpn.log

# -----------------------------------------------------------------------------
# Provider Configuration
# -----------------------------------------------------------------------------
providers:
  # Default provider when not specified per-namespace
  active: nordvpn

  nordvpn:
    type: cli
    tool: nordvpn
    # WireGuard interface created by the NordVPN daemon
    interface: nordlynx
    # Seconds to wait between sequential discoveries (provider rate limit)
    connection_cooldown: 5
    # Connect/handshake timeout comes from global.connection_timeout.
    # Preconditions enforced before discovery (see Section 5.3.1):
    # technology=nordlynx, killswitch=off, autoconnect=off

  custom:
    type: manual
    # Directory containing static WireGuard config files named {id}.conf
    config_dir: /etc/wireguard/custom

# -----------------------------------------------------------------------------
# Namespace Definitions
# -----------------------------------------------------------------------------
# Derived names (not configurable, kept consistent by convention):
#   netns:      vpn-{id}
#   host veth:  veth-{id}     (carries gateway_subnet .2)
#   ns veth:    veth0         (carries gateway_ip = .1)
#   wg iface:   wg-{id}
# mark == routing_table for every namespace.
namespaces:
  - id: tw
    provider: nordvpn
    country: Taiwan
    expected_country_code: TW
    gateway_subnet: 172.30.30.0/24
    gateway_ip: 172.30.30.1
    host_veth_ip: 172.30.30.2
    routing_table: 100
    enabled: true
    description: "Taiwan exit node for APAC testing"

  - id: sg
    provider: nordvpn
    country: Singapore
    expected_country_code: SG
    gateway_subnet: 172.30.31.0/24
    gateway_ip: 172.30.31.1
    host_veth_ip: 172.30.31.2
    routing_table: 101
    enabled: true
    description: "Singapore exit node for Southeast Asia testing"

  - id: nl
    provider: nordvpn
    country: Netherlands
    expected_country_code: NL
    gateway_subnet: 172.30.32.0/24
    gateway_ip: 172.30.32.1
    host_veth_ip: 172.30.32.2
    routing_table: 102
    enabled: true
    description: "Netherlands exit node for EU testing"

  - id: us
    provider: nordvpn
    country: United_States
    expected_country_code: US
    gateway_subnet: 172.30.33.0/24
    gateway_ip: 172.30.33.1
    host_veth_ip: 172.30.33.2
    routing_table: 103
    enabled: true
    description: "US exit node for North America testing"

  - id: jp
    provider: nordvpn
    country: Japan
    expected_country_code: JP
    gateway_subnet: 172.30.34.0/24
    gateway_ip: 172.30.34.1
    host_veth_ip: 172.30.34.2
    routing_table: 104
    enabled: true
    description: "Japan exit node for East Asia testing"

# -----------------------------------------------------------------------------
# Client Steering
# -----------------------------------------------------------------------------
client_steering:
  # Rules live in /etc/vpn/steering/rules.yaml (Section 3.5).
  rules_file: /etc/vpn/steering/rules.yaml

  # Pull client DNS (udp/tcp 53) into the tunnel and DNAT it to
  # dns_redirect_target inside the namespace. Prevents DNS queries to the
  # LAN resolver from leaking outside the VPN. See Section 2.4 for ordering.
  dns_redirect: false
  dns_redirect_target: 1.1.1.1

  # Resolver written to /etc/netns/vpn-{id}/resolv.conf so that
  # `vpn_ctl exec` / health checks resolve through the tunnel. Required
  # because the host's systemd-resolved stub (127.0.0.53) is unreachable
  # from inside a namespace.
  namespace_dns: [1.1.1.1, 1.0.0.1]

  # Block forwarded IPv6 from steered clients (backstop against geo bypass)
  block_ipv6: true

  # Behavior for client traffic that matches no rule:
  #   use_main_table — follows the host's normal default route (no VPN)
  #   drop           — adds a filter rule dropping unmatched steered-LAN
  #                    forwarding (strict lab mode)
  default_action: use_main_table

# -----------------------------------------------------------------------------
# State Management
# -----------------------------------------------------------------------------
state:
  # Persistent discovered-config storage
  lib_dir: /var/lib/vpn
  # Ephemeral runtime status
  run_dir: /run/vpn

  # Maximum age for discovered configs before re-discovery is forced
  # (seconds). MUST be set below the credential lifetime measured in the
  # Phase 0 spike (Section 7.0). 86400 = 24 h is the optimistic default.
  config_max_age: 86400

  # Validate cached configs (handshake within timeout) when restoring
  validate_on_restore: true

# -----------------------------------------------------------------------------
# Health Monitoring
# -----------------------------------------------------------------------------
health:
  # Executed by vpn-health.timer (Section 8.5); interval set there.
  # Consecutive failures before a namespace is marked DEGRADED:
  failure_threshold: 3
  # Repair attempts (re-discover + restart) before giving up → STOPPED:
  repair_attempts: 3
  # Seconds without a WireGuard handshake before the tunnel is considered dead
  # (WG handshakes occur at least every ~2 min under traffic/keepalive)
  handshake_max_age: 180
  # Geo-IP services, tried in order. Field mapping in Section 5.2.9.
  geo_services:
    - https://api.ip.sb/geoip
    - https://ipinfo.io/json
    - https://ifconfig.co/json
  curl_timeout: 10

# -----------------------------------------------------------------------------
# Stubs for Future Phases (disabled; schema reserved)
# -----------------------------------------------------------------------------
monitoring:
  enabled: false
ssl_inspection:
  enabled: false
qos:
  enabled: false
```

Removed from v1: `bridge:` section (no bridge exists), `client_range` (clients
never hold gateway-subnet addresses), `wg_interface` (derived as `wg-{id}`),
duplicated steering rules (single source of truth is `rules.yaml`), and the
unimplemented `logging.rotation` block (logrotate ships as a packaged config
instead, Section 8.2).

### 3.3 Provider Configuration Files

> **Scope note for implementers:** these files are *descriptive defaults and
> reserved schema* — they document provider behavior and hold room for future
> per-provider tuning, but the plugins in Section 5.3 do **not** parse them.
> The authoritative runtime knobs are in `config.yaml`
> (`global.connection_timeout`, `providers.nordvpn.connection_cooldown`,
> `providers.custom.config_dir` via the `CUSTOM_CONFIG_DIR` env default) plus
> the env overrides at the top of each plugin. Do not invent additional
> wiring from these YAML files; ship them as installed documentation.

#### 3.3.1 NordVPN Provider (`/etc/vpn/providers/nordvpn.yaml`)

```yaml
provider:
  name: nordvpn
  type: cli
  version: "2.0"

cli:
  tool: nordvpn
  check_command: "nordvpn version"
  connect_template: "nordvpn connect {country}"
  disconnect_template: "nordvpn disconnect"
  status_template: "nordvpn status"
  timeout: 30
  retry_count: 3
  retry_delay: 5

  # Settings enforced (via `nordvpn set ...`) before discovery runs.
  # killswitch/autoconnect interfere with namespace routing and harvesting.
  required_settings:
    technology: nordlynx
    killswitch: disabled
    autoconnect: disabled

discovery:
  # Single source of truth: `wg showconf nordlynx` run as root.
  # It contains [Interface] PrivateKey (+ListenPort,FwMark — both stripped)
  # and [Peer] PublicKey / AllowedIPs / Endpoint.
  method: wg_showconf
  interface: nordlynx
  # Interface address comes from `ip -j addr show nordlynx`
  # (`wg show <if> addresses` is NOT a valid wg subcommand).
  handshake_timeout: 30

limits:
  max_connections: 10
  connection_cooldown: 5
```

#### 3.3.2 Custom Provider (`/etc/vpn/providers/custom.yaml`)

```yaml
provider:
  name: custom
  type: manual
  version: "2.0"

manual:
  config_dir: /etc/wireguard/custom
  file_pattern: "{id}.conf"
  # No connect/disconnect cycle: discovery parses the file directly and the
  # namespace manager builds the interface itself (wg-quick is never used).
  required_fields: [PrivateKey, PublicKey, Endpoint, Address]
```

### 3.4 State File Schemas

#### 3.4.1 Discovered Config (`/var/lib/vpn/namespaces/{id}.json`, 0600, persistent)

Contains **no key material** — the private key stays in the referenced
`key_file`.

```json
{
  "version": "2.0.0",
  "namespace_id": "tw",
  "provider": "nordvpn",
  "country": "Taiwan",
  "expected_country_code": "TW",

  "wireguard": {
    "key_file": "/var/lib/vpn/keys/tw.conf",
    "wg_ip": "10.5.0.2/32",
    "wg_peer_public_key": "bmXCs...=",
    "wg_peer_endpoint": "45.76.123.45:51820",
    "wg_allowed_ips": "0.0.0.0/0",
    "mtu": 1420
  },

  "verification": {
    "external_ip": "103.253.41.98",
    "geo_country_code": "TW",
    "geo_city": "Taipei",
    "geo_service": "https://api.ip.sb/geoip",
    "verified_at": "2026-06-09T10:30:00Z"
  },

  "discovered_at": "2026-06-09T10:30:00Z",
  "valid_until": "2026-06-10T10:30:00Z"
}
```

#### 3.4.2 Runtime Status (`/run/vpn/status/{id}.json`, 0600, ephemeral)

```json
{
  "version": "2.0.0",
  "namespace_id": "tw",
  "phase": "ACTIVE",
  "started_at": "2026-06-09T10:30:10Z",
  "last_health_check": "2026-06-09T10:35:00Z",
  "last_handshake": "2026-06-09T10:34:55Z",
  "consecutive_failures": 0,
  "repair_attempts": 0,
  "last_error": null,
  "geo_verified": true,
  "actual_country_code": "TW"
}
```

Field names are identical between writer (`discover.sh`) and validator
(`state.sh`) — v1's `peer_endpoint` vs `wg_peer_endpoint` mismatch (which made
every cached state fail validation) is resolved by this single schema.

#### 3.4.3 Key File (`/var/lib/vpn/keys/{id}.conf`, 0600)

Sanitized `wg showconf` output, directly consumable by `wg setconf`:

```ini
[Interface]
PrivateKey = <base64>
# ListenPort and FwMark stripped during discovery:
#  - ListenPort: all WG sockets bind in the HOST netns; identical ports
#    harvested from nordlynx would collide across the 5 tunnels
#  - FwMark: NordVPN sets 0xca6c for its own routing; irrelevant here

[Peer]
PublicKey = <base64>
AllowedIPs = 0.0.0.0/0
Endpoint = 45.76.123.45:51820
PersistentKeepalive = 25
```

### 3.5 Client Steering Rules File

**Path:** `/etc/vpn/steering/rules.yaml`

```yaml
# =============================================================================
# Client Steering Rules — single source of truth
# =============================================================================
# Each rule maps one client IPv4 address to one namespace. The iptables mark
# and routing table are derived from the namespace (mark == routing_table);
# they are not configurable per rule.

rules:
  - client: 192.168.1.50
    namespace: tw
    description: "Research station A - Taiwan exit"
    enabled: true

  - client: 192.168.1.51
    namespace: sg
    description: "Research station B - Singapore exit"
    enabled: true

  - client: 192.168.1.52
    namespace: nl
    description: "Research station C - Netherlands exit"
    enabled: true

  - client: 192.168.1.53
    namespace: us
    description: "Research station D - US exit"
    enabled: true

  - client: 192.168.1.54
    namespace: jp
    description: "Research station E - Japan exit"
    enabled: true

# Advanced matching (MAC / dport based) is deferred to a future phase; the
# chain structure (Section 2.4) leaves room for it ahead of the per-client
# marks.
```

---

## 4. Component Design

### 4.1 Module Overview

| Module | File | Purpose | Dependencies |
|--------|------|---------|--------------|
| **CLI Entry Point** | `vpn_ctl` | Command parsing and orchestration | All lib modules |
| **Logger** | `lib/log.sh` | Leveled logging to stderr + file | — |
| **Config Manager** | `lib/config.sh` | YAML parsing, validation, defaults | `yq` |
| **State Manager** | `lib/state.sh` | Discovered-config + runtime-status I/O, validation | `jq` |
| **Provider Abstraction** | `lib/provider.sh` | Plugin loading and dispatch | Provider plugins |
| **Discovery Engine** | `lib/discover.sh` | Connect, harvest WG params, geo-verify, persist | Provider plugins, `wg`, `curl`, `jq` |
| **Namespace Manager** | `lib/namespace.sh` | netns/veth/WG lifecycle, in-ns firewall & routes | `ip`, `wg`, `iptables` |
| **Routing Manager** | `lib/routing.sh` | PBR tables, ip rules, sysctls, host filter chains | `ip`, `iptables`, `sysctl` |
| **Steering Controller** | `lib/steering.sh` | Client mark rules, rules.yaml sync, conntrack flush | `lib/routing.sh`, `yq`, `conntrack` (optional) |
| **Health Checker** | `lib/health.sh` | Handshake/connectivity/geo checks, DEGRADED handling, repair | `curl`, `jq`, `wg` |

**Sourcing model:** libraries never `source` each other. `vpn_ctl` (and only
`vpn_ctl`) sources all of them, in this order:
`log → config → state → provider → routing → namespace → steering → discover → health`.
Because bash resolves function names at call time, not parse time,
cross-library calls in *both* directions are legal once everything is sourced
(`discover.sh` calls `health_geo_lookup`; `health.sh` calls `discover_config`
and `namespace_up`). Implementers must keep this single-entry-point sourcing
model; do not add `source` lines inside libraries to "fix" forward references.

### 4.2 Interface Specifications

Function-level contracts. Full implementations are in the referenced sections —
**all of which exist in this revision**.

#### 4.2.1 Logger (`lib/log.sh`) — Section 5.2.1

```bash
log_debug "msg"   # shown when log_level=debug
log_info  "msg"
log_warn  "msg"
log_error "msg"   # always shown, goes to stderr and log file
```

#### 4.2.2 Config Manager (`lib/config.sh`) — Section 5.2.2

```bash
config_load [file]                 # validate YAML syntax, set CONFIG_FILE; 0/1
config_get <key.path> [default]    # scalar lookup, e.g. config_get global.mtu
config_query <yq-expression>       # raw yq expression for complex queries
config_get_enabled_namespaces      # enabled ids, one per line
config_get_ns_field <id> <field>   # field of one namespace entry
config_validate                    # schema + uniqueness + subnet checks; 0/1
```

`config_get` takes dotted key paths only; `config_query` takes full yq
expressions. (v1 routed yq expressions through `config_get`, which prepended a
dot and produced invalid `..namespaces[]` queries.)

#### 4.2.3 State Manager (`lib/state.sh`) — Section 5.2.3

```bash
state_init                          # create /var/lib/vpn + /run/vpn trees (0700)
discovered_path <id>                # echo path of discovered-config JSON
discovered_save <id> <json>         # atomic write, 0600
discovered_is_valid <id>            # JSON valid + fields present + key file
                                    #   exists + age < config_max_age; 0/1
runtime_set <id> <jq-filter>        # update runtime status atomically
runtime_get <id> <jq-path>          # read a runtime status field
runtime_delete <id>
state_list_runtime                  # ids with runtime status files
```

#### 4.2.4 Provider Plugin Contract — Sections 5.2.4, 5.3

Each plugin defines underscore-prefixed hooks; `lib/provider.sh` wraps them:

```bash
_provider_preflight                # verify tool present, enforce settings; 0/1
_provider_connect <country|id>     # establish provider connection; 0/1
_provider_disconnect <country|id>  # tear down provider connection
_provider_harvest <id> <key_file> <json_out>
                                   # write sanitized wg setconf file (0600) and
                                   # a JSON fragment {wg_ip, wg_peer_public_key,
                                   # wg_peer_endpoint, wg_allowed_ips}; 0/1
_provider_status                   # human-readable status
```

#### 4.2.5 Discovery Engine (`lib/discover.sh`) — Section 5.2.5

```bash
discover_config <id>               # full pipeline: preflight → connect →
                                   # harvest → geo-verify (BEFORE disconnect)
                                   # → disconnect → persist; 0/1
discover_all                       # sequential, with provider cooldown;
                                   # continue-on-error + summary
```

#### 4.2.6 Namespace Manager (`lib/namespace.sh`) — Section 5.2.6

```bash
namespace_up <id>                  # cached-or-rediscover, then build netns,
                                   # veth, WG (host-created, then moved),
                                   # in-ns routes, NAT, firewall, DNS; 0/1
namespace_down <id>                # tear down ns + veth + PBR table/rule
namespace_status <id>              # one-block status report
namespace_exists <id>              # netns vpn-{id} present; 0/1
```

#### 4.2.7 Routing Manager (`lib/routing.sh`) — Section 5.2.7

```bash
routing_sysctls                    # ip_forward=1, rp_filter=2 (all/default)
routing_host_chains_init           # create/flush VPN_STEER (mangle) and
                                   #   VPN_FWD (filter) chains, jump rules,
                                   #   inter-ns DROP, v6 backstop
routing_host_chains_teardown
routing_table_up <id>              # table N: default via gateway_ip dev veth-{id};
                                   #   ip rule pref 1000+N fwmark N lookup N
routing_table_down <id>
```

#### 4.2.8 Steering Controller (`lib/steering.sh`) — Section 5.2.8

```bash
steering_apply_all                 # sync VPN_STEER chain from rules.yaml
                                   #   (only for namespaces currently ACTIVE)
steering_clear                     # flush per-client rules
steering_add_client <ip> <id>      # add rule + persist to rules.yaml
steering_remove_client <ip>        # remove rule + persist
steering_list                      # table of configured vs applied rules
steering_flush_conntrack <ip>      # best-effort conntrack -D
```

#### 4.2.9 Health Checker (`lib/health.sh`) — Section 5.2.9

```bash
health_check <id>                  # handshake age + connectivity + geo match;
                                   #   updates runtime status; 0/1
health_check_all                   # all ACTIVE namespaces; drives the
                                   #   ACTIVE→DEGRADED transition and recovery
health_geo_lookup [netns]          # multi-service geo query, normalized JSON
repair_namespace <id>              # down → re-discover → up; bounded retries
```

### 4.3 Data Structures

Authoritative schemas are in Section 3.4. Summary:

- **Discovered config** (persistent, no secrets): provider, country,
  `wireguard{key_file, wg_ip, wg_peer_public_key, wg_peer_endpoint,
  wg_allowed_ips, mtu}`, `verification{...}`, `discovered_at`, `valid_until`.
- **Runtime status** (ephemeral): `phase` (state machine, Section 2.7),
  health counters, `last_error`.
- **Steering rule**: `{client, namespace, description, enabled}`; mark and
  table derive from the namespace.

---

## 5. Implementation Details

Shell conventions used throughout:

- `bash` with `set -u`; **not** `set -e` in libraries (explicit error handling;
  `set -e` interacts badly with `((x++))` and command-substitution returns).
  The CLI entry point uses `set -uo pipefail`.
- All mutating `ip`/`iptables` calls are idempotent: `iptables -C` before `-A`,
  `ip rule del` guarded by existence checks, `|| true` only where the failure
  is genuinely ignorable.
- Secrets are written with `umask 077` + `install -m 600`.

### 5.1 Setup Script (`setup.sh`)

```bash
#!/usr/bin/env bash
#
# setup.sh - Initialize VPN Namespace Manager directory structure
# Usage: sudo ./setup.sh
#
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/usr/local/lib/vpn"
CONFIG_DIR="/etc/vpn"
LIB_DIR="/var/lib/vpn"
RUN_DIR="/run/vpn"
LOG_DIR="/var/log/vpn"

# Minimal logging (lib/log.sh is not installed yet at this point)
info() { echo "[setup] $*"; }
fail() { echo "[setup] ERROR: $*" >&2; exit 1; }

info "Checking dependencies..."
for dep in yq jq wg ip iptables curl; do
    command -v "$dep" >/dev/null 2>&1 || fail "$dep not found in PATH"
done
yq --version 2>/dev/null | grep -q 'v4' || fail "yq v4 (mikefarah) required"

info "Creating directories..."
install -d -m 755 "$INSTALL_DIR" "$INSTALL_DIR/lib" "$INSTALL_DIR/providers" \
                  "$INSTALL_DIR/tests"
install -d -m 755 "$CONFIG_DIR" "$CONFIG_DIR/providers" "$CONFIG_DIR/steering"
install -d -m 700 "$LIB_DIR" "$LIB_DIR/keys" "$LIB_DIR/namespaces"
install -d -m 700 "$RUN_DIR" "$RUN_DIR/status"
install -d -m 750 "$LOG_DIR"
# NOTE: directories need the execute bit; v1's `chmod 644` on /etc/vpn made
# the config directory untraversable.

info "Installing program files..."
install -m 755 "$SCRIPT_DIR/vpn_ctl" "$INSTALL_DIR/vpn_ctl"
install -m 644 "$SCRIPT_DIR"/lib/*.sh "$INSTALL_DIR/lib/"
install -m 644 "$SCRIPT_DIR"/providers/*.sh "$INSTALL_DIR/providers/"
ln -sf "$INSTALL_DIR/vpn_ctl" /usr/local/sbin/vpn_ctl

info "Installing default configuration (existing files preserved)..."
for f in config.yaml steering/rules.yaml providers/nordvpn.yaml providers/custom.yaml; do
    dest="$CONFIG_DIR/$f"
    if [[ -f "$dest" ]]; then
        info "  $dest already exists, skipping"
    else
        install -m 644 "$SCRIPT_DIR/templates/${f##*/}.example" "$dest"
        info "  created $dest"
    fi
done

info "Installing systemd units..."
install -m 644 "$SCRIPT_DIR"/systemd/vpn-namespace.service \
               "$SCRIPT_DIR"/systemd/vpn-health.service \
               "$SCRIPT_DIR"/systemd/vpn-health.timer \
               /etc/systemd/system/
install -m 644 "$SCRIPT_DIR/templates/vpn.logrotate" /etc/logrotate.d/vpn
systemctl daemon-reload

info "Setup complete. Next steps:"
info "  1. Edit $CONFIG_DIR/config.yaml (namespaces, LAN subnet)"
info "  2. Edit $CONFIG_DIR/steering/rules.yaml (client steering)"
info "  3. vpn_ctl config validate"
info "  4. vpn_ctl discover all      # requires nordvpn login"
info "  5. vpn_ctl up all"
info "  6. systemctl enable --now vpn-health.timer"
```

### 5.2 Core Library Implementations

#### 5.2.1 Logger (`lib/log.sh`)

```bash
#!/usr/bin/env bash
#
# log.sh - Leveled logging to stderr and the log file.
#

VPN_LOG_LEVEL="${VPN_LOG_LEVEL:-info}"
VPN_LOG_FILE="${VPN_LOG_FILE:-/var/log/vpn/vpn.log}"

_log_level_num() {
    case "$1" in
        debug) echo 0 ;;
        info)  echo 1 ;;
        warn)  echo 2 ;;
        error) echo 3 ;;
        *)     echo 1 ;;
    esac
}

_log() {
    local level="$1"; shift
    local want have
    want=$(_log_level_num "$VPN_LOG_LEVEL")
    have=$(_log_level_num "$level")
    [[ "$have" -lt "$want" ]] && return 0

    local line
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [$level] $*"
    echo "$line" >&2
    if [[ -w "$VPN_LOG_FILE" || -w "$(dirname "$VPN_LOG_FILE")" ]]; then
        echo "$line" >> "$VPN_LOG_FILE" 2>/dev/null || true
    fi
}

log_debug() { _log debug "$@"; }
log_info()  { _log info  "$@"; }
log_warn()  { _log warn  "$@"; }
log_error() { _log error "$@"; }
```

#### 5.2.2 Configuration Manager (`lib/config.sh`)

```bash
#!/usr/bin/env bash
#
# config.sh - YAML configuration access (yq v4).
#

CONFIG_FILE="${CONFIG_FILE:-/etc/vpn/config.yaml}"
CONFIG_LOADED=false

config_load() {
    local config_file="${1:-$CONFIG_FILE}"

    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        return 1
    fi
    if ! yq eval '.' "$config_file" >/dev/null 2>&1; then
        log_error "Invalid YAML syntax in $config_file"
        return 1
    fi

    CONFIG_FILE="$config_file"
    CONFIG_LOADED=true
    # Propagate logging config early
    VPN_LOG_LEVEL=$(config_get global.log_level info)
    VPN_LOG_FILE=$(config_get global.log_file /var/log/vpn/vpn.log)
    log_debug "Configuration loaded from $config_file"
    return 0
}

_config_ensure_loaded() {
    [[ "$CONFIG_LOADED" == "true" ]] || config_load "$CONFIG_FILE"
}

# Scalar lookup by dotted key path: config_get global.mtu [default]
config_get() {
    local key_path="$1" default="${2:-}"
    _config_ensure_loaded || return 1

    local value
    value=$(yq eval ".${key_path}" "$CONFIG_FILE" 2>/dev/null)
    if [[ -z "$value" || "$value" == "null" ]]; then
        if [[ -n "$default" ]]; then echo "$default"; return 0; fi
        return 1
    fi
    echo "$value"
}

# Raw yq expression for anything beyond a scalar key path.
config_query() {
    _config_ensure_loaded || return 1
    yq eval "$1" "$CONFIG_FILE" 2>/dev/null
}

config_get_enabled_namespaces() {
    config_query '.namespaces[] | select(.enabled == true) | .id'
}

config_get_ns_field() {
    local ns_id="$1" field="$2"
    local value
    value=$(config_query ".namespaces[] | select(.id == \"$ns_id\") | .$field")
    [[ -n "$value" && "$value" != "null" ]] || return 1
    echo "$value"
}

# Resolve uplink interface ('auto' → default route device)
config_uplink_iface() {
    local iface
    iface=$(config_get global.uplink_iface auto)
    if [[ "$iface" == "auto" ]]; then
        iface=$(ip -j route show default 2>/dev/null | jq -r '.[0].dev // empty')
        [[ -n "$iface" ]] || { log_error "Cannot auto-detect uplink interface"; return 1; }
    fi
    echo "$iface"
}

config_validate() {
    _config_ensure_loaded || return 1
    local errors=()

    [[ -n "$(config_get global.client_lan '')" ]] || \
        errors+=("global.client_lan is required")

    local ns_count
    ns_count=$(config_query '.namespaces | length')
    [[ "$ns_count" -gt 0 ]] || errors+=("At least one namespace must be defined")

    local dup
    dup=$(config_query '.namespaces[].id' | sort | uniq -d)
    [[ -z "$dup" ]] || errors+=("Duplicate namespace IDs: $dup")

    dup=$(config_query '.namespaces[].routing_table' | sort | uniq -d)
    [[ -z "$dup" ]] || errors+=("Duplicate routing tables: $dup")

    dup=$(config_query '.namespaces[].gateway_subnet' | sort | uniq -d)
    [[ -z "$dup" ]] || errors+=("Duplicate gateway subnets: $dup")

    local ns_id field
    for ns_id in $(config_get_enabled_namespaces); do
        for field in country expected_country_code gateway_subnet gateway_ip \
                     host_veth_ip routing_table; do
            config_get_ns_field "$ns_id" "$field" >/dev/null || \
                errors+=("Namespace $ns_id: missing $field")
        done
        # Ids become interface names: lowercase alnum only, and short
        # enough that veth-{id} / vp-{id} / wg-{id} fit IFNAMSIZ (15)
        if [[ ! "$ns_id" =~ ^[a-z0-9]+$ ]]; then
            errors+=("Namespace id '$ns_id' invalid (lowercase a-z0-9 only)")
        fi
        if [[ "${#ns_id}" -gt 9 ]]; then
            errors+=("Namespace id '$ns_id' too long (max 9 chars for veth-/wg- names)")
        fi
        local table
        table=$(config_get_ns_field "$ns_id" routing_table) || continue
        if [[ "$table" -lt 100 || "$table" -gt 252 ]]; then
            errors+=("Namespace $ns_id: routing_table $table outside safe range 100-252")
        fi
    done

    # Steering rules must reference defined namespaces
    local rules_file
    rules_file=$(config_get client_steering.rules_file /etc/vpn/steering/rules.yaml)
    if [[ -f "$rules_file" ]]; then
        local ref
        for ref in $(yq eval '.rules[] | select(.enabled == true) | .namespace' "$rules_file" 2>/dev/null); do
            config_get_ns_field "$ref" id >/dev/null 2>&1 || \
                errors+=("Steering rule references unknown namespace: $ref")
        done
        dup=$(yq eval '.rules[] | select(.enabled == true) | .client' "$rules_file" | sort | uniq -d)
        [[ -z "$dup" ]] || errors+=("Duplicate steering clients: $dup")
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        log_error "Configuration validation failed:"
        local e; for e in "${errors[@]}"; do log_error "  - $e"; done
        return 1
    fi
    log_info "Configuration validation passed"
    return 0
}
```

#### 5.2.3 State Manager (`lib/state.sh`)

```bash
#!/usr/bin/env bash
#
# state.sh - Persistent discovered configs (/var/lib/vpn) and ephemeral
# runtime status (/run/vpn). Atomic writes, restrictive modes.
#

VPN_LIB_DIR="${VPN_LIB_DIR:-/var/lib/vpn}"
VPN_RUN_DIR="${VPN_RUN_DIR:-/run/vpn}"
KEYS_DIR="$VPN_LIB_DIR/keys"
DISCOVERED_DIR="$VPN_LIB_DIR/namespaces"
STATUS_DIR="$VPN_RUN_DIR/status"

state_init() {
    install -d -m 700 "$VPN_LIB_DIR" "$KEYS_DIR" "$DISCOVERED_DIR" \
                      "$VPN_RUN_DIR" "$STATUS_DIR"
}

discovered_path() { echo "$DISCOVERED_DIR/$1.json"; }
key_path()        { echo "$KEYS_DIR/$1.conf"; }
status_path()     { echo "$STATUS_DIR/$1.json"; }

# Atomic, mode-0600 JSON write
_json_write() {
    local dest="$1" json="$2" tmp
    tmp=$(mktemp "${dest}.XXXXXX")
    echo "$json" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$dest"
}

discovered_save() {
    local ns_id="$1" json="$2"
    _json_write "$(discovered_path "$ns_id")" "$json"
    log_debug "Discovered config saved for $ns_id"
}

discovered_load() {
    local f
    f=$(discovered_path "$1")
    [[ -f "$f" ]] && cat "$f"
}

# Valid = parseable JSON + all required fields + key file exists + not expired.
# Field names match the writer exactly (Section 3.4.1).
discovered_is_valid() {
    local ns_id="$1" f
    f=$(discovered_path "$ns_id")
    [[ -f "$f" ]] || return 1

    jq empty "$f" 2>/dev/null || { log_warn "Invalid JSON in $f"; return 1; }

    local field
    for field in .namespace_id .wireguard.key_file .wireguard.wg_ip \
                 .wireguard.wg_peer_public_key .wireguard.wg_peer_endpoint; do
        local v
        v=$(jq -r "$field // empty" "$f")
        [[ -n "$v" ]] || { log_debug "$ns_id state missing $field"; return 1; }
    done

    local key_file
    key_file=$(jq -r '.wireguard.key_file' "$f")
    [[ -f "$key_file" ]] || { log_warn "$ns_id key file missing: $key_file"; return 1; }

    local discovered_at ts now max_age
    discovered_at=$(jq -r '.discovered_at // empty' "$f")
    ts=$(date -d "$discovered_at" +%s 2>/dev/null) || return 1
    now=$(date +%s)
    max_age=$(config_get state.config_max_age 86400)
    if (( now - ts > max_age )); then
        log_debug "$ns_id discovered config expired ($(( now - ts ))s > ${max_age}s)"
        return 1
    fi
    return 0
}

discovered_delete() {
    rm -f "$(discovered_path "$1")" "$(key_path "$1")"
}

# Initialize runtime status for a namespace
runtime_init() {
    local ns_id="$1" phase="${2:-STARTING}"
    _json_write "$(status_path "$ns_id")" "$(jq -n \
        --arg id "$ns_id" --arg phase "$phase" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{version: "2.0.0", namespace_id: $id, phase: $phase,
          started_at: $ts, consecutive_failures: 0, repair_attempts: 0,
          last_error: null}')"
}

# runtime_set tw '.phase = "ACTIVE" | .consecutive_failures = 0'
runtime_set() {
    local ns_id="$1" filter="$2" f
    f=$(status_path "$ns_id")
    [[ -f "$f" ]] || runtime_init "$ns_id"
    _json_write "$f" "$(jq "$filter" "$f")"
}

runtime_get() {
    local f
    f=$(status_path "$1")
    [[ -f "$f" ]] || return 1
    jq -r "$2 // empty" "$f"
}

runtime_delete() { rm -f "$(status_path "$1")"; }

state_list_runtime() {
    local f
    for f in "$STATUS_DIR"/*.json; do
        [[ -f "$f" ]] && basename "$f" .json
    done
}
```

#### 5.2.4 Provider Abstraction (`lib/provider.sh`)

```bash
#!/usr/bin/env bash
#
# provider.sh - Plugin loader and dispatch. Wrapper names differ from hook
# names (provider_* vs _provider_*) so a plugin cannot accidentally recurse.
#

PROVIDERS_DIR="${PROVIDERS_DIR:-/usr/local/lib/vpn/providers}"
ACTIVE_PROVIDER=""

provider_load() {
    local provider_name="$1"
    local plugin_file="$PROVIDERS_DIR/${provider_name}.sh"

    if [[ ! -f "$plugin_file" ]]; then
        log_error "Provider plugin not found: $plugin_file"
        return 1
    fi
    # shellcheck source=/dev/null
    source "$plugin_file"

    local func
    for func in _provider_preflight _provider_connect _provider_disconnect \
                _provider_harvest _provider_status; do
        if ! declare -F "$func" >/dev/null; then
            log_error "Provider $provider_name missing hook: $func"
            return 1
        fi
    done
    ACTIVE_PROVIDER="$provider_name"
    log_debug "Provider loaded: $provider_name"
}

_provider_require() {
    [[ -n "$ACTIVE_PROVIDER" ]] || { log_error "No provider loaded"; return 1; }
}

provider_preflight()  { _provider_require && _provider_preflight; }
provider_connect()    { _provider_require && _provider_connect "$@"; }
provider_disconnect() { _provider_require && _provider_disconnect "$@"; }
provider_harvest()    { _provider_require && _provider_harvest "$@"; }
provider_status()     { _provider_require && _provider_status; }
```

#### 5.2.5 Discovery Engine (`lib/discover.sh`)

```bash
#!/usr/bin/env bash
#
# discover.sh - Connect via provider, harvest WG credentials, verify exit
# geo BEFORE disconnecting, persist to /var/lib/vpn.
#

discover_config() {
    local ns_id="$1"
    local country provider expected_cc
    country=$(config_get_ns_field "$ns_id" country) || {
        log_error "Unknown namespace: $ns_id"; return 1; }
    provider=$(config_get_ns_field "$ns_id" provider) || provider=$(config_get providers.active nordvpn)
    expected_cc=$(config_get_ns_field "$ns_id" expected_country_code) || expected_cc=""

    log_info "Discovery: $ns_id ($country) via $provider"

    provider_load "$provider" || return 1
    provider_preflight || return 1

    provider_connect "$country" || return 1

    # Everything from here on must disconnect on exit
    local rc=0 key_file geo_json ext_ip actual_cc
    key_file=$(key_path "$ns_id")
    local wg_fragment
    wg_fragment=$(mktemp)

    if ! provider_harvest "$ns_id" "$key_file" "$wg_fragment"; then
        log_error "Harvest failed for $ns_id"
        rc=1
    else
        # Geo verification — MUST run while still connected. (v1 ran this
        # after disconnect and recorded the host's own location.)
        geo_json=$(health_geo_lookup) || geo_json=""
        if [[ -z "$geo_json" ]]; then
            log_error "Geo lookup failed for $ns_id (all services)"
            rc=1
        else
            ext_ip=$(echo "$geo_json" | jq -r '.ip // empty')
            actual_cc=$(echo "$geo_json" | jq -r '.country_code // empty')
            if [[ -n "$expected_cc" && "$actual_cc" != "$expected_cc" ]]; then
                log_error "Geo mismatch for $ns_id: expected $expected_cc, got $actual_cc"
                rc=1
            fi
        fi
    fi

    provider_disconnect "$country" || log_warn "Disconnect failed (continuing)"

    if [[ "$rc" -ne 0 ]]; then
        rm -f "$wg_fragment"
        return 1
    fi

    local mtu now valid_until
    mtu=$(config_get global.mtu 1420)
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    valid_until=$(date -u -d "+$(config_get state.config_max_age 86400) seconds" \
                  +%Y-%m-%dT%H:%M:%SZ)

    local state_json
    state_json=$(jq -n \
        --arg ns_id "$ns_id" \
        --arg provider "$provider" \
        --arg country "$country" \
        --arg expected_cc "$expected_cc" \
        --arg key_file "$key_file" \
        --argjson wg "$(cat "$wg_fragment")" \
        --argjson mtu "$mtu" \
        --arg ext_ip "$ext_ip" \
        --argjson geo "$geo_json" \
        --arg now "$now" \
        --arg valid_until "$valid_until" \
        '{
            version: "2.0.0",
            namespace_id: $ns_id,
            provider: $provider,
            country: $country,
            expected_country_code: $expected_cc,
            wireguard: ($wg + {key_file: $key_file, mtu: $mtu}),
            verification: {
                external_ip: $ext_ip,
                geo_country_code: ($geo.country_code // "UNKNOWN"),
                geo_city: ($geo.city // "Unknown"),
                geo_service: ($geo.service // "unknown"),
                verified_at: $now
            },
            discovered_at: $now,
            valid_until: $valid_until
        }')
    rm -f "$wg_fragment"

    discovered_save "$ns_id" "$state_json"
    log_info "Discovery complete: $ns_id → $ext_ip ($actual_cc), endpoint $(echo "$state_json" | jq -r '.wireguard.wg_peer_endpoint')"
    return 0
}

discover_all() {
    local cooldown successes=() failures=() ns_id
    cooldown=$(config_get providers.nordvpn.connection_cooldown 5)

    local namespaces=()
    mapfile -t namespaces < <(config_get_enabled_namespaces)
    if [[ ${#namespaces[@]} -eq 0 ]]; then
        log_error "No enabled namespaces in configuration"
        return 1
    fi

    log_info "Discovering ${#namespaces[@]} namespaces (sequential)"
    for ns_id in "${namespaces[@]}"; do
        if discover_config "$ns_id"; then
            successes+=("$ns_id")
        else
            failures+=("$ns_id")
        fi
        sleep "$cooldown"
    done

    log_info "Discovery summary: ${#successes[@]} ok, ${#failures[@]} failed"
    local ns
    for ns in "${successes[@]}"; do log_info "  OK   $ns"; done
    for ns in "${failures[@]}";  do log_error "  FAIL $ns"; done
    [[ ${#failures[@]} -eq 0 ]]
}
```

#### 5.2.6 Namespace Manager (`lib/namespace.sh`)

```bash
#!/usr/bin/env bash
#
# namespace.sh - Build and tear down one namespace: netns, veth pair,
# WireGuard interface (created in the HOST netns, then moved — the WG UDP
# socket stays bound to the host's routing, which is what gives the tunnel
# internet access), in-namespace routes, NAT, firewall, MSS clamp, DNS.
#

ns_name()   { echo "vpn-$1"; }
veth_host() { echo "veth-$1"; }
wg_name()   { echo "wg-$1"; }

namespace_exists() { ip netns list | grep -qw "$(ns_name "$1")"; }

namespace_up() {
    local ns_id="$1"

    # 1. Ensure a valid discovered config (cached or fresh)
    if ! discovered_is_valid "$ns_id"; then
        log_info "$ns_id: no valid cached config, running discovery"
        discover_config "$ns_id" || return 1
    fi

    if namespace_exists "$ns_id"; then
        log_warn "$ns_id: namespace already exists; run 'down' first"
        return 1
    fi

    runtime_init "$ns_id" STARTING
    log_info "$ns_id: creating namespace $(ns_name "$ns_id")"

    # 2. Build, with rollback on any failure
    if ! _namespace_build "$ns_id"; then
        log_error "$ns_id: bring-up failed, rolling back"
        namespace_down "$ns_id" quiet
        return 1
    fi

    runtime_set "$ns_id" '.phase = "ACTIVE"'
    log_info "$ns_id: ACTIVE"
    return 0
}

_namespace_build() {
    local ns_id="$1"
    local ns wg veth_h veth_p state
    ns=$(ns_name "$ns_id"); wg=$(wg_name "$ns_id")
    veth_h=$(veth_host "$ns_id"); veth_p="vp-$ns_id"   # transient peer name

    state=$(discovered_load "$ns_id") || return 1
    local gateway_ip host_ip gateway_subnet prefix table client_lan
    local mtu key_file wg_ip
    gateway_ip=$(config_get_ns_field "$ns_id" gateway_ip) || return 1
    host_ip=$(config_get_ns_field "$ns_id" host_veth_ip) || return 1
    gateway_subnet=$(config_get_ns_field "$ns_id" gateway_subnet) || return 1
    prefix=${gateway_subnet#*/}                        # e.g. 24
    table=$(config_get_ns_field "$ns_id" routing_table) || return 1
    client_lan=$(config_get global.client_lan) || return 1
    mtu=$(echo "$state" | jq -r '.wireguard.mtu')
    key_file=$(echo "$state" | jq -r '.wireguard.key_file')
    wg_ip=$(echo "$state" | jq -r '.wireguard.wg_ip')

    ip netns add "$ns" || return 1
    ip -n "$ns" link set lo up

    # --- WireGuard: create in HOST netns, configure, then move ---
    # Do not "simplify" this into creating the interface inside the netns:
    # the UDP socket binds in the creating namespace, and host-side binding
    # is what lets encrypted traffic reach the VPN server via ens20.
    ip link add "$wg" type wireguard || return 1
    wg setconf "$wg" "$key_file" || return 1
    ip link set "$wg" mtu "$mtu"
    ip link set "$wg" netns "$ns" || return 1
    ip -n "$ns" addr add "$wg_ip" dev "$wg" || return 1
    ip -n "$ns" link set "$wg" up

    # --- veth pair (routed; host side keeps an IP — no bridge) ---
    ip link add "$veth_h" type veth peer name "$veth_p" || return 1
    ip link set "$veth_p" netns "$ns"
    ip -n "$ns" link set "$veth_p" name veth0
    ip addr add "$host_ip/$prefix" dev "$veth_h" || return 1
    ip link set "$veth_h" up
    ip -n "$ns" addr add "$gateway_ip/$prefix" dev veth0
    ip -n "$ns" link set veth0 up

    # rp_filter loose on the new host-side interface: return traffic arrives
    # here with internet source addresses that the main table routes via the
    # uplink (Section 2.3.2 step 5). Plain name is safe in the sysctl path:
    # ids are validated to [a-z0-9] (config_validate), so no dots possible.
    sysctl -qw "net.ipv4.conf.${veth_h}.rp_filter=2"

    # --- in-namespace routing ---
    ip -n "$ns" route add default dev "$wg" || return 1
    # Return route for client traffic. Without this, de-NATted replies to
    # clients would follow the default route back out the tunnel (v1 bug).
    ip -n "$ns" route add "$client_lan" via "$host_ip" dev veth0 || return 1

    ip netns exec "$ns" sysctl -qw net.ipv4.ip_forward=1

    # --- in-namespace firewall + NAT ---
    ip netns exec "$ns" iptables -w -t nat -A POSTROUTING -o "$wg" -j MASQUERADE
    ip netns exec "$ns" iptables -w -P FORWARD DROP
    ip netns exec "$ns" iptables -w -A FORWARD -i veth0 -o "$wg" -j ACCEPT
    ip netns exec "$ns" iptables -w -A FORWARD -i "$wg" -o veth0 \
        -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    if [[ "$(config_get global.clamp_mss true)" == "true" ]]; then
        ip netns exec "$ns" iptables -w -t mangle -A FORWARD \
            -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    fi
    # Optional client DNS capture target: queries marked into this namespace
    # by the steering chain (Section 2.4) get rewritten to the tunnel-side
    # resolver, so they exit through the VPN instead of the LAN resolver.
    if [[ "$(config_get client_steering.dns_redirect false)" == "true" ]]; then
        local dns_target
        dns_target=$(config_get client_steering.dns_redirect_target 1.1.1.1)
        ip netns exec "$ns" iptables -w -t nat -A PREROUTING -i veth0 \
            -p udp --dport 53 -j DNAT --to-destination "$dns_target"
        ip netns exec "$ns" iptables -w -t nat -A PREROUTING -i veth0 \
            -p tcp --dport 53 -j DNAT --to-destination "$dns_target"
    fi

    # --- namespace DNS ---
    # The host's systemd-resolved stub (127.0.0.53) is unreachable from
    # inside a netns; without this file, `vpn_ctl exec`/health checks could
    # not resolve hostnames (v1 gap).
    install -d -m 755 "/etc/netns/$ns"
    config_query '.client_steering.namespace_dns[]' | \
        sed 's/^/nameserver /' > "/etc/netns/$ns/resolv.conf"

    # --- host-side PBR (table + ip rule for this namespace) ---
    routing_table_up "$ns_id" || return 1

    return 0
}

namespace_down() {
    local ns_id="$1" quiet="${2:-}"
    local ns veth_h
    ns=$(ns_name "$ns_id"); veth_h=$(veth_host "$ns_id")

    [[ -z "$quiet" ]] && runtime_set "$ns_id" '.phase = "STOPPING"' 2>/dev/null

    routing_table_down "$ns_id"

    # Deleting the netns destroys the WG interface and the veth peer (the
    # host-side veth dies with its peer). Explicit delete is belt-and-braces
    # for half-built states where the peer never moved.
    ip link del "$veth_h" 2>/dev/null
    if ip netns list | grep -qw "$ns"; then
        ip netns del "$ns" || log_warn "$ns_id: netns delete failed"
    fi
    rm -rf "/etc/netns/$ns"

    runtime_delete "$ns_id"
    [[ -z "$quiet" ]] && log_info "$ns_id: stopped"
    return 0
}

namespace_status() {
    local ns_id="$1"
    local ns wg phase
    ns=$(ns_name "$ns_id"); wg=$(wg_name "$ns_id")
    phase=$(runtime_get "$ns_id" .phase 2>/dev/null) || phase="STOPPED"

    echo "── $ns_id ($(config_get_ns_field "$ns_id" country 2>/dev/null)) ─ $phase"
    if namespace_exists "$ns_id"; then
        local hs
        hs=$(ip netns exec "$ns" wg show "$wg" latest-handshakes 2>/dev/null | awk '{print $2}')
        if [[ -n "$hs" && "$hs" != "0" ]]; then
            echo "   handshake: $(( $(date +%s) - hs ))s ago"
        else
            echo "   handshake: never"
        fi
        echo "   endpoint:  $(ip netns exec "$ns" wg show "$wg" endpoints 2>/dev/null | awk '{print $2}')"
        echo "   transfer:  $(ip netns exec "$ns" wg show "$wg" transfer 2>/dev/null | awk '{print "rx "$2"  tx "$3}')"
    fi
    if discovered_is_valid "$ns_id" 2>/dev/null; then
        echo "   config:    valid (discovered $(discovered_load "$ns_id" | jq -r .discovered_at))"
    else
        echo "   config:    missing or expired"
    fi
}
```

#### 5.2.7 Routing Manager (`lib/routing.sh`)

```bash
#!/usr/bin/env bash
#
# routing.sh - Host-side data plane: sysctls, the VPN_STEER (mangle) and
# VPN_FWD (filter) chain scaffolding, and per-namespace PBR tables and
# ip rules. Every operation is idempotent (check-then-add / replace).
#

VPN_STEER_CHAIN="VPN_STEER"   # mangle/PREROUTING: packet marking
VPN_FWD_CHAIN="VPN_FWD"       # filter/FORWARD: permit/deny steered traffic

routing_sysctls() {
    sysctl -qw net.ipv4.ip_forward=1
    # Loose reverse-path filtering. Return traffic from the namespaces
    # arrives on veth-{id} with internet source addresses (e.g. 8.8.8.8)
    # that the main table routes via the uplink; strict rp_filter (1) would
    # drop every reply packet of every steered flow. (v1 gap.)
    sysctl -qw net.ipv4.conf.all.rp_filter=2
    sysctl -qw net.ipv4.conf.default.rp_filter=2
    # No ICMP redirects. Unsteered client traffic hairpins (in uplink, out
    # uplink toward the router) and the kernel would tell clients "use the
    # router directly"; clients cache that route and would keep bypassing
    # this host even after being ADDED to steering. The kernel sends
    # redirects if all OR the interface flag is set, so clear both scopes
    # (the uplink itself is cleared in routing_host_chains_init).
    sysctl -qw net.ipv4.conf.all.send_redirects=0
    sysctl -qw net.ipv4.conf.default.send_redirects=0
}

# Idempotent append: only add the rule if an identical one is not present.
# _ipt <table> <chain> <rule...>
_ipt() {
    local table="$1" chain="$2"; shift 2
    iptables -w -t "$table" -C "$chain" "$@" 2>/dev/null || \
        iptables -w -t "$table" -A "$chain" "$@"
}

routing_host_chains_init() {
    local uplink client_lan
    uplink=$(config_uplink_iface) || return 1
    client_lan=$(config_get global.client_lan) || return 1

    routing_sysctls
    sysctl -qw "net.ipv4.conf.${uplink}.send_redirects=0"

    # ---- mangle/VPN_STEER ----
    # Chain layout (evaluation order matters, see Section 2.4):
    #   [1..n]  DNS-capture marks      (inserted at top by steering.sh,
    #                                   only when dns_redirect: true)
    #   [n+1]   LAN bypass RETURN      (installed here)
    #   [n+2..] per-client marks       (appended by steering.sh)
    #
    # The LAN bypass guarantees client↔client, client↔router and
    # client↔host traffic is never marked. This also protects traffic
    # destined to the VPN host itself: the PBR tables contain only a
    # default route, so a marked packet for 192.168.1.10 would otherwise
    # be misrouted into a namespace.
    iptables -w -t mangle -N "$VPN_STEER_CHAIN" 2>/dev/null || true
    _ipt mangle PREROUTING -i "$uplink" -j "$VPN_STEER_CHAIN"
    _ipt mangle "$VPN_STEER_CHAIN" -s "$client_lan" -d "$client_lan" -j RETURN

    # ---- filter/VPN_FWD ----
    iptables -w -N "$VPN_FWD_CHAIN" 2>/dev/null || true
    # Insert (not append) the jump so VPN_FWD is evaluated before any
    # pre-existing FORWARD rules (e.g. docker's).
    iptables -w -C FORWARD -j "$VPN_FWD_CHAIN" 2>/dev/null || \
        iptables -w -I FORWARD 1 -j "$VPN_FWD_CHAIN"

    # Inter-namespace isolation: namespaces must never reach each other.
    # With routed veths there is no L2 adjacency (unlike v1's shared
    # bridge), so host forwarding is the only possible path — block it.
    _ipt filter "$VPN_FWD_CHAIN" -i veth-+ -o veth-+ -j DROP
    # Client → namespace (steered traffic)
    _ipt filter "$VPN_FWD_CHAIN" -i "$uplink" -o veth-+ -j ACCEPT
    # Namespace → client: return traffic only. New flows originating from
    # a gateway subnet toward the LAN are implicitly not accepted here.
    _ipt filter "$VPN_FWD_CHAIN" -i veth-+ -o "$uplink" \
        -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    _ipt filter "$VPN_FWD_CHAIN" -i veth-+ -o "$uplink" -j DROP

    # Strict mode: drop unmatched (unmarked) client traffic instead of
    # letting it follow the host's normal default route.
    if [[ "$(config_get client_steering.default_action use_main_table)" == "drop" ]]; then
        _ipt filter "$VPN_FWD_CHAIN" -i "$uplink" -o "$uplink" -j DROP
    fi

    # ---- IPv6 backstop ----
    # Steering matches IPv4 sources only; any forwarded IPv6 would bypass
    # the tunnels entirely and silently invalidate geo tests. This host is
    # not meant to be a v6 router, so drop all forwarded v6.
    if [[ "$(config_get client_steering.block_ipv6 true)" == "true" ]] \
       && command -v ip6tables >/dev/null 2>&1; then
        ip6tables -w -C FORWARD -j DROP 2>/dev/null || \
            ip6tables -w -A FORWARD -j DROP
    fi
}

routing_host_chains_teardown() {
    local uplink
    uplink=$(config_uplink_iface) || return 1

    iptables -w -t mangle -D PREROUTING -i "$uplink" -j "$VPN_STEER_CHAIN" 2>/dev/null
    iptables -w -t mangle -F "$VPN_STEER_CHAIN" 2>/dev/null
    iptables -w -t mangle -X "$VPN_STEER_CHAIN" 2>/dev/null
    iptables -w -D FORWARD -j "$VPN_FWD_CHAIN" 2>/dev/null
    iptables -w -F "$VPN_FWD_CHAIN" 2>/dev/null
    iptables -w -X "$VPN_FWD_CHAIN" 2>/dev/null
    # The ip6tables FORWARD drop is intentionally left in place: it is a
    # safe default and removing it on teardown would re-open the v6 bypass
    # while namespaces are down but clients still point at this gateway.
}

# Per-namespace PBR: table N holds a single default route into the
# namespace; ip rule pref (1000+N) sends fwmark-N packets to table N.
routing_table_up() {
    local ns_id="$1"
    local table gateway_ip veth_h pref
    table=$(config_get_ns_field "$ns_id" routing_table) || return 1
    gateway_ip=$(config_get_ns_field "$ns_id" gateway_ip) || return 1
    veth_h=$(veth_host "$ns_id")
    pref=$((1000 + table))

    # Nexthop is resolvable because the host owns host_veth_ip/prefix on
    # veth_h (Section 5.2.6). `replace` keeps this idempotent.
    ip route replace default via "$gateway_ip" dev "$veth_h" table "$table" || return 1

    # delete-then-add keeps exactly one rule at this pref
    while ip rule del pref "$pref" 2>/dev/null; do :; done
    ip rule add pref "$pref" fwmark "$table" lookup "$table"
}

routing_table_down() {
    local ns_id="$1"
    local table pref
    table=$(config_get_ns_field "$ns_id" routing_table) || return 1
    pref=$((1000 + table))
    while ip rule del pref "$pref" 2>/dev/null; do :; done
    ip route flush table "$table" 2>/dev/null
    return 0
}
```

#### 5.2.8 Steering Controller (`lib/steering.sh`)

```bash
#!/usr/bin/env bash
#
# steering.sh - Manage per-client mark rules in the VPN_STEER chain.
# rules.yaml is the single source of truth: CLI add/remove writes the file
# first, then re-syncs the chain from it. Conntrack entries for affected
# clients are flushed so changes apply to established flows immediately.
#

steering_rules_file() {
    config_get client_steering.rules_file /etc/vpn/steering/rules.yaml
}

# Emit "client<TAB>namespace" for enabled rules
_steering_enabled_rules() {
    local f
    f=$(steering_rules_file)
    [[ -f "$f" ]] || return 0
    yq eval '.rules[] | select(.enabled == true) | [.client, .namespace] | @tsv' "$f" 2>/dev/null
}

# Remove all per-client rules from VPN_STEER. The LAN bypass RETURN rule
# (owned by routing.sh) is preserved; everything steering.sh added carries
# a MARK target, which is what we filter on. Deletion runs in reverse
# line-number order so the numbering stays stable while deleting.
steering_clear() {
    local num
    while read -r num; do
        iptables -w -t mangle -D "$VPN_STEER_CHAIN" "$num"
    done < <(iptables -w -t mangle -L "$VPN_STEER_CHAIN" --line-numbers -n 2>/dev/null | \
             awk '/MARK set/ {print $1}' | sort -rn)
}

# Sync the chain from rules.yaml. Rules referencing namespaces that are not
# currently running are reported and skipped — marking traffic into a dead
# table would blackhole the client (the fwmark rule routes to a table whose
# device no longer exists).
steering_apply_all() {
    local dns_redirect client ns_id table
    dns_redirect=$(config_get client_steering.dns_redirect false)

    steering_clear

    while IFS=$'\t' read -r client ns_id; do
        [[ -n "$client" ]] || continue

        if ! table=$(config_get_ns_field "$ns_id" routing_table); then
            log_warn "steering: $client references unknown namespace '$ns_id', skipping"
            continue
        fi
        if ! namespace_exists "$ns_id"; then
            log_warn "steering: namespace $ns_id not running; rule for $client not applied"
            continue
        fi

        # DNS capture precedes the LAN bypass (insert at position 1) so
        # queries addressed to the LAN resolver are pulled into the tunnel
        # and DNAT-ed inside the namespace (Sections 2.4, 5.2.6).
        if [[ "$dns_redirect" == "true" ]]; then
            iptables -w -t mangle -I "$VPN_STEER_CHAIN" 1 -s "$client" \
                -p udp --dport 53 -j MARK --set-mark "$table"
            iptables -w -t mangle -I "$VPN_STEER_CHAIN" 1 -s "$client" \
                -p tcp --dport 53 -j MARK --set-mark "$table"
        fi
        # Plain per-client mark, appended after the LAN bypass
        iptables -w -t mangle -A "$VPN_STEER_CHAIN" -s "$client" \
            -j MARK --set-mark "$table"

        log_info "steering: $client → $ns_id (mark $table)"
        steering_flush_conntrack "$client"
    done < <(_steering_enabled_rules)
}

steering_add_client() {
    local client="$1" ns_id="$2" f
    f=$(steering_rules_file)

    # Validate inputs before touching the rules file
    if [[ ! "$client" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        log_error "Invalid client IPv4 address: $client"
        return 1
    fi
    config_get_ns_field "$ns_id" id >/dev/null || {
        log_error "Unknown namespace: $ns_id"; return 1; }

    # Persist first (replace any existing rule for this client), then sync.
    # env() avoids quoting/injection issues with yq expressions.
    CLIENT="$client" NS="$ns_id" yq eval -i '
        .rules = ([.rules[] | select(.client != env(CLIENT))] + [{
            "client": env(CLIENT),
            "namespace": env(NS),
            "description": "added via vpn_ctl",
            "enabled": true
        }])' "$f" || return 1

    steering_apply_all
}

steering_remove_client() {
    local client="$1" f
    f=$(steering_rules_file)

    CLIENT="$client" yq eval -i \
        '.rules = [.rules[] | select(.client != env(CLIENT))]' "$f" || return 1

    steering_apply_all
    steering_flush_conntrack "$client"
}

# Show configured rules and whether each is actually applied in the chain —
# the two can differ (namespace down, rule disabled), and making that
# visible beats debugging it with raw iptables output.
steering_list() {
    local f client ns_id enabled desc applied table
    f=$(steering_rules_file)
    [[ -f "$f" ]] || { echo "(no steering rules file)"; return 0; }

    printf "%-16s %-6s %-9s %s\n" "CLIENT" "NS" "APPLIED" "DESCRIPTION"
    while IFS=$'\t' read -r client ns_id enabled desc; do
        [[ -n "$client" ]] || continue
        applied=no
        if [[ "$enabled" != "true" ]]; then
            applied=disabled
        elif table=$(config_get_ns_field "$ns_id" routing_table 2>/dev/null); then
            iptables -w -t mangle -C "$VPN_STEER_CHAIN" -s "$client" \
                -j MARK --set-mark "$table" 2>/dev/null && applied=yes
        fi
        printf "%-16s %-6s %-9s %s\n" "$client" "$ns_id" "$applied" "$desc"
    done < <(yq eval '.rules[] | [.client, .namespace, .enabled, .description // ""] | @tsv' "$f" 2>/dev/null)
}

# Established flows keep their pre-change path until their conntrack
# entries expire (marking only affects new lookups). Flush the client's
# entries so steering changes take effect immediately. Best-effort: absence
# of conntrack(8) degrades to "changes apply to new flows only".
steering_flush_conntrack() {
    local client="$1"
    command -v conntrack >/dev/null 2>&1 || return 0
    conntrack -D --orig-src "$client" >/dev/null 2>&1 || true
}
```

#### 5.2.9 Health Checker (`lib/health.sh`)

```bash
#!/usr/bin/env bash
#
# health.sh - Per-namespace health verification and DEGRADED/repair logic.
# Invoked by vpn-health.timer (Section 8.5), `vpn_ctl health`, and
# `vpn_ctl repair`. Also provides the geo lookup used by discovery.
#

# Multi-service geo lookup with normalized output:
#   {ip, country_code, city, service}
# Tries each configured service in order; returns the first usable answer.
# Field names differ between services (api.ip.sb: country_code; ipinfo.io:
# country; ifconfig.co: country_iso), so responses are normalized here and
# nowhere else.
#
# Usage: health_geo_lookup [netns]   (no arg = host namespace; used by
#        discovery while the provider connection is still up)
health_geo_lookup() {
    local netns="${1:-}" timeout url
    local prefix=()
    timeout=$(config_get health.curl_timeout 10)
    [[ -n "$netns" ]] && prefix=(ip netns exec "$netns")

    while read -r url; do
        [[ -n "$url" ]] || continue
        local raw norm
        raw=$("${prefix[@]}" curl -s --max-time "$timeout" "$url" 2>/dev/null) || continue
        norm=$(jq --arg svc "$url" -c '
            {
                ip: (.ip // empty),
                country_code: (.country_code // .country_iso // .country // empty),
                city: (.city // "unknown"),
                service: $svc
            } | select(.ip and .country_code)' <<<"$raw" 2>/dev/null)
        if [[ -n "$norm" ]]; then
            echo "$norm"
            return 0
        fi
        log_debug "geo service unusable: $url"
    done < <(config_query '.health.geo_services[]')

    return 1
}

# Handshake age check. A live WireGuard tunnel under traffic or keepalive
# re-handshakes at least every ~2 minutes; a stale handshake means the
# server stopped answering (e.g. credentials invalidated — Section 1.7).
health_check_handshake() {
    local ns_id="$1"
    local ns wg hs now max_age
    ns=$(ns_name "$ns_id"); wg=$(wg_name "$ns_id")
    max_age=$(config_get health.handshake_max_age 180)

    hs=$(ip netns exec "$ns" wg show "$wg" latest-handshakes 2>/dev/null | awk '{print $2}')
    if [[ -z "$hs" || "$hs" == "0" ]]; then
        log_debug "$ns_id: no handshake recorded"
        return 1
    fi
    now=$(date +%s)
    if (( now - hs > max_age )); then
        log_debug "$ns_id: handshake stale ($(( now - hs ))s > ${max_age}s)"
        return 1
    fi
    return 0
}

# Full health check for one namespace:
#   1. generate a little traffic (forces a handshake on an idle tunnel —
#      otherwise a healthy-but-idle tunnel would look stale)
#   2. handshake age
#   3. geo verification from INSIDE the namespace against the expected
#      country code
# Updates the runtime status counters either way.
health_check() {
    local ns_id="$1"
    local expected_cc rc=0 detail=""

    if ! namespace_exists "$ns_id"; then
        log_error "$ns_id: namespace not running"
        return 1
    fi
    expected_cc=$(config_get_ns_field "$ns_id" expected_country_code 2>/dev/null) || expected_cc=""

    ip netns exec "$(ns_name "$ns_id")" ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || true

    if ! health_check_handshake "$ns_id"; then
        rc=1; detail="handshake stale or missing"
    else
        local geo actual_cc
        if geo=$(health_geo_lookup "$(ns_name "$ns_id")"); then
            actual_cc=$(jq -r .country_code <<<"$geo")
            runtime_set "$ns_id" ".actual_country_code = \"$actual_cc\""
            if [[ -n "$expected_cc" && "$actual_cc" != "$expected_cc" ]]; then
                rc=1; detail="geo mismatch: expected $expected_cc, got $actual_cc"
                runtime_set "$ns_id" '.geo_verified = false'
            else
                runtime_set "$ns_id" '.geo_verified = true'
            fi
        else
            rc=1; detail="all geo services unreachable"
        fi
    fi

    local ts hs_ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    hs_ts=$(ip netns exec "$(ns_name "$ns_id")" wg show "$(wg_name "$ns_id")" \
            latest-handshakes 2>/dev/null | awk '{print $2}')
    [[ -n "$hs_ts" && "$hs_ts" != "0" ]] && \
        runtime_set "$ns_id" ".last_handshake = \"$(date -u -d "@$hs_ts" +%Y-%m-%dT%H:%M:%SZ)\""

    if [[ "$rc" -eq 0 ]]; then
        runtime_set "$ns_id" ".last_health_check = \"$ts\"
            | .consecutive_failures = 0 | .last_error = null"
        log_info "$ns_id: healthy"
    else
        runtime_set "$ns_id" ".last_health_check = \"$ts\"
            | .consecutive_failures += 1 | .last_error = \"$detail\""
        log_warn "$ns_id: unhealthy ($detail)"
    fi
    return "$rc"
}

# Timer entry point: check every running namespace and drive the state
# machine (Section 2.7): ACTIVE → DEGRADED after N consecutive failures,
# DEGRADED → ACTIVE on recovery, DEGRADED → repair → ACTIVE | STOPPED.
health_check_all() {
    local threshold ns_id phase failures
    threshold=$(config_get health.failure_threshold 3)

    for ns_id in $(state_list_runtime); do
        phase=$(runtime_get "$ns_id" .phase)
        [[ "$phase" == "ACTIVE" || "$phase" == "DEGRADED" ]] || continue

        if health_check "$ns_id"; then
            if [[ "$phase" == "DEGRADED" ]]; then
                runtime_set "$ns_id" '.phase = "ACTIVE" | .repair_attempts = 0'
                log_info "$ns_id: recovered, back to ACTIVE"
            fi
            continue
        fi

        failures=$(runtime_get "$ns_id" .consecutive_failures)
        if (( failures >= threshold )); then
            runtime_set "$ns_id" '.phase = "DEGRADED"'
            log_warn "$ns_id: DEGRADED after $failures consecutive failures"
            repair_namespace "$ns_id"
        fi
    done
}

# Repair path (also exposed as `vpn_ctl repair {id}`). Two stages:
#   Stage 1 — restart with the cached config. Cheap; fixes local breakage
#             (deleted interface, flushed rules, crashed netns).
#   Stage 2 — force re-discovery. Fixes server-side credential
#             invalidation, i.e. the Section 1.7 assumption failing.
# Attempts are bounded by health.repair_attempts; when exhausted the
# namespace is stopped rather than left flapping. The counter resets when
# a health check passes (see health_check_all).
repair_namespace() {
    local ns_id="$1"
    local max_attempts attempts
    max_attempts=$(config_get health.repair_attempts 3)
    attempts=$(runtime_get "$ns_id" .repair_attempts 2>/dev/null) || attempts=0

    if (( attempts >= max_attempts )); then
        log_error "$ns_id: repair attempts exhausted ($attempts/$max_attempts); stopping namespace"
        namespace_down "$ns_id"
        return 1
    fi
    attempts=$((attempts + 1))
    log_info "$ns_id: repair attempt $attempts/$max_attempts"

    # Stage 1: restart from cache
    namespace_down "$ns_id" quiet
    if discovered_is_valid "$ns_id" && namespace_up "$ns_id" && health_check "$ns_id"; then
        runtime_set "$ns_id" ".repair_attempts = $attempts"
        log_info "$ns_id: recovered with cached config"
        return 0
    fi

    # Stage 2: credentials may be dead server-side — discard and re-discover
    log_info "$ns_id: cached config failed; forcing re-discovery"
    namespace_down "$ns_id" quiet
    discovered_delete "$ns_id"
    if discover_config "$ns_id" && namespace_up "$ns_id" && health_check "$ns_id"; then
        runtime_set "$ns_id" ".repair_attempts = $attempts"
        log_info "$ns_id: recovered after re-discovery"
        return 0
    fi

    # Leave DEGRADED with the incremented counter; the next timer tick
    # retries until max_attempts is reached.
    namespace_down "$ns_id" quiet
    runtime_init "$ns_id" DEGRADED
    runtime_set "$ns_id" ".repair_attempts = $attempts | .last_error = \"repair failed\""
    log_error "$ns_id: repair attempt $attempts failed"
    return 1
}
```

### 5.3 Provider Plugins

#### 5.3.1 NordVPN Plugin (`providers/nordvpn.sh`)

```bash
#!/usr/bin/env bash
#
# NordVPN provider plugin. Harvests the complete WireGuard configuration
# via `wg showconf` — the only command that exposes the private key, and
# the same mechanism the legacy update.sh relied on. v1's plugin assembled
# fragments from `wg show` and never captured the private key at all,
# producing configs that `wg setconf` could not use.
#

NORDVPN_INTERFACE="${NORDVPN_INTERFACE:-nordlynx}"
# Env override → config global.connection_timeout → 30. (Plugins are sourced
# by provider_load after config_load, so config_get is available here.)
NORDVPN_TIMEOUT="${NORDVPN_TIMEOUT:-$(config_get global.connection_timeout 30)}"

_provider_preflight() {
    command -v nordvpn >/dev/null 2>&1 || {
        log_error "nordvpn CLI not found"; return 1; }
    nordvpn account >/dev/null 2>&1 || {
        log_error "nordvpn not logged in (run: nordvpn login)"; return 1; }

    # Required settings (Section 3.3.1): nordlynx for WireGuard harvesting;
    # killswitch and autoconnect manipulate host routing/firewall in ways
    # that break both discovery and the steered data plane.
    nordvpn set technology nordlynx >/dev/null 2>&1 || true
    nordvpn set killswitch off      >/dev/null 2>&1 || true
    nordvpn set autoconnect off     >/dev/null 2>&1 || true
    return 0
}

_provider_connect() {
    local country="$1"

    if ! timeout "$NORDVPN_TIMEOUT" nordvpn connect "$country" >/dev/null 2>&1; then
        log_error "nordvpn connect $country failed"
        return 1
    fi

    # Wait for the interface AND a completed handshake instead of v1's
    # blind `sleep 3` — connect returns before the tunnel is usable.
    local deadline hs
    deadline=$(( $(date +%s) + NORDVPN_TIMEOUT ))
    while (( $(date +%s) < deadline )); do
        if ip link show "$NORDVPN_INTERFACE" >/dev/null 2>&1; then
            hs=$(wg show "$NORDVPN_INTERFACE" latest-handshakes 2>/dev/null | awk '{print $2}')
            [[ -n "$hs" && "$hs" != "0" ]] && return 0
        fi
        sleep 1
    done
    log_error "no WireGuard handshake on $NORDVPN_INTERFACE within ${NORDVPN_TIMEOUT}s"
    return 1
}

_provider_disconnect() {
    timeout 10 nordvpn disconnect >/dev/null 2>&1 || \
        log_warn "nordvpn disconnect failed"
    return 0
}

# _provider_harvest <id> <key_file> <json_out>
# Writes the sanitized wg setconf file and a JSON metadata fragment.
_provider_harvest() {
    local ns_id="$1" key_file="$2" json_out="$3"

    ip link show "$NORDVPN_INTERFACE" >/dev/null 2>&1 || {
        log_error "interface $NORDVPN_INTERFACE not found"; return 1; }

    # ---- key file: full config including PrivateKey, sanitized ----
    # ListenPort stripped: all five WG sockets bind in the HOST netns
    #   (Section 2.1); identical harvested ports would collide. With no
    #   ListenPort the kernel assigns an ephemeral port per interface.
    # FwMark stripped: NordVPN's 0xca6c mark serves its own routing
    #   exclusions and is meaningless inside our namespaces.
    local conf
    conf=$(wg showconf "$NORDVPN_INTERFACE" 2>/dev/null) || {
        log_error "wg showconf failed (requires root)"; return 1; }
    umask 077
    grep -v -E '^(ListenPort|FwMark)' <<<"$conf" > "$key_file"
    chmod 600 "$key_file"

    # ---- metadata ----
    # The interface address comes from `ip -j addr show`:
    # `wg show <if> addresses` is NOT a valid wg subcommand (v1 bug).
    local wg_ip peer_pubkey peer_endpoint allowed_ips
    wg_ip=$(ip -j addr show "$NORDVPN_INTERFACE" 2>/dev/null | \
        jq -r '.[0].addr_info[]? | select(.family == "inet") |
               "\(.local)/\(.prefixlen)"' | head -n1)

    # `wg show <if> public-key` prints OUR public key, not the peer's
    # (v1 stored it as wg_peer_public_key). The peer's key is the first
    # column of the peers/endpoints listings.
    peer_pubkey=$(wg show "$NORDVPN_INTERFACE" peers 2>/dev/null | head -n1)
    peer_endpoint=$(wg show "$NORDVPN_INTERFACE" endpoints 2>/dev/null | \
        awk '{print $2}' | head -n1)
    allowed_ips=$(grep -E '^AllowedIPs' <<<"$conf" | head -n1 | \
        awk -F'= *' '{print $2}')

    local v
    for v in wg_ip peer_pubkey peer_endpoint; do
        [[ -n "${!v}" ]] || { log_error "harvest: failed to extract $v"; return 1; }
    done
    grep -q '^PrivateKey' "$key_file" || {
        log_error "harvest: key file contains no PrivateKey"; return 1; }

    jq -n --arg ip "$wg_ip" --arg pk "$peer_pubkey" --arg ep "$peer_endpoint" \
          --arg aips "${allowed_ips:-0.0.0.0/0}" \
          '{wg_ip: $ip, wg_peer_public_key: $pk,
            wg_peer_endpoint: $ep, wg_allowed_ips: $aips}' > "$json_out"
    return 0
}

_provider_status() {
    nordvpn status 2>/dev/null || echo "NordVPN daemon not reachable"
}
```

#### 5.3.2 Custom WireGuard Plugin (`providers/custom.sh`)

```bash
#!/usr/bin/env bash
#
# Custom static-config provider. There is no connect/disconnect cycle and
# no wg-quick (v1 used `wg-quick up` during discovery, which would have
# hijacked the HOST's routing with the config's AllowedIPs): discovery
# parses the file, and the namespace manager builds the interface itself.
#
# Geo verification is skipped at discovery time — there is no live
# connection to verify. The first health check after `up` provides it.
#

CUSTOM_CONFIG_DIR="${CUSTOM_CONFIG_DIR:-/etc/wireguard/custom}"

_provider_preflight() {
    [[ -d "$CUSTOM_CONFIG_DIR" ]] || {
        log_error "custom config dir missing: $CUSTOM_CONFIG_DIR"; return 1; }
    return 0
}

# Static configs: nothing to connect or disconnect.
_provider_connect()    { return 0; }
_provider_disconnect() { return 0; }

_provider_harvest() {
    local ns_id="$1" key_file="$2" json_out="$3"
    local src="$CUSTOM_CONFIG_DIR/${ns_id}.conf"

    [[ -f "$src" ]] || { log_error "config not found: $src"; return 1; }

    # First match wins; tolerate "Key=Val" and "Key = Val"
    _wgconf_get() {
        grep -E "^[[:space:]]*$1[[:space:]]*=" "$src" | head -n1 | \
            sed -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//"
    }

    local wg_ip private_key peer_pubkey endpoint allowed_ips keepalive
    wg_ip=$(_wgconf_get Address)
    private_key=$(_wgconf_get PrivateKey)
    peer_pubkey=$(_wgconf_get PublicKey)
    endpoint=$(_wgconf_get Endpoint)
    allowed_ips=$(_wgconf_get AllowedIPs)
    keepalive=$(_wgconf_get PersistentKeepalive)

    local v
    for v in wg_ip private_key peer_pubkey endpoint; do
        [[ -n "${!v}" ]] || { log_error "harvest: $src missing $v"; return 1; }
    done

    # Re-emit as a sanitized setconf file (Address/DNS/MTU are wg-quick
    # extensions that `wg setconf` rejects; they live in the JSON instead)
    umask 077
    cat > "$key_file" <<KEYFILE_EOF
[Interface]
PrivateKey = $private_key

[Peer]
PublicKey = $peer_pubkey
AllowedIPs = ${allowed_ips:-0.0.0.0/0}
Endpoint = $endpoint
PersistentKeepalive = ${keepalive:-25}
KEYFILE_EOF
    chmod 600 "$key_file"

    jq -n --arg ip "$wg_ip" --arg pk "$peer_pubkey" --arg ep "$endpoint" \
          --arg aips "${allowed_ips:-0.0.0.0/0}" \
          '{wg_ip: $ip, wg_peer_public_key: $pk,
            wg_peer_endpoint: $ep, wg_allowed_ips: $aips}' > "$json_out"
    return 0
}

_provider_status() {
    echo "Custom WireGuard provider ($CUSTOM_CONFIG_DIR)"
    ls -1 "$CUSTOM_CONFIG_DIR"/*.conf 2>/dev/null || echo "  (no configs found)"
}
```

### 5.4 CLI Entry Point (`vpn_ctl`)

**Installed at:** `/usr/local/lib/vpn/vpn_ctl`, symlinked from `/usr/local/sbin/vpn_ctl`

```bash
#!/usr/bin/env bash
#
# vpn_ctl - VPN Namespace Manager CLI
#
set -uo pipefail

VERSION="2.0.0"
# readlink -f resolves the /usr/local/sbin symlink back to the install dir
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/provider.sh"
source "$SCRIPT_DIR/lib/routing.sh"
source "$SCRIPT_DIR/lib/namespace.sh"
source "$SCRIPT_DIR/lib/steering.sh"
source "$SCRIPT_DIR/lib/discover.sh"
source "$SCRIPT_DIR/lib/health.sh"

# Accept both "all" and "--all": v1 documented --all in every example but
# the code only matched the literal "all".
_norm_target() { echo "${1#--}"; }

require_root() {
    [[ $EUID -eq 0 ]] || { log_error "this command must run as root"; exit 1; }
}

main() {
    local command="${1:-help}"
    shift || true

    # Commands that need no config file
    case "$command" in
        version)        echo "vpn_ctl version $VERSION"; exit 0 ;;
        help|--help|-h) show_help; exit 0 ;;
    esac

    config_load || { log_error "Failed to load configuration"; exit 1; }

    case "$command" in
        up)       require_root; state_init; cmd_up "$@" ;;
        down)     require_root; cmd_down "$@" ;;
        restart)  require_root; state_init; cmd_restart "$@" ;;
        discover) require_root; state_init; cmd_discover "$@" ;;
        repair)   require_root; state_init; cmd_repair "$@" ;;
        status)   cmd_status "$@" ;;
        health)   require_root; cmd_health "$@" ;;
        exec)     require_root; cmd_exec "$@" ;;
        steering) require_root; cmd_steering "$@" ;;
        provider) cmd_provider "$@" ;;
        config)   cmd_config "$@" ;;
        *)
            log_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

cmd_up() {
    local target
    target=$(_norm_target "${1:-}")
    [[ -n "$target" ]] || { log_error "Usage: vpn_ctl up {id|all}"; exit 1; }

    config_validate || exit 1
    routing_host_chains_init || exit 1

    if [[ "$target" == "all" ]]; then
        local failures=() ns_id
        for ns_id in $(config_get_enabled_namespaces); do
            namespace_up "$ns_id" || failures+=("$ns_id")
        done
        steering_apply_all
        if [[ ${#failures[@]} -gt 0 ]]; then
            log_error "Failed namespaces: ${failures[*]} (others are up)"
            exit 1
        fi
    else
        namespace_up "$target" || exit 1
        steering_apply_all
    fi
    log_info "Up complete"
}

cmd_down() {
    local target
    target=$(_norm_target "${1:-}")
    [[ -n "$target" ]] || { log_error "Usage: vpn_ctl down {id|all}"; exit 1; }

    if [[ "$target" == "all" ]]; then
        local ns_id
        # Union of runtime state and configured namespaces: covers
        # namespaces left over after a crash that lost /run (no status
        # file) as well as ones since removed from the config.
        for ns_id in $( { state_list_runtime; config_get_enabled_namespaces; } | sort -u ); do
            namespace_exists "$ns_id" && namespace_down "$ns_id"
        done
        steering_clear
        routing_host_chains_teardown
    else
        namespace_down "$target"
        # Re-sync so applied marks pointing at the stopped namespace are
        # removed (steering_apply_all skips non-running namespaces).
        steering_apply_all
    fi
    log_info "Down complete"
}

cmd_restart() {
    local target
    target=$(_norm_target "${1:-}")
    [[ -n "$target" ]] || { log_error "Usage: vpn_ctl restart {id|all}"; exit 1; }
    cmd_down "$target"
    sleep 1
    cmd_up "$target"
}

cmd_discover() {
    local target
    target=$(_norm_target "${1:-}")
    case "$target" in
        all) discover_all ;;
        "")  log_error "Usage: vpn_ctl discover {id|all}"; exit 1 ;;
        *)   discover_config "$target" ;;
    esac
}

cmd_repair() {
    local ns_id="${1:-}"
    [[ -n "$ns_id" ]] || { log_error "Usage: vpn_ctl repair {id}"; exit 1; }
    repair_namespace "$ns_id"
}

cmd_status() {
    local target
    target=$(_norm_target "${1:-all}")
    if [[ "$target" == "all" ]]; then
        echo "=== VPN Namespace Status ==="
        local ns_id
        for ns_id in $(config_get_enabled_namespaces); do
            namespace_status "$ns_id"
        done
        echo
        echo "=== Client Steering ==="
        steering_list
    else
        namespace_status "$target"
    fi
}

cmd_health() {
    local target
    target=$(_norm_target "${1:-all}")
    if [[ "$target" == "all" ]]; then
        health_check_all
    else
        health_check "$target"
    fi
}

cmd_exec() {
    local ns_id="${1:-}"
    shift || true
    [[ -n "$ns_id" && $# -gt 0 ]] || {
        log_error "Usage: vpn_ctl exec {id} {command...}"; exit 1; }
    # Map id → netns name. v1 grepped `ip netns list` for the bare id while
    # namespaces are named vpn-{id}, so exec always failed.
    namespace_exists "$ns_id" || {
        log_error "Namespace not running: $ns_id"; exit 1; }
    exec ip netns exec "$(ns_name "$ns_id")" "$@"
}

cmd_steering() {
    local sub="${1:-list}"
    shift || true
    case "$sub" in
        add)
            [[ $# -eq 2 ]] || { log_error "Usage: vpn_ctl steering add {client_ip} {id}"; exit 1; }
            steering_add_client "$1" "$2" ;;
        remove)
            [[ $# -eq 1 ]] || { log_error "Usage: vpn_ctl steering remove {client_ip}"; exit 1; }
            steering_remove_client "$1" ;;
        apply) steering_apply_all ;;
        list)  steering_list ;;
        *)     log_error "Unknown steering subcommand: $sub"; exit 1 ;;
    esac
}

cmd_provider() {
    local sub="${1:-show}"
    shift || true
    case "$sub" in
        show) echo "Active provider: $(config_get providers.active nordvpn)" ;;
        list)
            echo "Available providers:"
            local p
            for p in "$PROVIDERS_DIR"/*.sh; do
                [[ -f "$p" ]] && echo "  - $(basename "$p" .sh)"
            done ;;
        status)
            provider_load "$(config_get providers.active nordvpn)" && provider_status ;;
        *) log_error "Unknown provider subcommand: $sub"; exit 1 ;;
    esac
}

cmd_config() {
    local sub="${1:-validate}"
    case "$sub" in
        validate) config_validate ;;
        show)     config_query '.' ;;
        *)        log_error "Unknown config subcommand: $sub"; exit 1 ;;
    esac
}

show_help() {
    cat <<EOF
vpn_ctl - VPN Namespace Manager CLI (v$VERSION)

Usage: vpn_ctl <command> [arguments]

Commands:
  up {id|all}              Start namespace(s) (+ host PBR + steering)
  down {id|all}            Stop namespace(s) (all: full host cleanup)
  restart {id|all}         Restart namespace(s)
  discover {id|all}        (Re-)discover WireGuard configuration
  repair {id}              Restart from cache; re-discover if that fails
  status [id]              Show namespace + steering status
  health [id|all]          Run health checks (geo-verified)
  exec {id} {command...}   Execute command inside namespace vpn-{id}
  steering add {ip} {id}   Add + persist + apply a steering rule
  steering remove {ip}     Remove + persist + apply
  steering apply           Re-sync applied rules from rules.yaml
  steering list            Show configured vs applied rules
  provider show|list|status
  config validate|show
  version | help

Examples:
  vpn_ctl discover all
  vpn_ctl up all
  vpn_ctl steering add 192.168.1.50 tw
  vpn_ctl exec tw curl -s https://api.ip.sb/geoip
  vpn_ctl health all
  vpn_ctl down all

Files:
  Config:      /etc/vpn/config.yaml
  Steering:    /etc/vpn/steering/rules.yaml
  Discovered:  /var/lib/vpn/  (persistent; key files are root-only 0600)
  Runtime:     /run/vpn/      (ephemeral status)
  Log:         /var/log/vpn/vpn.log
EOF
}

main "$@"
```

---

## 6. CLI Reference

### 6.1 Command Summary

| Command | Syntax | Root | Description |
|---------|--------|------|-------------|
| `up` | `vpn_ctl up {id\|all}` | yes | Start namespace(s); installs host PBR + steering |
| `down` | `vpn_ctl down {id\|all}` | yes | Stop namespace(s); `all` removes host chains too |
| `restart` | `vpn_ctl restart {id\|all}` | yes | down + up |
| `discover` | `vpn_ctl discover {id\|all}` | yes | (Re-)harvest WireGuard config from the provider |
| `repair` | `vpn_ctl repair {id}` | yes | Restart from cache; force re-discovery if that fails |
| `status` | `vpn_ctl status [id]` | no | Namespace phase, handshake, transfer, config validity, steering table |
| `health` | `vpn_ctl health [id\|all]` | yes | Handshake + geo verification; `all` drives the state machine |
| `exec` | `vpn_ctl exec {id} {cmd...}` | yes | Run a command inside netns `vpn-{id}` |
| `steering add` | `vpn_ctl steering add {ip} {id}` | yes | Persist to rules.yaml + apply + conntrack flush |
| `steering remove` | `vpn_ctl steering remove {ip}` | yes | Remove + apply + conntrack flush |
| `steering apply` | `vpn_ctl steering apply` | yes | Re-sync chain from rules.yaml |
| `steering list` | `vpn_ctl steering list` | yes | Configured vs applied rules |
| `provider` | `vpn_ctl provider show\|list\|status` | no | Provider info |
| `config` | `vpn_ctl config validate\|show` | no | Validate/dump configuration |
| `version`, `help` | — | no | — |

`all` and `--all` are interchangeable everywhere.

### 6.2 Command Details

#### `up`

```bash
vpn_ctl up tw      # one namespace
vpn_ctl up all     # all enabled namespaces
```

Process:
1. `config_validate` (fail fast)
2. Host plumbing: sysctls (`ip_forward`, `rp_filter=2`), `VPN_STEER`/`VPN_FWD`
   chains, IPv6 backstop
3. Per namespace: cached config check → discovery if invalid/expired →
   netns + WG (host-created, then moved) + routed veth + in-namespace
   routes/NAT/firewall/MSS clamp/DNS → PBR table + ip rule
4. `steering_apply_all`

Failures in one namespace do not abort the others; the command exits non-zero
with a summary if any failed.

#### `down`

```bash
vpn_ctl down tw    # stop one; steering re-synced (its marks removed)
vpn_ctl down all   # stop everything incl. crash leftovers; remove host chains
```

`down all` intentionally does **not** remove the `ip6tables` FORWARD drop
(rationale in Section 5.2.7) and does not delete discovered configs or key
files — a later `up` reuses the cache if it is still valid.

#### `discover`

```bash
vpn_ctl discover all   # sequential, provider cooldown between namespaces
vpn_ctl discover tw    # one namespace (overwrites cached config + key file)
```

Requires `nordvpn login` to have been completed for NordVPN namespaces.
Discovery briefly routes the **host** through the provider; avoid running it
while latency-sensitive host traffic is in flight. Already-running namespaces
and their steered clients are unaffected (their WG sockets and credentials are
independent of the nordlynx interface used for harvesting).

#### `repair`

```bash
vpn_ctl repair tw
```

Stage 1: down + up from cached config (fixes local breakage). Stage 2, only if
stage 1 fails: discard cache, re-discover, up (fixes server-side credential
invalidation). Bounded by `health.repair_attempts`. This is the same code path
the health timer triggers for DEGRADED namespaces — running it manually is
always safe.

#### `status`

```bash
vpn_ctl status        # all namespaces + steering table
vpn_ctl status tw     # one namespace
```

Example output:

```
=== VPN Namespace Status ===
── tw (Taiwan) ─ ACTIVE
   handshake: 34s ago
   endpoint:  45.76.123.45:51820
   transfer:  rx 1.2MiB  tx 4.5MiB
   config:    valid (discovered 2026-06-09T10:30:00Z)
── sg (Singapore) ─ STOPPED
   config:    missing or expired

=== Client Steering ===
CLIENT           NS     APPLIED   DESCRIPTION
192.168.1.50     tw     yes       Research station A - Taiwan exit
192.168.1.51     sg     no        Research station B - Singapore exit
```

`APPLIED=no` while the target namespace is down is by design (Section 5.2.8):
marking traffic into a dead routing table would blackhole the client. The rule
is applied automatically when the namespace comes back up.

#### `health`

```bash
vpn_ctl health tw     # one check: handshake age + in-namespace geo lookup
vpn_ctl health all    # what the timer runs: checks + state machine + repair
```

#### `exec`

```bash
vpn_ctl exec tw curl -s https://api.ip.sb/geoip   # → Taiwan exit
vpn_ctl exec tw ping -c3 1.1.1.1
vpn_ctl exec tw traceroute 8.8.8.8
```

DNS inside the namespace resolves via `/etc/netns/vpn-{id}/resolv.conf`
(`client_steering.namespace_dns`), not the host's stub resolver.

#### `steering`

```bash
vpn_ctl steering add 192.168.1.50 tw
vpn_ctl steering list
vpn_ctl steering remove 192.168.1.50
vpn_ctl steering apply       # re-sync after hand-editing rules.yaml
```

`add`/`remove` write `rules.yaml` first, then re-sync the live chain, then
flush the client's conntrack entries so the change applies to established
flows immediately (not after conntrack timeout).

---

## 7. Testing Strategy

### 7.0 Phase 0: Credential Lifetime Spike (BLOCKING)

Everything in this design assumes harvested NordLynx credentials keep working
after `nordvpn disconnect` (Section 1.7). **This spike runs before any other
implementation work**, and its results set `state.config_max_age` — or stop
the project before effort is spent on an unworkable assumption.

**Script:** `tests/spike_credential_lifetime.sh`

```bash
#!/usr/bin/env bash
#
# Measures how long a harvested NordLynx config remains usable after
# `nordvpn disconnect`. Run for at least 48 h; results drive config_max_age.
#
# Method:
#   1. nordvpn connect {country}; harvest sanitized config (same mechanism
#      as providers/nordvpn.sh); nordvpn disconnect
#   2. Build a minimal test namespace from the harvested config (same
#      mechanism as lib/namespace.sh)
#   3. Every CHECK_INTERVAL: ping through the tunnel; record elapsed time,
#      handshake age, and success/failure to CSV
#   4. Stop after the tunnel has been dead for 3 consecutive checks
#
set -uo pipefail
COUNTRY="${1:-Taiwan}"
CHECK_INTERVAL=600        # 10 minutes
OUT="credential_lifetime_$(date +%Y%m%d_%H%M).csv"

# ... harvest + minimal namespace setup (reuses lib/ functions) ...

echo "timestamp,elapsed_s,handshake_age_s,ping_ok" > "$OUT"
start=$(date +%s); dead=0
while (( dead < 3 )); do
    sleep "$CHECK_INTERVAL"
    now=$(date +%s)
    hs=$(ip netns exec spike-ns wg show spike-wg latest-handshakes | awk '{print $2}')
    if ip netns exec spike-ns ping -c1 -W5 1.1.1.1 >/dev/null 2>&1; then
        ok=1; dead=0
    else
        ok=0; dead=$((dead + 1))
    fi
    echo "$(date -u +%FT%TZ),$((now - start)),$((now - hs)),$ok" >> "$OUT"
done
echo "Tunnel died after $(( $(date +%s) - start ))s — see $OUT"
```

**Additional measurements (separate runs):**

- **Concurrency:** repeat with all 5 country configs in active namespaces
  simultaneously — does establishing a 5th session invalidate the 1st?
- **Re-discovery interaction:** does a fresh `nordvpn connect Taiwan`
  invalidate a previously harvested Taiwan config (same server pool)? This
  determines whether `repair` of one namespace can break another.
- **Idle vs. active:** run one tunnel with continuous traffic and one idle —
  does the server expire idle peers faster?

**Acceptance gates:**

| Measured lifetime | Consequence |
|---|---|
| ≥ 24 h, 5 concurrent sessions stable | Proceed as designed; keep `config_max_age: 86400` |
| 1–24 h | Proceed; set `config_max_age` to ~70 % of measured lifetime; expect routine repair cycles and document the churn |
| < 1 h, or concurrent sessions evict each other | **Stop.** The harvest-and-reuse architecture is not viable; rework toward keeping provider sessions alive per namespace, or a provider that issues static WireGuard configs (the `custom` plugin path) |

### 7.1 Unit Tests

**Location:** `tests/unit.sh` — pure functions only (config, state, rules-file
manipulation); no root, no network, no namespace operations. Uses temp dirs
via the `VPN_LIB_DIR` / `VPN_RUN_DIR` / `CONFIG_FILE` environment overrides
that every library already honors.

```bash
#!/usr/bin/env bash
#
# Unit tests. NOTE: deliberately no `set -e` — it would abort the runner on
# the first failing assertion, and `((x++))` returns non-zero when x was 0
# (this exact combination made the v1 suite exit after its first PASS).
#
set -u

export VPN_LOG_LEVEL=error
export VPN_LIB_DIR VPN_RUN_DIR
VPN_LIB_DIR=$(mktemp -d)
VPN_RUN_DIR=$(mktemp -d)
trap 'rm -rf "$VPN_LIB_DIR" "$VPN_RUN_DIR" "${CONFIG_FILE:-}"' EXIT

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib"
source "$LIB/log.sh"; source "$LIB/config.sh"; source "$LIB/state.sh"

TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0

assert_equals() {  # expected actual message
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$1" == "$2" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "FAIL: ${3:-} (expected '$1', got '$2')" >&2
    fi
}

assert_ok() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@"; then TESTS_PASSED=$((TESTS_PASSED + 1))
    else TESTS_FAILED=$((TESTS_FAILED + 1)); echo "FAIL: $*" >&2; fi
}

assert_fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! "$@"; then TESTS_PASSED=$((TESTS_PASSED + 1))
    else TESTS_FAILED=$((TESTS_FAILED + 1)); echo "FAIL (expected failure): $*" >&2; fi
}

# ---- config ----
test_config() {
    CONFIG_FILE=$(mktemp)
    cat > "$CONFIG_FILE" <<'YAML'
global: {client_lan: 192.168.1.0/24, mtu: 1420}
namespaces:
  - {id: tw, provider: nordvpn, country: Taiwan, expected_country_code: TW,
     gateway_subnet: 172.30.30.0/24, gateway_ip: 172.30.30.1,
     host_veth_ip: 172.30.30.2, routing_table: 100, enabled: true}
  - {id: xx, provider: nordvpn, country: Nowhere, expected_country_code: XX,
     gateway_subnet: 172.30.40.0/24, gateway_ip: 172.30.40.1,
     host_veth_ip: 172.30.40.2, routing_table: 110, enabled: false}
YAML
    CONFIG_LOADED=false
    assert_ok      config_load "$CONFIG_FILE"
    assert_equals  "1420" "$(config_get global.mtu)"              "config_get scalar"
    assert_equals  "fb"   "$(config_get global.missing fb)"       "config_get default"
    assert_fail    config_get global.missing
    assert_equals  "tw"   "$(config_get_enabled_namespaces)"      "disabled ns excluded"
    assert_equals  "Taiwan" "$(config_get_ns_field tw country)"   "ns field lookup"
    assert_fail    config_get_ns_field tw nonexistent
    assert_ok      config_validate
}

# ---- config validation rejects duplicates ----
test_config_duplicates() {
    CONFIG_FILE=$(mktemp)
    cat > "$CONFIG_FILE" <<'YAML'
global: {client_lan: 192.168.1.0/24}
namespaces:
  - {id: tw, country: T, expected_country_code: TW,
     gateway_subnet: 172.30.30.0/24, gateway_ip: 172.30.30.1,
     host_veth_ip: 172.30.30.2, routing_table: 100, enabled: true}
  - {id: sg, country: S, expected_country_code: SG,
     gateway_subnet: 172.30.31.0/24, gateway_ip: 172.30.31.1,
     host_veth_ip: 172.30.31.2, routing_table: 100, enabled: true}
YAML
    CONFIG_LOADED=false; config_load "$CONFIG_FILE"
    assert_fail config_validate     # duplicate routing_table 100
}

# ---- state ----
test_state() {
    state_init
    local now json
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    json=$(jq -n --arg kf "$VPN_LIB_DIR/keys/t1.conf" --arg ts "$now" '{
        version: "2.0.0", namespace_id: "t1",
        wireguard: {key_file: $kf, wg_ip: "10.5.0.2/32",
                    wg_peer_public_key: "pk",
                    wg_peer_endpoint: "1.2.3.4:51820"},
        discovered_at: $ts}')
    touch "$VPN_LIB_DIR/keys/t1.conf"

    discovered_save t1 "$json"
    assert_equals "600" "$(stat -c %a "$(discovered_path t1)")"  "state file mode"
    assert_ok discovered_is_valid t1

    rm "$VPN_LIB_DIR/keys/t1.conf"
    assert_fail discovered_is_valid t1          # missing key file invalidates

    touch "$VPN_LIB_DIR/keys/t1.conf"
    discovered_save t1 "$(jq '.discovered_at = "2020-01-01T00:00:00Z"' <<<"$json")"
    assert_fail discovered_is_valid t1          # expiry honored

    runtime_init t1 STARTING
    runtime_set t1 '.phase = "ACTIVE" | .consecutive_failures += 1'
    assert_equals "ACTIVE" "$(runtime_get t1 .phase)"            "runtime roundtrip"
    assert_equals "1" "$(runtime_get t1 .consecutive_failures)"  "runtime counter"
    runtime_delete t1; discovered_delete t1
}

test_config
test_config_duplicates
test_state

echo "----------------------------------------"
echo "Run: $TESTS_RUN  Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
```

### 7.2 Static Analysis

All shell sources must pass `shellcheck` with no warnings; this is a CI gate
alongside the unit tests (both run without root):

```bash
shellcheck -x vpn_ctl lib/*.sh providers/*.sh tests/*.sh setup.sh
```

### 7.3 Integration Tests

**Location:** `tests/integration.sh` — requires root, a logged-in provider,
and a scratch host (it mutates routing and firewall state; do not run on a
host carrying other traffic). Assertions verify the **actual v2 artifacts**;
v1's suite grepped for rules its own design never created (e.g. the unquoted
`grep fwmark 100` against `ip rule` output, which matched nothing).

Uses the same `assert_*` helpers and result counters as `unit.sh` (sourced
from a shared `tests/helpers.sh`); each test cleans up after itself so a
failure in one does not poison the next.

```bash
# ---- single namespace lifecycle ----
test_lifecycle() {
    vpn_ctl discover tw                                   || return 1
    # harvested artifacts: present, locked down, sanitized
    test -f /var/lib/vpn/keys/tw.conf                     || return 1
    [[ $(stat -c %a /var/lib/vpn/keys/tw.conf) == 600 ]]  || return 1
    grep -q  '^PrivateKey' /var/lib/vpn/keys/tw.conf      || return 1
    ! grep -qE '^(ListenPort|FwMark)' /var/lib/vpn/keys/tw.conf || return 1

    vpn_ctl up tw                                         || return 1
    # data plane artifacts
    ip netns list | grep -qw vpn-tw                       || return 1
    ip route show table 100 | \
        grep -q 'default via 172.30.30.1 dev veth-tw'     || return 1
    ip rule show | grep -qE '^1100:.*fwmark (0x64|100) lookup 100' || return 1
    ip netns exec vpn-tw ip route show | \
        grep -q '192.168.1.0/24 via 172.30.30.2'          || return 1  # return route
    test -f /etc/netns/vpn-tw/resolv.conf                 || return 1
    [[ $(cat /proc/sys/net/ipv4/conf/veth-tw/rp_filter) == 2 ]] || return 1

    # function
    vpn_ctl health tw                                     || return 1
    [[ "$(vpn_ctl exec tw curl -s https://api.ip.sb/geoip \
          | jq -r .country_code)" == "TW" ]]              || return 1

    vpn_ctl down tw                                       || return 1
    ! ip netns list | grep -qw vpn-tw                     || return 1
    ! ip rule show  | grep -q '^1100:'                    || return 1
    [[ -z "$(ip route show table 100 2>/dev/null)" ]]     || return 1
}

# ---- steering: applied rule, persistence, removal ----
test_steering() {
    vpn_ctl up tw                                         || return 1
    vpn_ctl steering add 192.168.1.50 tw                  || return 1
    iptables -t mangle -C VPN_STEER -s 192.168.1.50 \
        -j MARK --set-mark 100                            || return 1
    grep -q '192.168.1.50' /etc/vpn/steering/rules.yaml   || return 1

    vpn_ctl steering remove 192.168.1.50                  || return 1
    ! iptables -t mangle -C VPN_STEER -s 192.168.1.50 \
        -j MARK --set-mark 100 2>/dev/null                || return 1
    ! grep -q '192.168.1.50' /etc/vpn/steering/rules.yaml || return 1
    vpn_ctl down tw
}

# ---- steering refuses to blackhole: rule for a stopped namespace ----
test_steering_down_ns() {
    vpn_ctl up tw                                         || return 1
    vpn_ctl steering add 192.168.1.50 sg                  || return 1  # sg is DOWN
    # persisted but NOT applied
    grep -q '192.168.1.50' /etc/vpn/steering/rules.yaml   || return 1
    ! iptables -t mangle -L VPN_STEER -n | grep -q 192.168.1.50 || return 1
    vpn_ctl steering remove 192.168.1.50
    vpn_ctl down tw
}

# ---- isolation: namespaces must NOT reach each other ----
test_isolation() {
    vpn_ctl up tw && vpn_ctl up sg                        || return 1
    ! vpn_ctl exec tw ping -c1 -W2 172.30.31.1            || return 1
    ! vpn_ctl exec sg ping -c1 -W2 172.30.30.1            || return 1
    vpn_ctl down all
}

# ---- cache reuse: second up must not re-discover ----
test_cache_reuse() {
    vpn_ctl up tw || return 1
    vpn_ctl down tw
    local before after
    before=$(stat -c %Y /var/lib/vpn/namespaces/tw.json)
    vpn_ctl up tw                                         || return 1
    after=$(stat -c %Y /var/lib/vpn/namespaces/tw.json)
    [[ "$before" == "$after" ]]                           || return 1
    vpn_ctl down tw
}

# ---- repair: stage 1 recovers a locally broken namespace ----
test_repair() {
    vpn_ctl up tw || return 1
    ip netns exec vpn-tw ip link del wg-tw                # break it locally
    vpn_ctl repair tw                                     || return 1
    vpn_ctl health tw                                     || return 1
    vpn_ctl down tw
}

# ---- crash recovery: down all cleans leftovers with /run lost ----
test_crash_cleanup() {
    vpn_ctl up tw || return 1
    rm -rf /run/vpn/status            # simulate reboot-wiped runtime state
    vpn_ctl down all                                      || return 1
    ! ip netns list | grep -qw vpn-tw                     || return 1
    ! iptables -t mangle -L VPN_STEER -n >/dev/null 2>&1  || return 1  # chain gone
}

# ---- idempotency: up twice fails cleanly, down twice succeeds ----
test_idempotency() {
    vpn_ctl up tw   || return 1
    ! vpn_ctl up tw || return 1       # refuses, does not corrupt
    vpn_ctl health tw || return 1     # still healthy after refused second up
    vpn_ctl down tw || return 1
    vpn_ctl down tw || return 1       # second down is a no-op, exit 0
}
```

### 7.4 End-to-End Validation (manual, per deployment)

The integration suite cannot validate the client side of the steering path
(it has no second machine). After deployment, verify from an **actual steered
client** (default gateway = VPN host, Section 2.6):

```bash
curl -s https://api.ip.sb/geoip | jq .country_code   # expected exit country
dig +short whoami.akamai.net                          # DNS egress path check
curl -6 -s --max-time 5 https://api6.ipify.org        # must FAIL (v6 blocked)
ping -c3 192.168.1.10                                 # LAN bypass: host reachable
ping -c3 192.168.1.1                                  # LAN bypass: router reachable
ssh user@192.168.1.51 true                            # LAN bypass: client↔client
```

With `dns_redirect: true`, additionally confirm the resolver answering is the
tunnel-side one:

```bash
dig +short TXT whoami.cloudflare @192.168.1.1 CHAOS   # answered via tunnel DNAT
```

On the host while the client generates traffic:

```bash
iptables -t mangle -L VPN_STEER -v -n    # per-client packet counters rising
conntrack -L --orig-src 192.168.1.50     # flows tracked
ip netns exec vpn-tw wg show             # handshake fresh, transfer rising
```

And the TCP path health check (validates MSS clamping end to end):

```bash
curl -s -o /dev/null -w '%{speed_download}\n' https://speed.cloudflare.com/__down?bytes=10000000
# A hang or stall here with small transfers working points at MTU/MSS issues.
```

---

## 8. Deployment Guide

### 8.1 Prerequisites

- **Operating System:** Linux (tested on Debian 12/13, Ubuntu 22.04+)
- **Kernel:** 5.6+ (in-tree WireGuard)
- **Packages:**
  - `wireguard-tools` (`wg`)
  - `iproute2` with JSON support (`ip -j`; any non-ancient version)
  - `iptables` (legacy or nft backend — rules use the `iptables` front-end)
  - `jq`
  - `yq` v4 (mikefarah; not the Python `yq`)
  - `curl`
  - `conntrack` (recommended — immediate steering changes; optional)
  - `nordvpn` CLI, logged in (for the nordvpn provider)
- **Not required:** `bridge-utils` (v1 dependency; there is no bridge),
  `wg-quick` (interfaces are built directly)
- **Network:** a routed LAN-facing interface (e.g. `ens20`). The host's IP
  configuration is never modified by this system — unlike v1, whose bridge
  enslaving could cut off remote access.

```bash
sudo apt update
sudo apt install -y wireguard-tools jq iptables curl conntrack
wget -qO /tmp/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo install -m 755 /tmp/yq /usr/local/bin/yq
```

### 8.2 Installation

```bash
git clone https://github.com/your-org/vpn-namespace-manager.git
cd vpn-namespace-manager
sudo ./setup.sh          # dirs, permissions, files, systemd units, logrotate
vpn_ctl version          # verify install
```

`setup.sh` (Section 5.1) also installs `/etc/logrotate.d/vpn`:

```
/var/log/vpn/vpn.log {
    weekly
    rotate 5
    size 10M
    compress
    missingok
    notifempty
}
```

### 8.3 Configuration

```bash
sudo nano /etc/vpn/config.yaml             # namespaces, client_lan, providers
sudo nano /etc/vpn/steering/rules.yaml     # client → namespace mapping
vpn_ctl config validate                    # must pass before first up
```

For the NordVPN provider, log in once interactively:

```bash
sudo nordvpn login    # then follow the browser flow
sudo nordvpn account  # verify
```

(Preflight enforces `technology nordlynx`, `killswitch off`,
`autoconnect off` automatically on every discovery — Section 5.3.1.)

### 8.4 Client Gateway Setup (required — Section 2.6)

Host PBR only steers traffic the host routes. Pick one:

**Option 1 (recommended): per-client gateway override.** On the router's
DHCP server, create reservations for the steered clients with DHCP option 3
(router) = `192.168.1.10`; or configure the gateway statically on each client.
Non-steered hosts keep using the router directly and are untouched.

**Option 2: router policy routes.** Clients keep the router as gateway; the
router policy-routes traffic *from* each steered client IP to `192.168.1.10`
as next-hop. Requires a router with source-based routing (OpenWrt, MikroTik,
pfSense, etc.). Host configuration is identical.

**IPv6 on the client LAN:** the host blocks forwarded v6 (Section 5.2.7), but
clients with a *different* v6 default route (router RAs) bypass the host
entirely — v6 traffic would exit unsteered and invalidate geo tests. Disable
router advertisements toward steered clients (or disable IPv6 on them), and
verify with the v6 check in Section 7.4.

### 8.5 Systemd Units

#### `vpn-namespace.service` — bring-up at boot

```ini
[Unit]
Description=VPN Namespace Manager
# Needs working DNS + uplink (discovery and tunnels) and the NordVPN daemon.
# v1 had Before=network-online.target, which is backwards for a service that
# requires the network to be online.
Wants=network-online.target
After=network-online.target nordvpnd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/vpn_ctl up all
ExecStop=/usr/local/sbin/vpn_ctl down all
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
```

`TimeoutStartSec=600` covers the worst case where every cached config expired
and boot triggers five sequential discoveries. With intact caches in
`/var/lib/vpn`, start takes seconds — the persistence split (Section 3.1) is
what makes boot-time restore practical at all.

#### `vpn-health.service` + `vpn-health.timer` — the health loop actor

```ini
# vpn-health.service
[Unit]
Description=VPN namespace health check pass
After=vpn-namespace.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn_ctl health all
```

```ini
# vpn-health.timer
[Unit]
Description=Periodic VPN namespace health checks

[Timer]
OnBootSec=2min
OnUnitInactiveSec=60s

[Install]
WantedBy=timers.target
```

`OnUnitInactiveSec` (rather than `OnCalendar`) prevents overlapping runs: the
next interval starts counting only after the previous pass — which may include
a multi-minute repair with re-discovery — has finished.

#### Enable

```bash
sudo systemctl enable --now vpn-namespace.service
sudo systemctl enable --now vpn-health.timer
```

### 8.6 First Run

```bash
sudo vpn_ctl discover all     # ~1 min per namespace (connect/harvest/verify)
sudo vpn_ctl up all
vpn_ctl status
sudo vpn_ctl exec tw curl -s https://api.ip.sb/geoip   # spot-check one exit
```

Then run the client-side checks from Section 7.4 from at least one steered
client before declaring the deployment done.

### 8.7 Upgrades

```bash
sudo systemctl stop vpn-namespace.service   # runs down all
cd vpn-namespace-manager && git pull
sudo ./setup.sh                             # preserves /etc/vpn configs
sudo systemctl start vpn-namespace.service
```

Discovered configs and keys in `/var/lib/vpn` survive upgrades; namespaces
come back from cache without re-discovery.

---

## 9. Troubleshooting

### 9.1 Common Issues

#### Namespace fails to start

```bash
# What does the manager know?
vpn_ctl status tw
sudo tail -50 /var/log/vpn/vpn.log

# Is the cached config valid? (age, fields, key file)
sudo jq . /var/lib/vpn/namespaces/tw.json
sudo head -c 200 /var/lib/vpn/keys/tw.conf   # should show [Interface]/PrivateKey

# Force a fresh discovery
sudo vpn_ctl discover tw && sudo vpn_ctl up tw
```

Typical causes: expired cache with the provider unreachable (check
`nordvpn account`), or a half-deleted previous instance — `vpn_ctl down tw`
is safe to run on leftovers before retrying.

#### Tunnel up but no handshake / no traffic

```bash
sudo vpn_ctl exec tw wg show               # handshake age, endpoint, transfer
sudo vpn_ctl exec tw ping -c3 1.1.1.1      # forces a handshake attempt
```

- **Handshake never completes:** harvested credentials are likely dead
  server-side (Section 1.7). `sudo vpn_ctl repair tw` — stage 2 re-discovers.
- **Handshake OK but no traffic:** check the in-namespace default route
  (`vpn_ctl exec tw ip route`) and NAT
  (`vpn_ctl exec tw iptables -t nat -L POSTROUTING -n`).

#### Client steering not working

Work through the packet path in order — each step has an observable artifact:

```bash
# 0. Is the client's traffic reaching this host at all?
#    (Section 2.6: client default gw must be the VPN host or router PBR)
sudo tcpdump -ni ens20 host 192.168.1.50 and not arp -c 10

# 1. Is the rule configured AND applied? (APPLIED=no → namespace down)
sudo vpn_ctl steering list

# 2. Is the mark being set? (pkts counter must rise with client traffic)
sudo iptables -t mangle -L VPN_STEER -v -n

# 3. Does the fwmark rule + table exist?
ip rule show | grep 1100
ip route show table 100

# 4. Is traffic crossing the veth?
sudo tcpdump -ni veth-tw -c 10

# 5. Old flows still on the old path? (steering changed mid-connection)
sudo conntrack -D --orig-src 192.168.1.50

# 6. rp_filter regression? (some hardening tools reset it to 1 = strict,
#    which silently drops ALL return traffic — Section 5.2.7)
sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.veth-tw.rp_filter
```

Step 0 is the most common failure: if the client still uses the router as
default gateway, no later step can work — that is a deployment issue
(Section 8.4), not a host issue.

#### Health check fails / DEGRADED

```bash
sudo vpn_ctl exec tw ping -c3 1.1.1.1                      # raw connectivity
sudo vpn_ctl exec tw curl -sv https://api.ip.sb/geoip      # geo service + DNS
cat /etc/netns/vpn-tw/resolv.conf                          # ns resolver set?
sudo jq . /run/vpn/status/tw.json                          # counters, last_error
```

- **All geo services unreachable but ping works:** DNS problem inside the
  namespace; check the resolv.conf above.
- **Geo mismatch:** provider moved the exit, or a geo database disagrees.
  Cross-check a second service manually before blaming the tunnel; if real,
  `vpn_ctl repair tw` re-discovers.
- **Flapping ACTIVE↔DEGRADED:** raise `health.handshake_max_age` or check for
  packet loss to the WG endpoint (`ping $(jq -r .wireguard.wg_peer_endpoint \
  /var/lib/vpn/namespaces/tw.json | cut -d: -f1)`).

#### Small transfers work, large ones stall

Classic MTU/PMTUD failure. Verify MSS clamping is active:

```bash
sudo vpn_ctl exec tw iptables -t mangle -L FORWARD -n | grep TCPMSS
```

If present and stalls persist, lower `global.mtu` (e.g. 1380) and
`vpn_ctl restart` the namespaces.

#### Discovery fails

```bash
sudo nordvpn account                # logged in?
nordvpn status                      # daemon reachable?
sudo wg showconf nordlynx           # works only while connected, as root
sudo vpn_ctl provider status
```

If `nordvpn connect` succeeds but the handshake wait times out, check that
the killswitch is actually off (`nordvpn settings`) — preflight sets it, but
a daemon update can re-enable it.

### 9.2 Debug Mode

```bash
# Per-invocation
sudo VPN_LOG_LEVEL=debug vpn_ctl up tw

# Persistent: /etc/vpn/config.yaml → global.log_level: debug
```

### 9.3 Full Recovery Procedure

For a host in an unknown state (failed upgrade, manual experimentation):

```bash
# 1. Tear down everything the manager knows about, plus crash leftovers
sudo vpn_ctl down all

# 2. Verify nothing is left (each should print nothing)
ip netns list | grep '^vpn-'
ip rule show | awk '$1 ~ /^1[01][0-9][0-9]:/'
ip link show type veth | grep 'veth-'
sudo iptables -t mangle -L VPN_STEER -n 2>/dev/null

# 3. If something survived, remove it directly
sudo ip -all netns delete                      # ALL netns on the host (lab only)
for t in 100 101 102 103 104; do sudo ip route flush table $t; done

# 4. Optionally discard cached configs to force clean re-discovery
sudo rm -f /var/lib/vpn/namespaces/*.json /var/lib/vpn/keys/*.conf

# 5. Rebuild
sudo vpn_ctl discover all && sudo vpn_ctl up all
```

Do **not** use v1's `iptables -t nat -F` / `-t mangle -F` here: flushing whole
tables destroys rules owned by other software (Docker, libvirt, fail2ban).
v2 confines itself to its own named chains precisely so that recovery never
has to touch anything else's rules.

---

## 10. Future Enhancements

Config stubs for all three exist (disabled) in Section 3.2 so enabling them
later is not a schema migration.

### 10.1 SSL Inspection (Stub)

**Planned:** per-namespace transparent mitmproxy for traffic analysis.

**Implementation notes (updated for the routed topology):**
- Run mitmproxy *inside* the namespace; redirect with an in-namespace
  `nat PREROUTING` rule (`-i veth0 -p tcp --dport 443 -j REDIRECT
  --to-ports 8080`) — same pattern as the existing DNS redirect (5.2.6),
  no host-side changes needed.
- Per-namespace CA certificates under `/var/lib/vpn/ca/{id}/` (0600,
  alongside the WG keys); inspection logs to `/var/log/vpn/inspection/{id}/`.
- Steered clients must trust the CA — distribution is out of scope here.

### 10.2 QoS / Traffic Shaping (Stub)

**Planned:** per-namespace bandwidth limits.

**Implementation notes:**
- `tc` HTB on the **host side** of each veth (`veth-{id}`) shapes
  namespace-bound (client→VPN) traffic; an HTB on `veth0` inside the
  namespace shapes the return direction. Both attachment points already
  exist per namespace — no allocation logic needed.
- `fq_codel` as the leaf qdisc to keep latency sane under load.

### 10.3 Prometheus Metrics (Stub)

**Planned:** textfile-collector or small HTTP exporter reading what the
system already records.

**Metrics (all derivable from existing state + `wg show`):**
- `vpn_namespace_up{namespace}` — phase == ACTIVE
- `vpn_namespace_handshake_age_seconds{namespace}`
- `vpn_namespace_transfer_bytes{namespace,direction}`
- `vpn_namespace_consecutive_failures{namespace}`
- `vpn_namespace_geo_verified{namespace}`
- `vpn_steering_rules{state="applied|configured"}`

Cheapest path: a `vpn_ctl metrics` subcommand emitting Prometheus text
format, run by the existing health timer into
`/var/lib/node_exporter/textfile/vpn.prom`.

### 10.4 Other Candidates

- **Advanced steering matches** (MAC source, destination port): the
  `VPN_STEER` chain structure already accommodates extra match rules ahead
  of the per-client marks; needs schema + CLI only.
- **REST API / remote management:** wrap `vpn_ctl` verbs; authentication
  design required first.
- **IPv6 transport:** end-to-end v6 through the tunnels (currently blocked
  by design, Section 5.2.7).

---

## 11. Appendices

### 11.1 Glossary

| Term | Definition |
|------|------------|
| **Namespace (netns)** | Linux network namespace; isolated network stack (interfaces, routes, firewall) |
| **PBR** | Policy-Based Routing — routing decisions from packet marks rather than destination only |
| **fwmark** | Kernel packet mark set by iptables, matched by `ip rule` |
| **veth pair** | Virtual ethernet cable; here: routed link between host and namespace (one IP per end) |
| **WireGuard socket trick** | A WG interface's UDP socket stays bound in the netns where the interface was *created*; creating on the host and moving into the netns gives the tunnel internet access without an uplink veth |
| **NordLynx** | NordVPN's WireGuard implementation; source of harvested configs |
| **MASQUERADE** | Source NAT to the outgoing interface's address (here: the WG interface IP inside each namespace) |
| **rp_filter** | Reverse-path filter; must be loose (2) here because PBR return traffic is asymmetric |
| **MSS clamping** | Rewriting TCP MSS in SYNs to fit the tunnel MTU; substitute for broken PMTUD |
| **Discovery** | Connecting via a provider once to harvest WireGuard credentials for later standalone use |

### 11.2 Quick Reference Card

```
Topology:    client (gw=host) → ens20 → [mark] → table 10x → veth-{id}
             → netns vpn-{id} → MASQ → wg-{id} → (host-bound UDP socket)
             → internet → VPN exit

Naming:      netns vpn-{id} · host veth veth-{id} (.2) · ns veth veth0 (.1)
             wg iface wg-{id} · table == mark == 100..104 · rule pref 1000+mark

Paths:       /etc/vpn (config) · /var/lib/vpn (keys+discovered, 0600/0700)
             /run/vpn (runtime) · /var/log/vpn (logs)

Key cmds:    vpn_ctl up all · status · health all · repair {id}
             steering add {ip} {id} · exec {id} {cmd} · down all
```

### 11.3 References

- [Linux Network Namespaces (LWN)](https://lwn.net/Articles/580893/)
- [WireGuard: Routing & Network Namespace Integration](https://www.wireguard.com/netns/) — authoritative description of the socket-stays-in-creating-netns behavior this design depends on
- [Policy Routing with Linux (ip-rule(8), ip-route(8))](https://man7.org/linux/man-pages/man8/ip-rule.8.html)
- [WireGuard Documentation](https://www.wireguard.com/)
- [NordVPN Linux CLI](https://github.com/NordVPN/nordvpn-linux)
- [netfilter/iptables documentation](https://netfilter.org/documentation/)

### 11.4 Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-06-09 | Initial plan (bridged topology; superseded) |
| 2.0.0 | 2026-06-09 | Routed/PBR architecture; discovery fixes (private key capture, geo-before-disconnect, ListenPort stripping); persistence split /var/lib vs /run; secrets out of state JSON; missing libraries (5.2.5–5.2.9) specified; health timer + repair path; DNS/IPv6/MSS/rp_filter handling; Phase 0 credential spike; CLI fixes (all/--all, exec mapping, repair, config validate); corrected systemd ordering; chain-scoped firewall recovery |

### 11.5 Document Approval

| Role | Name | Date | Signature |
|------|------|------|-----------|
| Author | Security Research Infrastructure Team | 2026-06-09 | — |
| Reviewer (network architecture) | | | |
| Approver | | | |
