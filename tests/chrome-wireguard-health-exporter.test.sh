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
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAILS=0
pass() { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; FAILS=$((FAILS+1)); }
has() { grep -qF -- "$2" "$1" && pass "$3" || { fail "$3 (missing: $2)"; sed 's/^/     | /' "$1"; }; }
hasnt() { grep -qF -- "$2" "$1" && { fail "$3 (unexpected: $2)"; sed 's/^/     | /' "$1"; } || pass "$3"; }

if [ "${1:-}" = --live ]; then
  : "${WG_HA_LIVE_HOSTS:?set WG_HA_LIVE_HOSTS to the ssh targets of every chrome node}"
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  ssh_() { timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=5 "$@"; }
  files=()
  for h in $WG_HA_LIVE_HOSTS; do
    f="$T/$(echo "$h" | tr -c 'A-Za-z0-9.\n' _).prom"; files+=("$f")
    ssh_ "$h" cat /var/lib/wg-ha-metrics/wg_ha.prom >"$f" || { fail "$h: textfile unreadable"; continue; }
    ssh_ "$h" systemctl is-active wg-ha-health.timer >/dev/null && pass "$h: timer active" || fail "$h: timer inactive"
    curl -sf --max-time 5 "http://$h:9101/metrics" >/dev/null 2>&1 || \
      ssh_ "$h" curl -sf --max-time 5 http://127.0.0.1:9101/metrics >"$T/scrape" && grep -q '^wg_ha_observation_timestamp_seconds' "$T/scrape" \
      && pass "$h: node_exporter serves wg_ha_* on :9101" || fail "$h: node_exporter :9101 lacks wg_ha_*"
    state=$(ssh_ "$h" cat /run/wg-ha/vrrp-state 2>/dev/null | tr -d '[:space:]')
    [ -n "$state" ] && has "$f" "state=\"$state\"} 1" "$h: exported role matches host vrrp-state ($state)"
    holder=$(ssh_ "$h" wg-ha status 2>/dev/null | sed -n 's/^upnp holder: //p')
    if [ "$state" = MASTER ]; then
      has "$f" "wg_ha_upnp_lease_owned{" "$h: leader exports lease ownership"
      grep -qE '^wg_ha_upnp_lease_owned\{.*\} 1$' "$f" && pass "$h: leader owns lease (holder $holder)" || fail "$h: leader does not own lease"
      n_host=$(ssh_ "$h" sudo -n wg show wg0 latest-handshakes 2>/dev/null | grep -c . || true)
      n_exp=$(grep -c '^wg_ha_peer_last_handshake_timestamp_seconds' "$f")
      [ "$n_host" = "$n_exp" ] && pass "$h: peer count $n_exp matches wg" || fail "$h: peers exported=$n_exp host=$n_host"
    fi
    grep -qiE 'private|PrivateKey' "$f" && fail "$h: key material in textfile" || pass "$h: no key material"
  done
  WG_HA_MAX_AGE=120 bash "$ROOT/scripts/wg-ha-health-collector.sh" evaluate "${files[@]}" \
    && pass "fleet: exactly one fresh leader with a valid lease" || fail "fleet verdict not ok"
  echo "failures: $FAILS"; [ $FAILS = 0 ]; exit
fi

# ---------- NixOS wiring (evaluated, not grepped) ----------
COLLECTOR=""
for n in chrome1 chrome2 chrome3; do
  j=$(cd "$ROOT" && nix eval --json ".#nixosConfigurations.$n.config" --apply 'c: {
      exec = c.systemd.services.wg-ha-health.serviceConfig.ExecStart;
      type = c.systemd.services.wg-ha-health.serviceConfig.Type;
      prot = c.systemd.services.wg-ha-health.serviceConfig.ProtectSystem;
      rw = c.systemd.services.wg-ha-health.serviceConfig.ReadWritePaths;
      node = c.systemd.services.wg-ha-health.environment.WG_HA_NODE;
      timer = c.systemd.timers.wg-ha-health.wantedBy;
      every = c.systemd.timers.wg-ha-health.timerConfig.OnUnitActiveSec;
      ne = c.services.prometheus.exporters.node.enable;
      port = c.services.prometheus.exporters.node.port;
      flags = c.services.prometheus.exporters.node.extraFlags; }' 2>/dev/null) \
    || { fail "$n: nix eval of wg-ha-health wiring"; continue; }
  echo "$j" | jq -e --arg n "$n" '.type=="oneshot" and .prot=="strict" and .rw==["/var/lib/wg-ha-metrics"]
      and .node==$n and (.timer|index("timers.target")) != null and .every=="30s"
      and .ne and .port==9101 and (.flags|index("--collector.textfile.directory=/var/lib/wg-ha-metrics")) != null
      and (.exec|test(" collect /var/lib/wg-ha-metrics/wg_ha.prom$"))' >/dev/null \
    && pass "$n: service/timer/textfile/node_exporter wiring" || fail "$n: wiring $j"
  COLLECTOR=$(echo "$j" | jq -r '.exec' | awk '{print $2}')
done
[ -x "$COLLECTOR" ] || [ -r "$COLLECTOR" ] || { fail "collector store path from ExecStart"; COLLECTOR="$ROOT/scripts/wg-ha-health-collector.sh"; }
echo "# collector under test: $COLLECTOR"

# ---------- simulated host ----------
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/wg" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SIM/wg.calls"
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
grep -vq 'latest-handshakes' "$T/healthy/wg.calls" && fail "only targeted wg query" || pass "only targeted wg query (no dump/showconf)"

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
ev() { WG_HA_NOW=$NOW bash "$COLLECTOR" evaluate "$@" >"$T/ev" 2>&1; echo $?; }
[ "$(ev $T/healthy.prom $T/follower.prom)" = 0 ] && grep -q verdict=ok "$T/ev" && pass "fleet: one leader ok" || { fail "fleet ok"; cat "$T/ev"; }
[ "$(ev $T/follower.prom $T/missing.prom)" != 0 ] && pass "fleet: no-leader/missing rejected" || fail "fleet no-leader"
[ "$(ev $T/follower.prom $T/follower.prom)" = 4 ] && grep -q verdict=no_leader "$T/ev" && pass "fleet: no_leader" || fail "fleet no_leader"
cp $T/healthy.prom $T/healthy2.prom
[ "$(ev $T/healthy.prom $T/healthy2.prom)" = 5 ] && grep -q verdict=multiple_leaders "$T/ev" && pass "fleet: split leader detected" || { fail "split leader"; cat "$T/ev"; }
[ "$(WG_HA_NOW=$((NOW+1000)) bash "$COLLECTOR" evaluate $T/healthy.prom $T/follower.prom >/dev/null; echo $?)" = 3 ] && pass "fleet: stale observations degraded" || fail "fleet stale"
[ "$(ev $T/healthy.prom $T/nonexistent.prom)" = 3 ] && pass "fleet: missing node file degraded" || fail "fleet missing file"
[ "$(ev $T/expired.prom $T/follower.prom)" = 3 ] && grep -q leader_without_lease "$T/ev" && pass "fleet: leader with expired lease rejected" || { fail "fleet expired"; cat "$T/ev"; }

echo "failures: $FAILS"
[ $FAILS = 0 ]
