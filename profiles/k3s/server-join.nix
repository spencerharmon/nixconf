{ config, ... }:
# A chrome server that JOINS the existing embedded-etcd cluster. Its env
# file carries K3S_TOKEN (same value as the init node's) and K3S_URL
# (https://<init-node>:6443) — kept encrypted so no LAN address lands in
# this public repo.
{
  imports = [ ./k3s-common.nix ];

  age.secrets.k3s-join-env = {
    file = ../../secrets/k3s-join.env.age;
    mode = "0400";
  };

  services.k3s.environmentFile = config.age.secrets.k3s-join-env.path;
}
