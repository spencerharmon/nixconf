#!/usr/bin/env bash
# Self-contained even when ExecStart references only this file in the Nix store.
# Read-only observer: no wg dumps/configs/keys, UPnP list only, no env execution.
set -euo pipefail
exec python3 - "$@" <<'PY'
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time

STATES = ('MASTER', 'BACKUP', 'FAULT', 'STOP')


def uint(value):
    if not re.fullmatch(r'[0-9]{1,20}', str(value)):
        raise ValueError('invalid integer')
    return int(value)


def literal(value):
    # Shell literal assignments, including concatenated quotes and escapes, but
    # never expansion/eval. Ignore unrelated env lines without interpreting them.
    result, quote, i = '', '', 0
    while i < len(value):
        ch = value[i]
        if ch == quote:
            quote = ''
        elif quote == "'":
            result += ch
        elif ch == '\\':
            i += 1
            if i == len(value):
                raise ValueError('continuation unsupported')
            if quote == '"' and value[i] not in '$`"\\':
                result += '\\'
            result += value[i]
        elif ch in '$`' or (not quote and ch in ';|&<>()'):
            raise ValueError('nonliteral setting')
        elif not quote and ch in "\"'":
            quote = ch
        elif not quote and ch.isspace():
            rest = value[i:].strip()
            if rest and not rest.startswith('#'):
                raise ValueError('extra setting tokens')
            break
        else:
            result += ch
        i += 1
    if quote:
        raise ValueError('unclosed quote')
    return result


