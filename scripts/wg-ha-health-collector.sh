#!/usr/bin/env bash
# wg-ha health collector — read-only observer of the native wg-ha stack
# (profiles/wireguard-ha.nix). Emits a node_exporter textfile; see
# docs/wireguard-ha-health-metrics.md for the metric contract.
#
#   collect [OUT]          observe this node, write Prometheus text to OUT (atomic) or stdout
#   evaluate FILE...       fleet verdict over per-node outputs (one per node)
#
# Never reads/exports private keys: wg is queried only with the targeted
# `wg show <if> latest-handshakes` (public keys + timestamps); the peer label is
# a sha256 prefix of the PUBLIC key. Nothing here changes VPN/VRRP/UPnP state:
# upnpc is only invoked with -l (list).
#
# Inputs (env, all optional; defaults are the production paths):
#   WG_HA_RUN_DIR (/run/wg-ha)  WG_HA_STATE_DIR (/var/lib/wg-ha)  WG_HA_IF (wg0)
#   WG_HA_ENV_FILE  secret env providing WG_HA_UPNP_URL / WG_HA_PORT (sourced, never printed)
#   WG_HA_OWN_IP    override own LAN address (default: ip route get src)
#   WG_HA_NODE      node label (default: hostname)
#   WG_HA_CMD_TIMEOUT (5)  per-command timeout seconds
#   WG_HA_HANDSHAKE_HEALTHY (180)  handshake age considered healthy
#   WG_HA_NOW       override epoch (tests)
#   WG_HA_MAX_AGE (180)  evaluate: max observation age before "stale"
set -uo pipefail

CLUSTER=chrome
now() { echo "${WG_HA_NOW:-$(date +%s)}"; }
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

