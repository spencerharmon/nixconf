{ pkgs, ... }: {
  services.openssh.enable = true;
  time.timeZone = "America/Chicago";
  nixpkgs.config.allowUnfree = true;
  environment = {
    systemPackages = with pkgs; [
      git
      emacs-nox
    ];
  };
  nix = {
    package = pkgs.nixFlakes;
    extraOptions = ''
        experimental-features = nix-command flakes
        '';
  };
  nix.requireSignedBinaryCaches = false;  
}