def collect():
    run = Path(os.environ.get('WG_HA_RUN_DIR', '/run/wg-ha'))
    state_dir = Path(os.environ.get('WG_HA_STATE_DIR', '/var/lib/wg-ha'))
    interface = os.environ.get('WG_HA_IF', 'wg0')
    node = os.environ.get('WG_HA_NODE') or os.uname().nodename
    now = uint(os.environ.get('WG_HA_NOW', str(int(time.time()))))
    healthy = uint(os.environ.get('WG_HA_HANDSHAKE_HEALTHY', '180'))
    timeout = float(os.environ.get('WG_HA_CMD_TIMEOUT', '5'))
    if not math.isfinite(timeout) or timeout <= 0 or not re.fullmatch(r'[\w.-]{1,15}', interface):
        raise ValueError('invalid collector configuration')
    lines, types, errors = [], set(), 0

    def emit(name, value, **labels):
        if name not in types:
            lines.append(f'# TYPE wg_ha_{name} gauge')
            types.add(name)
        labels = dict(cluster='chrome', node=node, **labels)
        label_text = ','.join(k + '=' + json.dumps(v, ensure_ascii=False) for k, v in labels.items())
        lines.append(f'wg_ha_{name}{{{label_text}}} {value}')

    def query(*args):
        return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              text=True, timeout=timeout, check=True).stdout

    emit('observation_timestamp_seconds', now)
    try:
        role = (run / 'vrrp-state').read_text().strip()
        if role not in STATES:
            raise ValueError('invalid role')
    except (OSError, ValueError):
        emit('role_observed', 0)
        errors += 1
    else:
        emit('role_observed', 1)
        for state in STATES:
            emit('role', int(role == state), state=state)
    emit('armed', int((state_dir / 'armed').exists()))

    try:
        settings = {key: os.environ.get(key, '') for key in ('WG_HA_UPNP_URL', 'WG_HA_PORT')}
        env_file = os.environ.get('WG_HA_ENV_FILE')
        files = [Path(env_file)] if env_file else []
        override = state_dir / 'override.env'
        if override.exists():
            files.append(override)
        for path in files:
            with path.open() as stream:
                for line in stream:
                    match = re.match(r'^\s*(?:export\s+)?(WG_HA_UPNP_URL|WG_HA_PORT)=(.*)$', line.rstrip('\n'))
                    if match:
                        settings[match[1]] = literal(match[2])
                    elif re.match(r'^\s*(?:export\s+)?(?:WG_HA_UPNP_URL|WG_HA_PORT)\b', line):
                        raise ValueError('malformed relevant setting')
        url = settings['WG_HA_UPNP_URL']
        port = uint(settings['WG_HA_PORT'] or '51820')
        if not re.fullmatch(r'https?://[^\s]+', url) or not 1 <= port <= 65535:
            raise ValueError('invalid mapping configuration')
        own = os.environ.get('WG_HA_OWN_IP')
        if not own:
            route = query('ip', '-4', '-o', 'route', 'get', '1.1.1.1')
            addresses = re.findall(r'\bsrc\s+(\S+)', route)
            if len(addresses) != 1:
                raise ValueError('missing own address')
            own = addresses[0]
        own = str(ipaddress.IPv4Address(own))
        listing = query('upnpc', '-u', url, '-l')
        if not re.search(r'^\s*i\s+protocol\s+exPort->inAddr:inPort\b', listing, re.M | re.I):
            raise ValueError('missing mapping table')
        mappings = []
        for line in listing.splitlines():
            # Inspect every UDP table row, including malformed target rows. Do
            # not treat a failed regex match as evidence that no mapping exists.
            if not re.match(r'^\s*(?:\S+\s+)?UDP\b', line):
                continue
            fields = shlex.split(line)
            if len(fields) != 6 or not fields[0].isdigit() or fields[1] != 'UDP':
                raise ValueError('malformed mapping row')
            match = re.fullmatch(r'(\d+)->([^:]+):(\d+)', fields[2])
            if not match:
                raise ValueError('malformed mapping address')
            external, holder, internal = uint(match[1]), str(ipaddress.IPv4Address(match[2])), uint(match[3])
            remaining = uint(fields[5])
            if not 1 <= external <= 65535 or not 1 <= internal <= 65535:
                raise ValueError('invalid mapping port')
            if external == port:
                if internal != port:
                    raise ValueError('wrong internal port')
                mappings.append((holder, remaining))
        if len(mappings) > 1:
            raise ValueError('duplicate mapping')
    except (OSError, ValueError, subprocess.SubprocessError):
        emit('upnp_lease_observed', 0)
        errors += 1
    else:
        emit('upnp_lease_observed', 1)
        emit('upnp_lease_present', int(bool(mappings)))
        emit('upnp_lease_owned', int(bool(mappings) and mappings[0][0] == own))
        if mappings:
            emit('upnp_lease_remaining_seconds', mappings[0][1])

    present = None
    try:
        interfaces = query('wg', 'show', 'interfaces').split()
        if len(set(interfaces)) != len(interfaces) or any(not re.fullmatch(r'[\w.-]{1,15}', i) for i in interfaces):
            raise ValueError('invalid interface list')
        present = interface in interfaces
    except (OSError, ValueError, subprocess.SubprocessError):
        emit('interface_observed', 0)
        errors += 1
    else:
        emit('interface_observed', 1)
        emit('interface_present', int(present))

    hs_ok = 0
    if present is not False:
        try:
            handshakes = query('wg', 'show', interface, 'latest-handshakes')
            peers = {}
            for line in handshakes.splitlines():
                match = re.fullmatch(r'([A-Za-z0-9+/]{43}=)\s+([0-9]+)', line)
                if not match or match[1] in peers:
                    raise ValueError('invalid or duplicate handshake')
                timestamp = uint(match[2])
                if timestamp > now:
                    raise ValueError('future handshake')
                peers[match[1]] = timestamp
        except (OSError, ValueError, subprocess.SubprocessError):
            errors += 1
        else:
            # Validate the complete result before publishing any peer series.
            hs_ok = 1
            for public_key, timestamp in peers.items():
                peer = hashlib.sha256(public_key.encode()).hexdigest()[:12]
                emit('peer_last_handshake_timestamp_seconds', timestamp, peer=peer)
                emit('peer_never_handshaken', int(timestamp == 0), peer=peer)
                emit('peer_healthy', int(timestamp != 0 and now - timestamp <= healthy), peer=peer)
                if timestamp:
                    emit('peer_handshake_age_seconds', now - timestamp, peer=peer)
    emit('wg_observed', hs_ok)
    emit('collector_errors', errors)
    return '\n'.join(lines) + '\n'


