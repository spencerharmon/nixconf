{ config, pkgs, inputs, ... }:
{
  # cavemacs comes from the spencerharmon/cavemacs flake (registered in
  # emacsPackages via its overlay; consumed in home/spencer.nix).
  nixpkgs.overlays = [
    inputs.cavemacs.overlays.x86_64-linux.default

    # Upstream cavemacs.el declares:
    #   Package-Requires: ((emacs "30.1") (markdown-mode "2.5") (transient "0.7"))
    # but the flake's Nix package currently only sets
    # packageRequires = [ transient ]. Byte-compilation then fails on
    # `(require 'markdown-mode)`. Patch the package locally until the
    # cavemacs flake adds markdown-mode itself.
    (final: prev: {
      emacsPackagesFor = emacs:
        (prev.emacsPackagesFor emacs).overrideScope (efinal: eprev: {
          cavemacs = eprev.cavemacs.overrideAttrs (old: {
            packageRequires = (old.packageRequires or [ ]) ++ [ efinal.markdown-mode ];
          });
        });
    })
  ];
}
