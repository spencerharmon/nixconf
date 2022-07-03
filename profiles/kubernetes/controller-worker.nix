{ config, ... }: {
  networking.firewall.allowedTCPPorts = [ 8888 9488 ];
  imports = [
    ./kubernetes-common.nix
  ];
  services.kubernetes = {
    roles = [ "master" "node" ];
  };
}
