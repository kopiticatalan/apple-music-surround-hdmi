#!/usr/bin/env python3
from pathlib import Path
import os, signal, time
import Bridge

pid = Bridge.active_bridge_pid()
if pid is None:
    if Bridge.ACTIVE.exists():
        print('The saved playback process has already ended.')
        Bridge.ACTIVE.unlink(missing_ok=True)
    else:
        print('No saved running DTS bridge. If it is open in Terminal, press Control-C there.')
    raise SystemExit(0)
os.kill(pid, signal.SIGINT)
for _ in range(80):
    if Bridge.active_bridge_pid() is None:
        Bridge.ACTIVE.unlink(missing_ok=True)
        print('DTS playback stopped. The bridge restored the previous sound output.')
        break
    time.sleep(0.1)
else:
    print('Stop requested. Check the playback window if it has not finished.')
