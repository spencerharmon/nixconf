#!/usr/bin/env python3
"""Independent, read-only host observation and fail-closed live metric verification.

Install `wg-ha-health-observe` as a wrapper running this file with `observe`,
WG_HA_ENV_FILE set to the native router env, and the required tools on PATH.
Only that router env (URL/port/subnet), not the WireGuard config, is sourced.
`live` requires positionally paired WG_HA_LIVE_HOSTS and WG_HA_EXPECTED_NODES.
"""

import decimal
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import time


class Invalid(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Invalid(message)


def now():
    return int(os.environ.get("WG_HA_NOW", time.time()))


def command(args, seconds=5):
    # Kill the process group on timeout, including ssh/bash children. Never relay
    # stderr or command output on failure (the env loader must not leak values).
    with subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          start_new_session=True) as proc:
        try:
            output, _ = proc.communicate(timeout=seconds)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
            raise Invalid("read timed out") from None
        require(proc.returncode == 0, "read failed")
    require(len(output) <= 8 * 1024 * 1024, "oversized response")
    return output.decode("utf-8", errors="strict")


def observe():
    started = now()
    run = Path(os.environ.get("WG_HA_RUN_DIR", "/run/wg-ha"))
    state = Path(os.environ.get("WG_HA_STATE_DIR", "/var/lib/wg-ha"))
    env_file = os.environ.get("WG_HA_ENV_FILE")
    require(env_file, "native router env not configured")
    # Source once, in isolation, with native override precedence. All source
    # output/errors are suppressed; a failed source is not an empty observation.
    values = command([
        "bash", "-c", '''set -eu
unset WG_HA_UPNP_URL WG_HA_PORT WG_HA_SUBNET
. "$1" >/dev/null 2>&1
if [ -e "$2" ]; then . "$2" >/dev/null 2>&1; fi
printf '%s\\0%s\\0%s' "${WG_HA_UPNP_URL:?}" "${WG_HA_PORT:-51820}" "${WG_HA_SUBNET:?}"
''', "router-env", env_file, str(state / "override.env")]).split("\0")
    require(len(values) == 3, "invalid router env")
    url, port, subnet = values
    require(re.fullmatch(r"https?://[^\s]+", url), "invalid router URL")
    require(port.isdecimal() and 0 < int(port) <= 65535, "invalid router port")
    ipaddress.IPv4Network(subnet)
    port = int(port)
    node = command(["hostname"]).strip()
    role = (run / "vrrp-state").read_text().strip()
    require(role in ("MASTER", "BACKUP", "FAULT", "STOP"), "invalid role")
    # stat the directory first: an inaccessible state directory is not disarmed.
    list(state.iterdir())
    armed = int((state / "armed").exists())
    routes = json.loads(command(["ip", "-j", "-4", "route", "get", "1.1.1.1"]))
    require(isinstance(routes, list) and len(routes) == 1, "invalid route response")
    own = str(ipaddress.IPv4Address(routes[0]["prefsrc"]))

    lease_time = now()
    listing = command(["upnpc", "-u", url, "-l"])
    # Parse the actual router table, not the daemon's upnp-holder cache. A
    # recognized table header is required even if there are no mappings.
    require(re.search(r"(?m)^\s*i\s+protocol\s+exPort->inAddr:inPort\s+description\s+remoteHost\s+leaseTime\s*$",
                      listing), "router table missing")
    mappings = []
    for line in listing.splitlines():
        if not re.match(r"^\s*\d+\s", line):
            continue
        fields = shlex.split(line)
        require(len(fields) == 6 and fields[0].isdecimal()
                and fields[1] in ("UDP", "TCP"), "malformed router row")
        match = re.fullmatch(r"(\d+)->([0-9.]+):(\d+)", fields[2])
        require(match and fields[5].isdecimal(), "malformed router mapping")
        external, holder, internal = match.groups()
        holder = str(ipaddress.IPv4Address(holder))
        require(0 < int(external) <= 65535 and 0 < int(internal) <= 65535,
                "invalid mapping port")
        if fields[1] == "UDP" and int(external) == port:
            require(int(internal) == port and fields[4] == "", "wrong router mapping")
            mappings.append((holder, int(fields[5])))
    require(len(mappings) <= 1, "ambiguous router mapping")
    holder, remaining = mappings[0] if mappings else (None, None)

    interfaces = command(["wg", "show", "interfaces"]).split()
    require(len(interfaces) == len(set(interfaces))
            and all(re.fullmatch(r"[A-Za-z0-9_.-]{1,15}", i) for i in interfaces),
            "malformed interface list")
    present = int("wg0" in interfaces)
    peers = {}
    if present:
        for line in command(["wg", "show", "wg0", "latest-handshakes"]).splitlines():
            fields = line.split()
            require(len(fields) == 2 and re.fullmatch(r"[A-Za-z0-9+/]{43}=", fields[0])
                    and re.fullmatch(r"0|[1-9][0-9]*", fields[1]), "malformed handshake")
            identity = hashlib.sha256(fields[0].encode()).hexdigest()[:12]
            stamp = int(fields[1])
            require(identity not in peers and stamp <= now(), "invalid handshake identity/time")
            peers[identity] = stamp
    return dict(node=node, timestamp=started, role=role, armed=armed, own=own,
                port=port, override=int((state / "override.env").exists()),
                interface=present, peers=peers, holder=holder, remaining=remaining,
                lease_timestamp=lease_time)


