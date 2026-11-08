#!/usr/bin/env python3
"""Offline visual/5.1 integration; no Music, network, or sound-routing changes."""
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import time
import HLSBridge as hls


def check():
    hls.build_helpers()
    with tempfile.TemporaryDirectory(prefix='surround-visual-test-') as temporary:
        root=Path(temporary);media=root/'media';media.mkdir()
        picture=root/'photo.png'
        subprocess.run([hls.Bridge.FFMPEG,'-v','error','-f','lavfi','-i',
            'testsrc2=size=1280x720','-frames:v','1','-threads','1',str(picture)],check=True)
        processes=[]
        with (root/'renderer.log').open('wb') as render_log, (root/'encoder.log').open('wb') as encoder_log:
            renderer=subprocess.Popen([str(hls.Bridge.BUILD/'TileRenderer'),'--render',str(root/'visuals')],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=render_log);processes.append(renderer)
            capture=subprocess.Popen(hls.synthetic_capture(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
            processes.append(capture)
            def update(title):
                renderer.stdin.write((json.dumps({'key':title,'name':title,'artist':'Visual regression',
                    'album':'Synthetic audio only','imagePaths':[str(picture),str(picture)]})+'\n').encode())
                renderer.stdin.flush()
            update('First song')
            fd=renderer.stdout.fileno()
            encoder=subprocess.Popen(hls.encoder_command(media,20,visuals=True,video_fd=fd),
                stdin=capture.stdout,stdout=subprocess.PIPE,stderr=encoder_log,pass_fds=(fd,))
            processes.append(encoder);capture.stdout.close();renderer.stdout.close()
            progress={};lock=threading.Lock()
            threading.Thread(target=hls.progress_reader,args=(encoder.stdout,progress,lock),daemon=True).start()
            began=time.monotonic()
            try:
                time.sleep(6);update('A different song — same continuous stream')
                time.sleep(7)
                assert encoder.poll() is None,(root/'encoder.log').read_text()
                with lock:values=dict(progress)
                assert int(values.get('drop_frames',0))==0,values
                assert float(values['out_time_us'])/1e6>time.monotonic()-began-3,values
                names=sorted(media.glob('*.ts'))
                assert len(names)>=9,len(names)
                probe=subprocess.run(['ffprobe','-v','error','-show_entries',
                    'stream=codec_name,channels,width,height,sample_rate','-of','json',str(names[-2])],
                    capture_output=True,text=True,check=True)
                streams=json.loads(probe.stdout)['streams']
                assert any(s.get('width')==1280 and s.get('height')==720 for s in streams)
                assert any(s.get('codec_name')=='ac3' and s.get('channels')==6 for s in streams)
                pixels=subprocess.run([hls.Bridge.FFMPEG,'-v','error','-i',str(names[-2]),
                    '-frames:v','1','-vf','scale=32:18','-pix_fmt','rgb24','-f','rawvideo','pipe:1'],
                    capture_output=True,check=True).stdout
                assert max(pixels)-min(pixels)>120 and sum(pixels)/len(pixels)>10, \
                    'Renderer produced a blank frame; run with normal macOS GPU access.'
                ends=[]
                for path in names[4:7]:
                    result=subprocess.run(['ffprobe','-v','error','-select_streams','a:0','-show_packets',
                        '-show_entries','packet=pts_time,duration_time','-of','json',str(path)],
                        capture_output=True,text=True,check=True)
                    packets=json.loads(result.stdout)['packets']
                    ends.append((float(packets[0]['pts_time']),float(packets[-1]['pts_time'])+float(packets[-1]['duration_time'])))
                assert all(abs(a[1]-b[0])<.00001 for a,b in zip(ends,ends[1:])),ends
                meter=subprocess.run([hls.Bridge.FFMPEG,'-hide_banner','-nostats','-i',str(names[-2]),
                    '-map','0:a:0','-af','astats=metadata=0:reset=0','-f','null','-'],
                    capture_output=True,text=True,check=True)
                levels=hls.Bridge.astats(meter.stderr)
                assert len(levels)==6 and all(v['rmsDb'] is not None for v in levels.values())
                result={'passed':True,'video':'H.264 1280×720','audio':'AC-3 48 kHz, six active channels',
                    'metadataChange':'continuous encoder','visibleVideo':'passed',
                    'audioTimestampContinuity':'passed','encoderProgress':values}
            finally:
                for p in reversed(processes):
                    if p.poll() is None:p.terminate()
                for p in processes:
                    try:p.wait(timeout=4)
                    except subprocess.TimeoutExpired:p.kill();p.wait()
        print(json.dumps(result,indent=2))
        return result


if __name__=='__main__':check()
