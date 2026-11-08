#!/usr/bin/env python3
"""Live PCM -> DTS 5.1 -> IEC 61937. No audio files are recorded."""
from pathlib import Path
import datetime, json, math, os, re, shutil, signal, subprocess, sys, time

HERE = Path(__file__).resolve().parent
BUILD = Path(os.environ.get('HDMI_LAB_BUILD', str(HERE / 'build')))
PROBE = BUILD / 'SinkProbe'
BACKEND = BUILD / 'AudioBridge'
FFMPEG = shutil.which('ffmpeg')
MAIN = 'HDMI Lab 16ch'
MIRROR = MAIN + ' Mirror'
# Driver channel order: L R C LFE Ls Rs Rls Rrs Lw Rw Ltf Rtf Ltm Rtm Ltr Rtr.
PAN = ('pan=5.1(side)|FL=c0+0.707*c8+0.707*c10|FR=c1+0.707*c9+0.707*c11'
       '|FC=c2|LFE=c3|SL=c4+0.707*c6+0.707*c12+0.707*c14'
       '|SR=c5+0.707*c7+0.707*c13+0.707*c15,alimiter=limit=0.95:level=false')
RUNTIME = HERE / 'runtime'
ACTIVE = RUNTIME / 'ACTIVE-BRIDGE.json'

def active_bridge_pid():
    try:
        pid = int(json.loads(ACTIVE.read_text())['pid'])
        command = subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'args='], text=True).strip()
        if str(HERE / 'Bridge.py') in command and '--verify' not in command:
            return pid
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError):
        pass
    return None

def inventory():
    p = subprocess.run([str(PROBE), 'snapshot'], text=True, capture_output=True)
    if p.returncode:
        raise RuntimeError('Core Audio is unavailable here. Launch the .command file locally in Terminal.')
    return json.loads(p.stdout)

def set_default(name):
    subprocess.run([str(PROBE), 'set-default', name], check=True, stdout=subprocess.DEVNULL)

# The full inventory lists every device and format; it is only needed occasionally.
FORMAT_CHECK_SECONDS = 10

def default_output():
    """Name of the current default output. Much cheaper than inventory()."""
    p = subprocess.run([str(PROBE), 'default-name'], text=True, capture_output=True)
    if p.returncode:
        raise RuntimeError('Core Audio is unavailable here. Launch the .command file locally in Terminal.')
    return p.stdout.strip()

def source_ready(inv):
    by_name = {d['name']: d for d in inv['devices']}
    for name, key in [(MAIN, 'output'), (MIRROR, 'input')]:
        if name not in by_name or not by_name[name][key]:
            raise RuntimeError(f'{name} is not installed.')
        f = by_name[name][key][0]['physical']
        if (f['id'] != 'lpcm' or f['channels'] != 16 or f['rate'] != 48000
                or f['bits'] != 32 or not (f.get('flags', 0) & 1)):
            raise RuntimeError(f'{name} must be 16-channel float PCM at 48 kHz. Disable Music HDMI Passthrough.')

def hdmi_sink(inv):
    requested = os.environ.get('DD51_HDMI')
    candidates = []
    for d in inv['devices']:
        if not d['output'] or d['transport'] != 'hdmi':
            continue
        if d['name'].startswith(('HDMI Lab', 'Atmos Sink', 'Surround HDMI')):
            continue
        if requested and d['name'] != requested:
            continue
        formats = d['output'][0]['availablePhysical']
        if any(f['id'] == 'cac3' and f['rate'] == 48000 and f['channels'] == 2 and f['bits'] == 16 and f.get('bytesPerFrame') == 4 for f in formats):
            candidates.append(d['name'])
    if len(candidates) != 1:
        raise RuntimeError('Connect the physical HDMI device. If several are attached, set DD51_HDMI to its exact name. No audio settings were changed.')
    return candidates[0]

def stop(processes):
    for p in processes:
        if p.poll() is None:
            p.terminate()
    for p in processes:
        try:
            p.wait(timeout=4)
        except subprocess.TimeoutExpired:
            p.kill(); p.wait()

def astats(text):
    channel = None; result = {}
    for line in text.splitlines():
        m = re.search(r'Channel:\s*(\d+)', line)
        if m:
            channel = int(m.group(1)); result[channel] = {}
        if 'Overall' in line:
            channel = None
        if channel:
            for key, pattern in [('peakDb', r'Peak level dB:\s*([-+\w.]+)'), ('rmsDb', r'RMS level dB:\s*([-+\w.]+)')]:
                m = re.search(pattern, line)
                if m:
                    v = float(m.group(1))
                    result[channel][key] = v if math.isfinite(v) else None
    return result

