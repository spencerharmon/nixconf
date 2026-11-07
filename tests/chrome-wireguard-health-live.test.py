#!/usr/bin/env python3
"""Read-only live probe regressions; no network or elevated privileges needed."""

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "live", Path(__file__).resolve().parents[1] / "scripts/wg-ha-health-live.py")
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)
NOW = 1800000000
KEY = "A" * 43 + "="
PEER = hashlib.sha256(KEY.encode()).hexdigest()[:12]


def observation(node, master):
    return dict(node=node, timestamp=NOW, role="MASTER" if master else "BACKUP",
                armed=1, own="192.0.2.10" if master else "192.0.2.11",
                port=51820, override=0, interface=int(master),
                peers={PEER: NOW - 30} if master else {}, holder="192.0.2.10",
                remaining=97, lease_timestamp=NOW)


def metrics(o):
    values = dict(observation_timestamp_seconds=NOW, collector_errors=0,
                  role_observed=1, armed=o["armed"], config_port=o["port"],
                  config_override_present=o["override"], interface_present=o["interface"],
                  wg_observed=o["interface"], upnp_lease_observed=1,
                  upnp_lease_present=1, upnp_lease_owned=int(o["holder"] == o["own"]),
                  upnp_lease_remaining_seconds=o["remaining"])
    labels = f'cluster="chrome",node="{o["node"]}"'
    lines = [f"wg_ha_{k}{{{labels}}} {v}" for k, v in values.items()]
    for role in ("MASTER", "BACKUP", "FAULT", "STOP"):
        lines.append(f'wg_ha_role{{{labels},state="{role}"}} {int(o["role"] == role)}')
    for peer, timestamp in o["peers"].items():
        values = dict(peer_last_handshake_timestamp_seconds=timestamp,
                      peer_never_handshaken=int(timestamp == 0),
                      peer_healthy=int(timestamp > 0 and NOW - timestamp <= 180))
        if timestamp:
            values["peer_handshake_age_seconds"] = NOW - timestamp
        lines.extend(f'wg_ha_{k}{{{labels},peer="{peer}"}} {v}' for k, v in values.items())
    return "\n".join(lines) + "\n"


class LiveTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, WG_HA_NOW=str(NOW),
                              WG_HA_LIVE_HOSTS="host-a host-b", WG_HA_EXPECTED_NODES="a b")
        self.env.start()
        self.addCleanup(self.env.stop)
        self.observed = {"a": observation("a", True), "b": observation("b", False)}
        self.text = {n: metrics(o) for n, o in self.observed.items()}
        self.scrapes = self.text.copy()
        self.fallback = False
        self.timer = "active\n"
        self.calls = []

    def command(self, args, seconds=5):
        self.calls.append(args)
        if args[0] == "curl":
            if self.fallback:
                raise live.Invalid("direct unavailable")
            return self.scrapes["a" if "host-a" in args[-1] else "b"]
        self.assertEqual(args[:5], ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"])
        node = {"host-a": "a", "host-b": "b"}[args[5]]
        cmd = args[6:]
        if cmd == ["cat", "/var/lib/wg-ha-metrics/wg_ha.prom"]:
            return self.text[node]
        if cmd == ["systemctl", "is-active", "wg-ha-health.timer"]:
            return self.timer
        if cmd == ["sudo", "-n", "wg-ha-health-observe"]:
            return json.dumps(self.observed[node])
        self.assertEqual(cmd, ["curl", "-fsS", "--max-time", "5", "http://127.0.0.1:9101/metrics"])
        return self.scrapes[node]

    def run_live(self):
        with patch.object(live, "command", self.command), contextlib.redirect_stdout(io.StringIO()):
            live.live()

    def test_direct_and_ssh_fallback_validate_bodies(self):
        self.run_live()
        self.fallback = True
        self.run_live()
        self.scrapes["a"] = "node_exporter_build_info 1\n"
        with self.assertRaises(live.Invalid):
            self.run_live()

    def test_real_shell_live_entrypoint(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            fake = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
data = json.loads(Path(os.environ["FIXTURE"]).read_text())
args = sys.argv[1:]
if Path(sys.argv[0]).name == "curl":
    if data["fallback"]: sys.exit(7)
    node = "a" if "host-a" in args[-1] else "b"
    print(data["scrapes"][node]); sys.exit(0)
node = {"host-a":"a", "host-b":"b"}[args[4]]
cmd = args[5:]
if cmd == ["cat", "/var/lib/wg-ha-metrics/wg_ha.prom"]:
    print(data["text"][node])
elif cmd == ["systemctl", "is-active", "wg-ha-health.timer"]:
    print("active")
elif cmd == ["sudo", "-n", "wg-ha-health-observe"]:
    if data["reads_fail"]: sys.exit(1)
    print(json.dumps(data["observed"][node]))
elif cmd == ["curl", "-fsS", "--max-time", "5", "http://127.0.0.1:9101/metrics"]:
    print(data["scrapes"][node])
else: sys.exit(9)
'''
            for name in ("ssh", "curl"):
                path = temp / name
                path.write_text(fake)
                path.chmod(0o755)
            fixture = temp / "fixture.json"
            baseline = dict(text=self.text, scrapes=self.scrapes, observed=self.observed,
                            fallback=False, reads_fail=False)

            def invoke(data, success):
                fixture.write_text(json.dumps(data))
                env = dict(os.environ, PATH=directory + ":" + os.environ["PATH"],
                           FIXTURE=str(fixture))
                result = subprocess.run([str(root / "tests/chrome-wireguard-health-exporter.test.sh"),
                                         "--live"], env=env, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)

            invoke(baseline, True)
            invoke(dict(baseline, fallback=True), True)
            invoke(dict(baseline, reads_fail=True), False)
            for change in ("peer", "stamp", "expired", "scrape", "second", "stale"):
                data = copy.deepcopy(baseline)
                if change == "peer":
                    data["observed"]["a"]["peers"] = {"f" * 12: NOW - 30}
                elif change == "stamp":
                    data["observed"]["a"]["peers"][PEER] = NOW - 31
                elif change == "expired":
                    data["observed"]["a"]["remaining"] = 0
                elif change == "scrape":
                    data["scrapes"]["a"] = ""
                elif change == "second":
                    data["scrapes"]["b"] = data["scrapes"]["a"]
                else:
                    data["scrapes"]["a"] = data["scrapes"]["a"].replace(str(NOW), str(NOW - 121))
                with self.subTest(change=change):
                    invoke(data, False)

    def test_wrong_successful_direct_body_does_not_fall_back(self):
        self.scrapes["a"] = self.text["b"]
        with self.assertRaises(live.Invalid):
            self.run_live()
        self.assertFalse(any(args[0] == "ssh" and "curl" in args for args in self.calls))

    def test_rejects_bad_metric_bodies_on_both_sources(self):
        original = self.text["a"]
        for body in ("", original + original, original.replace(str(NOW), str(NOW - 121)),
                     original.replace(str(NOW), str(NOW + 1)),
                     original.replace('node="a"', 'node="other"'),
                     original.replace(PEER, "f" * 12),
                     original.replace("} 51820", "} 51821"),
                     original.replace("wg_ha_config_override_present", "wg_ha_unknown")):
            for source in (self.text, self.scrapes):
                with self.subTest(body=body[:60], source="text" if source is self.text else "scrape"):
                    source["a"] = body
                    with self.assertRaises(live.Invalid):
                        self.run_live()
                    source["a"] = original

    def test_independent_observation_disagreements(self):
        original = copy.deepcopy(self.observed["a"])
        for key, value in (("role", "BACKUP"), ("armed", 0), ("interface", 0),
                           ("node", "other"), ("timestamp", NOW - 121),
                           ("port", 51821), ("override", 1), ("peers", {}),
                           ("holder", "192.0.2.99"), ("remaining", 0)):
            with self.subTest(key=key):
                self.observed["a"] = dict(original, **{key: value})
                with self.assertRaises(live.Invalid):
                    self.run_live()
        self.observed["a"] = original
        self.timer = "inactive\n"
        with self.assertRaises(live.Invalid):
            self.run_live()

    def test_inventory_and_split_leader(self):
        for hosts, nodes in (("", ""), ("host-a", "a b"), ("host-a host-a", "a b"),
                             ("host-a host-b", "a a"), ("-option", "a")):
            with patch.dict(os.environ, WG_HA_LIVE_HOSTS=hosts, WG_HA_EXPECTED_NODES=nodes):
                with self.assertRaises(live.Invalid):
                    self.run_live()
        self.observed["b"] = observation("b", True)
        self.text["b"] = self.scrapes["b"] = metrics(self.observed["b"])
        with self.assertRaises(live.Invalid):
            self.run_live()

    def test_never_handshaken_and_stale_peers_are_observed_not_fabricated(self):
        for timestamp in (0, NOW - 900):
            self.observed["a"]["peers"][PEER] = timestamp
            self.text["a"] = self.scrapes["a"] = metrics(self.observed["a"])
            self.run_live()

    def test_observer_sources_native_override_and_only_reads_targeted_state(self):
        real_command = live.command
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "vrrp-state").write_text("MASTER\n")
            (root / "armed").touch()
            (root / "env").write_text("WG_HA_UPNP_URL=http://192.0.2.1/rootDesc.xml\n"
                                      "WG_HA_PORT=51820\nWG_HA_SUBNET=198.51.100.0/24\n")
            (root / "override.env").write_text("WG_HA_PORT=51821\n")
            replies = {
                ("hostname",): "a\n",
                ("ip", "-j", "-4", "route", "get", "1.1.1.1"): '[{"prefsrc":"192.0.2.10"}]',
                ("upnpc", "-u", "http://192.0.2.1/rootDesc.xml", "-l"):
                    " i protocol exPort->inAddr:inPort description remoteHost leaseTime\n"
                    " 0 UDP 51821->192.0.2.10:51821 'wg-ha' '' 97\n",
                ("wg", "show", "interfaces"): "wg0\n",
                ("wg", "show", "wg0", "latest-handshakes"): f"{KEY}\t{NOW - 30}\n",
            }

            def command(args, seconds=5):
                return real_command(args, seconds) if args[0] == "bash" else replies[tuple(args)]

            with patch.dict(os.environ, WG_HA_RUN_DIR=directory, WG_HA_STATE_DIR=directory,
                            WG_HA_ENV_FILE=str(root / "env")), patch.object(live, "command", command):
                result = live.observe()
                self.assertEqual(result, dict(observation("a", True), port=51821, override=1))
                self.assertNotIn(KEY, json.dumps(result))
                router = ("upnpc", "-u", "http://192.0.2.1/rootDesc.xml", "-l")
                original = replies[router]
                replies[router] = original.replace(":51821", ":9999")
                with self.assertRaises(live.Invalid):
                    live.observe()
                replies[router] = original
                for failing in ("upnpc", "wg"):
                    def failed_command(args, seconds=5):
                        if args[0] == failing:
                            raise live.Invalid("read failed or timed out")
                        return command(args, seconds)
                    with patch.object(live, "command", failed_command):
                        with self.assertRaises(live.Invalid):
                            live.observe()
                (root / "override.env").write_text("false\n")
                with self.assertRaises(live.Invalid):
                    live.observe()


if __name__ == "__main__":
    unittest.main()
