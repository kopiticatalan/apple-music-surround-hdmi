#!/usr/bin/env python3
"""Install the player/server under ~/Applications and add Desktop shortcuts."""
import json
from pathlib import Path
import shutil
import subprocess
import sys

HERE=Path(__file__).resolve().parent
FILES=['Bridge.py','HLSBridge.py','HLSService.py','TileVisuals.py','TileRenderer.swift',
    'AudioBridge.swift','SinkProbe.swift','HLSPlayer.swift','build_player.py',
    'Play-HLS-over-AirPlay.command','Start-HLS-Server.command','Stop-HLS.command',
    'README.md','VISUALS.md','INDEPENDENT-PLAYBACK.md','Build-HLS.command','LICENSE','NOTICE.md']

def main():
    destination=Path.home()/'Applications'/'Surround Stream'
    if destination.resolve()==HERE:raise SystemExit('Run this installer from the source folder.')
    subprocess.run([sys.executable,str(HERE/'HLSBridge.py'),'--build-only'],check=True)
    subprocess.run([sys.executable,str(HERE/'build_player.py')],check=True)
    destination.mkdir(parents=True,exist_ok=True)
    for name in FILES:shutil.copy2(HERE/name,destination/name)
    build=destination/'build';build.mkdir(exist_ok=True)
    for name in ['AudioBridge','SinkProbe','TileRenderer']:shutil.copy2(HERE/'build'/name,build/name)
    shutil.copytree(HERE/'Surround Stream.app',destination/'Surround Stream.app',dirs_exist_ok=True)
    runtime=destination/'runtime';runtime.mkdir(mode=0o700,exist_ok=True)
    source_settings=HERE/'runtime'/'SERVICE-HLS.json'
    if source_settings.exists() and not (runtime/'SERVICE-HLS.json').exists():
        config=json.loads(source_settings.read_text())
        command=config.get('restartCommand',[])
        config['restartCommand']=[str(destination/'HLSBridge.py') if p==str(HERE/'HLSBridge.py') else p for p in command]
        (runtime/'SERVICE-HLS.json').write_text(json.dumps(config,indent=2))
    for name in ['Play-HLS-over-AirPlay.command','Start-HLS-Server.command','Stop-HLS.command']:
        (destination/name).chmod(0o755)
    desktop=Path.home()/'Desktop'
    links={'Surround Stream.app':destination/'Surround Stream.app',
        'Start Surround Server.command':destination/'Start-HLS-Server.command',
        'Stop Surround Server.command':destination/'Stop-HLS.command'}
    for name,target in links.items():
        link=desktop/name
        if link.is_symlink():link.unlink()
        elif link.exists():raise SystemExit('Existing Desktop item left untouched: '+str(link))
        link.symlink_to(target,target_is_directory=target.is_dir())
    print(json.dumps({'installed':str(destination),'desktopShortcuts':list(links)},indent=2))

if __name__=='__main__':main()
