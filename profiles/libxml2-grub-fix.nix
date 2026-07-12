# profiles/libxml2-grub-fix.nix
#
# WHY THIS EXISTS
# --------------
# The pinned nixpkgs (flake input rev d233902) ships a broken toolchain
# pair: libxml2 2.15.1 together with the perl module XML::LibXML 2.0210.
# NixOS's GRUB bootloader installer (install-grub.pl) drives XML::LibXML
# XPath while generating grub.cfg, and does so many times per run. With
# this pair it DETERMINISTICALLY SIGSEGVs *inside* libxml2.so.16 (2.15.1)
# at the xmlCheckVersion region -- a near-null write, at an identical
# fault address on every run. Diagnosed from two matching coredumps:
#
#   perl ... install-grub.pl ... : segfault at 6d ip ...
#   in libxml2.so.16.1.1[...+0x4c7a0]   (0x4c7a0 == xmlCheckVersion)
#
# Effect: `nixos-install` fails at "Failed to install bootloader", and
# every on-device `nixos-rebuild switch` would hit the same crash. An
# isolated parse/XPath reproduction does NOT crash; only the full
# install-grub run reaches the bad libxml2 state, so this cannot be
# worked around at the script level -- the toolchain must be fixed.
#
# THE FIX
# -------
# nixpkgs-unstable resolves this by shipping the known-good pair
# libxml2 2.15.3 + XML::LibXML 2.0213 (build + run cleanly together;
# the three CVE-2026-098x/099x patches carried on 2.15.1 are folded
# into 2.15.3 upstream, so 2.15.3 needs no patches). We pin BOTH
# packages to that exact combo here.
#
# XML::LibXML's XS links libxml2 at BUILD time (via Alien::Libxml2),
# so the module must be *rebuilt against* 2.15.3 -- not merely paired
# at runtime. The overlay is therefore two stages: stage 1 swaps
# libxml2 -> 2.15.3 (Alien::Libxml2 and XML::LibXML then rebuild
# against it automatically); stage 2 -- whose `prev` already has
# libxml2 2.15.3 -- bumps the XML::LibXML module to 2.0213. Verified:
# the resulting XML::LibXML reports $VERSION 2.0213 and its LibXML.so
# links libxml2.so.16 from the 2.15.3 store path.
#
# SCOPE
# -----
# Applied only where imported (currently yoga-sd-0), because that is
# the only host being deployed right now. The chrome/k3s fleet needs
# the same fix and will get it via the planned nixpkgs input bump --
# tracked in ROI.md ("nixpkgs upgrade for chrome/k3s fleet"). When
# that bump lands (to a tree that already carries 2.15.3 / 2.0213),
# this profile becomes redundant and should be dropped.
{ ... }:
{
  nixpkgs.overlays = [
    # Stage 1: libxml2 2.15.1 -> 2.15.3 (CVE patches are upstreamed
    # into 2.15.3, hence patches = []).
    (final: prev: {
      libxml2 = prev.libxml2.overrideAttrs (old: rec {
        version = "2.15.3";
        src = prev.fetchFromGitLab {
          domain = "gitlab.gnome.org";
          owner = "GNOME";
          repo = "libxml2";
          rev = "v${version}";
          hash = "sha256-fDntZDyITs223by8n7ueOXiO7yyzshtANoWbY0+yeqo=";
        };
        patches = [ ];
      });
    })

    # Stage 2: XML::LibXML 2.0210 -> 2.0213, rebuilt against the
    # stage-1 libxml2 (prev.perl here already links 2.15.3, so
    # prev.perl.pkgs.XMLLibXML is 2.0210-built-against-2.15.3; we only
    # bump the module version/src on top of it). The 2.13-test patch
    # carried on 2.0210 does not apply to 2.0213, hence patches = [].
    (final: prev: {
      perl = prev.perl.override {
        overrides = pkgs: {
          XMLLibXML = prev.perl.pkgs.XMLLibXML.overrideAttrs (old: rec {
            version = "2.0213";
            src = prev.fetchurl {
              url = "mirror://cpan/authors/id/T/TO/TODDR/XML-LibXML-${version}.tar.gz";
              hash = "sha256-KvIcXWGsNOompfq/FbpaWEHmSPcYnbPjO28otUiYAqs=";
            };
            patches = [ ];
            # NOTE: the derivation NAME stays "...-XML-LibXML-2.0210"
            # (buildPerlPackage fixes `name` before overrideAttrs runs),
            # but the built module is genuine 2.0213 source: its
            # $VERSION reports 2.0213 and LibXML.so links libxml2 2.15.3.
          });
        };
      };
    })
  ];
}
