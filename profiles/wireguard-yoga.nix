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
# AllowedIPs is the routed split-tunnel flux already settled on in
# wireguard-routed-lan: the WG pool (10.8.0.0/24) plus the server's
# real LAN (192.168.1.0/24), routed (not NAT'd) over the tunnel.
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
        allowedIPs = [ "10.8.0.0/24" "192.168.1.0/24" ];
        persistentKeepalive = 25;
      }
    ];
  };
}
