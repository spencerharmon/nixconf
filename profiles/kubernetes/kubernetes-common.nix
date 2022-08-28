{ pkgs, ... }: {
  imports = [
    ../common.nix
  ];
  environment = {
    systemPackages = with pkgs; [
      kubectl
    ];
  };
  services.flannel.backend.Type = "host-gw";
}
