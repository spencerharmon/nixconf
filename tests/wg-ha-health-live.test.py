#!/usr/bin/env python3
"""Exercise the real --live entrypoint with simulated transport and host reads."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
NOW = 1800000000
KEY = 'A' * 43 + '='
PEER = hashlib.sha256(KEY.encode()).hexdigest()[:12]
checks = 0


def check(condition, name):
    global checks
    checks += 1
    assert condition, name
    print('ok - live: ' + name)


def metrics(node):
    leader = node == 'leader'
    values = dict(observation_timestamp_seconds=NOW, role_observed=1,
                  upnp_lease_observed=1, upnp_lease_present=1,
                  upnp_lease_owned=int(leader), upnp_lease_remaining_seconds=97,
                  interface_observed=1, interface_present=int(leader),
                  wg_observed=int(leader), collector_errors=0, armed=1)
    result = []

    def emit(name, value, **extra):
        labels = dict(cluster='chrome', node=node, **extra)
        result.append('wg_ha_' + name + '{' + ','.join(k + '=' + json.dumps(v) for k, v in labels.items()) + '} ' + str(value))

    for name, value in values.items():
        emit(name, value)
    for role in ('MASTER', 'BACKUP', 'FAULT', 'STOP'):
        emit('role', int(role == ('MASTER' if leader else 'BACKUP')), state=role)
    if leader:
        for name, value in dict(peer_last_handshake_timestamp_seconds=NOW-30,
                                peer_handshake_age_seconds=30, peer_healthy=1,
                                peer_never_handshaken=0).items():
            emit(name, value, peer=PEER)
    return '\n'.join(result) + '\n'


observations = {node: dict(node=node, role='MASTER' if node == 'leader' else 'BACKUP',
                           timestamp=NOW, lease_timestamp=NOW, present=True,
                           owned=node == 'leader', remaining=97,
                           interface=node == 'leader', peers={PEER: NOW-30} if node == 'leader' else {})
                for node in ('leader', 'follower')}

with tempfile.TemporaryDirectory(prefix='wg-ha-live-test-') as tmp:
    sim = Path(tmp)
    mock = '''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ['SIM_LIVE'])
c = json.loads((p/'scenario').read_text())
if pathlib.Path(sys.argv[0]).name == 'curl':
    host = sys.argv[-1].split('://')[1].split(':')[0]
    action = 'direct'
else:
    host = sys.argv[5]
    cmd = sys.argv[6]
    if cmd.startswith('cat '): action = 'text'
    elif cmd.startswith('systemctl '): action = 'timer'
    elif cmd.startswith('curl '): action = 'fallback'
    elif cmd == 'sudo -n /run/current-system/sw/bin/wg-ha-health-observe': action = 'observe'
    else: sys.exit(99)
node = {'host-a':'leader', 'host-b':'follower'}[host]
if action in c.get('fail', []): sys.exit(1)
if action == 'timer': sys.exit(0)
if action == 'observe': print(json.dumps(c['observed'][node]))
elif action == 'text': print(c['text'][node], end='')
else: print(c['scrape'][node], end='')
'''
    for name in ('ssh', 'curl'):
        (sim / name).write_text(mock)
        (sim / name).chmod(0o755)
    base = dict(observed=observations, text={n: metrics(n) for n in observations},
                scrape={n: metrics(n) for n in observations})

    def run(name, scenario=None, success=False, **extra):
        (sim / 'scenario').write_text(json.dumps(scenario or base))
        env = dict(os.environ, PATH=str(sim) + ':' + os.environ['PATH'], SIM_LIVE=str(sim),
                   WG_HA_NOW=str(NOW), WG_HA_EXPECTED_NODES='leader follower',
                   WG_HA_LIVE_HOSTS='host-a host-b')
        env.update(extra)
        result = subprocess.run([str(ROOT / 'tests/chrome-wireguard-health-exporter.test.sh'), '--live'],
                                env=env, text=True, capture_output=True, timeout=10)
        check((result.returncode == 0) == success, name + ': ' + result.stdout + result.stderr)

    run('direct curl body is captured', success=True)
    scenario = copy.deepcopy(base)
    for node in scenario['scrape']:
        scenario['scrape'][node] = '\n'.join(line.rsplit(' ', 1)[0] + ' ' + format(int(line.rsplit(' ', 1)[1]), '.12e')
                                                   for line in scenario['scrape'][node].splitlines()) + '\n'
    run('node exporter scientific numeric notation', scenario, success=True)
    for sample in (
        'wg_ha_peer_healthy{cluster="chrome",node="leader",peer="unknown"} 1',
        'wg_ha_peer_last_handshake_timestamp_seconds{cluster="chrome",node="leader",peer="unknown",extra="bad"} 0',
        'wg_ha_peer_handshake_age_seconds{cluster="chrome",node="follower",peer="unknown"} 1',
    ):
        scenario = copy.deepcopy(base)
        node = 'follower' if 'node="follower"' in sample else 'leader'
        scenario['scrape'][node] += sample + '\n'
        run('extra peer series rejected', scenario)
    scenario = copy.deepcopy(base)
    scenario['fail'] = ['direct']
    run('SSH scrape fallback', scenario, success=True)
    for action in ('observe', 'text', 'timer'):
        scenario = copy.deepcopy(base)
        scenario['fail'] = [action]
        run(action + ' read failure fails closed', scenario)
    for name, field, value in (
        ('role mismatch', 'role', 'BACKUP'), ('wrong lease holder', 'owned', False),
        ('router lease absent', 'present', False), ('router lease expired', 'remaining', 0),
        ('router lease duration mismatch', 'remaining', 5), ('wrong host', 'node', 'other'),
        ('peer identity mismatch with same count', 'peers', {'0' * 12: NOW-30}),
        ('peer timestamp mismatch with same count', 'peers', {PEER: NOW-31}),
        ('future handshake', 'peers', {PEER: NOW+1}), ('missing leader interface', 'interface', False),
    ):
        scenario = copy.deepcopy(base)
        scenario['observed']['leader'][field] = value
        run(name, scenario)
    for field in ('text', 'scrape'):
        scenario = copy.deepcopy(base)
        scenario[field]['follower'] = scenario[field]['leader']
        run(field + ' cannot reuse prior node body', scenario)
        scenario = copy.deepcopy(base)
        scenario[field]['leader'] = scenario[field]['leader'].replace(str(NOW), str(NOW-121))
        run(field + ' stale observation', scenario)
    scenario = copy.deepcopy(base)
    scenario['scrape']['leader'] = ''
    run('HTTP 200 without metrics', scenario)
    scenario = copy.deepcopy(base)
    scenario['fail'] = ['direct', 'fallback']
    run('both scrape paths unavailable', scenario)
    run('missing expected node', WG_HA_EXPECTED_NODES='leader follower third')
    run('duplicate host', WG_HA_LIVE_HOSTS='host-a host-a')
    scenario = copy.deepcopy(base)
    scenario['observed']['leader']['peers'][PEER] = NOW
    run('new handshake during observation race', scenario, success=True)

# Exercise the deployed snapshot code's actual independent query paths as well.
spec = importlib.util.spec_from_file_location('probe', ROOT / 'scripts/wg-ha-health-live.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
calls = []
failed = None


def query(args, timeout=5):
    calls.append(args)
    if failed and args[0] == failed:
        raise subprocess.CalledProcessError(1, args)
    if args[0] == 'ip':
        return '1.1.1.1 dev eth0 src 192.0.2.10\n'
    if args[0] == 'upnpc':
        assert args == ['upnpc', '-u', 'http://192.0.2.1/igd', '-l']
        return " i protocol exPort->inAddr:inPort description remoteHost leaseTime\n 0 UDP 51821->192.0.2.10:51821 'wg-ha' '' 97\n"
    if args == ['wg', 'show', 'interfaces']:
        return 'wg0\n'
    assert args == ['wg', 'show', 'wg0', 'latest-handshakes']
    return KEY + '\t' + str(NOW-30) + '\n'


def read(path, *args, **kwargs):
    if str(path) == '/sim/env':
        return 'WG_HA_PORT=51820\nWG_HA_UPNP_URL="http://192.0.2.1/igd"\n'
    if str(path) == '/var/lib/wg-ha/override.env':
        return 'WG_HA_PORT=51821\n'
    assert str(path) == '/run/wg-ha/vrrp-state'
    if failed == 'role':
        raise PermissionError()
    return 'MASTER\n'


with patch.dict(os.environ, WG_HA_ENV_FILE='/sim/env'), patch.object(Path, 'read_text', read), \
        patch.object(Path, 'exists', return_value=True), patch.object(probe, 'command', query), \
        patch.object(probe.time, 'time', return_value=NOW):
    state = probe.snapshot()
    check(state['owned'] and state['remaining'] == 97 and state['peers'] == {PEER: NOW-30},
          'snapshot reads real router and peer query results with overrides')
    check(KEY not in json.dumps(state) and '192.0.2.' not in json.dumps(state), 'snapshot sanitizes identifiers')
    for failed in ('role', 'ip', 'upnpc', 'wg'):
        try:
            probe.snapshot()
        except (OSError, subprocess.SubprocessError):
            check(True, failed + ' independent read cannot become success')
        else:
            check(False, failed + ' should fail')

print(f'{checks} live regression checks passed')
