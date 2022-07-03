{ pkgs, ... }: {
  networking.firewall.allowedTCPPorts = [
    10250
  ];
  
  networking.firewall.allowedTCPPortRanges = [
    {from = 30000; to = 32767}
  ];

  imports = [
    ./kubernetes-common.nix
  ];
  services.kubernetes = {
    roles = [ "node" ];
  };
}
