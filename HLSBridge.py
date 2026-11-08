#!/usr/bin/env python3
"""HDMI Lab PCM capture -> AC-3 5.1 -> bounded, local HLS for AirPlay media playback."""
import argparse
import fcntl
import functools
import http.server
import io
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse

import Bridge
import HLSService

HERE = Path(__file__).resolve().parent
RUNTIME = Path(os.environ.get('HLS_RUNTIME', str(HERE / 'runtime'))).resolve()
STATE = RUNTIME / 'ACTIVE-HLS.json'
STOP = threading.Event()
STOP_SIGNAL = None


def atomic_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2))
    temporary.replace(path)


def build_helpers():
    Bridge.BUILD.mkdir(parents=True, exist_ok=True)
    for name in ('AudioBridge', 'SinkProbe', 'TileRenderer'):
        target = Bridge.BUILD / name
        source = HERE / (name + '.swift')
        if target.exists() and target.stat().st_mtime >= source.stat().st_mtime:
            continue
        subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path',
            str(Bridge.BUILD / 'ModuleCache'), str(source), '-o', str(target)], check=True)


def read_state():
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {}


def matching_process(state):
    try:
        pid = int(state['pid'])
        result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'args='],
                                capture_output=True, text=True)
        return pid > 1 and result.returncode == 0 and str(HERE / 'HLSBridge.py') in result.stdout
    except (KeyError, ValueError, OSError):
        return False


def stop_running():
    state = read_state()
    if not matching_process(state):
        # A job may still be starting before it has written its state file.
        # bootout sends SIGTERM, which the server treats as an explicit stop.
        HLSService.unload(RUNTIME)
        print('No running HLS bridge found.')
        return 0
    atomic_json(RUNTIME/'STOP-HLS.json', {'pid':state['pid']})
    os.kill(state['pid'], signal.SIGINT)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if not STATE.exists():
            HLSService.unload(RUNTIME)
            (RUNTIME/'STOP-HLS.json').unlink(missing_ok=True)
            print('HLS stopped; rolling audio segments removed and previous output restored.')
            return 0
        time.sleep(.2)
    raise RuntimeError('Stop requested, but cleanup has not completed. Inspect runtime/hls-console.log.')


def wait_until_ready(deadline, on_tick=None):
    """Poll the state file until the server reports ready; return the state or None."""
    last_tick = 0
    while time.monotonic() < deadline:
        state = read_state()
        if state.get('ready') and matching_process(state):
            return state
        if on_tick and time.monotonic() - last_tick >= 1:
            last_tick = time.monotonic()
            on_tick()
        time.sleep(.2)
    return None


def announce(state):
    print('Apple Music HLS is running.\n' + state['url'])
    print('Open Surround Stream.app and choose your TV using its AirPlay button.')
    print('Run Stop-HLS.command to stop and clean up.')


def local_address(target):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.connect((target, 7000))
        return sock.getsockname()[0]


def encoder_command(directory, window, duration=0, segment_seconds=1, visuals=None, video_fd=None):
    # Explicit indices in Bridge.PAN preserve the virtual driver's speaker order.
    cmd = [Bridge.FFMPEG, '-nostdin', '-hide_banner', '-loglevel', 'warning',
        '-probesize', '32', '-analyzeduration', '0',
        '-thread_queue_size', '4', '-f', 'f32le', '-ar', '48000', '-ac', '16',
        '-i', 'pipe:0']
    graph = '[0:a]asplit=2[programme][clock];[programme]' + Bridge.PAN + '[audio];'
    if visuals:
        if video_fd is None:raise ValueError('A live visual video pipe is required')
        cmd += ['-thread_queue_size','2','-f','rawvideo','-pixel_format','rgba','-video_size','1280x720',
                '-framerate','25','-i',f'pipe:{video_fd}']
        graph += ('[clock]pan=mono|c0=0*c0,showwaves=s=1280x720:r=25:colors=black,format=yuv420p[clockvideo];'
            '[clockvideo][1:v]overlay=shortest=1,format=yuv420p[video]')
    else:
        graph += '[clock]pan=mono|c0=0*c0,showwaves=s=640x360:r=25:colors=black,format=yuv420p[video]'
    cmd += ['-filter_complex_threads','1','-filter_complex',graph, '-map', '[video]', '-map', '[audio]',
        '-c:a', 'ac3', '-b:a', '384k', '-ar', '48000',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency',
        '-profile:v', 'baseline', '-level:v', '3.1' if visuals else '3.0', '-pix_fmt', 'yuv420p',
        '-g', str(round(25*segment_seconds)), '-keyint_min', str(round(25*segment_seconds)),
        '-sc_threshold', '0', '-threads:v', '1', '-max_delay', '0', '-flush_packets', '1',
        '-progress', 'pipe:1', '-stats_period', '1']
    if duration:
        cmd += ['-t', str(duration)]
    return cmd + ['-f', 'hls', '-hls_time', str(segment_seconds), '-hls_list_size', str(window),
        '-hls_delete_threshold', str(window),
        '-hls_flags', 'delete_segments+independent_segments+temp_file+omit_endlist+program_date_time',
        '-hls_segment_filename', str(directory / 'segment%09d.ts'),
        str(directory / 'index.m3u8')]


