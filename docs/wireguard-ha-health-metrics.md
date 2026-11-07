# WireGuard HA Health Metrics

`scripts/wg-ha-health-collector.sh collect [OUT]` is a read-only observer of
native keepalived, UPnP and WireGuard state. `OUT` is atomically replaced, mode
0644; without it, metrics go to stdout. Collection failures are represented in
metrics, not fabricated zero values. Fatal configuration/write failures exit 2
and do not replace the previous file. A successful collection exits 0 even when
some observations failed: consumers must inspect observation flags and freshness.

The NixOS service runs every 30 seconds (5-second timer accuracy), with a
45-second service deadline. Node exporter serves its textfile directory on port
9101. This does not establish Mimir ingestion or end-to-end VPN connectivity.

## Metric Contract

Every metric is a gauge with `cluster="chrome"` and `node="<hostname>"` labels.
Only `wg_ha_role` adds `state`; only peer metrics add `peer`. No raw keys,
addresses, router URLs, or env contents are exported. `peer` is the first 12 hex
characters of SHA-256 over the public-key string, without a trailing newline.

| Metric | Meaning and presence |
| --- | --- |
| `wg_ha_observation_timestamp_seconds` | Collection-start Unix epoch seconds; always present. |
| `wg_ha_role_observed` | Always present: 1 for a valid native role; 0 for missing/unreadable/malformed state. |
| `wg_ha_role{state="MASTER\|BACKUP\|FAULT\|STOP"}` | Four separate one-hot series only when role was observed. Missing is not BACKUP. |
| `wg_ha_armed` | Always present: 1 if the native `armed` marker exists, otherwise 0. Not a leader or connectivity assertion. |
| `wg_ha_upnp_lease_observed` | Always present: 1 only when configuration, own IPv4 and the router mapping table were valid; otherwise 0. |
| `wg_ha_upnp_lease_present` | Only with lease-observed=1: 1 for the configured UDP mapping, 0 for observed absence. |
| `wg_ha_upnp_lease_owned` | Only with lease-observed=1: 1 if the mapping targets this node's own IPv4 and configured internal port; otherwise 0. Ownership alone does not establish remaining validity. |
| `wg_ha_upnp_lease_remaining_seconds` | Only when a valid mapping exists: router-reported remaining duration at collection. Zero does not establish a valid finite HA lease, even if a router uses zero for permanent mappings. |
| `wg_ha_interface_observed` | Always present: 1 if `wg show interfaces` succeeded with a valid interface list; otherwise 0. |
| `wg_ha_interface_present` | Only with interface-observed=1: 1 if the configured interface appears, otherwise 0. An absent follower interface is expected, not a query failure. |
| `wg_ha_wg_observed` | Always present: 1 if the complete targeted handshake query succeeded and validated; otherwise 0. A known-absent interface skips that query and reports 0 without an error. |
| `wg_ha_peer_last_handshake_timestamp_seconds` | Per peer, only with wg-observed=1: the kernel timestamp, including zero for never-handshaken. An empty successful query emits no peer series. |
| `wg_ha_peer_never_handshaken` | Per observed peer: 1 for timestamp zero, otherwise 0. |
| `wg_ha_peer_handshake_age_seconds` | Per observed peer with nonzero timestamp: collection epoch minus handshake epoch. Absent for never-handshaken peers. |
| `wg_ha_peer_healthy` | Per observed peer: 1 for a nonzero handshake within the configured recent-handshake window, otherwise 0. **Zero means idle/unknown, not VPN failure.** This historical name represents recent handshake evidence only. |
| `wg_ha_collector_errors` | Always present: number of failed observation groups in this run, not a cumulative counter. Role, lease, interface enumeration and handshake query each contribute at most one. Every failed wg query counts, including on followers. |

The interface observation is independent of the handshake observation. If
enumeration fails, the collector still attempts the targeted handshake query;
if both fail, the error count increases by two. Never infer absence solely from
`wg_ha_wg_observed=0`. Malformed, duplicate or future-dated handshake rows reject
the entire peer set, with no partial peer metrics. Old handshakes and
never-handshaken peers are valid observations and do not increment errors.

