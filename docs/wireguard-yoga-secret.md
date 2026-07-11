# wireguard-yoga-secret

Real WireGuard keypair for the `yoga` (yoga-sd-0) peer, stored as agenix secret
`secrets/wireguard-yoga.age` (private key only), registered in
`secrets/secrets.nix` with recipients `spencer` + the `yoga` host SSH key —
mirroring the `wifi-yoga.age` pattern.

The keypair is real cryptographic material generated locally with
`wg genkey` / `wg pubkey`. The private key is never committed in cleartext; the
public key is published in the beehive change doc
(`docs/bee-wireguard-yoga-secret-wireguard-yoga-secret.md`) for dependent tasks
(here and the linked `flux` plan) to consume without re-deriving.

Consume like `profiles/wifi-yoga.nix`:
`age.secrets.wireguard-yoga = { file = ../secrets/wireguard-yoga.age; ... }`.
