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

  home.file.".cave/agents".source = ./spencer/.cave/agents;

  home.file.".cave/agent/skills/caveman".source = inputs.caveman-skill;
  home.file.".cave/agent/skills/anthropic-skills".source = inputs.anthropic-skills;
  home.file.".cave/agent/skills/pi-skills".source = inputs.pi-skills;

  # caveman-code: spencerharmon/caveman-code spencer-dev.
  # Track the fork branch until it can be packaged reproducibly.
  #
  # Not packaged with nix: its monorepo has postinstall scripts
  # (onnxruntime-node, canvas) that fetch network resources or build
  # native modules, neither of which works in the nix sandbox.
  # Keep it as a writable dev checkout and build it during activation.
  #
  # TODO: once caveman-code is published in a form usable by Nix,
  # switch to a flake input + buildNpmPackage that consumes a published
  # tarball with `--ignore-scripts` (prebuilt dist/ required, so no
  # native build needed). Remove this activation block and the
  # ~/.local/bin/caveman wrapper below.
  home.activation.cloneCavemanCode =
    config.lib.dag.entryAfter [ "writeBoundary" ] ''
      # caveman-code is useful tooling, not part of the login/EXWM
      # critical path. Never fail Home Manager activation if GitHub or
      # npm is unavailable; otherwise a network hiccup leaves managed
      # dotfile symlinks stale/dangling and breaks emacs-as-WM.
      (
        set -u
        warn() { printf 'caveman-code activation skipped: %s\n' "$*" >&2; }

        REPO="$HOME/git-repos/caveman-code"
        BRANCH="spencer-dev"
        REMOTE_URL="https://github.com/spencerharmon/caveman-code.git"
        if [ ! -d "$REPO/.git" ]; then
          mkdir -p "$HOME/git-repos"
          if ! ${pkgs.git}/bin/git clone --branch "$BRANCH" "$REMOTE_URL" "$REPO"; then
            warn "git clone failed (network/DNS unavailable?)"
            exit 0
          fi
        else
          ${pkgs.git}/bin/git -C "$REPO" remote set-url origin "$REMOTE_URL" || true
          if ${pkgs.git}/bin/git -C "$REPO" fetch --quiet origin "$BRANCH"; then
            if ${pkgs.git}/bin/git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
              ${pkgs.git}/bin/git -C "$REPO" switch "$BRANCH" || true
            else
              ${pkgs.git}/bin/git -C "$REPO" switch --track -c "$BRANCH" "origin/$BRANCH" || true
            fi
            ${pkgs.git}/bin/git -C "$REPO" pull --ff-only origin "$BRANCH" || true
          else
            warn "git fetch failed; using existing checkout if present"
          fi
        fi

        CLI="$REPO/packages/coding-agent/dist/cli.js"
        STAMP="$REPO/.nixconf-caveman-code-built-rev"
        if ! HEAD_REV="$(${pkgs.git}/bin/git -C "$REPO" rev-parse HEAD 2>/dev/null)"; then
          warn "not a usable git checkout at $REPO"
          exit 0
        fi
        if [ -n "$(${pkgs.git}/bin/git -C "$REPO" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
          BUILD_KEY="$HEAD_REV-dirty"
        else
          BUILD_KEY="$HEAD_REV"
        fi

        if [ ! -f "$CLI" ] || [ ! -f "$STAMP" ] || [ "$(cat "$STAMP" 2>/dev/null || true)" != "$BUILD_KEY" ]; then
          export PATH="${pkgs.nodejs_24}/bin:${pkgs.git}/bin:$PATH"
          export HUSKY=0
          cd "$REPO"
          if [ -f package-lock.json ]; then
            npm ci || { warn "npm ci failed"; exit 0; }
          else
            npm install || { warn "npm install failed"; exit 0; }
          fi
          npm run build || { warn "npm run build failed"; exit 0; }
          printf '%s\n' "$BUILD_KEY" > "$STAMP"
        fi
      )
    '';

  # Wrapper so `caveman` is on PATH after activation builds caveman-code.
  home.file.".local/bin/caveman".text = ''
    #!${pkgs.bash}/bin/bash
    exec ${pkgs.nodejs_24}/bin/node \
      "$HOME/git-repos/caveman-code/packages/coding-agent/dist/cli.js" "$@"
  '';
  home.file.".local/bin/caveman".executable = true;

  home.file.".local/bin/caveman-code".text = ''
    #!${pkgs.bash}/bin/bash
    exec ${pkgs.nodejs_24}/bin/node \
      "$HOME/git-repos/caveman-code/packages/coding-agent/dist/cli.js" "$@"
  '';
  home.file.".local/bin/caveman-code".executable = true;

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
      cavemacs
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
