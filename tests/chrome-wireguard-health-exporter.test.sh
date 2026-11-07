#!/usr/bin/env bash
# Integration test for the wg-ha health collector (profiles/wireguard-ha.nix +
# scripts/wg-ha-health-collector.sh).
#
#   tests/chrome-wireguard-health-exporter.test.sh         offline: evaluate the
#       NixOS wiring for chrome1..3, then run the EXACT collector the unit's
#       ExecStart names against simulated wg/upnpc/ip/vrrp inputs and assert
#       the emitted metrics + fleet verdicts.
#   tests/chrome-wireguard-health-exporter.test.sh --live  read-only host probe:
#       WG_HA_LIVE_HOSTS="<ssh-target> ..." (one per chrome node; no hostnames
#       are baked into this public repo). Compares each node's deployed textfile
#       with its observed role / lease holder / handshake set and evaluates the
#       fleet. Does NOT claim Mimir ingestion and changes nothing.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAILS=0
pass() { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; FAILS=$((FAILS+1)); }
has() { grep -qF -- "$2" "$1" && pass "$3" || { fail "$3 (missing: $2)"; sed 's/^/     | /' "$1"; }; }
hasnt() { grep -qF -- "$2" "$1" && { fail "$3 (unexpected: $2)"; sed 's/^/     | /' "$1"; } || pass "$3"; }

if [ "${1:-}" = --live ]; then
  exec python3 "$ROOT/scripts/wg-ha-health-live.py" live
fi

python3 "$ROOT/tests/chrome-wireguard-health-live.test.py" \
  && pass "simulated --live regressions" || fail "simulated --live regressions"

# ---------- NixOS wiring (evaluated, not grepped) ----------
COLLECTOR=""
for n in chrome1 chrome2 chrome3; do
  j=$(nix eval --json "path:$ROOT#nixosConfigurations.$n.config" --apply 'c: {
      exec = c.systemd.services.wg-ha-health.serviceConfig.ExecStart;
      type = c.systemd.services.wg-ha-health.serviceConfig.Type;
      prot = c.systemd.services.wg-ha-health.serviceConfig.ProtectSystem;
      rw = c.systemd.services.wg-ha-health.serviceConfig.ReadWritePaths;
      node = c.systemd.services.wg-ha-health.environment.WG_HA_NODE;
      validator = c.systemd.services.wg-ha-health.environment.WG_HA_VALIDATOR;
      timer = c.systemd.timers.wg-ha-health.wantedBy;
      every = c.systemd.timers.wg-ha-health.timerConfig.OnUnitActiveSec;
      ne = c.services.prometheus.exporters.node.enable;
      port = c.services.prometheus.exporters.node.port;
      caps = c.systemd.services.wg-ha-health.serviceConfig.CapabilityBoundingSet;
      hidden = c.systemd.services.wg-ha-health.serviceConfig.InaccessiblePaths;
      helper = builtins.any (p: p.name == "wg-ha-health-observe") c.environment.systemPackages;
      flags = c.services.prometheus.exporters.node.extraFlags; }' 2>/dev/null) \
    || { fail "$n: nix eval of wg-ha-health wiring"; continue; }
  echo "$j" | jq -e --arg n "$n" '.type=="oneshot" and .prot=="strict" and .rw==["/var/lib/wg-ha-metrics"]
      and .node==$n and (.timer|index("timers.target")) != null and .every=="30s"
      and .ne and .port==9101 and (.flags|index("--collector.textfile.directory=/var/lib/wg-ha-metrics")) != null
      and .caps==["CAP_NET_ADMIN"] and (.hidden|length)==1 and .helper
      and (.validator|startswith("/nix/store/"))
      and (.exec|test(" collect /var/lib/wg-ha-metrics/wg_ha.prom$"))' >/dev/null \
    && pass "$n: service/timer/textfile/node_exporter wiring" || fail "$n: wiring $j"
  COLLECTOR=$(echo "$j" | jq -r '.exec' | awk '{print $2}')
  export WG_HA_VALIDATOR=$(echo "$j" | jq -r '.validator')
done
[ -r "${WG_HA_VALIDATOR:-}" ] || fail "validator store path from service environment"
[ -x "$COLLECTOR" ] || [ -r "$COLLECTOR" ] || { fail "collector store path from ExecStart"; COLLECTOR="$ROOT/scripts/wg-ha-health-collector.sh"; }
echo "# collector under test: $COLLECTOR"

