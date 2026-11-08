#!/usr/bin/env python3
"""Build and test locally. Does not install anything or change audio settings."""
from pathlib import Path
import os, platform, plistlib, subprocess

HERE = Path(__file__).resolve().parent
BUILD = Path(os.environ.get('HDMI_LAB_BUILD', str(HERE / 'build'))).resolve()

def run(*args):
    subprocess.run([str(a) for a in args], check=True, cwd=HERE)

def main():
    if platform.system() != 'Darwin':
        raise SystemExit('Building requires macOS and Xcode Command Line Tools.')
    BUILD.mkdir(parents=True, exist_ok=True)
    common = ['xcrun', 'clang', '-mmacosx-version-min=12.0', '-O2', '-fblocks',
              '-framework', 'CoreAudio', '-framework', 'CoreFoundation', '-framework', 'Accelerate']
    for channels in (8, 16):
        bundle = BUILD / f'HDMILab{channels}ch.driver'
        contents = bundle / 'Contents'
        (contents / 'MacOS').mkdir(parents=True, exist_ok=True)
        factory = 'e395c745-4eea-4d94-bb92-46224221047c'
        info = {
            'CFBundleDevelopmentRegion':'English', 'CFBundleExecutable':'HDMILab',
            'CFBundleIdentifier':f'audio.local.HDMILab{channels}ch',
            'CFBundleInfoDictionaryVersion':'6.0', 'CFBundleName':f'HDMI Lab {channels}ch',
            'CFBundlePackageType':'BNDL', 'CFBundleShortVersionString':'0.2.0',
            'CFBundleVersion':'3', 'CFBundleSignature':'????',
            'CFPlugInFactories':{factory:'BlackHole_Create'},
            'CFPlugInTypes':{'443ABAB8-E7B3-491A-B985-BEB9187030DB':[factory]},
        }
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        run(*common, '-bundle', f'-DLAB_CHANNELS={channels}', HERE/'HDMILab.c',
            '-o', contents/'MacOS'/'HDMILab')
        run('codesign', '--force', '--sign', '-', bundle)
        run('codesign', '--verify', '--strict', '--deep', bundle)
        verifier = BUILD / f'verify-{channels}'
        run(*common, f'-DLAB_CHANNELS={channels}', HERE/'verify_driver.c', '-o', verifier)
        run(verifier)
    for source in ('AudioBridge', 'SinkProbe'):
        run('xcrun', 'swiftc', '-O', '-module-cache-path', BUILD/'ModuleCache',
            HERE/f'{source}.swift', '-o', BUILD/source)
    print(f'Built and tested native {platform.machine()} binaries in {BUILD}')

if __name__ == '__main__':
    main()
