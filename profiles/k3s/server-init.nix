{ config, ... }:
# The ONE chrome node that bootstraps the embedded-etcd cluster
# (`--cluster-init`). Its env file carries only K3S_TOKEN (the shared
# cluster secret the other servers present when joining).
{
  imports = [ ./k3s-common.nix ];

  age.secrets.k3s-init-env = {
    file = ../../secrets/k3s-init.env.age;
    mode = "0400";
  };

  services.k3s = {
    clusterInit = true;
    environmentFile = config.age.secrets.k3s-init-env.path;
  };
}
