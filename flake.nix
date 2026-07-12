{
  description = "deploy nixos systems";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/d233902339c02a9c334e7e593de68855ad26c4cb";
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
  outputs = inputs@{ self, nixpkgs, deploy-rs, agenix, home-manager, cavemacs, caveman-skill, anthropic-skills, pi-skills }: {
    nixosConfigurations = {
      chrome1 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          agenix.nixosModules.default
          ./systems/chrome1/configuration.nix
          ./profiles/kubernetes/controller-worker.nix
          ./clusters/chrome-kube.nix
          ./users.nix
        ];
      };
      chrome2 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          agenix.nixosModules.default
          ./systems/chrome2/configuration.nix
          ./profiles/kubernetes/worker.nix
          ./clusters/chrome-kube.nix
          ./users.nix
        ];
      };
      chrome3 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          agenix.nixosModules.default
          ./systems/chrome3/configuration.nix
          ./profiles/kubernetes/worker.nix
          ./clusters/chrome-kube.nix
          ./users.nix
        ];
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
          ./systems/yoga-sd-0/configuration.nix
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
    checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
  };
}
