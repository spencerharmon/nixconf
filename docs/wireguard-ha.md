# HA WireGuard on the chrome fleet

`profiles/wireguard-ha.nix` + `scripts/wg-ha-peers.py`. One WireGuard server
identity, three candidate nodes; keepalived (VRRP) elects the active one.

## Why it looks like this

The LAN router supports **neither static port-forwards nor static routes — only
UPnP (IGD)**. So:

- Inbound: the active node holds a UPnP mapping `WG port -> its own LAN IP`.
- Return path: the active node MASQUERADEs the VPN pool onto its LAN uplink
  (LAN hosts see VPN traffic from the active node's IP). No route, no floating IP.

The router's UPnP was measured (test port, no live impact):

| behaviour | result | consequence |
|---|---|---|
| another host adds the same external port | 718 ConflictInMappingEntry | no takeover |
| another host deletes it | 606 not authorized (secure mode) | only the owner can release |
| lease expiry | exact (to the second) | dead node's mapping frees itself |
| owner re-add | resets the lease | refresh works |

Hence: short lease (120 s), refreshed every 30 s by the active node; a graceful
handover releases the mapping (seconds); a hard node failure is covered by lease
expiry (<= 120 s) while the new active node retries every 5 s. Because only the
mapping owner receives WAN traffic, the router itself fences VRRP split-brain.

## Moving parts (per node)

- `keepalived` VRRP instance `wg` (state BACKUP, `nopreempt`, per-host priority).
  Its notify hook starts `wg-ha-active.service` on MASTER and stops it otherwise.
- `wg-ha-active.service` (only if `/var/lib/wg-ha/armed` exists):
  `ExecStartPre` = `wg-quick up` (agenix `wg0.conf`) + INPUT/FORWARD/MASQUERADE;
  `ExecStart` = UPnP claim/refresh loop; `ExecStopPost` = release mapping, remove
  rules, `wg-quick down`.
- `wg-ha status|arm|disarm` on each node. `/var/lib/wg-ha/override.env` may override
  `WG_HA_PORT` for testing (e.g. a spare port) without touching the secrets.

## Secrets (agenix)

| file | recipients | content |
|---|---|---|
| `wg-ha-state.age` | admin only | source of truth: server key, all client keys, client settings, router IGD URL |
| `wg-ha-wg0.conf.age` | admin + chrome hosts | derived wg-quick config (server key + enabled peers) |
| `wg-ha.env.age` | admin + chrome hosts | derived `WG_HA_UPNP_URL`, `WG_HA_SUBNET`, `WG_HA_PORT`, `WG_HA_LEASE` |

## Peers

```
nix run .#wg-ha-peers -- list
nix run .#wg-ha-peers -- add <name>          # keys + next free address, re-renders
nix run .#wg-ha-peers -- show <name> --qr    # client config + QR
nix run .#wg-ha-peers -- disable|enable|remove <name>
```

Then commit `secrets/` and deploy the chrome hosts (deploy-rs). `wg-quick` reloads
on the active node when its config changes (restart of `wg-ha-active`).

## Operations

- Which node is active: `wg-ha status` on each node (or the router's `upnpc -l`).
- Planned maintenance of the active node: `systemctl stop keepalived` there first
  (graceful handover), then reboot/deploy.
- Never run two independent WireGuard servers with this identity holding the same
  router port; the cutover from any previous server must release its mapping first
  (a UPnP mapping can only be deleted by the host that owns it).