UPnP inspection requires the native miniupnpc mapping-table header and valid UDP
rows. A wrong internal port, malformed UDP row (including a matching row),
duplicate configured mapping, invalid address or missing own address rejects the
lease observation entirely. A valid empty table is observed absence. Only
`upnpc -u URL -l` is used; there is no claim, refresh or deletion.

## Fleet Evaluation

`WG_HA_EXPECTED_NODES="node-a node-b node-c" bash scripts/wg-ha-health-collector.sh evaluate FILE...`
requires exactly one node observation file per expected identity. Inventory must
be nonempty and unique. Files must contain collector-format integer samples,
with `cluster="chrome"`, a single expected node identity, no duplicate samples
and the documented label sets. Missing, duplicate, mixed or unknown nodes fail
closed. Every node needs a complete, one-hot observed role and valid observed
lease facts, including followers. Comments and label ordering are supported.

The default maximum observation age is 120 seconds, inclusive. Future timestamps
are rejected, not clamped. A MASTER's remaining lease is reduced by the elapsed
observation age; remaining validity must be strictly positive. A stale cached
textfile cannot indefinitely preserve leadership health.

| Exit | Final stdout line | Meaning |
| --- | --- | --- |
| 3 | `verdict=degraded_observation` | Missing/stale/future/invalid observations or inventory; also a sole MASTER without a still-valid owned lease. |
| 5 | `verdict=multiple_leaders` | More than one actual MASTER in a complete valid fresh fleet, regardless of which one owns the lease. |
| 4 | `verdict=no_leader` | Complete valid fresh fleet with no MASTER. |
| 0 | `verdict=ok` | Exactly one MASTER with a still-valid owned lease. |

Invalid observations take precedence over a fleet conclusion. Once observations
are valid, count actual MASTER roles **before** checking the sole leader's lease:
two MASTERs with only one lease must return 5, not 3. Per-node status lines are
diagnostic; the final verdict and exit status are the machine interface.

Evaluation is a role/lease verdict, not a peer-connectivity check. It does not
require recent peer traffic, armed=1, or zero collector errors. A live probe must
separately check expected interface presence and successful handshake observation
on the active node; idle peers must not be interpreted as a broken VPN.

## Configuration And Safety

| Variable | Default / scope |
| --- | --- |
| `WG_HA_RUN_DIR` | `/run/wg-ha`; reads `vrrp-state`. |
| `WG_HA_STATE_DIR` | `/var/lib/wg-ha`; reads `armed` existence and optional `override.env`. |
| `WG_HA_ENV_FILE` | Unset standalone; NixOS supplies the agenix native env path. An explicitly configured unreadable file invalidates lease observation. |
| `WG_HA_UPNP_URL` | No default; required for lease observation. |
| `WG_HA_PORT` | `51820` when unset/empty; must be 1..65535. Both external and internal UDP ports must match. |
| `WG_HA_OWN_IP` | Otherwise discovered with `ip -4 -o route get 1.1.1.1` (route lookup, not a network probe). Must be a single valid IPv4 address. |
| `WG_HA_IF` | `wg0`; only this interface's handshakes are queried. |
| `WG_HA_NODE` | Hostname. |
| `WG_HA_CMD_TIMEOUT` | `5` seconds per subprocess; positive fractional values supported. |
| `WG_HA_HANDSHAKE_HEALTHY` | `180` seconds, inclusive recent-handshake window; zero timestamp never qualifies. |
| `WG_HA_EXPECTED_NODES` | Required space-separated inventory for `evaluate`; no inferred fleet size. |
| `WG_HA_MAX_AGE` | `120` seconds for `evaluate`. |
| `WG_HA_NOW` | Current Unix epoch; deterministic test override for either operation. |

