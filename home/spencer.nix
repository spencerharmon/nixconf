{ config, pkgs, ... }:
{
  home.stateVersion = "22.11";

  home.file.".emacs".source = ./spencer/.emacs;

  programs.emacs = {
    enable = true;
    extraPackages = epkgs: with epkgs; [
      better-defaults
      elpy
      flycheck
      py-autopep8
      material-theme
      flyspell-correct-ivy
      yaml-mode
      pyvenv
      magit
      nix-mode
      use-package
      exwm
      exwm-firefox-core
      auto-sudoedit
      agent-shell
    ];
  };

  # opencode auth.json is provided via system-level agenix (see
  # profiles/opencode.nix). Home-manager just needs to know not to
  # manage that path so it doesn't conflict with the agenix symlink.
}
