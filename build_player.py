#!/usr/bin/env python3
"""Build the local AirPlay controller app. Does not install or launch it."""
from pathlib import Path
import plistlib
import subprocess

root = Path(__file__).resolve().parent
app = root/'Surround Stream.app'
contents = app/'Contents'
binary = contents/'MacOS'/'SurroundStream'
binary.parent.mkdir(parents=True, exist_ok=True)
info = {'CFBundleExecutable':'SurroundStream', 'CFBundleIdentifier':'local.audio.SurroundStream',
        'CFBundleName':'Surround Stream', 'CFBundleDisplayName':'Surround Stream',
        'CFBundlePackageType':'APPL', 'CFBundleVersion':'1', 'CFBundleShortVersionString':'0.1',
        'LSMinimumSystemVersion':'12.0', 'NSHighResolutionCapable':True,
        'NSAppTransportSecurity':{'NSAllowsArbitraryLoads':True}}
(contents/'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-parse-as-library','-module-cache-path',
                str(root/'build'/'ModuleCache'),str(root/'HLSPlayer.swift'),'-o',str(binary)],check=True)
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
print(app)
