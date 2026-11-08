#!/usr/bin/env python3
from pathlib import Path
import json, os, signal, subprocess, time

here = Path(__file__).resolve().parent
state = here / 'runtime' / 'ACTIVE-BRIDGE.json'
if not state.exists():
    print('No saved running DTS bridge. If it is open in Terminal, press Control-C there.')
    raise SystemExit(0)
info = json.loads(state.read_text()); pid = int(info['pid'])
p = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'args='], text=True, capture_output=True)
if p.returncode or str(here / 'Bridge.py') not in p.stdout or '--verify' in p.stdout:
    print('The saved playback process has already ended.')
    state.unlink(missing_ok=True)
    raise SystemExit(0)
os.kill(pid, signal.SIGINT)
for _ in range(80):
    p = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'args='], text=True, capture_output=True)
    if p.returncode or str(here / 'Bridge.py') not in p.stdout:
        state.unlink(missing_ok=True)
        print('DTS playback stopped. The bridge restored the previous sound output.')
        break
    time.sleep(0.1)
else:
    print('Stop requested. Check the playback window if it has not finished.')