def metrics(body, node):
    samples = {}
    for line in body.splitlines():
        if not line.startswith("wg_ha_"):
            continue
        # node_exporter re-renders textfile values with Go's %g formatting, so a
        # Unix timestamp is served as e.g. 1.794042566e+09. Accept plain or
        # exponent notation but require an exact non-negative integer.
        match = re.fullmatch(r'(wg_ha_[a-z_]+)\{([^{}]+)\} ([0-9]+(?:\.[0-9]+)?(?:e\+?[0-9]+)?)', line)
        require(match, "malformed wg_ha sample")
        name, labels, value = match.groups()
        value = decimal.Decimal(value)
        require(value == value.to_integral_value() and value < 2 ** 53, "non-integer wg_ha sample")
        pairs = re.findall(r'([a-z_]+)="([A-Za-z0-9_.-]+)"', labels)
        require(",".join(f'{k}="{v}"' for k, v in pairs) == labels
                and len(dict(pairs)) == len(pairs), "invalid metric labels")
        labels = dict(pairs)
        require(labels.pop("node", None) == node
                and labels.pop("cluster", None) == "chrome", "wrong metric node/cluster")
        key = (name, tuple(sorted(labels.items())))
        require(key not in samples, "duplicate sample")
        samples[key] = int(value)
    require(samples, "no wg_ha metrics")
    return samples


def validate(body, node, observed):
    samples = metrics(body, node)

    def take(name, value=None, **labels):
        key = ("wg_ha_" + name, tuple(sorted(labels.items())))
        require(key in samples, "missing " + name)
        actual = samples.pop(key)
        require(value is None or value == actual, "mismatched " + name)
        return actual

    stamp = take("observation_timestamp_seconds")
    require(0 <= now() - stamp <= 120, "stale/future metrics")
    take("collector_errors", 0)
    take("role_observed", 1)
    for role in ("MASTER", "BACKUP", "FAULT", "STOP"):
        take("role", int(observed["role"] == role), state=role)
    take("armed", observed["armed"])
    take("config_port", observed["port"])
    take("config_override_present", observed["override"])
    take("interface_present", observed["interface"])
    take("wg_observed", observed["interface"])
    take("upnp_lease_observed", 1)
    take("upnp_lease_present", int(observed["holder"] is not None))
    take("upnp_lease_owned", int(observed["holder"] == observed["own"]))
    if observed["holder"] is not None:
        remaining = take("upnp_lease_remaining_seconds")
        # A refreshed router lease need not have the same remaining seconds as
        # the previous collection. Both must still be valid at verification time.
        require(remaining > now() - stamp, "exported lease expired")
        require(observed["remaining"] > now() - observed["lease_timestamp"],
                "router lease expired")
    for peer, timestamp in observed["peers"].items():
        require(timestamp <= stamp, "handshake newer than exported observation")
        take("peer_last_handshake_timestamp_seconds", timestamp, peer=peer)
        take("peer_never_handshaken", int(timestamp == 0), peer=peer)
        take("peer_healthy", int(timestamp > 0 and stamp - timestamp <= 180), peer=peer)
        if timestamp:
            take("peer_handshake_age_seconds", stamp - timestamp, peer=peer)
    require(not samples, "unexpected metric/peer series")