# ---------- simulated host ----------
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/wg" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SIM/wg.calls"
[ "$*" = "show interfaces" ] && { [ "$SIM_WG" = down ] || echo wg0; exit 0; }
[ "$*" = "show wg0 latest-handshakes" ] || { echo "unexpected wg args: $*" >&2; exit 9; }
case "$SIM_WG" in
  sleep) sleep 30 ;; down) echo "Unable to access interface: No such device" >&2; exit 1 ;;
  *) cat "$SIM/hs" ;;
esac
EOF
cat >"$T/bin/upnpc" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SIM/upnpc.calls"
case "$*" in *" -l") ;; *) echo "mutating upnpc call: $*" >&2; exit 9 ;; esac
case "$SIM_UPNP" in sleep) sleep 30 ;; fail) exit 1 ;; *) cat "$SIM/upnp" ;; esac
EOF
printf '#!/bin/sh\necho "1.1.1.1 via 192.0.2.1 dev enp1s0 src $SIM_IP uid 0"\n' >"$T/bin/ip"
chmod +x "$T/bin/"*
K1=$(printf 'A%.0s' {1..43})=; K2=$(printf 'B%.0s' {1..43})=; K3=$(printf 'C%.0s' {1..43})=
NOW=1800000000

# run <case> [env...]: sets up $T/<case>/ and collects to $T/<case>.prom
run() {
  local c=$1; shift
  export SIM="$T/$c"; mkdir -p "$SIM/run" "$SIM/state"
  printf 'WG_HA_UPNP_URL=http://192.0.2.1:5000/rootDesc.xml\nWG_HA_PORT=51820\nWG_HA_SUBNET=198.51.100.0/24\n' >"$SIM/env"
  [ -f "$SIM/hs" ] || printf '%s\t%s\n%s\t%s\n' "$K1" $((NOW-30)) "$K2" $((NOW-60)) >"$SIM/hs"
  [ -f "$SIM/upnp" ] || cat >"$SIM/upnp" <<EOF
 i protocol exPort->inAddr:inPort description remoteHost leaseTime
 0 UDP 51820->192.0.2.10:51820 'wg-ha' '' 97
EOF
  env PATH="$T/bin:$PATH" SIM_IP=192.0.2.10 SIM_WG= SIM_UPNP= WG_HA_NOW=$NOW WG_HA_NODE=$c \
      WG_HA_RUN_DIR="$SIM/run" WG_HA_STATE_DIR="$SIM/state" WG_HA_ENV_FILE="$SIM/env" WG_HA_CMD_TIMEOUT=1 "$@" \
      bash "$COLLECTOR" collect "$T/$c.prom"
}
prep() { mkdir -p "$T/$1/run"; }

# healthy leader
prep healthy; echo MASTER >"$T/healthy/run/vrrp-state"; run healthy
P=$T/healthy.prom
has $P 'wg_ha_role{cluster="chrome",node="healthy",state="MASTER"} 1' "healthy: role MASTER"
has $P 'wg_ha_upnp_lease_owned{cluster="chrome",node="healthy"} 1' "healthy: owns lease"
has $P 'wg_ha_upnp_lease_remaining_seconds{cluster="chrome",node="healthy"} 97' "healthy: remaining validity"
has $P "wg_ha_observation_timestamp_seconds{cluster=\"chrome\",node=\"healthy\"} $NOW" "healthy: observation timestamp"
ID1=$(printf '%s' "$K1" | sha256sum | cut -c1-12)
has $P "wg_ha_peer_last_handshake_timestamp_seconds{cluster=\"chrome\",node=\"healthy\",peer=\"$ID1\"} $((NOW-30))" "healthy: per-peer handshake ts, hashed id"
has $P "wg_ha_peer_healthy{cluster=\"chrome\",node=\"healthy\",peer=\"$ID1\"} 1" "healthy: peer healthy"
has $P 'wg_ha_collector_errors{cluster="chrome",node="healthy"} 0' "healthy: no errors"
hasnt $P "$K1" "healthy: raw public key not exported"
grep -vEx 'show interfaces|show wg0 latest-handshakes' "$T/healthy/wg.calls" && fail "only targeted wg query" || pass "only targeted wg query (no dump/showconf)"

# follower: lease held by another node, wg0 down
prep follower; echo BACKUP >"$T/follower/run/vrrp-state"; run follower SIM_IP=192.0.2.11 SIM_WG=down
P=$T/follower.prom
has $P 'wg_ha_role{cluster="chrome",node="follower",state="MASTER"} 0' "follower: not MASTER"
has $P 'wg_ha_upnp_lease_owned{cluster="chrome",node="follower"} 0' "follower: lease not owned"
has $P 'wg_ha_wg_observed{cluster="chrome",node="follower"} 0' "follower: wg down -> unobserved, not zero handshakes"
hasnt $P 'wg_ha_peer_' "follower: no fabricated peer series"

