let
  spencer = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID+HZIIpyKjtjEgGktsmicRO0qpyCiPnD2YGhBgZAUXj spencer@spray";
  users = [ spencer ];

  yoga = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINM/rswMb7RDDmbcQv0dYFODi/cgjlHef2WsHbg2wgVe root@yoga";

  # chrome k3s fleet host keys (/etc/ssh/ssh_host_ed25519_key.pub).
  # A new chrome host: add its key here, append it to the lists below, and
  # rekey (`agenix -r`) before deploying it.
  chrome1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAaEZOde5FOqfWGQGU/NniI7OH8Jq2a+TTQ6SgyXpLs0";
  chrome2 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPpOEDXpMNl3JW5OVeaxGz+Xyq7MsKxf+6RZzgE2gAdz";
  chrome3 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOfDGJWu7jpcz0tl2x++4uYhq1ltzYM2fN6bC0X+7YBf";
  chromeAll = [ chrome1 chrome2 chrome3 ];
  chromeJoiners = [ chrome2 chrome3 ];
in
{
  # k3s cluster-init node env: K3S_TOKEN.
  "k3s-init.env.age".publicKeys = users ++ [ chrome1 ];
  # k3s joining-server env: K3S_TOKEN + K3S_URL.
  "k3s-join.env.age".publicKeys = users ++ chromeJoiners;
  # Per-host DDNS env: CLOUDFLARE_API_TOKEN + DDNS_ZONE.
  "cloudflare-ddns.env.age".publicKeys = users ++ chromeAll;
  # HA WireGuard (profiles/wireguard-ha.nix, managed by scripts/wg-ha-peers.py).
  # State = server + ALL client keys: admin only, never a host.
  "wg-ha-state.age".publicKeys = users;
  # Derived from the state by `wg-ha-peers render`; decrypted on every chrome node.
  "wg-ha-wg0.conf.age".publicKeys = users ++ chromeAll;
  "wg-ha.env.age".publicKeys = users ++ chromeAll;

  "wifi-yoga.age".publicKeys = users ++ [ yoga ];
  # "opencode-auth.age" left registered but not consumed by any host module.
  "opencode-auth.age".publicKeys = users ++ [ yoga ];
  # Cross-SD LUKS keyfile. Same 64-byte random blob lives in slot 1
  # of every yoga-sd's LUKS container and underyoga's. Used
  # post-boot to open sibling LUKS without re-prompting for the
  # slot-0 password. Initrd does NOT use this file.
  "cross-sd-key.age".publicKeys = users ++ [ yoga ];
  # SSH host private key for yoga (and every yoga-sd; all share the
  # "yoga" identity). Decrypted by agenix on first boot and dropped
  # into /etc/ssh/ssh_host_ed25519_key. ONLY "users" (spencer) can
  # decrypt this -- a fresh-installed yoga can't decrypt its own
  # host key (chicken-and-egg). On first install the cleartext
  # private key is dropped into /mnt/etc/ssh/ manually before boot;
  # this agenix copy is recovery / re-install only.
  "yoga-host-key.age".publicKeys = users;
  # Hashed password for spencer on yoga-family systems. Contains a
  # yescrypt hash from /etc/shadow, not the plaintext password. Used
  # by profiles/spencer-password.nix so slock can unlock.
  "spencer-password-hash.age".publicKeys = users ++ [ yoga ];
  # WireGuard private key for the yoga (yoga-sd-0) peer. Public key:
  # 4ZzZba0gUeeYprKU0VF/hJaIKec3e6DHrb4NODxU/jA= (recorded in
  # docs/bee-wireguard-yoga-secret-wireguard-yoga-secret.md for
  # dependent tasks to consume without re-deriving).
  "wireguard-yoga.age".publicKeys = users ++ [ yoga ];
}
