{ pkgs, ... }: {
  imports = [
    ../common.nix
  ];
  environment = {
    systemPackages = with pkgs; [
      kubectl
    ];
  };
  services.flannel.backend.Type = "host-gw";

  # nixpkgs's pkgs.flannel (0.28.6) pins its GitHub tarball source with a
  # fixed-output hash that no longer matches what GitHub currently serves for
  # that tag (GitHub regenerates release-archive tarballs over time, so the
  # bytes -- and hence the sha256 -- drift out from under an old pin; this is
  # not something this repo caused and not fixable by bumping nixpkgs further,
  # since the same drift can recur on any later pin). Override just the `src`
  # hash to the value GitHub actually serves today so the fixed-output-derivation
  # check passes; upstream nixpkgs will eventually pick up the corrected hash
  # itself. Verified against nixpkgs rev e7a3ca8092b61ff85b6a45bf863ea2b2d6a661b3
  # while build-testing the pending nixpkgs bump (see
  # docs/nixpkgs-build-test-hosts.md) -- drop this overlay once nixpkgs itself
  # carries a matching hash for the flannel version in use.
  nixpkgs.overlays = [
    (final: prev: {
      flannel = prev.flannel.overrideAttrs (old: {
        src = prev.fetchFromGitHub {
          owner = "flannel-io";
          repo = "flannel";
          rev = "v${prev.flannel.version}";
          sha256 = "sha256-sqpsUAKBza96AMQMUCG94KOht5ExnHRLR7eGna3m3Xg=";
        };
      });
    })
  ];
}
