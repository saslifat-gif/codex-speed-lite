#!/usr/bin/env python3
"""Reversible setup. Does not read auth.json, change login mode, or make model calls."""
import datetime
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time
import tomllib
import urllib.request

ROOT = Path(__file__).resolve().parent
HOME = Path.home()
CONFIG = HOME / '.codex/config.toml'
LABEL = 'local.codex.speedlite.relay'
AGENT = HOME / f'Library/LaunchAgents/{LABEL}.plist'
BEGIN = '# BEGIN CODEX SPEED LITE API MONITOR'
END = '# END CODEX SPEED LITE API MONITOR'
BLOCK = f'''{BEGIN}
openai_base_url = "http://127.0.0.1:47831/backend-api/codex"
{END}
'''


def health_info():
    # Explicitly avoid system HTTP proxies for loopback health checks.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open('http://127.0.0.1:47831/health', timeout=1) as response:
            data = json.load(response)
            return data if isinstance(data, dict) and data.get('service') == 'codex-speed-lite' else None
    except Exception:
        return None


def health():
    info = health_info()
    return bool(info and info.get('version') == 3)


def save(text):
    tomllib.loads(text)
    backup = ROOT / 'backups' / ('config-before-monitor-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '.toml')
    backup.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(CONFIG, backup)
    backup.chmod(0o600)
    tmp = CONFIG.with_name('config.speedlite.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(text)
    os.replace(tmp, CONFIG)


def relay():
    info = health_info()
    if info:
        if info.get('version') == 3:
            return
        raise RuntimeError('Old relay is running. An explicitly approved restart is needed; configuration was not changed.')
    AGENT.parent.mkdir(parents=True, exist_ok=True)
    spec = {'Label': LABEL, 'ProgramArguments': [str(ROOT / '.venv/bin/python'), str(ROOT / 'api_monitor.py')],
            'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 5,
            'WorkingDirectory': str(ROOT), 'Umask': 0o077,
            'StandardOutPath': '/dev/null', 'StandardErrorPath': '/dev/null'}
    with AGENT.open('wb') as f:
        plistlib.dump(spec, f)
    AGENT.chmod(0o600)
    domain = f'gui/{os.getuid()}'
    loaded = subprocess.run(['launchctl', 'print', f'{domain}/{LABEL}'], capture_output=True).returncode == 0
    if not loaded:
        subprocess.run(['launchctl', 'bootstrap', domain, str(AGENT)], check=True, capture_output=True)
    else:
        subprocess.run(['launchctl', 'kickstart', f'{domain}/{LABEL}'], check=True, capture_output=True)
    for _ in range(50):
        if health():
            return
        time.sleep(.1)
    raise RuntimeError('Relay did not become healthy; configuration was not changed.')


def enable():
    text = CONFIG.read_text()
    data = tomllib.loads(text)
    if BEGIN in text:
        if BLOCK not in text:
            raise RuntimeError('Monitor configuration was edited; refusing to overwrite it.')
        relay()
        print('Monitor already configured. Fully quit and reopen the Codex desktop app to apply; restarting only the CLI daemon is not sufficient.')
        return
    if data.get('model_provider', 'openai') != 'openai' or 'openai_base_url' in data or 'openai' in data.get('model_providers', {}):
        raise RuntimeError('Existing provider override found; refusing to change it automatically.')
    relay()
    # Recheck before writing: do not overwrite changes made while the helper started.
    if CONFIG.read_text() != text:
        raise RuntimeError('Configuration changed during setup; try again.')
    save(BLOCK + '\n' + text)
    print('Local API monitor enabled. Fully quit and reopen the Codex desktop app to apply; restarting only the CLI daemon is not sufficient. Account and model unchanged.')


def disable():
    text = CONFIG.read_text()
    if BEGIN not in text:
        print('Already using direct configuration.')
        return
    if BLOCK not in text:
        raise RuntimeError('Monitor block was edited; remove its marked section manually.')
    save(text.replace(BLOCK + '\n', '', 1) if BLOCK + '\n' in text else text.replace(BLOCK, '', 1))
    print('Direct connection restored. Fully quit and reopen the Codex desktop app when ready. Relay remains up for existing connections.')


def restart():
    # Only invoked with the explicit --confirm-interrupt flag below.
    domain = f'gui/{os.getuid()}/{LABEL}'
    subprocess.run(['launchctl', 'kickstart', '-k', domain], check=True, capture_output=True)
    for _ in range(100):
        if health():
            print('Collector v3 restarted. Codex routing configuration was not changed.')
            return
        time.sleep(.1)
    raise RuntimeError('Collector v3 did not become healthy; check installation before enabling routing.')


if __name__ == '__main__':
    restart_confirmed = sys.argv[1:] == ['restart', '--confirm-interrupt']
    if not restart_confirmed and (len(sys.argv) != 2 or sys.argv[1] not in ('enable', 'disable', 'health')):
        raise SystemExit('Usage: control.py enable|disable|health OR restart --confirm-interrupt')
    try:
        if restart_confirmed:
            restart()
        elif sys.argv[1] == 'health':
            info = health_info()
            print('healthy v3' if health() else ('legacy relay running; restart required' if info else 'unavailable'))
        else:
            {'enable': enable, 'disable': disable}[sys.argv[1]]()
    except Exception as error:
        # Do not dump config or credential-bearing subprocess output.
        print(str(error) if isinstance(error, RuntimeError) else 'Setup failed; no credentials logged.', file=sys.stderr)
        raise SystemExit(1)