def progress_reader(stream, values, lock):
    pending = {}
    try:
        for raw in stream:
            key, sep, value = raw.decode(errors='replace').strip().partition('=')
            if sep:
                pending[key] = value
            if key == 'progress':
                with lock:
                    values.update(pending)
                pending = {}
    finally:
        stream.close()


def synthetic_capture():
    # Distinct frequencies in all sixteen inputs; LFE remains below 120 Hz.
    expressions = [f'0.005*sin(2*PI*{80 if i == 3 else 220+i*43}*t)' for i in range(16)]
    return [Bridge.FFMPEG, '-nostdin', '-hide_banner', '-loglevel', 'error',
        '-re', '-f', 'lavfi', '-i', 'aevalsrc=' + '|'.join(expressions) + ':s=48000:c=hexadecagonal',
        '-f', 'f32le', 'pipe:1']


class HLSHandler(http.server.SimpleHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      '.m3u8': 'application/vnd.apple.mpegurl', '.ts': 'video/mp2t'}

    def allowed(self):
        path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
        prefix = '/' + self.server.session_token + '/'
        if self.client_address[0] not in self.server.allowed_clients or not path.startswith(prefix):
            self.send_error(403)
            return False
        filename = path[len(prefix):]
        if not re.fullmatch(r'(master\.m3u8|index\.m3u8|index\.html|segment\d{9}\.ts)', filename):
            self.send_error(404)
            return False
        self.path = '/' + filename
        return True

    def do_GET(self):
        if self.allowed():
            super().do_GET()

    def do_HEAD(self):
        if self.allowed():
            super().do_HEAD()

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Access-Control-Allow-Origin', '*')
        super().end_headers()

    def send_head(self):
        # Hint the initial live position without truncating the DVR window or
        # discarding segments a receiver may already have queued.
        if self.path == '/index.m3u8':
            try:
                content = (Path(self.directory)/'index.m3u8').read_text()
            except FileNotFoundError:
                self.send_error(404)
                return None
            target = int(re.search(r'#EXT-X-TARGETDURATION:(\d+)', content)[1])
            offset = max(3*target, self.server.live_offset)
            content = content.replace('#EXTM3U\n',
                f'#EXTM3U\n#EXT-X-START:TIME-OFFSET=-{offset:.3f},PRECISE=YES\n', 1)
            data = content.encode()
            self.send_response(200)
            self.send_header('Content-Type', self.extensions_map['.m3u8'])
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            return io.BytesIO(data)
        return super().send_head()

    def log_request(self, code='-', size='-'):
        with self.server.stats_lock:
            ip = self.client_address[0]
            stats = self.server.client_stats.setdefault(ip, {'requests': 0, 'segments': 0, 'lastStatus': None})
            stats['requests'] += 1
            stats['lastStatus'] = code
            if code == 200 and re.fullmatch(r'/segment\d{9}\.ts', self.path):
                stats['segments'] += 1
                sequence = int(re.search(r'(\d+)\.ts', self.path)[1])
                stats['lastSegment'] = sequence
                stats['lastSegmentRequestTime'] = time.time()
                stats['highestSegment'] = max(sequence, stats.get('highestSegment', sequence))
                stats['fetchBehindSeconds'] = max(0, self.server.latest_sequence-sequence)*self.server.segment_seconds
            if code == 404:
                stats['notFound'] = stats.get('notFound', 0) + 1

    def log_message(self, fmt, *args):
        pass