def main():
    verify = '--verify' in sys.argv
    if any(arg not in ('--verify',) for arg in sys.argv[1:]):
        raise RuntimeError('Usage: Bridge.py [--verify]')
    if not FFMPEG or not PROBE.is_file() or not BACKEND.is_file():
        raise RuntimeError('Install FFmpeg and run Build.command first.')
    RUNTIME.mkdir(exist_ok=True)
    existing = active_bridge_pid()
    if existing and existing != os.getpid():
        print(f'DTS playback is already running (PID {existing}). Use Stop-DTS.command to stop it first.')
        return 1
    inv = inventory(); source_ready(inv)
    sink = None if verify else hdmi_sink(inv)
    old_default = inv['defaultOutput']
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    run = RUNTIME / 'runs' / (('dts-verify-' if verify else 'dts-hdmi-') + stamp)
    run.mkdir(parents=True)
    (RUNTIME / 'LATEST-BRIDGE.txt').write_text(str(run))
    env = os.environ.copy(); env.update(DD51_SRC=MIRROR, DD51_CH='16')
    if sink:
        env['DD51_HDMI'] = sink
    processes = []
    if not verify:
        ACTIVE.write_text(json.dumps({'pid':os.getpid(), 'run':str(run), 'script':str(HERE/'Bridge.py'), 'previousOutput':old_default}, indent=2))
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        set_default(MAIN)
        print('Source: Apple Music -> HDMI Lab 16ch Mirror', flush=True)
        print('DTS core 5.1, 48 kHz, 1,411,200 bit/s; surrounds/heights folded to 5.1.', flush=True)
        print('No stereo upmix. No audio recording. Results: ' + str(run), flush=True)
        with (run/'capture.log').open('wb') as c_log, (run/'encoder.log').open('wb') as e_log:
            capture = subprocess.Popen([str(BACKEND), 'capture'], stdout=subprocess.PIPE, stderr=c_log, env=env)
            processes.append(capture)
            cmd = [FFMPEG, '-nostdin', '-hide_banner', '-loglevel', 'warning', '-f', 'f32le', '-ar', '48000', '-ac', '16', '-i', 'pipe:0', '-af', PAN]
            if verify:
                cmd += ['-t', '20']
            cmd += ['-ar', '48000', '-c:a', 'dca', '-strict', '-2', '-b:a', '1411200', '-f', 'spdif', '-flush_packets', '1', 'pipe:1']
            encoder = subprocess.Popen(cmd, stdin=capture.stdout, stdout=subprocess.PIPE, stderr=e_log)
            processes.append(encoder); capture.stdout.close()
            if verify:
                decoder = subprocess.Popen([FFMPEG, '-nostdin', '-hide_banner', '-f', 'spdif', '-i', 'pipe:0', '-af', 'astats=metadata=0:reset=0', '-f', 'null', '-'], stdin=encoder.stdout, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                processes.append(decoder); encoder.stdout.close()
                _, output = decoder.communicate(timeout=50)
                decoded = output.decode(errors='replace'); (run/'decoder.log').write_text(decoded)
                levels = astats(decoded)
                success = decoder.returncode == 0 and len(levels) == 6 and all(levels.get(c, {}).get('rmsDb') is not None for c in (1, 2, 5, 6))
                result = {'success':success, 'codec':'DTS core', 'sampleRate':48000, 'channels':len(levels), 'transport':'IEC 61937', 'source':MIRROR, 'recordedAudio':False, 'decodedLevels':levels, 'physicalHDMITest':'not tested by this verification'}
                (run/'result.json').write_text(json.dumps(result, indent=2))
                print(json.dumps(result, indent=2), flush=True)
                stop(processes); processes.clear()
                print('Verification complete; restoring the previous output.', flush=True)
                return 0 if success else 1
            with (run/'hdmi.log').open('wb') as p_log:
                playback = subprocess.Popen([str(BACKEND), 'play'], stdin=encoder.stdout, stderr=p_log, env=env)
                processes.append(playback); encoder.stdout.close()
                print('Streaming DTS to ' + sink + '. Control-C stops and restores the previous output.', flush=True)
                last_format_check = time.monotonic()
                while all(p.poll() is None for p in processes):
                    time.sleep(1)
                    # Starting exclusive HDMI playback may change the system's
                    # default route. Music must continue feeding the virtual sink.
                    if default_output() != MAIN:
                        set_default(MAIN)
                        print('Music output restored to ' + MAIN, flush=True)
                    if time.monotonic() - last_format_check >= FORMAT_CHECK_SECONDS:
                        last_format_check = time.monotonic()
                        source_ready(inventory())
                raise RuntimeError('One pipeline stage ended. Inspect the run logs.')
    finally:
        stop(processes)
        try:
            set_default(old_default)
            print('Previous output restored: ' + old_default, flush=True)
        except Exception as error:
            print('Could not restore output automatically: ' + str(error), file=sys.stderr)
        if not verify:
            try:
                if json.loads(ACTIVE.read_text())['pid'] == os.getpid():
                    ACTIVE.unlink()
            except (OSError, ValueError, KeyError):
                pass

if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('Stopped.')
    except Exception as e:
        print(str(e), file=sys.stderr); sys.exit(1)
