{ pkgs, ... }: {
  services.openssh.enable = true;
  time.timeZone = "America/Chicago";
  nixpkgs.config.allowUnfree = true;
  environment = {
    systemPackages = with pkgs; [
      emacs-nox
      git
    ];
  };
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.require-sigs = false;
  nix.settings.auto-optimise-store = true;
  nix.settings.min-free = 1024 * 1024 * 1024;       # 1 GiB
  nix.settings.max-free = 5 * 1024 * 1024 * 1024;   # 5 GiB
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
}