def background(args):
    existing = read_state()
    if matching_process(existing):
        if existing.get('ready'):
            print('Already running: ' + existing['url'])
            return 0
        # Still starting: block until it is live, the way a fresh start does,
        # so callers (and the player app) never spin on an instant exit.
        print('HLS is still starting; waiting for it to go live.', flush=True)
        state = wait_until_ready(time.monotonic() + 60)
        if state:
            announce(state)
            return 0
        raise RuntimeError('The running HLS server did not become ready. Inspect runtime/hls-console.log.')
    if HLSService.running(RUNTIME):
        # Job is alive but has not written its state file yet (e.g. compiling helpers).
        print('HLS server job is starting; waiting for it to go live.', flush=True)
        state = wait_until_ready(time.monotonic() + 60)
        if state:
            announce(state)
            return 0
        raise RuntimeError('The HLS server job did not become ready. Inspect runtime/hls-console.log.')
    RUNTIME.mkdir(exist_ok=True)
    arguments=['--tv',args.tv,'--port',str(args.port),'--window',str(args.window),
        '--segment-seconds',str(args.segment_seconds),'--live-offset',str(args.live_offset),
        '--duration',str(args.duration),'--visuals' if args.visuals else '--no-visuals']
    if args.bind:arguments+=['--bind',args.bind]
    if args.synthetic:arguments+=['--synthetic']
    command=[sys.executable,'-u',str(HERE/'HLSBridge.py'),*arguments]
    config=HLSService.settings(RUNTIME)
    HLSService.save_settings(RUNTIME,{**config,'tv':args.tv,'arguments':arguments,
        'restartCommand':[command[0],command[1],command[2],'--background',*arguments]})
    HLSService.start(RUNTIME,command)
    def check_job():
        failure=HLSService.failure(RUNTIME)
        if failure is not None:
            HLSService.unload(RUNTIME)
            log=RUNTIME/'hls-console.log'
            raise RuntimeError('Independent server exited ('+str(failure)+'):\n'+(log.read_text()[-1500:] if log.exists() else 'Check the installation path and macOS permissions.'))
    state = wait_until_ready(time.monotonic() + 40, on_tick=check_job)
    if state:
        announce(state)
        return 0
    # Ask for an explicit stop so the server restores the previous output.
    state = read_state()
    if state.get('pid'):
        atomic_json(RUNTIME/'STOP-HLS.json', {'pid':state['pid']})
    HLSService.unload(RUNTIME)
    raise RuntimeError('HLS startup timed out; stop requested. Inspect runtime/hls-console.log.')


