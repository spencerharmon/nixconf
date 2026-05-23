let
  spencer = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID+HZIIpyKjtjEgGktsmicRO0qpyCiPnD2YGhBgZAUXj spencer@spray";
  users = [ spencer ];

  yoga = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK/9dzZlbc1qJeVy3ReIGUEi+EJVYybOci5wqj6iTC5B root@yoga";
in
{
  "wifi-yoga.age".publicKeys = users ++ [ yoga ];
  # "opencode-auth.age" left registered but not consumed by any host module.
  "opencode-auth.age".publicKeys = users ++ [ yoga ];
}
