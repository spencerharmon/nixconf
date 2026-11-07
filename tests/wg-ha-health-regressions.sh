#!/usr/bin/env bash
# Offline regressions against the real source or packaged collector.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export COLLECTOR=${COLLECTOR:-$ROOT/scripts/wg-ha-health-collector.sh}
exec python3 - <<'PY'
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

collector = os.environ['COLLECTOR']
now = 1800000000
key = 'A' * 43 + '='
key2 = 'B' * 43 + '='
failures = 0
checks = 0

def check(condition, name):
    global failures, checks
    checks += 1
    print(('ok - ' if condition else 'FAIL - ') + name)
    failures += not condition

with tempfile.TemporaryDirectory(prefix='wg-ha-regression-') as tmp:
    root = Path(tmp)
    (root / 'bin').mkdir()
    mock = '''#!/usr/bin/env python3
import os, pathlib, sys, time
p = pathlib.Path(os.environ['SIM'])
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (p / 'calls').open('a') as f: f.write(name + ' ' + ' '.join(args) + '\\n')
if name == 'wg':
    if args == ['show', 'interfaces']: source = 'interfaces'
    elif args == ['show', os.environ.get('WG_HA_IF', 'wg0'), 'latest-handshakes']: source = 'hs'
    else: sys.exit(99)
elif name == 'upnpc':
    if len(args) != 3 or args[0] != '-u' or args[2] != '-l': sys.exit(99)
    source = 'upnp'
elif name == 'ip': source = 'ip'
else: sys.exit(99)
data = (p / source).read_text()
if data == 'FAIL': sys.exit(1)
if data == 'TIMEOUT': time.sleep(10)
print(data, end='')
'''
    for name in ('wg', 'upnpc', 'ip'):
        path = root / 'bin' / name
        path.write_text(mock)
        path.chmod(0o755)

    def collect(name, role='MASTER', own='192.0.2.10', hs=None, mapping=None,
                interfaces='wg0\n', config=None, override=None, **extra):
        sim = root / name
        sim.mkdir()
        (sim / 'run').mkdir()
        (sim / 'state').mkdir()
        if role is not None:
            (sim / 'run/vrrp-state').write_text(role + '\n')
        (sim / 'env').write_text(config if config is not None else
                                'WG_HA_UPNP_URL="http://192.0.2.1/rootDesc.xml"\nWG_HA_PORT=51820\n')
        if override is not None:
            (sim / 'state/override.env').write_text(override)
        (sim / 'hs').write_text(hs if hs is not None else f'{key}\t{now-30}\n')
        (sim / 'interfaces').write_text(interfaces)
        (sim / 'upnp').write_text(mapping if mapping is not None else
            " i protocol exPort->inAddr:inPort description remoteHost leaseTime\n"
            " 0 UDP 51820->192.0.2.10:51820 'wg-ha' '' 97\n")
        (sim / 'ip').write_text(f'1.1.1.1 dev eth0 src {own}\n' if own else 'FAIL')
        env = {k: v for k, v in os.environ.items() if not k.startswith('WG_HA_')}
        env.update(PATH=str(root / 'bin') + ':' + os.environ['PATH'], SIM=str(sim),
                   WG_HA_RUN_DIR=str(sim / 'run'), WG_HA_STATE_DIR=str(sim / 'state'),
                   WG_HA_ENV_FILE=str(sim / 'env'), WG_HA_NODE=name,
                   WG_HA_NOW=str(now), WG_HA_CMD_TIMEOUT='0.2')
        env.update(extra)
        out = root / (name + '.prom')
        result = subprocess.run(['bash', collector, 'collect', str(out)], env=env,
                                capture_output=True, text=True, timeout=5)
        check(result.returncode == 0 and out.exists(), name + ': collector completes')
        text = out.read_text() if out.exists() else ''
        check(not result.stdout and not result.stderr, name + ': no env/command logging')
        return out, text

    def metric(text, name, value):
        return any(line.startswith('wg_ha_' + name + '{') and line.endswith('} ' + str(value))
                   for line in text.splitlines())

    def evaluate(name, files, expected=3, nodes='leader follower', **extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith('WG_HA_')}
        env.update(WG_HA_NOW=str(now), WG_HA_EXPECTED_NODES=nodes)
        env.update(extra)
        r = subprocess.run(['bash', collector, 'evaluate', *map(str, files)], env=env,
                           capture_output=True, text=True, timeout=5)
        verdict = {0: 'ok', 3: 'degraded_observation', 4: 'no_leader', 5: 'multiple_leaders'}[expected]
        check(r.returncode == expected and 'verdict=' + verdict in r.stdout,
              name + f': rc={r.returncode}, expected {expected}')

    leader, good = collect('leader')
    follower, backup = collect('follower', role='BACKUP', own='192.0.2.11', interfaces='')
    check(metric(good, 'collector_errors', 0), 'healthy collector')
    check(metric(backup, 'interface_observed', 1) and metric(backup, 'interface_present', 0)
          and metric(backup, 'wg_observed', 0) and metric(backup, 'collector_errors', 0),
          'absent follower interface is known, not a failed query')
    evaluate('healthy fleet', [leader, follower], 0)
    evaluate('inventory required', [leader, follower], nodes='')
    evaluate('duplicate expected inventory', [leader, follower], nodes='leader leader follower')
    evaluate('missing expected node', [leader])
    evaluate('missing file', [leader, root / 'absent'])
    evaluate('duplicate file', [leader, follower, follower])
    evaluate('duplicate node cannot be split brain', [leader, leader], nodes='leader')
    evaluate('unknown node', [leader, follower], nodes='leader other')
    evaluate('no nodes', [], nodes='leader')
    evaluate('stale default 120 seconds', [leader, follower], WG_HA_NOW=str(now+121))
    evaluate('future observation', [leader, follower], WG_HA_NOW=str(now-1))
    evaluate('lease expires as observation ages', [leader, follower], WG_HA_NOW=str(now+97))
    evaluate('lease still valid', [leader, follower], 0, WG_HA_NOW=str(now+96))
    evaluate('max age override', [leader, follower], WG_HA_MAX_AGE='10', WG_HA_NOW=str(now+11))
    evaluate('invalid max age', [leader, follower], WG_HA_MAX_AGE='NaN')

    def changed(name, text):
        p = root / (name + '.prom')
        p.write_text(text)
        return p

    for name, text in (
        ('missing_role', '\n'.join(l for l in backup.splitlines() if not l.startswith('wg_ha_role'))),
        ('missing_lease', '\n'.join(l for l in backup.splitlines() if not l.startswith('wg_ha_upnp'))),
        ('wrong_cluster', backup.replace('cluster="chrome"', 'cluster="other"')),
        ('mixed_identity', backup.replace('wg_ha_role_observed{cluster="chrome",node="follower"}',
                                         'wg_ha_role_observed{cluster="chrome",node="other"}')),
        ('duplicate_sample', backup + next(l for l in backup.splitlines() if l.startswith('wg_ha_role_observed')) + '\n'),
        ('role_unobserved', backup.replace('wg_ha_role_observed{cluster="chrome",node="follower"} 1',
                                          'wg_ha_role_observed{cluster="chrome",node="follower"} 0')),
        ('lease_unobserved', backup.replace('wg_ha_upnp_lease_observed{cluster="chrome",node="follower"} 1',
                                           'wg_ha_upnp_lease_observed{cluster="chrome",node="follower"} 0')),
        ('extra_role_label', backup.replace('state="BACKUP"', 'state="BACKUP",extra="bad"')),
        ('missing_role_state', '\n'.join(l for l in backup.splitlines() if 'state="FAULT"' not in l)),
        ('missing_remaining', '\n'.join(l for l in backup.splitlines() if not l.startswith('wg_ha_upnp_lease_remaining_seconds'))),
        ('non_binary_role', backup.replace('state="MASTER"} 0', 'state="MASTER"} 2')),
        ('two_roles', backup.replace('state="FAULT"} 0', 'state="FAULT"} 1')),
        ('invalid_lease_value', backup.replace('wg_ha_upnp_lease_owned{cluster="chrome",node="follower"} 0',
                                              'wg_ha_upnp_lease_owned{cluster="chrome",node="follower"} NaN')),
    ):
        evaluate(name, [leader, changed(name, text)])
    split = backup.replace('state="BACKUP"} 1', 'state="BACKUP"} 0').replace('state="MASTER"} 0', 'state="MASTER"} 1')
    evaluate('two actual MASTERs, only one lease', [leader, changed('split', split)], 5)
    evaluate('no leaders', [changed('no_master', good.replace('state="MASTER"} 1', 'state="MASTER"} 0')
             .replace('state="BACKUP"} 0', 'state="BACKUP"} 1')
             .replace('wg_ha_upnp_lease_owned{cluster="chrome",node="leader"} 1',
                      'wg_ha_upnp_lease_owned{cluster="chrome",node="leader"} 0')), follower], 4)

    header = ' i protocol exPort->inAddr:inPort description remoteHost leaseTime\n'
    row = " 0 UDP 51820->192.0.2.10:51820 'wg-ha' '' 97\n"
    for name, mapping in (
        ('wrong_internal_port', header + row.replace(':51820', ':12345')),
        ('duplicate_mapping', header + row + row.replace(' 0 UDP', ' 1 UDP')),
        ('malformed_matching', header + ' 0 UDP 51820->broken\n'),
        ('malformed_row_index', header + row.replace(' 0 UDP', ' x UDP')),
        ('bad_holder_ip', header + row.replace('192.0.2.10', '999.0.2.10')),
        ('bad_lease', header + row.replace('97', 'oops')),
        ('failed_upnp', 'FAIL'), ('timeout_upnp', 'TIMEOUT'),
    ):
        _, text = collect(name, mapping=mapping)
        check(metric(text, 'upnp_lease_observed', 0) and 'wg_ha_upnp_lease_owned{' not in text,
              name + ': no fabricated lease facts')
    _, text = collect('missing_own_ip', own='')
    check(metric(text, 'upnp_lease_observed', 0), 'missing own IP rejected')
    _, text = collect('empty_mapping', mapping=header)
    check(metric(text, 'upnp_lease_observed', 1) and metric(text, 'upnp_lease_present', 0)
          and 'wg_ha_upnp_lease_remaining_seconds{' not in text, 'empty mapping is observed absence')
    _, text = collect('override', override="export WG_HA_PORT='51821'\nWG_HA_UPNP_URL=\"http://192.0.2.2/a?x=1&y=2\"\n",
                      mapping=header + row.replace('51820', '51821'))
    check(metric(text, 'upnp_lease_owned', 1), 'native override precedence and quoting')
    check('upnpc -u http://192.0.2.2/a?x=1&y=2 -l' in (root / 'override/calls').read_text(), 'override URL actually used')
    marker = root / 'executed'
    _, text = collect('no_execution', config=f'WG_HA_UPNP_URL=http://192.0.2.1/rootDesc.xml\n'
                      f'UNRELATED=$(touch {marker})\ntouch {marker}\nWG_HA_PORT=51820\n')
    check(not marker.exists() and metric(text, 'upnp_lease_observed', 1), 'unrelated env code never executed')
    _, text = collect('relevant_expansion', override=f'WG_HA_PORT=$(touch {marker})\n')
    check(not marker.exists() and metric(text, 'upnp_lease_observed', 0), 'executable relevant setting rejected')
    _, text = collect('bad_port', override='WG_HA_PORT=65536\n')
    check(metric(text, 'upnp_lease_observed', 0), 'invalid port rejected')
    _, text = collect('quoted_default', override="WG_HA_PORT=''\n")
    check(metric(text, 'upnp_lease_owned', 1), 'empty native port selects default')
    _, text = collect('escaped_config', override="export WG_HA_PORT=51\"82\"'0' # native literal\n"
                      'WG_HA_UPNP_URL=http://192.0.2.1/a?x=1\\&y=2\n')
    check(metric(text, 'upnp_lease_owned', 1)
          and 'upnpc -u http://192.0.2.1/a?x=1&y=2 -l' in (root / 'escaped_config/calls').read_text(),
          'native concatenated quotes, escaped ampersand and comment')
    _, text = collect('malformed_config', override='WG_HA_PORT =51821\n')
    check(metric(text, 'upnp_lease_observed', 0), 'malformed relevant assignment rejected')
    _, text = collect('missing_config', WG_HA_ENV_FILE=str(root / 'no-env'))
    check(metric(text, 'upnp_lease_observed', 0), 'unreadable explicit env file rejected')
    _, text = collect('invalid_role_file', role='MA STER')
    check(metric(text, 'role_observed', 0) and 'wg_ha_role{' not in text, 'internal role whitespace rejected')
    _, text = collect('missing_role_file', role=None)
    check(metric(text, 'role_observed', 0), 'missing role file rejected')
    for name, hs in (
        ('partial_peer', f'{key}\t{now-30}\nmalformed\n'),
        ('future_peer', f'{key}\t{now+1}\n'),
        ('duplicate_peer', f'{key}\t{now-30}\n{key}\t0\n'),
        ('extra_peer_field', f'{key}\t{now-30}\textra\n'),
        ('failed_peer', 'FAIL'), ('timeout_peer', 'TIMEOUT'),
    ):
        _, text = collect(name, role='BACKUP', hs=hs)
        check(metric(text, 'wg_observed', 0) and metric(text, 'collector_errors', 1)
              and 'wg_ha_peer_' not in text, name + ': counted, no partial peer output')
    _, text = collect('failed_interfaces', interfaces='FAIL', hs='FAIL', role='BACKUP')
    check(metric(text, 'interface_observed', 0) and 'wg_ha_interface_present{' not in text
          and metric(text, 'collector_errors', 2), 'both failed wg reads counted on follower')
    _, text = collect('idle_peers', hs=f'{key}\t0\n{key2}\t{now-900}\n')
    check(metric(text, 'peer_never_handshaken', 1) and metric(text, 'peer_handshake_age_seconds', 900)
          and metric(text, 'collector_errors', 0), 'idle/never peers are not collector failure')
    never_id = hashlib.sha256(key.encode()).hexdigest()[:12]
    check(not any('wg_ha_peer_handshake_age_seconds{' in l and never_id in l for l in text.splitlines()),
          'never-handshaken peer has no age')
    check(key not in text and key2 not in text, 'raw keys not exported')
    _, text = collect('empty_peers', hs='')
    check(metric(text, 'wg_observed', 1) and 'wg_ha_peer_' not in text, 'empty successful peer list')
    for calls in root.glob('*/calls'):
        check(all(l in ('wg show interfaces', 'wg show wg0 latest-handshakes')
                  for l in calls.read_text().splitlines() if l.startswith('wg ')),
              calls.parent.name + ': only key-free targeted wg commands')

print(f'{checks} checks, {failures} failures')
raise SystemExit(bool(failures))
PY