def serve(args):
    if not Bridge.FFMPEG:
        raise RuntimeError('FFmpeg is required.')
    RUNTIME.mkdir(exist_ok=True)
    # A held advisory lock prevents duplicate captures even if a stale state file exists.
    with (RUNTIME / 'hls.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('An HLS bridge is already running. Use Stop-HLS.command first.')
        previous_output = None
        processes = []
        server = None
        server_thread = None
        run = RUNTIME / ('hls-' + time.strftime('%Y%m%d-%H%M%S') + '-' + secrets.token_hex(3))
        media = run / 'media'
        media.mkdir(parents=True)
        state = {'pid': os.getpid(), 'ready': False, 'synthetic': args.synthetic,
                 'run': str(run), 'tv': args.tv, 'codec': 'AC-3', 'channels': 6, 'sampleRate': 48000,
                 'segmentSeconds': args.segment_seconds, 'clock': 'audio', 'liveOffsetHintSeconds': args.live_offset}
        try:
            if not args.synthetic:
                # Scoped to this server process; does not alter global power settings.
                processes.append(subprocess.Popen(['/usr/bin/caffeinate','-i','-w',str(os.getpid())]))
            if not args.synthetic:
                build_helpers()
                with socket.create_connection((args.tv, 7000), timeout=3):
                    pass
                inv = Bridge.inventory()
                Bridge.source_ready(inv)
                config=HLSService.settings(RUNTIME)
                previous_output = (config.get('previousOutput') if inv['defaultOutput']==Bridge.MAIN else inv['defaultOutput'])
                if previous_output:
                    HLSService.save_settings(RUNTIME,{**config,'previousOutput':previous_output})
                # This stream must remain separate from the QuickTime AirPlay media route.
                Bridge.set_default(Bridge.MAIN)
            visuals = None
            visual_worker = None
            if args.visuals:
                visuals = run/'visuals'
                visuals.mkdir()
                with (run/'visuals.log').open('wb') as visual_log:
                    visual_worker = subprocess.Popen([sys.executable,'-u',str(HERE/'TileVisuals.py'),str(visuals)],
                        stdout=subprocess.PIPE,stderr=visual_log)
                processes.append(visual_worker)
                deadline = time.monotonic()+12
                while not all((visuals/name).exists() for name in ('background.png','text.png')):
                    if visual_worker.poll() is not None or time.monotonic()>deadline:
                        raise RuntimeError('Visual renderer did not start. See visuals.log or use --no-visuals.')
                    time.sleep(.1)
            state['visuals'] = bool(visuals)
            bind = args.bind or local_address(args.tv)
            server = http.server.ThreadingHTTPServer((bind, args.port),
                functools.partial(HLSHandler, directory=str(media)))
            server.daemon_threads = True
            server.session_token = secrets.token_urlsafe(18)
            server.allowed_clients = {args.tv, bind, '127.0.0.1'}
            server.client_stats = {}
            server.stats_lock = threading.Lock()
            server.live_offset = args.live_offset
            server.segment_seconds = args.segment_seconds
            server.latest_sequence = 0
            state['url'] = f'http://{bind}:{server.server_port}/{server.session_token}/master.m3u8'
            state['previousOutput'] = previous_output
            atomic_json(STATE, state)
            video_variant = ('BANDWIDTH=8000000,RESOLUTION=1280x720,FRAME-RATE=25,CODECS="avc1.42c01f,ac-3"'
                             if visuals else 'BANDWIDTH=800000,RESOLUTION=640x360,FRAME-RATE=25,CODECS="avc1.42c01e,ac-3"')
            (media / 'master.m3u8').write_text('#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-INDEPENDENT-SEGMENTS\n'
                f'#EXT-X-START:TIME-OFFSET=-{args.live_offset:.3f},PRECISE=YES\n'
                '#EXT-X-STREAM-INF:'+video_variant+'\nindex.m3u8\n')
            (media / 'index.html').write_text('<!doctype html><meta charset="utf-8"><title>Apple Music Surround</title>'
                '<h1>Apple Music Surround</h1><p>Select your TV using the video AirPlay button.</p>'
                '<video controls playsinline preload="metadata" x-webkit-airplay="allow" src="master.m3u8" width="640"></video>')
            with (run / 'capture.log').open('wb') as capture_log, (run / 'encoder.log').open('wb') as encoder_log:
                env = os.environ.copy()
                env.update(DD51_SRC=Bridge.MIRROR, DD51_CH='16')
                capture = subprocess.Popen(synthetic_capture() if args.synthetic else [str(Bridge.BACKEND), 'capture'],
                    stdout=subprocess.PIPE, stderr=capture_log, env=env)
                processes.append(capture)
                video_fd = visual_worker.stdout.fileno() if visual_worker else None
                encoder = subprocess.Popen(encoder_command(media, args.window, 0, args.segment_seconds, visuals, video_fd),
                    stdin=capture.stdout, stdout=subprocess.PIPE, stderr=encoder_log,
                    pass_fds=(video_fd,) if video_fd is not None else ())
                if visual_worker:visual_worker.stdout.close()
                processes.append(encoder)
                capture.stdout.close()
                progress = {}
                progress_lock = threading.Lock()
                threading.Thread(target=progress_reader, args=(encoder.stdout, progress, progress_lock), daemon=True).start()
                server_thread = threading.Thread(target=server.serve_forever, daemon=True)
                server_thread.start()
                started = time.monotonic()
                last_check = 0
                last_format_check = started
                last_segment_time = started
                last_segment = None
                while not STOP.wait(.25):
                    now = time.monotonic()
                    if args.duration and now-started >= args.duration:
                        break
                    if encoder.poll() is not None:
                        if args.duration and encoder.returncode == 0:
                            break
                        raise RuntimeError('Encoder ended:\n' + (run / 'encoder.log').read_text(errors='replace')[-2500:])
                    if capture.poll() is not None:
                        raise RuntimeError('Capture ended:\n' + (run / 'capture.log').read_text(errors='replace')[-2500:])
                    if now - last_check < 1:
                        continue
                    last_check = now
                    if not args.synthetic:
                        # Cheap route check every second; the full format inventory
                        # only every ten seconds (the capture already refuses non-PCM).
                        if Bridge.default_output() != Bridge.MAIN:
                            Bridge.set_default(Bridge.MAIN)
                            print('Restored Music capture output to ' + Bridge.MAIN, flush=True)
                        if now - last_format_check >= Bridge.FORMAT_CHECK_SECONDS:
                            last_format_check = now
                            Bridge.source_ready(Bridge.inventory())
                    segments = sorted(media.glob('segment*.ts'))
                    latest = segments[-1].name if segments else None
                    if latest:
                        server.latest_sequence = int(re.search(r'(\d+)\.ts', latest)[1])
                    if latest != last_segment:
                        last_segment, last_segment_time = latest, now
                    if now - last_segment_time > 15:
                        raise RuntimeError('HLS stopped advancing. Stopping capture and restoring audio.')
                    if len(segments) >= 3 and not state['ready']:
                        state['ready'] = True
                        print('LIVE: ' + state['url'], flush=True)
                        print('AC-3 5.1, 48 kHz, 384 kbit/s. Open Surround Stream.app and choose your TV.', flush=True)
                        print('HLS keeps a short rolling disk buffer, removed when stopped. Control-C stops.', flush=True)
                    state.update(latestSegment=latest, retainedSegments=len(segments), uptimeSeconds=round(now-started, 1))
                    with progress_lock:
                        state['encoderProgress'] = dict(progress)
                    with server.stats_lock:
                        state['clients'] = {ip: dict(stats) for ip, stats in server.client_stats.items()}
                    atomic_json(STATE, state)
        finally:
            Bridge.stop(processes)
            if server:
                if server_thread and server_thread.is_alive():
                    server.shutdown()
                server.server_close()
            requested=False
            try:requested=json.loads((RUNTIME/'STOP-HLS.json').read_text()).get('pid')==os.getpid()
            except (OSError,ValueError):pass
            # Any signal (Control-C, Stop command, launchd bootout, logout) is a
            # deliberate stop and restores the previous output. Only a crash of a
            # pipeline stage (no signal) leaves Music on the virtual sink, so the
            # Mac speakers do not suddenly take over mid-song.
            restore_output = requested or bool(args.duration) or STOP_SIGNAL is not None
            if previous_output is not None and restore_output:
                try:
                    Bridge.set_default(previous_output)
                    print('Previous output restored: ' + previous_output, flush=True)
                except Exception as error:
                    print('Select your previous sound output manually: ' + str(error), file=sys.stderr)
            elif previous_output is not None:
                print('Unexpected stop: leaving Music routed to the virtual sink to avoid speaker fallback.',flush=True)
            shutil.rmtree(media, ignore_errors=True)
            shutil.rmtree(run/'visuals', ignore_errors=True)
            if read_state().get('pid') == os.getpid():
                atomic_json(run / 'summary.json', {**state, 'ready': False, 'stopped': True,
                    'stopSignal':STOP_SIGNAL,'outputRestored':restore_output,'audioSegmentsRemoved':not media.exists()})
                STATE.unlink(missing_ok=True)
            print('HLS stopped. Rolling audio segments removed.', flush=True)
    return 0


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tv', default=os.environ.get('HLS_TV_IP') or read_state().get('tv') or HLSService.settings(RUNTIME).get('tv'), help='TV IPv4 address')
    parser.add_argument('--bind', help='Local IPv4 address; defaults to the interface reaching the TV')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--window', type=int, default=12, help='Number of segments in the live playlist')
    parser.add_argument('--segment-seconds', type=float, choices=(1, 2), default=1,
                        help='Segment duration; defaults to one second')
    parser.add_argument('--live-offset', type=float, default=3, help='Initial distance behind live in seconds; at least three target durations')
    parser.add_argument('--duration', type=float, default=0, help='Optional test duration; zero streams until stopped')
    parser.add_argument('--synthetic', action='store_true', help='Use quiet synthetic 16-channel tones; do not change Mac audio')
    parser.add_argument('--visuals', action=argparse.BooleanOptionalAction, default=False,
                        help='Add the live artist portrait and Metro-style title animation')
    parser.add_argument('--background', action='store_true')
    parser.add_argument('--stop', action='store_true')
    parser.add_argument('--build-only', action='store_true')
    args = parser.parse_args()
    if args.tv is None and args.synthetic:
        args.tv = '127.0.0.1'
    if args.tv is None and not (args.stop or args.build_only):
        parser.error('Specify the TV address with --tv or HLS_TV_IP.')
    if args.tv is not None:
        ipaddress.IPv4Address(args.tv)
    if args.bind:
        ipaddress.IPv4Address(args.bind)
    if not 0 <= args.port <= 65535 or not 3 <= args.window <= 120 or args.duration < 0:
        parser.error('Use port 0..65535, window 3..120, and a non-negative duration.')
    if not 3 <= args.live_offset <= 30:
        parser.error('Use a live offset between 3 and 30 seconds.')
    args.live_offset = max(args.live_offset, 3*args.segment_seconds)
    if args.stop:
        return stop_running()
    if args.build_only:
        build_helpers()
        return 0
    if args.background:
        return background(args)
    def handle_signal(sig,_):
        global STOP_SIGNAL
        STOP_SIGNAL=sig;STOP.set()
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):signal.signal(sig,handle_signal)
    return serve(args)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
