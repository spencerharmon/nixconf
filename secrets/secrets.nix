let
  spencer = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID+HZIIpyKjtjEgGktsmicRO0qpyCiPnD2YGhBgZAUXj spencer@spray";
  users = [ spencer ];

  yoga = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINM/rswMb7RDDmbcQv0dYFODi/cgjlHef2WsHbg2wgVe root@yoga";
in
{
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
  # WireGuard private key for the yoga (yoga-sd-0) peer's wg0
  # interface, connecting to the flux wg-easy server. Consumed by
  # profiles/wireguard-yoga.nix via age.secrets.wireguard-yoga.
  "wireguard-yoga.age".publicKeys = users ++ [ yoga ];
}
