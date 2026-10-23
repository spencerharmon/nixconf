{
  description = "deploy nixos systems";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/d233902339c02a9c334e7e593de68855ad26c4cb";
    # Separate pin for the chrome k3s fleet (stable release branch) so a
    # server upgrade never drags the Yoga workstation pin along with it.
    nixpkgs-chrome.url = "github:nixos/nixpkgs/nixos-26.05";
    deploy-rs.url = "github:serokell/deploy-rs";
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    cavemacs = {
      url = "github:spencerharmon/cavemacs/v0.0.52";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    caveman-skill = {
      url = "github:JuliusBrussee/caveman";
      flake = false;
    };
    anthropic-skills = {
      url = "github:anthropics/skills";
      flake = false;
    };
    pi-skills = {
      url = "github:badlogic/pi-skills";
      flake = false;
    };
  };
  outputs = inputs@{ self, nixpkgs, nixpkgs-chrome, deploy-rs, agenix, home-manager, cavemacs, caveman-skill, anthropic-skills, pi-skills }: {
    nixosConfigurations = {
      # chrome1..3: HA k3s fleet, every node a server (embedded etcd).
      # chrome1 bootstraps the cluster; chrome2/3 join it. Every node runs
      # cloudflare-ddns for its own <hostname>.<zone>.
      chrome1 = nixpkgs-chrome.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          agenix.nixosModules.default
          ./systems/chrome1/configuration.nix
          ./profiles/wireguard-ha.nix
          { chrome.wireguardHa = { enable = true; priority = 150; }; }
          ./profiles/k3s/server-init.nix
          ./profiles/cloudflare-ddns.nix
          ./users.nix
        ];
      };
      chrome2 = nixpkgs-chrome.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          agenix.nixosModules.default
          ./systems/chrome2/configuration.nix
          ./profiles/wireguard-ha.nix
          { chrome.wireguardHa = { enable = true; priority = 100; }; }
          ./profiles/k3s/server-join.nix
          ./profiles/cloudflare-ddns.nix
          ./users.nix
        ];
      };
      chrome3 = nixpkgs-chrome.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          agenix.nixosModules.default
          ./systems/chrome3/configuration.nix
          ./profiles/wireguard-ha.nix
          { chrome.wireguardHa = { enable = true; priority = 50; }; }
          ./profiles/k3s/server-join.nix
          ./profiles/cloudflare-ddns.nix
          ./users.nix
        ];
      };
      # chrome-usb: installed NixOS on a USB stick for console-less
      # (re)installs of chrome hosts. installers/chrome-usb.nix; written
      # from the raw image packages.x86_64-linux.chrome-usb-image.
      chrome-usb = nixpkgs-chrome.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ ./installers/chrome-usb.nix ./users.nix ];
      };
      # underyoga: minimal eMMC-resident NixOS for yoga. Provides the
      # grub dispatcher that finds and chains to yoga-sd's, plus a
      # console-only recovery shell when no SD is inserted. Hostname
      # "underyoga" but reuses the canonical "yoga" SSH host key.
      # Design: docs/yoga-storage-redesign.md. Profile:
      # profiles/underyoga.nix.
      underyoga = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          agenix.nixosModules.default
          ./systems/yoga/configuration.nix
          ./profiles/wifi-yoga.nix
          ./profiles/zram.nix
          ./profiles/spencer-password.nix
          ./users.nix
          ./profiles/underyoga.nix
          ./systems/underyoga/configuration.nix
        ];
      };
      # Per-SD yoga installs. Each SD card has its own target;
      # all share profiles/yoga-sd.nix for the encrypted-root + SD-boot
      # plumbing and supply only their PARTUUIDs / labels via
      # systems/yoga-sd-N/configuration.nix. Hostname stays "yoga" on
      # every SD; all Yoga-family systems share the agenix-managed
      # yoga SSH host key for secret decryption.
      #
      # Design: docs/yoga-storage-redesign.md. Profile:
      # profiles/yoga-sd.nix.
      yoga-sd-0 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          agenix.nixosModules.default
          ./systems/yoga/configuration.nix
          ./profiles/laptop.nix
          ./profiles/wifi-yoga.nix
          ./profiles/zram.nix
          ./profiles/spencer-password.nix
          ./profiles/spencer-home.nix
          ./profiles/coding-agents.nix
          ./profiles/ai-tools.nix
          ./users.nix
          ./profiles/yoga-sd.nix
          ./profiles/libxml2-grub-fix.nix
          ./profiles/wireguard-yoga.nix
          ./systems/yoga-sd-0/configuration.nix
        ];
      };
      # yoga-sd-1: second SD card. Identical module stack to yoga-sd-0;
      # only the per-card identity (systems/yoga-sd-1/configuration.nix)
      # differs. See docs/yoga-storage-redesign.md + profiles/yoga-sd.nix.
      yoga-sd-1 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          agenix.nixosModules.default
          ./systems/yoga/configuration.nix
          ./profiles/laptop.nix
          ./profiles/wifi-yoga.nix
          ./profiles/zram.nix
          ./profiles/spencer-password.nix
          ./profiles/spencer-home.nix
          ./profiles/coding-agents.nix
          ./profiles/ai-tools.nix
          ./users.nix
          ./profiles/yoga-sd.nix
          ./profiles/libxml2-grub-fix.nix
          ./profiles/wireguard-yoga.nix
          ./systems/yoga-sd-1/configuration.nix
        ];
      };
    };
    deploy = {
      nodes.chrome1 = {
        hostname = "chrome1.lan";
        profiles.system = {
          sshUser = "spencer";
          user = "root";
          path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.chrome1;
        };
      };
      nodes.chrome2 = {
        hostname = "chrome2.lan";
        profiles.system = {
          sshUser = "spencer";
          user = "root";
          path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.chrome2;
        };
      };
      nodes.chrome3 = {
        hostname = "chrome3.lan";
        profiles.system = {
          sshUser = "spencer";
          user = "root";
          path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.chrome3;
        };
      };
    };
    # Raw disk image of the chrome-usb system (GPT: ESP + ext4 USBROOT).
    packages.x86_64-linux.chrome-usb-image = import "${nixpkgs-chrome}/nixos/lib/make-disk-image.nix" {
      inherit (self.nixosConfigurations.chrome-usb) config pkgs;
      lib = nixpkgs-chrome.lib;
      format = "raw";
      partitionTableType = "efi";
      bootSize = "512M";
      label = "USBROOT";
      diskSize = "auto";
      additionalSpace = "1G";
      copyChannel = false;
      installBootLoader = true;
    };
    # Peer management for the HA WireGuard server: nix run .#wg-ha-peers -- list
    apps.x86_64-linux.wg-ha-peers = let
      pkgs = nixpkgs-chrome.legacyPackages.x86_64-linux;
      prog = pkgs.writeShellApplication {
        name = "wg-ha-peers";
        runtimeInputs = with pkgs; [ python3 age wireguard-tools qrencode nix ];
        text = ''exec python3 ${./scripts/wg-ha-peers.py} "$@"'';
      };
    in { type = "app"; program = "${prog}/bin/wg-ha-peers"; };
    checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
  };
}
