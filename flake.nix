{
  description = "deploy nixos systems";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    deploy-rs.url = "github:serokell/deploy-rs";
  };
  outputs = { self, nixpkgs, deploy-rs }: {
    nixosConfigurations = {
      chrome1 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./systems/chrome1/configuration.nix
          ./profiles/default.nix
          ./users.nix
        ];
      };
      chrome2 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./systems/chrome2/configuration.nix
          ./profiles/default.nix
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
      nodes.chrome2 = {
        hostname = "chrome2.lan";
        profiles.system = {
          sshUser = "spencer";
          user = "root";
          path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.chrome1;
        };
        
      };
    };
    checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
  };
}
