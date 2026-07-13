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
# AllowedIPs: the WG pool (10.8.0.0/24) ONLY.
#
# TODO(operator-approved): the flux wireguard-routed-lan split-tunnel spec
# also wanted the server LAN 192.168.1.0/24 routed over wg0. It is
# DELIBERATELY EXCLUDED here (operator-approved 2026-07-13). yoga-sd-0 lives
# physically ON 192.168.1.0/24, and networking.wireguard.interfaces auto-adds
# `ip route replace 192.168.1.0/24 dev wg0`, which hijacks yoga's own LAN
# route and blackholes all local connectivity (this bricked a live deploy on
# 2026-07-13, dropping SSH mid-activation and stranding the host in emergency
# mode). While yoga is on the home LAN it reaches 192.168.1.0/24 directly and
# needs no tunnel route for it. Re-adding the LAN subnet requires
# collision-safe handling (policy routing / a wg-quick PostUp that only adds
# the route when yoga is NOT already on 192.168.1.0/24) before it is safe.
{ config, ... }:
{
  age.secrets.wireguard-yoga = {
    file = ../secrets/wireguard-yoga.age;
    owner = "root";
    mode = "0400";
  };

  networking.wireguard.interfaces.wg0 = {
    ips = [ "10.8.0.3/32" ];
    privateKeyFile = config.age.secrets.wireguard-yoga.path;
    peers = [
      {
        publicKey = "6dqts5KM9KJv0mNJHqpu/QS6z46ct2mFGFGj1sAyRC0=";
        endpoint = "wireguard.polyfam.studio:51820";
        allowedIPs = [ "10.8.0.0/24" ];
        persistentKeepalive = 25;
      }
    ];
  };
}
