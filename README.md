# tunnels

Namespace-based multi-country VPN host: one isolated network namespace per
configured country, each with its own NordVPN WireGuard tunnel, and policy-based
routing to steer LAN clients out a chosen country. Which countries run is defined
in [`src/config.yaml`](src/config.yaml), not baked into the code.

The application — scripts and documentation — lives in **[`src/`](src/)**:

| Doc | Purpose |
|-----|---------|
| [`src/QUICK_START.md`](src/QUICK_START.md) | Install from scratch + day-to-day operation |
| [`src/RECOVERY.md`](src/RECOVERY.md) | Post-reset recovery + operations runbook |
| [`src/IMPLEMENTATION_PLAN.md`](src/IMPLEMENTATION_PLAN.md) | Full system design |

## Configuration

[`src/config.yaml`](src/config.yaml) is the single source of truth for the region
list — every script reads it through [`src/regions.sh`](src/regions.sh), so no
country list is hardcoded. It's generated from a plain list of countries (codes
and subnets/tables are derived; NordVPN's API resolves names→ISO codes) — pass
whichever countries you want:

```bash
# the set this repo ships with; substitute any NordVPN countries
./src/generate_config.sh Taiwan Singapore Netherlands South_Korea Japan
```

## Operation

Once installed, the host is driven through one entry point,
`/etc/vpn/vpn_namespaces.sh`:

```
up [id]   down [id]   status   validate   enable <id>   disable <id>   backup   restore
steering {apply | add <client> <id> | remove <client> | clear | list}
```

`up` creates all enabled namespaces and applies client steering; a systemd unit
runs it on boot. `disable <id>` takes a country out of service (preserved across
config regeneration). See [`src/QUICK_START.md`](src/QUICK_START.md) for details.

---

`examples/` holds prior test output (PhishTank geographic analysis run through the
tunnels), and `examples/legacy/` keeps superseded prototype scripts for reference.
