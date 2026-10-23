{ config, lib, pkgs, ... }:
# HA WireGuard server for the chrome fleet: keepalived (VRRP) elects ONE active
# node; only that node brings up wg0, source-NATs the VPN pool onto its LAN
# uplink, and holds the router's UPnP port mapping for the WireGuard port.
#
# Why this shape (see docs/wireguard-ha.md):
# - The LAN router supports neither static port-forwards nor static routes, only
#   UPnP (IGD) — so inbound traffic follows a UPnP mapping that must point at the
#   active node's OWN address, and the return path is MASQUERADE, not a route.
#   No floating IP is needed.
# - The router runs UPnP in secure mode (verified): only the owning host may
#   change/delete a mapping, and leases are honoured exactly. So the active node
#   asserts a SHORT lease (default 120 s) and refreshes it; on graceful handover
#   it deletes its own mapping (seconds), after a hard node failure the new
#   active node takes over when the dead node's lease expires (<= lease).
#   The router's ownership rule also fences split-brain: only one node can hold
#   the mapping at a time.
# - Every node carries the same server key + peers (agenix), so clients never
#   change; wg0 is up ONLY on the active node so idle nodes don't black-hole the
#   VPN pool route.
#
# Arming: nothing is activated until /var/lib/wg-ha/armed exists (`wg-ha arm`),
# so the stack can be deployed and its VRRP election tested before cutover.
# Secrets (no infra identifiers in this public repo):
#   secrets/wg-ha-wg0.conf.age  wg-quick config: server key, address, peers
#   secrets/wg-ha.env.age       WG_HA_UPNP_URL (router IGD rootDesc URL),
#                               WG_HA_SUBNET (VPN pool CIDR), WG_HA_PORT,
#                               WG_HA_LEASE
let
  cfg = config.chrome.wireguardHa;
  stateDir = "/var/lib/wg-ha";
  runDir = "/run/wg-ha";
  conf = config.age.secrets."wg0.conf".path;
  envFile = config.age.secrets.wg-ha-env.path;
  path = with pkgs; [ wireguard-tools iproute2 iptables miniupnpc gnugrep gnused coreutils systemd bash ];

  # Shared prologue: load secret env, then optional local overrides (test port).
  loadEnv = ''
    set -a
    . ${envFile}
    [ -f ${stateDir}/override.env ] && . ${stateDir}/override.env
    set +a
    : "''${WG_HA_UPNP_URL:?}" "''${WG_HA_SUBNET:?}"
    WG_HA_PORT=''${WG_HA_PORT:-51820}
    WG_HA_LEASE=''${WG_HA_LEASE:-120}
    own_ip() { ip -4 -o route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p'; }
  '';

  up = pkgs.writeShellScript "wg-ha-up" ''
    set -euo pipefail
    ${loadEnv}
    ip link show wg0 >/dev/null 2>&1 && wg-quick down ${conf} || true
    wg-quick up ${conf}
    wg set wg0 listen-port "$WG_HA_PORT"
    iptables -w -C INPUT -p udp --dport "$WG_HA_PORT" -j ACCEPT 2>/dev/null || iptables -w -I INPUT -p udp --dport "$WG_HA_PORT" -j ACCEPT
    iptables -w -C FORWARD -i wg0 -j ACCEPT 2>/dev/null || iptables -w -I FORWARD -i wg0 -j ACCEPT
    iptables -w -C FORWARD -o wg0 -j ACCEPT 2>/dev/null || iptables -w -I FORWARD -o wg0 -j ACCEPT
    iptables -w -t nat -C POSTROUTING -s "$WG_HA_SUBNET" ! -o wg0 -j MASQUERADE 2>/dev/null \
      || iptables -w -t nat -I POSTROUTING -s "$WG_HA_SUBNET" ! -o wg0 -j MASQUERADE
    echo "wg-ha: wg0 up on port $WG_HA_PORT, NAT for $WG_HA_SUBNET"
  '';

  # Foreground loop: claim the router's UPnP mapping (retry every 5 s until the
  # previous holder's lease expires), then keep refreshing it.
  upnpLoop = pkgs.writeShellScript "wg-ha-upnp" ''
    set -uo pipefail
    ${loadEnv}
    held=0
    while true; do
      ip=$(own_ip)
      if out=$(upnpc -u "$WG_HA_UPNP_URL" -e wg-ha -a "$ip" "$WG_HA_PORT" "$WG_HA_PORT" UDP "$WG_HA_LEASE" 2>&1) \
         && echo "$out" | grep -q "is redirected"; then
        [ $held = 0 ] && echo "wg-ha: UPnP mapping held: $WG_HA_PORT/udp -> $ip (lease ''${WG_HA_LEASE}s)"
        held=1; echo "$ip" > ${runDir}/upnp-holder
        sleep $(( WG_HA_LEASE / 4 ))
      else
        [ $held = 1 ] && echo "wg-ha: lost UPnP mapping"
        held=0
        echo "wg-ha: UPnP claim failed (retrying in 5s): $(echo "$out" | grep -E 'failed|code' | head -1)"
        sleep 5
      fi
    done
  '';

  down = pkgs.writeShellScript "wg-ha-down" ''
    set -uo pipefail
    ${loadEnv}
    upnpc -u "$WG_HA_UPNP_URL" -d "$WG_HA_PORT" UDP >/dev/null 2>&1 && echo "wg-ha: released UPnP mapping" || true
    rm -f ${runDir}/upnp-holder
    iptables -w -t nat -D POSTROUTING -s "$WG_HA_SUBNET" ! -o wg0 -j MASQUERADE 2>/dev/null || true
    iptables -w -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
    iptables -w -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
    iptables -w -D INPUT -p udp --dport "$WG_HA_PORT" -j ACCEPT 2>/dev/null || true
    ip link show wg0 >/dev/null 2>&1 && wg-quick down ${conf} || true
    echo "wg-ha: inactive"
  '';

  # keepalived notify: <TYPE> <NAME> <STATE> <PRIORITY>
  notify = pkgs.writeShellScript "wg-ha-notify" ''
    PATH=${lib.makeBinPath path}
    mkdir -p ${runDir}
    echo "$3" > ${runDir}/vrrp-state
    case "$3" in
      MASTER) systemctl start --no-block wg-ha-active.service ;;
      *)      systemctl stop --no-block wg-ha-active.service ;;
    esac
  '';

  cli = pkgs.writeShellScriptBin "wg-ha" ''
    PATH=${lib.makeBinPath path}:$PATH
    state=$(cat ${runDir}/vrrp-state 2>/dev/null || echo UNKNOWN)
    case "''${1:-status}" in
      arm)
        mkdir -p ${stateDir}; touch ${stateDir}/armed
        [ "$state" = MASTER ] && systemctl start wg-ha-active.service
        echo "armed (vrrp: $state)" ;;
      disarm)
        rm -f ${stateDir}/armed
        systemctl stop wg-ha-active.service
        echo "disarmed" ;;
      status)
        echo "vrrp state : $state"
        echo "armed      : $([ -e ${stateDir}/armed ] && echo yes || echo no)"
        echo "active svc : $(systemctl is-active wg-ha-active.service)"
        echo "upnp holder: $(cat ${runDir}/upnp-holder 2>/dev/null || echo -)"
        ip link show wg0 >/dev/null 2>&1 && wg show wg0 | grep -E '^(interface|  listening port)|^peer|latest handshake' | sed -E 's/^(peer|interface): .*/\1/' || echo "wg0        : down" ;;
      *) echo "usage: wg-ha [status|arm|disarm]"; exit 2 ;;
    esac
  '';
