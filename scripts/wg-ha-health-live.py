#!/usr/bin/env python3
"""Bounded read-only host comparison, not a rollout or ingestion check."""
import hashlib
from decimal import Decimal, InvalidOperation
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time


def command(args, timeout=5):
    return subprocess.run(args, check=True, timeout=timeout, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout


def snapshot():
    # Independent host reads. Never open wg0.conf, source env, or use a wg dump.
    settings = {'WG_HA_PORT': '51820'}
    paths = [Path(os.environ['WG_HA_ENV_FILE']), Path('/var/lib/wg-ha/override.env')]
    for path in paths:
        if path == paths[1] and not path.exists():
            continue
        for line in path.read_text().splitlines():
            if not re.match(r'^\s*(export\s+)?WG_HA_(PORT|UPNP_URL)\b', line):
                continue
            words = shlex.split(line, comments=True)
            if words and words[0] == 'export':
                words.pop(0)
            if len(words) != 1 or '=' not in words[0] or re.search(r'[$`]', words[0]):
                raise ValueError('unsupported configuration')
            name, value = words[0].split('=', 1)
            settings[name] = value
    port = int(settings['WG_HA_PORT'] or '51820')
    if not 1 <= port <= 65535:
        raise ValueError('invalid port')
    role = Path('/run/wg-ha/vrrp-state').read_text().strip()
    if role not in ('MASTER', 'BACKUP', 'FAULT', 'STOP'):
        raise ValueError('invalid role')
    route = command(['ip', '-4', '-o', 'route', 'get', '1.1.1.1'])
    own = re.findall(r'\bsrc\s+(\S+)', route)
    if len(own) != 1:
        raise ValueError('missing own IP')
    listing = command(['upnpc', '-u', settings['WG_HA_UPNP_URL'], '-l'])
    if not re.search(r'^\s*i\s+protocol\s+exPort->inAddr:inPort\b', listing, re.M | re.I):
        raise ValueError('missing mapping table')
    mappings = []
    for line in listing.splitlines():
        if not re.match(r'^\s*\S+\s+UDP\b', line):
            continue
        fields = shlex.split(line)
        if len(fields) != 6:
            raise ValueError('malformed mapping')
        match = re.fullmatch(r'(\d+)->([0-9.]+):(\d+)', fields[2])
        if not match:
            raise ValueError('malformed mapping')
        if int(match[1]) == port:
            if int(match[3]) != port or not fields[5].isdigit():
                raise ValueError('wrong mapping port or duration')
            mappings.append((match[2] == own[0], int(fields[5])))
    if len(mappings) > 1:
        raise ValueError('duplicate mapping')
    lease_time = int(time.time())
    interfaces = command(['wg', 'show', 'interfaces']).split()
    peers = {}
    if 'wg0' in interfaces:
        for line in command(['wg', 'show', 'wg0', 'latest-handshakes']).splitlines():
            match = re.fullmatch(r'([A-Za-z0-9+/]{43}=)\s+(\d+)', line)
            if not match:
                raise ValueError('invalid handshake')
            peer = hashlib.sha256(match[1].encode()).hexdigest()[:12]
            if peer in peers:
                raise ValueError('duplicate peer')
            peers[peer] = int(match[2])
    # No addresses, URLs, or raw public keys leave the host.
    return dict(node=os.uname().nodename, role=role, timestamp=int(time.time()),
                lease_timestamp=lease_time, present=bool(mappings),
                owned=bool(mappings and mappings[0][0]), remaining=mappings[0][1] if mappings else 0,
                interface='wg0' in interfaces, peers=peers)


def samples(text, node):
    result = {}
    for line in text.splitlines():
        if not line.startswith('wg_ha_'):
            continue
        match = re.fullmatch(r'(wg_ha_\w+)\{(.*)\}\s+(\S+)', line)
        if not match:
            raise ValueError('malformed metric')
        labels = {}
        rest = match[2]
        while rest:
            label = re.match(r'(\w+)=("(?:[^"\\]|\\[\\"n])*")(,|$)', rest)
            if not label or label[1] in labels:
                raise ValueError('malformed labels')
            labels[label[1]] = json.loads(label[2])
            rest = rest[label.end():]
        if labels.pop('cluster', None) != 'chrome' or labels.pop('node', None) != node:
            raise ValueError('wrong metric identity')
        name = match[1].removeprefix('wg_ha_')
        expected = {'state'} if name == 'role' else {'peer'} if name.startswith('peer_') else set()
        if set(labels) != expected:
            raise ValueError('unexpected labels')
        number = Decimal(match[3])
        if not number.is_finite() or number < 0 or number != number.to_integral_value():
            raise ValueError('invalid metric value')
        key = (name, tuple(sorted(labels.items())))
        if key in result:
            raise ValueError('duplicate metric')
        result[key] = int(number)
    return result


def compare(metrics, observed, node, now):
    def value(name, **labels):
        return metrics[(name, tuple(sorted(labels.items())))]

    timestamp = value('observation_timestamp_seconds')
    if not 0 <= now - timestamp <= 120 or observed['node'] != node:
        raise ValueError('stale/future observation or wrong host')
    end = observed['timestamp']
    if not timestamp <= end <= now or now - end > 30:
        raise ValueError('invalid independent observation time')
    for flag in ('role_observed', 'upnp_lease_observed', 'interface_observed'):
        if value(flag) != 1:
            raise ValueError('unobserved host state')
    roles = ('MASTER', 'BACKUP', 'FAULT', 'STOP')
    if observed['role'] not in roles or any(value('role', state=s) != int(s == observed['role']) for s in roles):
        raise ValueError('role mismatch')
    for metric, field in (('upnp_lease_present', 'present'), ('upnp_lease_owned', 'owned'),
                          ('interface_present', 'interface')):
        if value(metric) != int(observed[field]):
            raise ValueError('lease/interface mismatch')
    if observed['present']:
        remaining = value('upnp_lease_remaining_seconds')
        live_remaining = observed['remaining']
        elapsed = observed['lease_timestamp'] - timestamp
        if not 0 <= elapsed <= 120 or min(remaining - (now - timestamp), live_remaining) <= 0:
            raise ValueError('expired lease')
        # Native renewal can raise remaining time at any point in this interval.
        # A lower value must agree with elapsed time, within 5s query granularity.
        if live_remaining < remaining - elapsed - 5:
            raise ValueError('lease validity mismatch')
    if observed['role'] == 'MASTER' and not observed['interface']:
        raise ValueError('leader interface absent')
    if value('collector_errors') != 0 or value('wg_observed') != int(observed['interface']):
        raise ValueError('failed host observation')
    peers = {dict(labels)['peer']: v for (name, labels), v in metrics.items()
             if name == 'peer_last_handshake_timestamp_seconds'}
    if set(peers) != set(observed['peers']):
        raise ValueError('peer identity mismatch')
    families = {'peer_last_handshake_timestamp_seconds', 'peer_never_handshaken',
                'peer_healthy', 'peer_handshake_age_seconds'}
    for (name, labels) in metrics:
        if name.startswith('peer_') and name not in families:
            raise ValueError('unknown peer family')
    for name in families:
        actual = {dict(labels)['peer'] for family, labels in metrics if family == name}
        expected = {p for p, ts in peers.items() if ts} if name == 'peer_handshake_age_seconds' else set(peers)
        if actual != expected:
            raise ValueError('inconsistent peer families')
    for peer, old in peers.items():
        current = observed['peers'][peer]
        # Only a handshake that occurred since the textfile was sampled is an
        # acceptable race. Arbitrary timestamp/count agreement is insufficient.
        if current > end or old > timestamp or (current != old and not max(timestamp, old) <= current <= end):
            raise ValueError('handshake mismatch')
        if value('peer_never_handshaken', peer=peer) != int(old == 0):
            raise ValueError('never-handshaken mismatch')
        if value('peer_healthy', peer=peer) != int(old != 0 and timestamp - old <= 180):
            raise ValueError('peer health mismatch')
        if old and value('peer_handshake_age_seconds', peer=peer) != timestamp - old:
            raise ValueError('peer age mismatch')


def live():
    nodes = os.environ.get('WG_HA_EXPECTED_NODES', '').split()
    hosts = os.environ.get('WG_HA_LIVE_HOSTS', '').split()
    if not nodes or len(nodes) != len(hosts) or len(set(nodes)) != len(nodes) or len(set(hosts)) != len(hosts):
        raise ValueError('provide unique expected nodes and corresponding SSH hosts')
    files = []
    with tempfile.TemporaryDirectory(prefix='wg-ha-live-') as tmp:
        for index, (node, host) in enumerate(zip(nodes, hosts)):
            if host.startswith('-'):
                raise ValueError('invalid SSH target')
            ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', host]
            text = command(ssh + ['cat /var/lib/wg-ha-metrics/wg_ha.prom'], 20)
            command(ssh + ['systemctl is-active --quiet wg-ha-health.timer'], 20)
            # Capture direct curl's body, never reuse a previous node's scrape.
            try:
                scrape = command(['curl', '-fsS', '--max-time', '5', f'http://{host}:9101/metrics'])
            except (OSError, subprocess.SubprocessError):
                scrape = command(ssh + ['curl -fsS --max-time 5 http://127.0.0.1:9101/metrics'], 20)
            observed = json.loads(command(ssh + ['sudo -n /run/current-system/sw/bin/wg-ha-health-observe'], 25))
            now = int(os.environ.get('WG_HA_NOW', str(int(time.time()))))
            parsed = samples(text, node)
            compare(parsed, observed, node, now)
            scraped = samples(scrape, node)
            compare(scraped, observed, node, now)
            # A timer tick between file read and HTTP scrape is allowed; both
            # observations must independently match the actual host snapshot.
            path = Path(tmp) / f'{index}.prom'
            path.write_text(text)
            files.append(str(path))
            print(f'ok - {node}: fresh textfile and scrape match independent role/router/peers')
        collector = Path(__file__).with_name('wg-ha-health-collector.sh')
        print(command(['bash', str(collector), 'evaluate', *files]), end='')
    print('live host comparison passed; Mimir ingestion not checked')


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['--snapshot']:
            print(json.dumps(snapshot()))
        elif not sys.argv[1:]:
            live()
        else:
            raise ValueError('invalid arguments')
    except (OSError, ValueError, InvalidOperation, KeyError, TypeError, subprocess.SubprocessError):
        # Never echo command stderr, config, or raw router/WG data.
        print('FAIL - host observation unavailable or inconsistent', file=sys.stderr)
        sys.exit(1)
