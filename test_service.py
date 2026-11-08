#!/usr/bin/env python3
"""Verify launchd ownership, launcher exit, failure cleanup, and explicit stop.

Uses a temporary copy, localhost and synthetic audio. No sound routing changes.
"""
import json
import os
from pathlib import Path
import platform
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
    if platform.system()!='Darwin':
        print(json.dumps({'skipped':'launchd is only available on macOS'}))
        return
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
                '--bind','127.0.0.1','--port','0'],env=env,capture_output=True,text=True,timeout=75)
            assert result.returncode==0,result.stderr+result.stdout
            return wait_for(lambda:state() if state().get('ready') else None)
        def summary_of(run):
            return wait_for(lambda:json.loads((Path(run)/'summary.json').read_text()) if (Path(run)/'summary.json').exists() else None)
        try:
            first=start()
            parent=subprocess.check_output(['/bin/ps','-p',str(first['pid']),'-o','ppid='],text=True).strip()
            assert parent=='1','Server remains owned by a launcher: '+parent
            sequence=first['latestSegment']
            wait_for(lambda:state().get('latestSegment')!=sequence,seconds=6)
            with urllib.request.urlopen(first['url'],timeout=3) as response:assert response.status==200
            # A second start while live must not kill the job; it reports the running URL.
            again=subprocess.run(command+['--background','--synthetic','--no-visuals','--tv','127.0.0.1'],
                env=env,capture_output=True,text=True,timeout=30)
            assert again.returncode==0 and first['url'] in again.stdout,again.stdout+again.stderr
            assert state().get('pid')==first['pid'],'Second start replaced the running server'
            result=subprocess.run(command+['--stop','--tv','127.0.0.1'],env=env,capture_output=True,text=True,timeout=20)
            assert result.returncode==0,result.stderr+result.stdout
            assert not (runtime/'ACTIVE-HLS.json').exists()
            summary=summary_of(first['run'])
            assert summary['outputRestored'] is True and summary['audioSegmentsRemoved']
            # Any signal is a deliberate stop and restores the previous output.
            second=start();os.kill(second['pid'],signal.SIGINT)
            wait_for(lambda:not (runtime/'ACTIVE-HLS.json').exists())
            summary=summary_of(second['run'])
            assert summary['outputRestored'] is True and summary['audioSegmentsRemoved']
            assert summary['stopSignal']==signal.SIGINT
            HLSService.unload(runtime)
            # A crashed pipeline stage (no signal) keeps Music on the virtual sink.
            third=start()
            subprocess.run(['/usr/bin/pkill','-KILL','-P',str(third['pid']),'-f','ffmpeg'],check=False)
            wait_for(lambda:not (runtime/'ACTIVE-HLS.json').exists())
            summary=summary_of(third['run'])
            assert summary['outputRestored'] is False and summary['audioSegmentsRemoved'],summary
            assert summary['stopSignal'] is None,summary
        finally:HLSService.unload(runtime)
    print(json.dumps({'passed':True,'serverParentPID':1,'survivedLauncherExit':True,
        'secondStartKeepsRunningServer':'passed','explicitStopRestoresOutput':'passed',
        'signalStopRestoresOutput':'passed','crashKeepsVirtualOutput':'passed'},indent=2))

if __name__=='__main__':check()
