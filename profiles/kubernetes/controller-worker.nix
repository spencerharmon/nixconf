{ config, ... }: {
  networking.firewall.allowedTCPPorts = [
    8888
    9488
    6443
    2379
    2380
    10250
    10259
    10257
  ];
  imports = [
    ./kubernetes-common.nix
  ];
  services.kubernetes = {
    roles = [ "master" "node" ];
  };
  services.kubernetes.apiserver.allowPrivileged = true;
}
