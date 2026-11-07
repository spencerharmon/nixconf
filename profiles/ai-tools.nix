{ config, pkgs, inputs, ... }:
let
  # ACP (Agent Client Protocol) adapter: emacs agent-shell speaks ACP, pi
  # speaks its own RPC; pi-acp bridges them. Not in nixpkgs, so build it from
  # the pinned flake input (inputs.pi-acp, flake = false).
  # Refresh npmDepsHash with `nix run nixpkgs#prefetch-npm-deps --
  # package-lock.json` inside the new checkout after bumping the input.
  pi-acp = pkgs.buildNpmPackage {
    pname = "pi-acp";
    version = "0.0.32";
    src = inputs.pi-acp;
    npmDepsHash = "sha256-sRBrTwBwo8pcOy5WGDxHE86fvldgOtlppuvcbiB+7uc=";
    # tsup bundles dist/index.js (the package's `bin`).
  };
in
{
  # pi (pi-coding-agent) is a plain Node app, so it runs on yoga's N3150
  # (no AVX2) unlike the Bun-based opencode. pi-acp spawns `pi` from PATH.
  environment.systemPackages = [
    pkgs.pi-coding-agent
    pi-acp
  ];
}