collect() {
  local run=${WG_HA_RUN_DIR:-/run/wg-ha} statedir=${WG_HA_STATE_DIR:-/var/lib/wg-ha}
  local ifc=${WG_HA_IF:-wg0} to=${WG_HA_CMD_TIMEOUT:-5} healthy=${WG_HA_HANDSHAKE_HEALTHY:-180}
  local node; node=$(esc "${WG_HA_NODE:-$(hostname)}")
  local t; t=$(now)
  local L="cluster=\"$CLUSTER\",node=\"$node\""
  local errors=0

  echo "# HELP wg_ha_observation_timestamp_seconds Epoch when this node's observation was taken."
  echo "# TYPE wg_ha_observation_timestamp_seconds gauge"
  echo "wg_ha_observation_timestamp_seconds{$L} $t"

  # --- role (keepalived notify writes vrrp-state) ---
  local state="" role_ok=0
  if [ -r "$run/vrrp-state" ]; then
    state=$(head -c 64 "$run/vrrp-state" | tr -d '[:space:]')
    case "$state" in MASTER|BACKUP|FAULT|STOP) role_ok=1 ;; esac
  fi
  echo "# HELP wg_ha_role_observed 1 if the VRRP role was read and valid; 0 = missing/malformed (role metrics absent)."
  echo "# TYPE wg_ha_role_observed gauge"
  echo "wg_ha_role_observed{$L} $role_ok"
  if [ $role_ok = 1 ]; then
    echo "# TYPE wg_ha_role gauge"
    for s in MASTER BACKUP FAULT STOP; do
      echo "wg_ha_role{$L,state=\"$s\"} $([ "$s" = "$state" ] && echo 1 || echo 0)"
    done
  else
    errors=$((errors+1))
  fi
  echo "# TYPE wg_ha_armed gauge"
  echo "wg_ha_armed{$L} $([ -e "$statedir/armed" ] && echo 1 || echo 0)"

  # --- UPnP lease (list only) ---
  local url="" port=51820 own="" lease_ok=0 owned=0 remaining="" holder=""
  if [ -n "${WG_HA_ENV_FILE:-}" ] && [ -r "$WG_HA_ENV_FILE" ]; then
    url=$( set +u; . "$WG_HA_ENV_FILE" >/dev/null 2>&1; printf '%s' "${WG_HA_UPNP_URL:-}")
    port=$( set +u; . "$WG_HA_ENV_FILE" >/dev/null 2>&1; printf '%s' "${WG_HA_PORT:-51820}")
  fi
  own=${WG_HA_OWN_IP:-$(timeout "$to" ip -4 -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')}
  if [ -n "$url" ] && [[ "$port" =~ ^[0-9]+$ ]]; then
    local out rc
    out=$(timeout "$to" upnpc -u "$url" -l 2>/dev/null); rc=$?
    if [ $rc = 0 ] && printf '%s\n' "$out" | grep -qiE 'external ?ip|^ *i protocol|->'; then
      lease_ok=1
      # e.g. " 0 UDP 51820->192.0.2.10:51820  'wg-ha' '' 97"
      local line
      line=$(printf '%s\n' "$out" | grep -E "^ *[0-9]+ +UDP +$port->[0-9.]+:[0-9]+ " | head -1)
      if [ -n "$line" ]; then
        holder=$(printf '%s' "$line" | sed -E "s/.*$port->([0-9.]+):.*/\1/")
        remaining=$(printf '%s' "$line" | awk '{print $NF}')
        [[ "$remaining" =~ ^[0-9]+$ ]] || { remaining=""; lease_ok=0; }
        [ -n "$own" ] && [ "$holder" = "$own" ] && owned=1
      fi
    fi
  fi
  echo "# HELP wg_ha_upnp_lease_observed 1 if the router mapping list was read; 0 = missing/timeout/malformed."
  echo "# TYPE wg_ha_upnp_lease_observed gauge"
  echo "wg_ha_upnp_lease_observed{$L} $lease_ok"
  if [ $lease_ok = 1 ]; then
    echo "# HELP wg_ha_upnp_lease_present 1 if a UDP mapping for the WireGuard port exists (any holder)."
    echo "# TYPE wg_ha_upnp_lease_present gauge"
    echo "wg_ha_upnp_lease_present{$L} $([ -n "$holder" ] && echo 1 || echo 0)"
    echo "# HELP wg_ha_upnp_lease_owned 1 if the mapping points at THIS node's real address."
    echo "# TYPE wg_ha_upnp_lease_owned gauge"
    echo "wg_ha_upnp_lease_owned{$L} $owned"
    if [ -n "$holder" ]; then
      echo "# TYPE wg_ha_upnp_lease_remaining_seconds gauge"
      echo "wg_ha_upnp_lease_remaining_seconds{$L} $remaining"
    fi
  else
    errors=$((errors+1))
  fi

  # --- handshakes (targeted query; public keys only) ---
  local hs_ok=0 hs
  hs=$(timeout "$to" wg show "$ifc" latest-handshakes 2>/dev/null); local rc=$?
  if [ $rc = 0 ]; then
    hs_ok=1
    local bad=0
    while IFS=$'\t' read -r pk ts; do
      [ -z "$pk" ] && continue
      [[ "$pk" =~ ^[A-Za-z0-9+/]{43}=$ ]] && [[ "$ts" =~ ^[0-9]+$ ]] || { bad=1; continue; }
      local id; id=$(printf '%s' "$pk" | sha256sum | cut -c1-12)
      echo "wg_ha_peer_last_handshake_timestamp_seconds{$L,peer=\"$id\"} $ts"
      if [ "$ts" = 0 ]; then
        echo "wg_ha_peer_never_handshaken{$L,peer=\"$id\"} 1"
        echo "wg_ha_peer_healthy{$L,peer=\"$id\"} 0"
      else
        local age=$(( t - ts ))
        echo "wg_ha_peer_never_handshaken{$L,peer=\"$id\"} 0"
        echo "wg_ha_peer_handshake_age_seconds{$L,peer=\"$id\"} $age"
        echo "wg_ha_peer_healthy{$L,peer=\"$id\"} $([ $age -le "$healthy" ] && echo 1 || echo 0)"
      fi
    done <<<"$hs"
    [ $bad = 1 ] && { hs_ok=0; errors=$((errors+1)); }
  fi
  echo "# HELP wg_ha_wg_observed 1 if wg handshakes were read (0 = interface down on non-leader, timeout or malformed)."
  echo "# TYPE wg_ha_wg_observed gauge"
  echo "wg_ha_wg_observed{$L} $hs_ok"

  echo "# HELP wg_ha_collector_errors Number of failed/malformed observations in this run."
  echo "# TYPE wg_ha_collector_errors gauge"
  echo "wg_ha_collector_errors{$L} $errors"
}

# value <file> <metric-prefix-regex>: first sample value matching
val() { grep -E "^$2[{ ]" "$1" | head -1 | awk '{print $NF}'; }

evaluate() {
  local maxage=${WG_HA_MAX_AGE:-180} t leaders=0 stale=0 missing=0
  t=$(now)
  for f in "$@"; do
    if [ ! -s "$f" ]; then missing=$((missing+1)); echo "node_file=$f status=missing"; continue; fi
    local ts role owned rem
    ts=$(val "$f" wg_ha_observation_timestamp_seconds)
    if ! [[ "$ts" =~ ^[0-9]+$ ]] || [ $((t - ts)) -gt "$maxage" ]; then
      stale=$((stale+1)); echo "node_file=$f status=stale"; continue
    fi
    role=$(grep -E '^wg_ha_role\{.*state="MASTER"' "$f" | awk '{print $NF}')
    owned=$(val "$f" wg_ha_upnp_lease_owned); rem=$(val "$f" wg_ha_upnp_lease_remaining_seconds)
    if [ "$role" = 1 ] && [ "$owned" = 1 ] && [[ "$rem" =~ ^[0-9]+$ ]] && [ "$rem" -gt 0 ]; then
      leaders=$((leaders+1)); echo "node_file=$f status=leader"
    elif [ "$role" = 1 ]; then
      leaders=$((leaders+1)); echo "node_file=$f status=leader_without_lease"; stale=$((stale+1))
    else
      echo "node_file=$f status=follower"
    fi
  done
  if [ $missing -gt 0 ] || [ $stale -gt 0 ]; then echo "verdict=degraded_observation"; return 3
  elif [ $leaders = 0 ]; then echo "verdict=no_leader"; return 4
  elif [ $leaders -gt 1 ]; then echo "verdict=multiple_leaders"; return 5
  fi
  echo "verdict=ok"
}

case "${1:-}" in
  collect)
    shift
    if [ -n "${1:-}" ]; then
      tmp="$1.tmp.$$"; collect >"$tmp" && mv -f "$tmp" "$1"
    else collect; fi ;;
  evaluate) shift; evaluate "$@" ;;
  *) echo "usage: $0 collect [OUT] | evaluate FILE..." >&2; exit 2 ;;
esac
