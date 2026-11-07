#!/usr/bin/env python3
"""Fail-closed fleet and live validation; never handles WireGuard configuration."""
import os
import re
import sys
import time


def now():
    return int(os.environ.get("WG_HA_NOW", time.time()))


def metrics(path):
    samples = {}
    nodes = set()
    with open(path) as stream:
        for line in stream:
            if not line.startswith("wg_ha_"):
                continue
            m = re.fullmatch(r'(wg_ha_\w+)\{([^}]+)\} ([0-9]+)\n?', line)
            if not m:
                raise ValueError("malformed sample")
            labels = dict(re.findall(r'(\w+)="([A-Za-z0-9_.:-]+)"', m[2]))
            if labels.get("cluster") != "chrome" or not labels.get("node"):
                raise ValueError("invalid identity")
            if ",".join(f'{k}="{v}"' for k, v in labels.items()) != m[2]:
                raise ValueError("invalid labels")
            nodes.add(labels["node"])
            key = (m[1], labels.get("state"), labels.get("peer"))
            if key in samples:
                raise ValueError("duplicate sample")
            samples[key] = int(m[3])
    if len(nodes) != 1:
        raise ValueError("missing or mixed node identity")
    return nodes.pop(), samples


def value(samples, name, state=None, peer=None):
    return samples[("wg_ha_" + name, state, peer)]


def validate(samples, t):
    age = t - value(samples, "observation_timestamp_seconds")
    if not 0 <= age <= int(os.environ.get("WG_HA_MAX_AGE", "120")):
        raise ValueError("stale or future observation")
    for metric in ("role_observed", "upnp_lease_observed"):
        if value(samples, metric) != 1:
            raise ValueError("unobserved " + metric)
    roles = {s: value(samples, "role", state=s) for s in ("MASTER", "BACKUP", "FAULT", "STOP")}
    if set(roles.values()) - {0, 1} or sum(roles.values()) != 1:
        raise ValueError("invalid role vector")
    present = value(samples, "upnp_lease_present")
    owned = value(samples, "upnp_lease_owned")
    if present not in (0, 1) or owned not in (0, 1) or owned > present:
        raise ValueError("invalid lease flags")
    valid_lease = present == 1 and value(samples, "upnp_lease_remaining_seconds") > age
    return roles["MASTER"] == 1, owned == 1 and valid_lease


def evaluate(paths):
    expected = os.environ.get("WG_HA_EXPECTED_NODES", "").split()
    if not expected or len(set(expected)) != len(expected):
        raise ValueError("WG_HA_EXPECTED_NODES must name unique expected nodes")
    seen = set()
    leaders = 0
    degraded = False
    lease_bad = False
    for path in paths:
        try:
            node, samples = metrics(path)
            if node in seen or node not in expected:
                raise ValueError("duplicate or unexpected node")
            seen.add(node)
            master, leased = validate(samples, now())
            leaders += master
            if value(samples, "collector_errors") != 0:
                degraded = True
            interface = value(samples, "interface_present")
            wg = value(samples, "wg_observed")
            if interface not in (0, 1) or wg != interface:
                degraded = True
            if master:
                healthy = (leased and value(samples, "wg_observed") == 1
                           and value(samples, "interface_present") == 1
                           and value(samples, "collector_errors") == 0)
                lease_bad |= not healthy
                print(f"node={node} status={'leader' if healthy else 'leader_without_lease'}")
            else:
                lease_bad |= leased
                print(f"node={node} status=follower")
        except (OSError, ValueError, KeyError) as error:
            degraded = True
            print(f"node_file={path} status=invalid reason={error}")
    # A positively observed split election is useful even if the router fences
    # all but one MASTER. Unknown/missing identities can never produce 'ok'.
    if leaders > 1:
        verdict, rc = "multiple_leaders", 5
    elif degraded or seen != set(expected):
        verdict, rc = "degraded_observation", 3
    elif leaders == 0:
        verdict, rc = "no_leader", 4
    elif lease_bad:
        verdict, rc = "degraded_observation", 3
    else:
        verdict, rc = "ok", 0
    print("verdict=" + verdict)
    return rc


if __name__ == "__main__":
    try:
        mode = sys.argv[1]
        if mode == "evaluate":
            sys.exit(evaluate(sys.argv[2:]))
        else:
            raise ValueError("unknown validation mode")
    except (OSError, ValueError, KeyError, IndexError):
        # Never echo command arguments, env, or raw observations on failure.
        print("health validation failed: missing, inconsistent or invalid observation", file=sys.stderr)
        sys.exit(3)
