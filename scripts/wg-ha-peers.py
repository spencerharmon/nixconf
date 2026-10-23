#!/usr/bin/env python3
"""Manage the HA WireGuard server's peers (profiles/wireguard-ha.nix).

Source of truth: secrets/wg-ha-state.age — JSON, encrypted to the admin key ONLY
(chrome hosts can't read it). It holds the server key, every client's keys and
the client-facing settings, so client configs/QRs can be regenerated. From it,
`render` derives what the chrome hosts decrypt:
  secrets/wg-ha-wg0.conf.age   wg-quick config (server key + peers)
  secrets/wg-ha.env.age        WG_HA_UPNP_URL / WG_HA_SUBNET / WG_HA_PORT / WG_HA_LEASE
Recipients come from secrets/secrets.nix. Run from the repo root:

  nix run .#wg-ha-peers -- list
  nix run .#wg-ha-peers -- add <name>            # new peer, next free address
  nix run .#wg-ha-peers -- show <name> [--qr]    # client config (+ QR)
  nix run .#wg-ha-peers -- disable|enable|remove <name>
  nix run .#wg-ha-peers -- render                # re-derive host secrets
  nix run .#wg-ha-peers -- import-wg-easy --endpoint H:P --allowed-ips CIDRS \
        --upnp-url URL [--dns IP] [--lease S] < wg0.json

After any change: commit secrets/ and deploy the chrome hosts.
"""
import argparse, datetime, ipaddress, json, os, subprocess, sys, tempfile

SECRETS = "secrets"
STATE = f"{SECRETS}/wg-ha-state.age"
WG0 = f"{SECRETS}/wg-ha-wg0.conf.age"
ENV = f"{SECRETS}/wg-ha.env.age"
IDENTITY = os.path.expanduser(os.environ.get("AGE_IDENTITY", "~/.ssh/id_ed25519"))


def run(cmd, inp=None):
    return subprocess.run(cmd, input=inp, capture_output=True, text=True, check=True).stdout


def recipients(name):
    rules = json.loads(run(["nix", "eval", "--json", "--file", f"{SECRETS}/secrets.nix"]))
    if name not in rules:
        sys.exit(f"{name} is not declared in {SECRETS}/secrets.nix")
    return rules[name]["publicKeys"]


def encrypt(path, text):
    args = ["age"]
    for r in recipients(os.path.basename(path)):
        args += ["-r", r]
    out = path + ".tmp"
    subprocess.run(args + ["-o", out], input=text, text=True, check=True)
    os.replace(out, path)


def load():
    return json.loads(run(["age", "-d", "-i", IDENTITY, STATE]))


def save(st):
    encrypt(STATE, json.dumps(st, indent=2, sort_keys=True) + "\n")


def keypair():
    priv = run(["wg", "genkey"]).strip()
    return priv, run(["wg", "pubkey"], priv).strip()


def render(st):
    srv = st["server"]
    net = ipaddress.ip_network(st["subnet"])
    lines = ["[Interface]", f"PrivateKey = {srv['privateKey']}",
             f"Address = {srv['address']}/{net.prefixlen}", f"ListenPort = {st['port']}", ""]
    for c in st["clients"]:
        if not c.get("enabled", True):
            continue
        lines += [f"# {c['name']}", "[Peer]", f"PublicKey = {c['publicKey']}"]
        if c.get("preSharedKey"):
            lines.append(f"PresharedKey = {c['preSharedKey']}")
        lines += [f"AllowedIPs = {c['address']}/32", ""]
    encrypt(WG0, "\n".join(lines))
    encrypt(ENV, "".join(f"{k}={v}\n" for k, v in [
        ("WG_HA_UPNP_URL", st["upnpUrl"]), ("WG_HA_SUBNET", st["subnet"]),
        ("WG_HA_PORT", st["port"]), ("WG_HA_LEASE", st["lease"])]))
    print(f"rendered {WG0} ({sum(c.get('enabled', True) for c in st['clients'])} peers) and {ENV}")


