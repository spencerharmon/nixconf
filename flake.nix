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
  };
  outputs = inputs@{ self, nixpkgs, deploy-rs, agenix, home-manager }: {
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
      yoga = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          agenix.nixosModules.default
          ./systems/yoga/configuration.nix
          ./profiles/laptop.nix
          ./profiles/wifi-yoga.nix
          ./profiles/spencer-home.nix
          ./profiles/coding-agents.nix
          ./users.nix
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