def live():
    hosts = os.environ.get("WG_HA_LIVE_HOSTS", "").split()
    nodes = os.environ.get("WG_HA_EXPECTED_NODES", "").split()
    require(0 < len(hosts) == len(nodes) <= 32, "explicit matching host/node inventory required")
    require(len(set(hosts)) == len(hosts) and len(set(nodes)) == len(nodes), "duplicate inventory identity")
    require(all(re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", n) for n in nodes), "invalid expected node")
    require(all(re.fullmatch(r"(?:[A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9][A-Za-z0-9.-]*", h)
                for h in hosts), "invalid SSH target")
    observations = []
    for host, node in zip(hosts, nodes):
        def ssh(*args):
            return command(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                            host, *args], seconds=45)

        try:
            textfile = ssh("cat", "/var/lib/wg-ha-metrics/wg_ha.prom")
            require(ssh("systemctl", "is-active", "wg-ha-health.timer").strip() == "active",
                    "collector timer inactive")
            observed = json.loads(ssh("sudo", "-n", "wg-ha-health-observe"))
            require(observed["node"] == node, "wrong observation node")
            require(0 <= now() - observed["timestamp"] <= 120, "stale/future host observation")
            require(observed["timestamp"] <= observed["lease_timestamp"] <= now(),
                    "invalid router observation time")
            require(observed["role"] in ("MASTER", "BACKUP", "FAULT", "STOP")
                    and observed["armed"] in (0, 1) and observed["interface"] in (0, 1)
                    and isinstance(observed["peers"], dict), "malformed host observation")
            # Retain the successful body on BOTH transports. A successful but
            # wrong/stale direct response is a failure, not a reason to fall back.
            try:
                scrape = command(["curl", "-fsS", "--max-time", "5",
                                  f"http://{host.rsplit('@', 1)[-1]}:9101/metrics"], seconds=7)
            except Invalid:
                scrape = ssh("curl", "-fsS", "--max-time", "5", "http://127.0.0.1:9101/metrics")
            validate(textfile, node, observed)
            validate(scrape, node, observed)
            observations.append(observed)
            print(f"ok - {node}: textfile and scrape match independent observation")
        except (Invalid, OSError, ValueError, KeyError, TypeError) as error:
            raise Invalid(f"{node}: live verification failed ({type(error).__name__})") from None
    leaders = [o for o in observations if o["role"] == "MASTER"]
    require(len(leaders) == 1, "fleet must have exactly one MASTER")
    leader = leaders[0]
    require(leader["armed"] == 1 and leader["interface"] == 1, "leader not armed/up")
    for observed in observations:
        require(observed["holder"] == leader["own"], "router mapping does not target leader")
        require(observed["remaining"] > now() - observed["lease_timestamp"], "router lease expired")
        require(0 <= now() - observed["timestamp"] <= 120, "fleet observation aged out")
    print("verdict=ok (independent read-only live verification)")


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 2 and sys.argv[1] in ("observe", "live"), "usage: observe | live")
        if sys.argv[1] == "observe":
            print(json.dumps(observe(), sort_keys=True))
        else:
            live()
    except (Invalid, OSError, ValueError, KeyError, TypeError) as error:
        # Only our own diagnostics are safe: parser/OS exceptions can include
        # raw response data or env paths. Do not print those exceptions.
        print("FAIL - " + (str(error) if isinstance(error, Invalid) else "invalid/unreadable observation"),
              file=sys.stderr)
        sys.exit(1)