# idle / never-handshaken + stale peer
prep idle; echo MASTER >"$T/idle/run/vrrp-state"; printf '%s\t0\n%s\t%s\n' "$K2" "$K3" $((NOW-900)) >"$T/idle/hs"; run idle
P=$T/idle.prom; ID2=$(printf '%s' "$K2" | sha256sum | cut -c1-12); ID3=$(printf '%s' "$K3" | sha256sum | cut -c1-12)
has $P "wg_ha_peer_never_handshaken{cluster=\"chrome\",node=\"idle\",peer=\"$ID2\"} 1" "idle: never-handshaken flagged"
hasnt $P "wg_ha_peer_handshake_age_seconds{cluster=\"chrome\",node=\"idle\",peer=\"$ID2\"}" "idle: no bogus age for never-handshaken"
has $P "wg_ha_peer_handshake_age_seconds{cluster=\"chrome\",node=\"idle\",peer=\"$ID3\"} 900" "idle: stale peer age"
has $P "wg_ha_peer_healthy{cluster=\"chrome\",node=\"idle\",peer=\"$ID3\"} 0" "idle: stale peer unhealthy"

# missing inputs
prep missing; rm -f "$T/missing/env"; run missing WG_HA_ENV_FILE=/nonexistent
P=$T/missing.prom
has $P 'wg_ha_role_observed{cluster="chrome",node="missing"} 0' "missing: role unobserved"
hasnt $P 'wg_ha_role{' "missing: no role series (missing != zero)"
has $P 'wg_ha_upnp_lease_observed{cluster="chrome",node="missing"} 0' "missing: lease unobserved"
hasnt $P 'wg_ha_upnp_lease_owned' "missing: no lease_owned series"

# malformed
prep malformed; echo 'garbage!!' >"$T/malformed/run/vrrp-state"; printf 'not-a-key\txyz\n' >"$T/malformed/hs"
echo 'Connected to garbage' >"$T/malformed/upnp"; run malformed
P=$T/malformed.prom
has $P 'wg_ha_role_observed{cluster="chrome",node="malformed"} 0' "malformed: bad role rejected"
has $P 'wg_ha_upnp_lease_observed{cluster="chrome",node="malformed"} 0' "malformed: bad upnp list rejected"
has $P 'wg_ha_wg_observed{cluster="chrome",node="malformed"} 0' "malformed: bad handshake rows rejected"
has $P 'wg_ha_collector_errors{cluster="chrome",node="malformed"} 3' "malformed: 3 errors"

# command timeouts (bounded)
prep tmo; echo MASTER >"$T/tmo/run/vrrp-state"
s=$(date +%s); run tmo SIM_WG=sleep SIM_UPNP=sleep; d=$(( $(date +%s) - s ))
[ $d -le 6 ] && pass "timeout: collector bounded (${d}s)" || fail "timeout: took ${d}s"
has $T/tmo.prom 'wg_ha_wg_observed{cluster="chrome",node="tmo"} 0' "timeout: wg unobserved"
has $T/tmo.prom 'wg_ha_upnp_lease_observed{cluster="chrome",node="tmo"} 0' "timeout: lease unobserved"

# expired lease: mapping present but owned by nobody alive (MASTER without lease)
prep expired; echo MASTER >"$T/expired/run/vrrp-state"
printf ' i protocol exPort->inAddr:inPort description remoteHost leaseTime\n' >"$T/expired/upnp"; run expired
has $T/expired.prom 'wg_ha_upnp_lease_present{cluster="chrome",node="expired"} 0' "expired: no mapping present"

# no secrets anywhere
cat "$T"/*.prom | grep -qiE 'privatekey|private_key|WG_HA_UPNP_URL|rootDesc' && fail "secret/env leaked" || pass "no key/env material in any output"
grep -h . "$T"/*/upnpc.calls | grep -v ' -l$' && fail "mutating upnpc" || pass "upnpc used read-only (-l)"

