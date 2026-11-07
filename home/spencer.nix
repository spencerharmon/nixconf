{ config, pkgs, inputs, ... }:
{
  home.stateVersion = "22.11";

  home.sessionPath = [ "$HOME/.local/bin" ];

  # Install ~/.bashrc + ~/.bash_profile that source home-manager's
  # session vars (otherwise home.sessionPath / sessionVariables are
  # ignored in interactive bash shells).
  programs.bash.enable = true;

  home.file.".emacs".source = ./spencer/.emacs;
  home.file.".emacs.d/spencer-theme.el".source = ./spencer/emacs.d/spencer-theme.el;
  home.file.".emacs.d/spencer-dark-theme.el".source = ./spencer/emacs.d/spencer-dark-theme.el;
  home.file.".emacs.d/soft-paper-theme.el".source = ./spencer/emacs.d/soft-paper-theme.el;

  # Skills for the pi coding agent (pi reads ~/.pi/agent/skills/*).
  home.file.".pi/agent/skills/anthropic-skills".source = inputs.anthropic-skills;
  home.file.".pi/agent/skills/pi-skills".source = inputs.pi-skills;

  home.packages = with pkgs; [ nodejs_24 pulseaudio ];

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
      outline-indent
      groovy-mode
      erc-image
      circe
      go-mode
      terraform-mode
      flycheck-yamllint
      poly-ansible
      edit-server
      # Volume control inside emacs (uses pulseaudio CLI).
      pulseaudio-control
    ];
  };

  # opencode auth.json is provided via system-level agenix (see
  # profiles/opencode.nix). Home-manager just needs to know not to
  # manage that path so it doesn't conflict with the agenix symlink.
}
