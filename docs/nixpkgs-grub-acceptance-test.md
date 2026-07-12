# nixpkgs-grub-acceptance-test — RESULT: PASS

Acceptance gate for dropping `profiles/libxml2-grub-fix.nix`. Proves that the target
rev picked by `nixpkgs-pick-target-rev` fixes the `install-grub.pl` / `XML::LibXML`
XPath grub SIGSEGV **without** the overlay. Scratch build only — no flake.lock bump,
no overlay removal landed here (that is `nixpkgs-bump-drop-overlay`, gated on this).

## Target rev under test
`nixpkgs` rev **`e7a3ca8092b61ff85b6a45bf863ea2b2d6a661b3`** (nixos-unstable head
2026-07-11), selected + version-verified by `nixpkgs-pick-target-rev`.

## What was built (overlay NOT applied)
Scratch build of the yoga-sd-0 boot-loader install path on the target rev, with
`./profiles/libxml2-grub-fix.nix` removed from the `yoga-sd-0` module list (change
made only in a throwaway working copy, reverted — NOT committed):

```
nix build --no-link \
  --override-input nixpkgs github:nixos/nixpkgs/e7a3ca8092b61ff85b6a45bf863ea2b2d6a661b3 \
  "path:.#nixosConfigurations.yoga-sd-0.config.system.build.installBootLoader"
# => /nix/store/d1hav7n54483g0ql9i9knc81z0cqyljr-install-grub.sh
```

Built cleanly. The generated `install-grub.sh` invokes:
```
.../perl-5.42.0-env/bin/perl  .../install-grub.pl  .../grub-config.xml  "$@"
```

## Toolchain pair as delivered by the target rev (no overlay)
The `perl.withPackages [... XMLLibXML ...]` env in the built `installBootLoader`
(`/nix/store/v8d9gvkkxvr1dp2aya53gqpi1aphr0d0-perl-5.42.0-env`):

- `XML::LibXML $VERSION` = **2.0213**
- `XML::LibXML::LIBXML_VERSION()` (compile-time)   = **21503** (libxml2 2.15.3)
- `XML::LibXML::LIBXML_RUNTIME_VERSION()`          = **21503** (libxml2 2.15.3)
- `auto/XML/LibXML/LibXML.so` links `libxml2.so.16` =>
  `/nix/store/xdj75qn68sq2sba1w3dbmhi7xkzqhaw7-libxml2-2.15.3/lib/libxml2.so.16`
  (`-> libxml2.so.16.1.3`).

Compile-time and runtime libxml2 versions **MATCH** (both 21503). This is the exact
known-good pair (`libxml2 2.15.3` + `XML::LibXML 2.0213`) that the overlay was
forcing — now delivered natively by the target rev with **no overlay**. The broken
pin `d233902` shipped the ABI-mismatched `libxml2 2.15.1` (`libxml2.so.16.1.1`) +
`XML::LibXML 2.0210`, which SIGSEGV'd at the `xmlCheckVersion` region (`+0x4c7a0`).

## Full install-grub run through the crash locus
The SIGSEGV occurred while `install-grub.pl` drove `XML::LibXML` XPath over the
generated grub-config XML. `install-grub.pl` does `XML::LibXML->load_xml(...)` (line
22) then ~30 `get()`/`getList()` `findvalue`/`findnodes` XPath queries (lines 24–98)
— the exact crash region — BEFORE it prints `updating GRUB 2 menu...` (line 100) and
first touches the disk at `make_path("$bootPath/grub")` (line 102).

Ran the actual built `install-grub.pl` against the actual built grub-config XML:
```
.../perl-5.42.0-env/bin/perl \
  .../install-grub.pl \
  /nix/store/vrvn8hkzcx33fq94zscc2scfxzm831jh-grub-config.xml \
  /run/current-system
```
Output:
```
updating GRUB 2 menu...
mkdir /boot/grub: Permission denied at .../install-grub.pl line 102.
```
Perl exit code **13** — a normal `die` at the first disk write (unprivileged, no
target device), **NOT** a signal. No SIGSEGV: exit was < 128, and the run printed
`updating GRUB 2 menu...`, proving control passed the entire `load_xml` + all
lines 24–98 XPath block that previously crashed. With the broken pair this run
terminated with SIGSEGV (signal 11 / exit 139) inside `libxml2.so.16` before ever
reaching line 102.

## Verdict
**PASS.** On target rev `e7a3ca8…`, without `profiles/libxml2-grub-fix.nix`, the
`install-grub.pl` / `XML::LibXML` grub SIGSEGV is gone: the toolchain is the matched
`libxml2 2.15.3` + `XML::LibXML 2.0213` pair and the full install-grub XPath phase
executes cleanly. The overlay is redundant on this rev and may be dropped by
`nixpkgs-bump-drop-overlay`.

## Notes / limits
- Scratch only. No `flake.lock` bump and no overlay removal landed here.
- The final `grub-install` to a real device needs root + the yoga SD and is out of
  scope (and unavailable headless); it runs strictly AFTER the XML crash locus, so it
  does not affect this SIGSEGV verdict.
