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

def default_runtime():
    return Path(os.environ.get('HLS_RUNTIME',str(HERE/'runtime'))).resolve()

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

def describe(runtime,kind='server'):
    """launchctl print output for the job, or '' when it is not loaded."""
    result=subprocess.run(['/bin/launchctl','print',domain()+'/'+identity(runtime,kind)],capture_output=True,text=True)
    return result.stdout if result.returncode==0 else ''

def running(runtime,kind='server'):
    return 'state = running' in describe(runtime,kind)

def unload(runtime,kind='server'):
    return subprocess.run(['/bin/launchctl','bootout',domain()+'/'+identity(runtime,kind)],
        capture_output=True,text=True)

def failure(runtime,kind='server'):
    """Exit status of a job that has stopped, or None while it runs or was never loaded.

    A job ended by a signal reports it as 128 + signal number, matching the shell convention.
    """
    text=describe(runtime,kind)
    if not text or 'state = not running' not in text:return None
    match=re.search(r'last exit code = (\d+)',text)
    if match:return int(match[1])
    match=re.search(r'last (?:exit )?signal = (\d+)',text) or re.search(r'last signal = \w+\s*\((\d+)\)',text)
    if match:return 128+int(match[1])
    return None

def start(runtime,command,kind='server'):
    runtime.mkdir(parents=True,exist_ok=True)
    label=identity(runtime,kind)
    if running(runtime,kind):
        # Never terminate a live job from a second start; the caller decides how to wait.
        raise RuntimeError('The independent '+kind+' job is already running. Use Stop-HLS.command first.')
    # This plist is explicitly bootstrapped for this login session. It is not
    # installed as a login item and does not start at boot or log in.
    path=runtime/(label+'.plist')
    environment={'PATH':'/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
        'HLS_RUNTIME':str(runtime),'PYTHONUNBUFFERED':'1','SURROUND_MANAGED':'1'}
    for name in ('HDMI_LAB_BUILD','DD51_HDMI','DD51_SRC','DD51_CH'):
        if os.environ.get(name):environment[name]=os.environ[name]
    config={'Label':label,'ProgramArguments':command,'WorkingDirectory':str(HERE),
        'AssociatedBundleIdentifiers':['local.audio.SurroundStream'],
        'RunAtLoad':True,'KeepAlive':False,'ProcessType':'Interactive','ExitTimeOut':20,
        'Umask':0o077,'StandardOutPath':str(runtime/('hls-console.log' if kind=='server' else 'player-console.log')),
        'StandardErrorPath':str(runtime/('hls-console.log' if kind=='server' else 'player-console.log')),
        'EnvironmentVariables':environment}
    path.write_bytes(plistlib.dumps(config));path.chmod(0o600)
    unload(runtime,kind)  # removes a finished job record; a running one was refused above
    result=subprocess.run(['/bin/launchctl','bootstrap',domain(),str(path)],capture_output=True,text=True)
    if result.returncode:
        raise RuntimeError('Could not start the independent '+kind+' job: '+result.stderr.strip())
    return label

def merged_start_command(runtime,extra):
    """Saved server arguments with any new flags layered on top (later flags win in argparse)."""
    config=settings(runtime)
    saved=config.get('arguments') or []
    if not saved and config.get('restartCommand'):
        command=config['restartCommand']
        saved=command[command.index('--background')+1:] if '--background' in command else []
    return [sys.executable,'-u',str(HERE/'HLSBridge.py'),'--background','--visuals',*saved,*extra]

def launch_player(runtime):
    binary=HERE/'Surround Stream.app/Contents/MacOS/SurroundStream'
    if not binary.exists():raise SystemExit('Run Build-HLS.command first.')
    # Do not terminate a running player when its desktop shortcut is clicked.
    existing=subprocess.run(['/usr/bin/pgrep','-u',str(os.getuid()),'-f','^'+re.escape(str(binary))+r'(\s|$)'],
        capture_output=True,text=True)
    if existing.returncode==0 or running(runtime,'player'):
        raise SystemExit(subprocess.run(['/usr/bin/open',str(HERE/'Surround Stream.app')]).returncode)
    start(runtime,[str(binary)],'player')

if __name__=='__main__':
    runtime=default_runtime()
    if sys.argv[1:2]==['--start']:
        raise SystemExit(subprocess.run(merged_start_command(runtime,sys.argv[2:])).returncode)
    if sys.argv[1:]!=['--player']:raise SystemExit('Usage: HLSService.py --start [server options] | --player')
    launch_player(runtime)
