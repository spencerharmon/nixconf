# profiles/libxml2-grub-fix.nix
#
# Full writeup (symptom, diagnosis, why-it-only-surfaced-now, removal
# condition): docs/libxml2-grub-install-segfault.md
#
# WHY THIS EXISTS
# --------------
# The pinned nixpkgs (flake input rev d233902) ships a broken toolchain
# pair: libxml2 2.15.1 together with the perl module XML::LibXML 2.0210.
# NixOS's GRUB bootloader installer (install-grub.pl) drives XML::LibXML
# XPath while generating grub.cfg, many times per run. With this pair it
# DETERMINISTICALLY SIGSEGVs *inside* libxml2.so.16 (2.15.1) at the
# xmlCheckVersion region -- a near-null write, at an identical fault
# address on every run. Diagnosed from two matching coredumps:
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
# THE FIX (scoped to the perl toolchain, NOT system-wide)
# -------------------------------------------------------
# nixpkgs-unstable resolves this by shipping the known-good pair
# libxml2 2.15.3 + XML::LibXML 2.0213 (build + run cleanly together;
# the three CVE-2026-098x/099x patches carried on 2.15.1 are folded
# into 2.15.3 upstream, so 2.15.3 needs no patches). We pin BOTH to
# that combo -- but ONLY inside the perl package set that builds the
# bootloader installer.
#
# The crash is reached exclusively through install-grub.pl's
# XML::LibXML -> libxml2 path; nothing else in the system triggers it,
# so the system-wide libxml2 is deliberately LEFT at 2.15.1. Overriding
# libxml2 globally would invalidate the cache for the entire desktop/X
# closure that links it and force a multi-hour local world-rebuild for
# no benefit. Scoping it to perl rebuilds only libxml2 (a second,
# perl-private 2.15.3 build) + Alien::Libxml2 + XML::LibXML.
#
# XML::LibXML's XS links libxml2 at BUILD time via Alien::Libxml2, so
# the fix threads a perl-private libxml2 2.15.3 through Alien::Libxml2
# and rebuilds XML::LibXML 2.0213 against that Alien. Verified: system
# pkgs.libxml2 stays 2.15.1 (cache-hit), while perl.pkgs.XMLLibXML
# reports $VERSION 2.0213 and its LibXML.so links libxml2.so.16 from
# the 2.15.3 store path.
#
# SCOPE
# -----
# Applied only where imported (currently yoga-sd-0). The chrome/k3s
# fleet needs the same fix and will get it via the planned nixpkgs input
# bump -- tracked in ROI.md ("fleet nixpkgs upgrade"). When that bump
# lands (to a tree already carrying 2.15.3 / 2.0213), this profile
# becomes redundant and should be dropped.
{ ... }:
{
  nixpkgs.overlays = [
    (final: prev:
      let
        # A perl-PRIVATE libxml2 2.15.3 (CVE patches are upstreamed into
        # 2.15.3, hence patches = []). This does NOT replace the
        # system-wide prev.libxml2 (2.15.1) -- it is only wired into
        # Alien::Libxml2 below.
        libxml2_2153 = prev.libxml2.overrideAttrs (old: rec {
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
      in
      {
        perl = prev.perl.override {
          overrides = pkgs: {
            # Rebuild Alien::Libxml2 against the perl-private 2.15.3
            # (swap the libxml2 buildInput; match on ".name" infix so
            # only the C libxml2 is hit, never "Alien-Libxml2" itself).
            AlienLibxml2 = prev.perl.pkgs.AlienLibxml2.overrideAttrs (old: {
              buildInputs = map
                (d: if prev.lib.hasInfix "libxml2-" (d.name or "")
                    then libxml2_2153 else d)
                (old.buildInputs or [ ]);
            });

            # XML::LibXML 2.0210 -> 2.0213, rebuilt against the Alien
            # above (so its XS links 2.15.3). The 2.13-test patch on
            # 2.0210 does not apply to 2.0213, hence patches = [].
            # NOTE: the derivation NAME stays "...-XML-LibXML-2.0210"
            # (buildPerlPackage fixes `name` before overrideAttrs runs),
            # but the built module is genuine 2.0213 source: $VERSION
            # reports 2.0213 and LibXML.so links libxml2 2.15.3.
            XMLLibXML = prev.perl.pkgs.XMLLibXML.overrideAttrs (old: {
              version = "2.0213";
              src = prev.fetchurl {
                url = "mirror://cpan/authors/id/T/TO/TODDR/XML-LibXML-2.0213.tar.gz";
                hash = "sha256-KvIcXWGsNOompfq/FbpaWEHmSPcYnbPjO28otUiYAqs=";
              };
              patches = [ ];
              buildInputs = map
                (d: if prev.lib.hasInfix "Alien-Libxml2" (d.name or "")
                    then pkgs.AlienLibxml2 else d)
                (old.buildInputs or [ ]);
            });
          };
        };
      })
  ];
}