# ---------- fleet verdicts ----------
ev() {
  local nodes="" f
  for f in "$@"; do nodes+="$(basename "$f" .prom) "; done
  WG_HA_EXPECTED_NODES="$nodes" WG_HA_NOW=$NOW bash "$COLLECTOR" evaluate "$@" >"$T/ev" 2>&1; echo $?
}
[ "$(ev $T/healthy.prom $T/follower.prom)" = 0 ] && grep -q verdict=ok "$T/ev" && pass "fleet: one leader ok" || { fail "fleet ok"; cat "$T/ev"; }
[ "$(ev $T/follower.prom $T/missing.prom)" != 0 ] && pass "fleet: no-leader/missing rejected" || fail "fleet no-leader"
prep follower2; echo BACKUP >"$T/follower2/run/vrrp-state"; run follower2 SIM_IP=192.0.2.12 SIM_WG=down
[ "$(ev $T/follower.prom $T/follower2.prom)" = 4 ] && grep -q verdict=no_leader "$T/ev" && pass "fleet: no_leader" || fail "fleet no_leader"
prep healthy2; echo MASTER >"$T/healthy2/run/vrrp-state"; run healthy2 SIM_IP=192.0.2.11
[ "$(ev $T/healthy.prom $T/healthy2.prom)" = 5 ] && grep -q verdict=multiple_leaders "$T/ev" && pass "fleet: split leader detected" || { fail "split leader"; cat "$T/ev"; }
[ "$(WG_HA_EXPECTED_NODES='healthy follower' WG_HA_NOW=$((NOW+1000)) bash "$COLLECTOR" evaluate $T/healthy.prom $T/follower.prom >/dev/null; echo $?)" = 3 ] && pass "fleet: stale observations degraded" || fail "fleet stale"
[ "$(ev $T/healthy.prom $T/nonexistent.prom)" = 3 ] && pass "fleet: missing node file degraded" || fail "fleet missing file"
[ "$(ev $T/expired.prom $T/follower.prom)" = 3 ] && grep -q leader_without_lease "$T/ev" && pass "fleet: leader with expired lease rejected" || { fail "fleet expired"; cat "$T/ev"; }

# Review reproductions: a healthy leader must never mask unknown followers.
for c in missing malformed tmo; do
  [ "$(ev "$T/healthy.prom" "$T/$c.prom")" = 3 ] && pass "fleet: healthy plus $c rejected" || fail "fleet: healthy masks $c"
done
for delta in -1 97 100 121; do
  [ "$(WG_HA_EXPECTED_NODES='healthy follower' WG_HA_NOW=$((NOW+delta)) bash "$COLLECTOR" evaluate "$T/healthy.prom" "$T/follower.prom" >/dev/null; echo $?)" = 3 ] \
    && pass "fleet: future/elapsed lease at delta=$delta rejected" || fail "fleet: time delta=$delta"
done
[ "$(WG_HA_EXPECTED_NODES='healthy follower' WG_HA_NOW=$NOW bash "$COLLECTOR" evaluate "$T/healthy.prom" "$T/healthy.prom" >/dev/null; echo $?)" = 3 ] \
  && pass "fleet: duplicate identity rejected" || fail "fleet: duplicate identity"
[ "$(WG_HA_EXPECTED_NODES='healthy follower absent' WG_HA_NOW=$NOW bash "$COLLECTOR" evaluate "$T/healthy.prom" "$T/follower.prom" >/dev/null; echo $?)" = 3 ] \
  && pass "fleet: omitted expected node rejected" || fail "fleet: omitted node"
prep wrongport; echo MASTER >"$T/wrongport/run/vrrp-state"
printf " i protocol exPort->inAddr:inPort description remoteHost leaseTime\n 0 UDP 51820->192.0.2.10:9999 'wg-ha' '' 97\n" >"$T/wrongport/upnp"
run wrongport
has "$T/wrongport.prom" 'wg_ha_upnp_lease_observed{cluster="chrome",node="wrongport"} 0' "wrong internal port rejected"
prep override; mkdir -p "$T/override/state"; echo MASTER >"$T/override/run/vrrp-state"
printf 'WG_HA_PORT=51821\nWG_HA_UPNP_URL=http://192.0.2.2/rootDesc.xml\n' >"$T/override/state/override.env"
printf " i protocol exPort->inAddr:inPort description remoteHost leaseTime\n 0 UDP 51821->192.0.2.10:51821 'wg-ha' '' 97\n" >"$T/override/upnp"
run override
has "$T/override.prom" 'wg_ha_config_port{cluster="chrome",node="override"} 51821' "override effective port exported"
has "$T/override.prom" 'wg_ha_config_override_present{cluster="chrome",node="override"} 1' "override presence exported"
has "$T/override.prom" 'wg_ha_upnp_lease_owned{cluster="chrome",node="override"} 1' "override mapping observed"
has "$T/override/upnpc.calls" '-u http://192.0.2.2/rootDesc.xml -l' "override URL queried"
has "$T/tmo.prom" 'wg_ha_collector_errors{cluster="chrome",node="tmo"} 2' "wg timeout counted as error"
has "$T/follower.prom" 'wg_ha_collector_errors{cluster="chrome",node="follower"} 0' "confirmed absent follower interface not an error"

echo "failures: $FAILS"
[ $FAILS = 0 ]