def evaluate(files):
    invalid, leaders, seen = False, [], set()
    try:
        expected = os.environ.get('WG_HA_EXPECTED_NODES', '').split()
        if not expected or len(set(expected)) != len(expected):
            raise ValueError('expected inventory required and unique')
        now = uint(os.environ.get('WG_HA_NOW', str(int(time.time()))))
        max_age = uint(os.environ.get('WG_HA_MAX_AGE', '120'))
    except ValueError:
        print('verdict=degraded_observation')
        return 3
    for file in files:
        try:
            samples, identities = {}, set()
            for line in Path(file).read_text().splitlines():
                if not line.strip() or line.lstrip().startswith('#'):
                    continue
                match = re.fullmatch(r'(wg_ha_\w+)\{(.*)\}\s+([0-9]+)', line)
                if not match:
                    raise ValueError('invalid sample')
                labels, pos = {}, 0
                while pos < len(match[2]):
                    label = re.match(r'(\w+)=("(?:[^"\\]|\\[\\"n])*")(,|$)', match[2][pos:])
                    if not label or label[1] in labels:
                        raise ValueError('invalid labels')
                    labels[label[1]] = json.loads(label[2])
                    pos += label.end()
                    if label[3] and pos == len(match[2]):
                        raise ValueError('trailing label separator')
                if labels.get('cluster') != 'chrome' or labels.get('node') not in expected:
                    raise ValueError('unexpected identity')
                required_labels = {'cluster', 'node'}
                if match[1] == 'wg_ha_role':
                    required_labels.add('state')
                elif match[1].startswith('wg_ha_peer_'):
                    required_labels.add('peer')
                if set(labels) != required_labels:
                    raise ValueError('unexpected labels')
                identities.add(labels['node'])
                key = (match[1], tuple(sorted(labels.items())))
                if key in samples:
                    raise ValueError('duplicate sample')
                samples[key] = uint(match[3])
            if len(identities) != 1:
                raise ValueError('missing or mixed identity')
            node = identities.pop()
            if node in seen:
                raise ValueError('duplicate node')
            seen.add(node)

            def value(name, **extra):
                labels = dict(cluster='chrome', node=node, **extra)
                return samples[('wg_ha_' + name, tuple(sorted(labels.items())))]

            timestamp = value('observation_timestamp_seconds')
            age = now - timestamp
            if age < 0 or age > max_age:
                raise ValueError('stale or future observation')
            if value('role_observed') != 1:
                raise ValueError('unobserved role')
            roles = [value('role', state=state) for state in STATES]
            if any(r not in (0, 1) for r in roles) or sum(roles) != 1:
                raise ValueError('invalid role')
            if sum(name == 'wg_ha_role' for name, _ in samples) != len(STATES):
                raise ValueError('extra role')
            if value('upnp_lease_observed') != 1:
                raise ValueError('unobserved lease')
            present, owned = value('upnp_lease_present'), value('upnp_lease_owned')
            if present not in (0, 1) or owned not in (0, 1) or owned > present:
                raise ValueError('invalid lease')
            remaining = value('upnp_lease_remaining_seconds') if present else 0
            if not present and any(name == 'wg_ha_upnp_lease_remaining_seconds' for name, _ in samples):
                raise ValueError('remaining validity without mapping')
            if roles[0]:
                valid_lease = owned == 1 and remaining > age
                leaders.append(valid_lease)
                print('node=' + node + ' status=' + ('leader' if valid_lease else 'leader_without_lease'))
            else:
                print('node=' + node + ' status=follower')
        except (OSError, ValueError, KeyError):
            invalid = True
            print('status=invalid_observation')
    if invalid or seen != set(expected):
        verdict, rc = 'degraded_observation', 3
    elif len(leaders) > 1:
        verdict, rc = 'multiple_leaders', 5
    elif not leaders:
        verdict, rc = 'no_leader', 4
    elif not leaders[0]:
        verdict, rc = 'degraded_observation', 3
    else:
        verdict, rc = 'ok', 0
    print('verdict=' + verdict)
    return rc


try:
    if len(sys.argv) >= 2 and sys.argv[1] == 'evaluate':
        sys.exit(evaluate(sys.argv[2:]))
    if len(sys.argv) not in (2, 3) or sys.argv[1] != 'collect':
        print('usage: wg-ha-health-collector.sh collect [OUT] | evaluate FILE...', file=sys.stderr)
        sys.exit(2)
    output = collect()
    if len(sys.argv) == 2:
        sys.stdout.write(output)
    else:
        destination = Path(sys.argv[2])
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode='w', dir=destination.parent, prefix=destination.name + '.',
                                             suffix='.tmp', delete=False) as stream:
                temporary = stream.name
                stream.write(output)
                os.fchmod(stream.fileno(), 0o644)
            os.replace(temporary, destination)
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)
except (OSError, ValueError):
    # Do not log paths, env values, router responses or command stderr.
    print('wg-ha-health: collection failed', file=sys.stderr)
    sys.exit(2)
PY
