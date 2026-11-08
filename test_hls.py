#!/usr/bin/env python3
"""Synthetic integration check: encode, HTTP delivery, live rollover, and cleanup.

No Core Audio routing changes and no Apple Music capture. Takes about 17 seconds.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

import HLSBridge as hls


def wait_for(predicate, seconds=25):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(.2)
    raise AssertionError('Timed out waiting for live test state')


def check():
    if hls.STATE.exists():
        raise SystemExit('Stop the live HLS bridge before running this isolated test.')
    hls.RUNTIME.mkdir(exist_ok=True)
    log_path = hls.RUNTIME / 'synthetic-test.log'
    with log_path.open('w') as log:
        process = subprocess.Popen([sys.executable, '-u', str(hls.HERE/'HLSBridge.py'),
            '--synthetic', '--tv', '127.0.0.1', '--bind', '127.0.0.1', '--port', '0', '--window', '3'],
            stdout=log, stderr=subprocess.STDOUT)
        run = None
        try:
            def ready_state():
                if process.poll() is not None:
                    raise AssertionError(log_path.read_text())
                s = hls.read_state()
                return s if s.get('pid') == process.pid and s.get('ready') else None
            state = wait_for(ready_state)
            run = Path(state['run'])
            master_url = state['url']
            base = master_url.rsplit('/', 1)[0] + '/'
            with urllib.request.urlopen(master_url, timeout=3) as response:
                assert response.headers['Cache-Control'] == 'no-store'
                assert 'mpegurl' in response.headers['Content-Type']
                assert 'ac-3' in response.read().decode()
            def playlist():
                with urllib.request.urlopen(base+'index.m3u8', timeout=3) as response:
                    return response.read().decode()
            first = playlist()
            assert '#EXT-X-ENDLIST' not in first
            assert '#EXT-X-START:TIME-OFFSET=-3.000,PRECISE=YES' in first
            assert '#EXT-X-TARGETDURATION:1' in first
            first_sequence = int(first.split('#EXT-X-MEDIA-SEQUENCE:')[1].splitlines()[0])
            segment = next(line for line in first.splitlines() if line.endswith('.ts'))
            probe = subprocess.run(['ffprobe', '-v', 'error', '-show_entries',
                'stream=codec_name,channels,channel_layout,sample_rate', '-of', 'json', base+segment],
                capture_output=True, text=True, check=True, timeout=10)
            streams = json.loads(probe.stdout)['streams']
            audio = next(s for s in streams if s['codec_name'] == 'ac3')
            assert audio['channels'] == 6 and audio['sample_rate'] == '48000'
            meter = subprocess.run(['ffmpeg', '-hide_banner', '-nostats', '-i', base+segment,
                '-map', '0:a:0', '-af', 'astats=metadata=0:reset=0', '-f', 'null', '-'],
                capture_output=True, text=True, check=True, timeout=10)
            levels = hls.Bridge.astats(meter.stderr)
            assert len(levels) == 6 and all(v['rmsDb'] is not None for v in levels.values())
            # Packet timestamps must be continuous across actual encoded segments.
            names = [line for line in first.splitlines() if line.endswith('.ts')]
            packet_ranges = []
            for name in names[:3]:
                packets = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'a:0',
                    '-show_packets', '-show_entries', 'packet=pts_time,duration_time', '-of', 'json', base+name],
                    capture_output=True, text=True, check=True, timeout=5)
                values = json.loads(packets.stdout)['packets']
                packet_ranges.append((float(values[0]['pts_time']),
                    float(values[-1]['pts_time'])+float(values[-1]['duration_time'])))
            for left, right in zip(packet_ranges, packet_ranges[1:]):
                assert abs(left[1]-right[0]) < .00001, packet_ranges
            for suffix, status in [('missing.ts', 404), ('../Bridge.py', 404)]:
                try:
                    urllib.request.urlopen(base+suffix, timeout=3)
                    raise AssertionError('Unexpectedly served '+suffix)
                except urllib.error.HTTPError as error:
                    assert error.code == status
            try:
                urllib.request.urlopen(urllib.parse.urlsplit(master_url)._replace(path='/master.m3u8').geturl(), timeout=3)
                raise AssertionError('Served media without the session path')
            except urllib.error.HTTPError as error:
                assert error.code == 403
            wait_for(lambda: hls.read_state().get('uptimeSeconds', 0) >= 16, seconds=15)
            later = playlist()
            later_sequence = int(later.split('#EXT-X-MEDIA-SEQUENCE:')[1].splitlines()[0])
            assert later_sequence > first_sequence
            assert len(list((run/'media').glob('*.ts'))) <= 7
            assert not (run/'media'/segment).exists(), 'Old music segment was not pruned'
            result = {'passed': True, 'codec': audio, 'activeChannels': len(levels),
                      'firstSequence': first_sequence, 'laterSequence': later_sequence,
                      'httpControls': 'passed', 'boundedRollover': 'passed',
                      'audioTimestampContinuity': 'passed', 'segmentSeconds': 1,
                      'encoderProgress': hls.read_state().get('encoderProgress')}
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
            process.wait(timeout=10)
        assert process.returncode == 0, log_path.read_text()
        assert not hls.STATE.exists()
        assert run is not None and not (run/'media').exists()
        result['cleanup'] = 'passed'
        (hls.RUNTIME/'hls-test-result.json').write_text(json.dumps(result, indent=2))
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    # An independent runtime lets this regression run while the user's old
    # working stream is still active. Only quiet synthetic audio is generated.
    with tempfile.TemporaryDirectory(prefix='hls-latency-test-') as directory:
        os.environ['HLS_RUNTIME'] = directory
        hls.RUNTIME = Path(directory)
        hls.STATE = hls.RUNTIME/'ACTIVE-HLS.json'
        check()
        target = hls.HERE/'runtime'/'hls-test-result.json'
        target.parent.mkdir(exist_ok=True)
        target.write_text((hls.RUNTIME/'hls-test-result.json').read_text())
