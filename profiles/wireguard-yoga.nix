# wireguard-yoga profile: wg0 client tunnel for the yoga (yoga-sd-0)
# workstation, peering with the flux-managed wg-easy server at
# wireguard.polyfam.studio.
#
# Private key: agenix-decrypted from secrets/wireguard-yoga.age (never
# rendered into the world-readable Nix store); the public half is
# recorded in
# submodules/nixconf/docs/bee-wireguard-yoga-secret-wireguard-yoga-secret.md
# (4ZzZba0gUeeYprKU0VF/hJaIKec3e6DHrb4NODxU/jA=).
#
# Peer: the flux wg-easy server, registered by the linked
# flux:wireguard-yoga-peer-register task
# (submodules/flux/sessions/bee-wireguard-yoga-peer-register-*.md):
#   - server public key: 6dqts5KM9KJv0mNJHqpu/QS6z46ct2mFGFGj1sAyRC0=
#   - yoga's assigned pool tunnel address: 10.8.0.3
#
# AllowedIPs: the WG pool (10.8.0.0/24) plus the server LAN 192.168.1.0/24,
# so spray services behind the wg server (e.g. 192.168.1.1) are reachable
# through the tunnel. Crypto-routing (allowedIPs) always includes the LAN;
# kernel routing is handled collision-safely below.
#
# COLLISION-SAFE LAN ROUTE (supersedes the 2026-07-13 operator decision to
# exclude the LAN entirely): the earlier brick was caused by
# networking.wireguard auto-adding `ip route replace 192.168.1.0/24 dev wg0`,
# which hijacked yoga's own LAN route when yoga was physically ON
# 192.168.1.0/24 -- blackholing local connectivity and dropping SSH
# mid-activation. Fix: allowedIPsAsRoutes = false disables that auto route,
# and postSetup adds the LAN route via wg0 ONLY when yoga is NOT already on a
# 192.168.1.x address. On the home LAN (192.168.1.x) yoga reaches the LAN
# directly and no tunnel route is installed -> no collision. On any other
# network (e.g. 192.168.217.x) the LAN route is installed and spray is
# reachable over the tunnel.
#
# dynamicEndpointRefreshSeconds re-resolves the endpoint hostname
# periodically, so a boot where DNS was not yet ready (the observed
# "Name or service not known: wireguard.polyfam.studio:51820" peer-unit
# failure) self-heals instead of leaving the tunnel peerless until a rebuild.
#
# LAN guard (2026-11-06): the tunnel ONLY works away from home. The endpoint
# resolves to the router's public IP, and the home router does not hairpin
# (NAT-loopback) LAN-originated traffic to its own WAN address, so on the home
# LAN the handshake initiation is never answered (verified: wg0 sent
# handshakes, the server saw nothing; pointing the endpoint at the server's LAN
# address handshook immediately, so the key/peer registration are fine). It is
# also pointless there: the LAN is directly reachable. So wg0 is not started
# at boot; a dhcpcd hook starts it when the lease's gateway is NOT the home
# router (other wifi, USB tether) and stops it when yoga is home. Manual:
# `systemctl start|stop wireguard-wg0.target`.
{ config, lib, pkgs, ... }:
let
  homeGateway = "192.168.1.1";
in
{
  # Not started at boot; the dhcpcd hook below starts it off the home LAN only.
  systemd.targets.wireguard-wg0.wantedBy = lib.mkForce [ ];

  networking.dhcpcd.runHook = ''
    gw="''${new_routers:-$routers}"
    ${pkgs.util-linux}/bin/logger -t wg-yoga-hook "reason=$reason interface=$interface gateway=$gw"
    case "$reason" in
      BOUND|REBIND|REOBTAIN)
        case "$interface" in
          lo|wg0) ;;
          *)
            if [ "$gw" = "${homeGateway}" ]; then
              ${pkgs.systemd}/bin/systemctl stop --no-block wireguard-wg0.target || true
            elif [ -n "$gw" ]; then
              ${pkgs.systemd}/bin/systemctl start --no-block wireguard-wg0.target || true
            fi
            ;;
        esac
        ;;
    esac
  '';

  age.secrets.wireguard-yoga = {
    file = ../secrets/wireguard-yoga.age;
    owner = "root";
    mode = "0400";
  };

  networking.wireguard.interfaces.wg0 = {
    ips = [ "10.8.0.3/32" ];
    privateKeyFile = config.age.secrets.wireguard-yoga.path;

    # Disable the built-in `ip route replace <allowedIP> dev wg0` so the
    # server LAN route never blindly hijacks yoga's own LAN route. Routes
    # are installed collision-safely in postSetup below.
    allowedIPsAsRoutes = false;

    postSetup = ''
      # WG pool always routes over the tunnel.
      ${pkgs.iproute2}/bin/ip route replace 10.8.0.0/24 dev wg0
      # Server LAN routes over the tunnel ONLY when yoga is not physically
      # on 192.168.1.x (otherwise it would blackhole the local LAN).
      if ! ${pkgs.iproute2}/bin/ip -4 -o addr show | ${pkgs.gnugrep}/bin/grep -q 'inet 192\.168\.1\.'; then
        ${pkgs.iproute2}/bin/ip route replace 192.168.1.0/24 dev wg0
      fi
    '';

    postShutdown = ''
      ${pkgs.iproute2}/bin/ip route del 192.168.1.0/24 dev wg0 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip route del 10.8.0.0/24 dev wg0 2>/dev/null || true
    '';

    peers = [
      {
        publicKey = "6dqts5KM9KJv0mNJHqpu/QS6z46ct2mFGFGj1sAyRC0=";
        endpoint = "wireguard.polyfam.studio:51820";
        allowedIPs = [ "10.8.0.0/24" "192.168.1.0/24" ];
        persistentKeepalive = 25;
        dynamicEndpointRefreshSeconds = 60;
      }
    ];
  };
}
