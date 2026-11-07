# Native WireGuard HA Health Metrics

This observes the existing keepalived election without a VIP and the secure UPnP
UDP lease to the elected node's real IP. It does not configure WireGuard, change
MASQUERADE, renew leases, or restart services. Do not use the historical routed
VPN topology to interpret these metrics.

## Transport And Identity

`wg-ha-health.service` writes `/var/lib/wg-ha-metrics/wg_ha.prom` atomically every
30 seconds. Node exporter serves its textfile collector on port 9101. This module
does not open that port in the firewall. Alloy must scrape a reachable host-side
endpoint and remote-write to Mimir; that configuration belongs to the consumer.
Neither the collector tests nor `--live` verify Alloy/Mimir ingestion.

All samples are gauges with `cluster="chrome",node="<NixOS hostname>"`. Preserve
these labels through Alloy relabeling and Mimir remote-write. `instance` and `job`
may be added but are not node identity. Peer samples add
`peer="<first 12 lowercase hex digits of SHA256(public-key bytes)>"`, hashing the
base64 public key string without a newline. A peer retains that identity across
failover nodes; it changes when its public key changes. Raw keys are never emitted.
Role samples add only `state="MASTER|BACKUP|FAULT|STOP"`.

## Contract

| Metric (prefix `wg_ha_`) | Meaning |
| --- | --- |
| `observation_timestamp_seconds` | Start of collection, Unix seconds; conservative timestamp for the bounded subsequent reads. |
| `role_observed` | 1 for a recognized native notify state; 0 for missing/malformed state. |
| `role{state=...}` | Four one-hot samples, emitted only when role was observed. |
| `armed` | 1 when the native armed marker exists. |
| `config_override_present` | 1 when native `override.env` exists. |
| `config_port` | Effective listener/UPnP port, omitted when invalid. Native env is loaded first, then `override.env`. No URL, subnet or env contents are exported. |
| `upnp_lease_observed` | 1 for a successful, recognized router mapping table and local source IP; 0 on missing config, malformed mapping, wrong internal port, failure or timeout. |
| `upnp_lease_present` | 1 for a mapping on the effective UDP port, any holder; absent if not observed. |
| `upnp_lease_owned` | 1 only when that mapping targets this node's real IP AND the effective internal port; absent if not observed. |
| `upnp_lease_remaining_seconds` | Router-reported remaining duration; emitted only for an observed present mapping. Zero is expired/unsupported permanent lease, never healthy. |
| `interface_present` | 0/1 from successful `wg show interfaces`; absent if that query fails. |
| `wg_observed` | 1 only after successful targeted handshake query and valid rows. 0 when wg0 is absent, or the query failed/timed out/was malformed. |
| `peer_last_handshake_timestamp_seconds` | Per-peer Unix handshake time; 0 means the observed peer has never handshaken. |
| `peer_never_handshaken` | 1 exactly when the observed timestamp is 0. |
| `peer_handshake_age_seconds` | Collection timestamp minus last handshake; omitted for never-handshaken peers. |
| `peer_healthy` | 1 for a nonzero handshake within 180 seconds at collection. This is recency, NOT a traffic or reachability test. |
| `collector_errors` | Number of failed observation groups in this collection, including failed/timed-out wg queries. Not a counter. Confirmed absent wg0 on a follower is not an error. |

Never convert absent series into zero. `wg_observed=0` invalidates all peer
samples, including partial output from malformed responses. An old handshake may
mean an idle client, not VPN failure. Never-handshaken is explicitly distinguished
from an old handshake; neither proves client demand or an outage. A follower's
absent interface has no peer series and must not be interpreted as zero peers.

## Fleet Acceptance

Maintain an independent expected node inventory. Missing nodes, duplicate node
identities and mixed-node files are invalid, not implicit followers. Each node
must have an observation age in `[0,120]` seconds, role/lease observed flags of 1,
a valid one-hot role vector and no collection errors. Future timestamps fail.
Compute lease validity at query time, NOT from the stored duration alone:

```text
observation_timestamp_seconds + upnp_lease_remaining_seconds > current_time
```

The 120-second limit applies even if Prometheus/Mimir still returns an older
sample within its lookback window. Freshness must be checked on the payload's
observation timestamp, not the scrape time. Peer recency must likewise advance
with current time, not remain frozen at the exported `peer_healthy` value.

Count elected MASTER roles independently from lease ownership. Two MASTER nodes
are split leadership even when secure UPnP permits only one to own the lease.
Exactly one fresh MASTER must own a still-valid lease and have wg0 observed/up;
no follower may own a valid lease. Zero MASTER nodes is `no_leader`; multiple
positively observed MASTER nodes is `multiple_leaders`. Missing/stale/invalid
observations otherwise produce `degraded_observation`, never `ok`.

`collect` writes metrics even for failed observations (flags and errors expose
them). `evaluate` exits 0 for ok, 3 for degraded/invalid input, 4 for no leader,
and 5 for multiple leaders. Set `WG_HA_EXPECTED_NODES` explicitly; it must not be
inferred from the received metric files. Default maximum observation age is 120s.

## Read-Only Live Gate

Run the delivered `tests/chrome-wireguard-health-exporter.test.sh --live` after
merge and an approved deployment. Supply space-separated `WG_HA_EXPECTED_NODES`
and positionally corresponding `WG_HA_LIVE_HOSTS` SSH targets. Inventory is runtime
configuration, not embedded deployment identifiers. In a beehive checkout use:

```sh
beehive submodule worktree exec nixconf bee-chrome-wireguard-health-exporter -- env WG_HA_EXPECTED_NODES="$WG_HA_EXPECTED_NODES" WG_HA_LIVE_HOSTS="$WG_HA_LIVE_HOSTS" tests/chrome-wireguard-health-exporter.test.sh --live
```

Each target must allow read-only textfile/timer access and noninteractive execution
of installed `wg-ha-health-observe` via `sudo -n`. This module does NOT grant sudo
rights or assume permission to deploy. Establish operator rollout authorization
and actual access before deployment; access failure makes verification fail
closed. No rollout/restart is performed by either probe entrypoint.

The installed helper independently reads the native role/armed state, effective
router config, actual `upnpc -l` mapping and targeted wg interface/handshake
queries. It does not trust the daemon's cached `upnp-holder` file. The live gate
compares each node's textfile AND actual scrape body with those independent
observations, including hashed peer identities, timestamps and recency flags.
Direct curl and SSH-localhost fallback both validate their own response bodies.
Missing reads, stale bodies, wrong node identities and expired leases fail closed.

Reads have bounded command deadlines (5s local commands, 45s SSH; at most 32
hosts). Handshake comparison has zero tolerance: a handshake that changes
between snapshots requires a retry after the next collection, not an assumed
match. Router renewals may change remaining duration; both the elapsed exported
lease and independently observed router lease must still be valid and owned by
the elected real node. The gate does not assert an exact matching expiry across
a renewal, or promise an atomic cluster snapshot.

The systemd collector is read-only except its textfile directory, bounded to 45s,
has only CAP_NET_ADMIN (required by the targeted wg netlink read), and cannot
access the private WireGuard configuration path. Neither helper uses `wg dump`,
`showconf`, generic key-bearing `wg show`, or the native cached status command.
The native router env is trusted shell configuration, loaded with suppressed
output and a timeout; the WireGuard private-key file is never read.