in
{
  options.chrome.wireguardHa = {
    enable = lib.mkEnableOption "HA WireGuard server (keepalived + UPnP)";
    priority = lib.mkOption {
      type = lib.types.ints.between 1 254;
      description = "VRRP priority; the highest live node becomes active at startup (nopreempt afterwards).";
    };
    interface = lib.mkOption {
      type = lib.types.str;
      default = "enp1s0";
      description = "LAN interface carrying VRRP and the uplink for NAT.";
    };
    virtualRouterId = lib.mkOption {
      type = lib.types.ints.between 1 255;
      default = 51;
      description = "VRRP router id (must be unique on the LAN).";
    };
  };

  config = lib.mkIf cfg.enable {
    age.secrets."wg0.conf" = {
      file = ../secrets/wg-ha-wg0.conf.age;
      name = "wg0.conf";
      mode = "0400";
    };
    age.secrets.wg-ha-env = {
      file = ../secrets/wg-ha.env.age;
      mode = "0400";
    };

    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    # VRRP adverts (proto 112) between the candidates. nixos-fw is flushed and
    # rebuilt on every (re)start, so a plain append is idempotent.
    networking.firewall.extraCommands = ''
      iptables -A nixos-fw -p vrrp -j nixos-fw-accept
    '';
    environment.systemPackages = [ cli pkgs.wireguard-tools ];
    systemd.tmpfiles.rules = [ "d ${stateDir} 0700 root root -" "d ${runDir} 0755 root root -" ];

    services.keepalived = {
      enable = true;
      # NOT openFirewall: its extraStopCommands delete the rule without `|| true`,
      # which makes every firewall reload fail ("Bad rule") and deploys roll back.
      enableScriptSecurity = true;
      extraGlobalDefs = "script_user root";
      vrrpInstances.wg = {
        interface = cfg.interface;
        state = "BACKUP";
        noPreempt = true;
        virtualRouterId = cfg.virtualRouterId;
        priority = cfg.priority;
        trackInterfaces = [ cfg.interface ];
        extraConfig = ''notify "${notify}"'';
      };
    };

    systemd.services.wg-ha-active = {
      description = "WireGuard HA: active node (wg0 + NAT + UPnP lease)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      inherit path;
      unitConfig.ConditionPathExists = "${stateDir}/armed";
      serviceConfig = {
        Type = "simple";
        ExecStartPre = "${up}";
        ExecStart = "${upnpLoop}";
        ExecStopPost = "${down}";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