For URL and port, precedence is inherited environment, then `WG_HA_ENV_FILE`,
then `WG_HA_STATE_DIR/override.env`, matching native override order. Only those
two assignments are interpreted. Supported native shell literal syntax includes
optional `export`, single/double quotes, concatenated quoted/unquoted segments,
backslash escapes, and trailing whitespace/comments. Expansions, substitutions,
multiline assignments and executable syntax in relevant settings are rejected;
unrelated lines are ignored, never executed. Use literal settings shared with the
native service. No env file is sourced, and no secret env or subprocess stderr is
logged. The WireGuard configuration/key file is never opened, and the systemd
sandbox makes it inaccessible.

Runtime dependencies are Bash, Python 3 (standard library only), wireguard-tools,
iproute2 and miniupnpc. Python is embedded in the shell entrypoint, so the exact
single store script referenced by `ExecStart` has no relative helper dependency.
The service's `path` supplies Python. It retains `CAP_NET_ADMIN` for read-only
netlink queries, a strict filesystem sandbox and only the metrics directory as
a write location.

## Standalone Regressions

The regressions execute the real collector with simulated commands, files and
clock. They never access hosts, deploy, read real keys or modify VPN state:

```sh
beehive submodule worktree exec nixconf bee-chrome-wireguard-health-exporter -- bash tests/wg-ha-health-regressions.sh
beehive submodule worktree exec nixconf bee-chrome-wireguard-health-exporter -- env COLLECTOR=/nix/store/<evaluated-collector> bash tests/wg-ha-health-regressions.sh
```

`COLLECTOR` defaults to the source entrypoint. The separate integration/live
suite owns NixOS fleet wiring and independent host observation checks.

## Alloy And Mimir

The consumer owns Alloy target discovery, network reachability and remote-write
credentials. Scrape the host node exporter on port 9101 every 30 seconds; retain
the exported `cluster`, `node`, `state` and `peer` labels without rewriting them.
Avoid colliding target-level `cluster`/`node` labels (or explicitly preserve the
exported labels); `job` and `instance` may identify the scrape transport but must
not replace stable node identity. Remote-write the `wg_ha_*` gauges to Mimir.
No credentials or remote-write endpoint belong in this collector.

Consumers must join samples with the node observation epoch, require
`0 <= time() - wg_ha_observation_timestamp_seconds <= 120`, and use an externally
configured complete node inventory. A successful scrape of an old textfile is
not fresh data. Never fill missing observation/role/lease series with zero.
Count fresh observed MASTER roles independently from lease ownership; secure
UPnP fencing can leave multiple MASTERs but only one holder. For the sole MASTER,
require lease-observed=1, lease-owned=1 and
`wg_ha_upnp_lease_remaining_seconds - (time() - wg_ha_observation_timestamp_seconds) > 0`.
Peer handshake recency is evidence of activity, not a liveness SLA for idle peers.

## Post-Merge Host Probe

The real entrypoint is `tests/chrome-wireguard-health-exporter.test.sh --live`.
Supply `WG_HA_EXPECTED_NODES` and `WG_HA_LIVE_HOSTS` as equal-length, unique,
space-separated lists in corresponding order. SSH targets may include a user.
The deployed `wg-ha-health-observe` helper is supplied by this module; it reads
role, effective env/overrides, routing source, the current router mapping list,
interface enumeration and targeted handshakes. It emits only a sanitized JSON
snapshot. It does not use the cached `upnp-holder` marker or key-bearing status.

The probe requires existing noninteractive read access via
`sudo -n /run/current-system/sw/bin/wg-ha-health-observe`. It grants no sudo rule,
performs no deployment and fails closed if access or any independent read fails.
SSH calls are bounded at 20 seconds (25 for the helper); each helper query is
bounded at 5 seconds. Direct HTTP bodies are captured per host, with an SSH-local
HTTP fallback. Both the textfile and scrape must match the independent snapshot,
including complete hashed peer identities, timestamps and health values.

Observation-race policy: role/ownership/interface changes fail for a later retry.
A new handshake is accepted only if it occurred between the exported observation
and independent snapshot. Router lease countdown allows 5 seconds of query
granularity and allows lease increases from native renewal; both exported elapsed
validity and independently observed validity must remain positive. No waits,
VPN restarts, mapping mutations, cutovers or Mimir-ingestion claims are made.
