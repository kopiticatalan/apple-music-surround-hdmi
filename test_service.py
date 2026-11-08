#!/usr/bin/env python3
"""Verify launchd ownership, launcher exit, failure cleanup, and explicit stop.

Uses a temporary copy, localhost and synthetic audio. No sound routing changes.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
import HLSService

HERE=Path(__file__).resolve().parent

def wait_for(predicate,seconds=15):
    until=time.monotonic()+seconds
    while time.monotonic()<until:
        value=predicate()
        if value:return value
        time.sleep(.2)
    raise AssertionError('Service test timed out')

def check():
    with tempfile.TemporaryDirectory(prefix='surround-service-test-') as directory:
        root=Path(directory);runtime=root/'runtime'
        for name in ['Bridge.py','HLSBridge.py','HLSService.py']:shutil.copy2(HERE/name,root/name)
        env={**os.environ,'HLS_RUNTIME':str(runtime)}
        command=[sys.executable,str(root/'HLSBridge.py')]
        def state():
            try:return json.loads((runtime/'ACTIVE-HLS.json').read_text())
            except (OSError,ValueError):return {}
        def start():
            result=subprocess.run(command+['--background','--synthetic','--no-visuals','--tv','127.0.0.1',
                '--bind','127.0.0.1','--port','0'],env=env,capture_output=True,text=True,timeout=45)
            assert result.returncode==0,result.stderr+result.stdout
            return wait_for(lambda:state() if state().get('ready') else None)
        try:
            first=start()
            parent=subprocess.check_output(['/bin/ps','-p',str(first['pid']),'-o','ppid='],text=True).strip()
            assert parent=='1','Server remains owned by a launcher: '+parent
            sequence=first['latestSegment']
            wait_for(lambda:state().get('latestSegment')!=sequence,seconds=6)
            with urllib.request.urlopen(first['url'],timeout=3) as response:assert response.status==200
            result=subprocess.run(command+['--stop','--tv','127.0.0.1'],env=env,capture_output=True,text=True,timeout=20)
            assert result.returncode==0,result.stderr+result.stdout
            assert not (runtime/'ACTIVE-HLS.json').exists()
            summary=json.loads((Path(first['run'])/'summary.json').read_text())
            assert summary['outputRestored'] is True and summary['audioSegmentsRemoved']
            second=start();os.kill(second['pid'],signal.SIGINT)
            wait_for(lambda:not (runtime/'ACTIVE-HLS.json').exists())
            summary=json.loads((Path(second['run'])/'summary.json').read_text())
            assert summary['outputRestored'] is False and summary['audioSegmentsRemoved']
            assert summary['stopSignal']==signal.SIGINT
        finally:HLSService.unload(runtime)
    print(json.dumps({'passed':True,'serverParentPID':1,'survivedLauncherExit':True,
        'explicitStopCleanup':'passed','unexpectedStopKeepsVirtualOutput':'passed'},indent=2))

if __name__=='__main__':check()
