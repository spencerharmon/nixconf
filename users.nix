{ pkgs, ...}:
{
  security.sudo.wheelNeedsPassword = false;

  # Bash is pinned explicitly here on multiple axes so it cannot be
  # silently dropped. Background: during the nixpkgs 22.11 -> 26.05
  # upgrade an agent edit was suspected of removing bash, leading to
  # an unbootable yoga because nothing could exec /bin/sh-equivalents.
  # While the actual diff did NOT remove bash, the failure shape was
  # close enough that we treat "bash present and usable on every host"
  # as a fleet-wide invariant. Removing any of these requires touching
  # users.nix, which is reviewed by humans for every host change.
  users.defaultUserShell = pkgs.bashInteractive;
  environment.systemPackages = with pkgs; [
    bash bashInteractive
  ];

  users.users.spencer = {
    isNormalUser = true;
    # Explicit shell as well as defaultUserShell above. Belt and
    # suspenders.
    shell = pkgs.bashInteractive;
    # wpa_supplicant group is needed for `wpa_cli` to talk to the
    # supplicant socket without sudo. Used by the M-x wifi picker in
    # home/spencer/.emacs.
    extraGroups = [ "wheel" "wpa_supplicant" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID+HZIIpyKjtjEgGktsmicRO0qpyCiPnD2YGhBgZAUXj spencer@spray"
    ];
  };
}
