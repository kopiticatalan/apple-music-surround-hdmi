#!/usr/bin/env python3
"""Start stream jobs in the logged-in macOS launchd session, outside the caller."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

HERE=Path(__file__).resolve().parent

def identity(runtime,kind='server'):
    suffix=hashlib.sha256(str(runtime.resolve()).encode()).hexdigest()[:12]
    return 'local.audio.SurroundStream.'+kind+'.'+suffix

def domain():return 'gui/'+str(os.getuid())

def settings(runtime):
    try:return json.loads((runtime/'SERVICE-HLS.json').read_text())
    except (OSError,ValueError):return {}

def save_settings(runtime,value):
    temporary=runtime/'SERVICE-HLS.tmp'
    temporary.write_text(json.dumps(value,indent=2));temporary.replace(runtime/'SERVICE-HLS.json')

def unload(runtime,kind='server'):
    return subprocess.run(['/bin/launchctl','bootout',domain()+'/'+identity(runtime,kind)],
        capture_output=True,text=True)

def failure(runtime,kind='server'):
    result=subprocess.run(['/bin/launchctl','print',domain()+'/'+identity(runtime,kind)],capture_output=True,text=True)
    match=re.search(r'last exit code = (\d+)',result.stdout)
    return int(match[1]) if match and 'state = not running' in result.stdout else None

def start(runtime,command,kind='server'):
    runtime.mkdir(parents=True,exist_ok=True)
    label=identity(runtime,kind)
    # This plist is explicitly bootstrapped for this login session. It is not
    # installed as a login item and does not start at boot or log in.
    path=runtime/(label+'.plist')
    config={'Label':label,'ProgramArguments':command,'WorkingDirectory':str(HERE),
        'AssociatedBundleIdentifiers':['local.audio.SurroundStream'],
        'RunAtLoad':True,'KeepAlive':False,'ProcessType':'Interactive','ExitTimeOut':20,
        'Umask':0o077,'StandardOutPath':str(runtime/('hls-console.log' if kind=='server' else 'player-console.log')),
        'StandardErrorPath':str(runtime/('hls-console.log' if kind=='server' else 'player-console.log')),
        'EnvironmentVariables':{'PATH':'/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
            'HLS_RUNTIME':str(runtime),'PYTHONUNBUFFERED':'1'}}
    path.write_bytes(plistlib.dumps(config));path.chmod(0o600)
    unload(runtime,kind)
    result=subprocess.run(['/bin/launchctl','bootstrap',domain(),str(path)],capture_output=True,text=True)
    if result.returncode:
        raise RuntimeError('Could not start the independent '+kind+' job: '+result.stderr.strip())
    return label

if __name__=='__main__':
    if sys.argv[1:2]==['--start']:
        runtime=HERE/'runtime'
        command=settings(runtime).get('restartCommand') if len(sys.argv)==2 else None
        command=command or [sys.executable,str(HERE/'HLSBridge.py'),'--background','--visuals',*sys.argv[2:]]
        raise SystemExit(subprocess.run(command).returncode)
    if sys.argv[1:]!=['--player']:raise SystemExit('Usage: HLSService.py --player')
    binary=HERE/'Surround Stream.app/Contents/MacOS/SurroundStream'
    if not binary.exists():raise SystemExit('Run Build-HLS.command first.')
    runtime=HERE/'runtime'
    # Do not terminate a running player when its desktop shortcut is clicked.
    existing=subprocess.run(['/usr/bin/pgrep','-u',str(os.getuid()),'-f','^'+re.escape(str(binary))+r'(\s|$)'],
        capture_output=True,text=True)
    if existing.returncode==0:
        raise SystemExit(subprocess.run(['/usr/bin/open',str(HERE/'Surround Stream.app')]).returncode)
    job=subprocess.run(['/bin/launchctl','print',domain()+'/'+identity(runtime,'player')],capture_output=True,text=True)
    if job.returncode==0 and 'state = running' in job.stdout:
        subprocess.run(['/usr/bin/open',str(HERE/'Surround Stream.app')],check=True)
    else:start(runtime,[str(binary)],'player')