def client_conf(st, c):
    if not c.get("privateKey"):
        sys.exit(f"{c['name']}: private key not held here (client-generated); config is on the device")
    lines = ["[Interface]", f"PrivateKey = {c['privateKey']}", f"Address = {c['address']}/32"]
    if st.get("dns"):
        lines.append(f"DNS = {st['dns']}")
    lines += ["", "[Peer]", f"PublicKey = {st['server']['publicKey']}"]
    if c.get("preSharedKey"):
        lines.append(f"PresharedKey = {c['preSharedKey']}")
    lines += [f"AllowedIPs = {st['clientAllowedIPs']}", f"Endpoint = {st['endpoint']}"]
    if st.get("persistentKeepalive"):
        lines.append(f"PersistentKeepalive = {st['persistentKeepalive']}")
    return "\n".join(lines) + "\n"


def find(st, name):
    for c in st["clients"]:
        if c["name"] == name:
            return c
    sys.exit(f"no peer named {name}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list"); sub.add_parser("render")
    a = sub.add_parser("add"); a.add_argument("name")
    s = sub.add_parser("show"); s.add_argument("name"); s.add_argument("--qr", action="store_true")
    for n in ("disable", "enable", "remove"):
        sub.add_parser(n).add_argument("name")
    im = sub.add_parser("import-wg-easy")
    im.add_argument("--endpoint", required=True); im.add_argument("--allowed-ips", required=True)
    im.add_argument("--upnp-url", required=True); im.add_argument("--dns", default="1.1.1.1")
    im.add_argument("--lease", type=int, default=120); im.add_argument("--keepalive", type=int, default=25)
    args = ap.parse_args()

    if args.cmd == "import-wg-easy":
        if os.path.exists(STATE):
            sys.exit(f"{STATE} exists; refusing to overwrite")
        w = json.load(sys.stdin)
        addr = w["server"]["address"]
        st = {
            "server": {k: w["server"][k] for k in ("privateKey", "publicKey")} | {"address": addr},
            "subnet": str(ipaddress.ip_network(f"{addr}/24", strict=False)),
            "port": int(args.endpoint.rsplit(":", 1)[1]), "lease": args.lease,
            "endpoint": args.endpoint, "clientAllowedIPs": args.allowed_ips, "dns": args.dns,
            "persistentKeepalive": args.keepalive, "upnpUrl": args.upnp_url,
            "clients": [{k: c.get(k) for k in ("name", "address", "privateKey", "publicKey",
                                                 "preSharedKey", "enabled", "createdAt")}
                        for c in sorted(w["clients"].values(), key=lambda c: ipaddress.ip_address(c["address"]))],
        }
        save(st); render(st)
        print(f"imported server + {len(st['clients'])} peers from wg-easy")
        return

    st = load()
    if args.cmd == "list":
        print(f"server {st['server']['address']} subnet {st['subnet']} endpoint {st['endpoint']}")
        for c in st["clients"]:
            print(f"  {c['address']:<12} {c['name']:<20} {'enabled' if c.get('enabled', True) else 'DISABLED':<9}"
                  f" psk={'yes' if c.get('preSharedKey') else 'no'} privkey={'held' if c.get('privateKey') else 'device-only'}")
    elif args.cmd == "render":
        render(st)
    elif args.cmd == "add":
        if any(c["name"] == args.name for c in st["clients"]):
            sys.exit(f"{args.name} exists")
        net = ipaddress.ip_network(st["subnet"])
        used = {st["server"]["address"]} | {c["address"] for c in st["clients"]}
        addr = next(str(h) for h in net.hosts() if str(h) not in used)
        priv, pub = keypair()
        st["clients"].append({"name": args.name, "address": addr, "privateKey": priv, "publicKey": pub,
                              "preSharedKey": run(["wg", "genpsk"]).strip(), "enabled": True,
                              "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat()})
        save(st); render(st)
        print(f"added {args.name} at {addr}; `show {args.name} --qr` for the client config")
    elif args.cmd == "show":
        conf = client_conf(st, find(st, args.name))
        print(conf)
        if args.qr:
            subprocess.run(["qrencode", "-t", "ansiutf8"], input=conf, text=True, check=True)
    elif args.cmd in ("disable", "enable"):
        find(st, args.name)["enabled"] = args.cmd == "enable"
        save(st); render(st)
    elif args.cmd == "remove":
        st["clients"] = [c for c in st["clients"] if c["name"] != args.name]
        save(st); render(st)


if __name__ == "__main__":
    main()
