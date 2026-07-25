{ pkgs, ... }: {
  services.openssh.enable = true;
  # Key-only auth fleet-wide. deploy-rs connects as sshUser=spencer
  # (a @wheel user with passwordless sudo) and activates as root, so
  # prohibit-password does not block deploys.
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    PermitRootLogin = "prohibit-password";
  };
  time.timeZone = "America/Chicago";
  nixpkgs.config.allowUnfree = true;
  environment = {
    systemPackages = with pkgs; [
      emacs-nox
      git
    ];
  };
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  # `spencer` is in @wheel (users.nix); trusting wheel lets deploy-rs
  # push unsigned locally-built closures without disabling signature
  # verification globally (was: require-sigs = false).
  nix.settings.trusted-users = [ "root" "@wheel" ];
  nix.settings.auto-optimise-store = true;
  nix.settings.min-free = 1024 * 1024 * 1024;       # 1 GiB
  nix.settings.max-free = 5 * 1024 * 1024 * 1024;   # 5 GiB
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
}
