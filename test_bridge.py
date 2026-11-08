#!/usr/bin/env python3
"""Offline checks. No Core Audio access, installation, live playback or music files."""
import copy, math, os, struct, subprocess, unittest
from unittest.mock import patch
import Bridge

def virtual(name, direction):
    return {'name':name, 'transport':'hdmi', 'output':[], 'input':[], direction:[{
        'physical':{'id':'lpcm','channels':16,'rate':48000,'bits':32,'flags':1}}]}

def source_inventory():
    return {'devices':[virtual(Bridge.MAIN,'output'), virtual(Bridge.MIRROR,'input')]}

class Preflight(unittest.TestCase):
    def test_source_requires_full_width_float_pcm(self):
        inv = source_inventory()
        Bridge.source_ready(inv)
        for key, bad in [('id','cac3'),('channels',2),('rate',44100),('bits',16),('flags',0)]:
            broken = copy.deepcopy(inv)
            broken['devices'][1]['input'][0]['physical'][key] = bad
            with self.assertRaises(RuntimeError):
                Bridge.source_ready(broken)

    def test_sink_selection_never_chooses_virtual_or_ambiguous_output(self):
        carrier = {'id':'cac3','rate':48000,'channels':2,'bits':16,'bytesPerFrame':4}
        def device(name):
            return {'name':name,'transport':'hdmi','output':[{'availablePhysical':[carrier]}]}
        inv = {'devices':[device(Bridge.MAIN),device('Test HDMI')]}
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(Bridge.hdmi_sink(inv), 'Test HDMI')
            inv['devices'].append(device('Other HDMI'))
            with self.assertRaises(RuntimeError): Bridge.hdmi_sink(inv)
        with patch.dict(os.environ, {'DD51_HDMI':'Other HDMI'}, clear=True):
            self.assertEqual(Bridge.hdmi_sink(inv),'Other HDMI')
        with patch.dict(os.environ, {'DD51_HDMI':'Not attached'}, clear=True):
            with self.assertRaises(RuntimeError): Bridge.hdmi_sink(inv)

    def test_measurement_parser_keeps_silence_distinct(self):
        parsed = Bridge.astats('Channel: 1\nPeak level dB: -2.5\nRMS level dB: -12\n'
                              'Channel: 2\nPeak level dB: -inf\nRMS level dB: -inf\n'
                              'Overall\nRMS level dB: -22\n')
        self.assertEqual(parsed[1], {'peakDb':-2.5,'rmsDb':-12})
        self.assertEqual(parsed[2], {'peakDb':None,'rmsDb':None})

@unittest.skipUnless(Bridge.FFMPEG, 'FFmpeg not installed; synthetic audio checks skipped')
class Conversion(unittest.TestCase):
    def ffmpeg(self, args, data):
        p = subprocess.run([Bridge.FFMPEG,'-nostdin','-hide_banner','-loglevel','error',*args],
                           input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(p.returncode,0,p.stderr.decode(errors='replace'))
        return p.stdout

    def test_each_source_channel_reaches_the_intended_speakers(self):
        # One source at a time: this detects accidental named-layout reordering.
        frames = 1600
        samples = [0.0] * (16 * frames * 16)
        for channel in range(16):
            for frame in range(frames):
                samples[((channel*frames)+frame)*16+channel] = 0.02
        data = struct.pack('<'+'f'*len(samples), *samples)
        # Check the matrix before the limiter, whose look-ahead shifts sample times.
        matrix = Bridge.PAN.split(',alimiter=')[0]
        raw = self.ffmpeg(['-f','f32le','-ar','48000','-ac','16','-i','pipe:0',
                           '-af',matrix,'-f','f32le','pipe:1'], data)
        values = struct.unpack('<'+'f'*(len(raw)//4),raw)
        expected = [(0,1),(1,1),(2,1),(3,1),(4,1),(5,1),(4,.707),(5,.707),
                    (0,.707),(1,.707),(0,.707),(1,.707),(4,.707),(5,.707),(4,.707),(5,.707)]
        for source, (destination,gain) in enumerate(expected):
            offset = (source*frames+frames//2)*6
            for out in range(6):
                self.assertAlmostEqual(values[offset+out], .02*gain if out==destination else 0, places=6)

    def test_synthetic_dts_carrier_round_trip_has_six_active_channels(self):
        rate, frames = 48000, 48000
        data = bytearray(frames*16*4)
        for frame in range(frames):
            for channel in range(16):
                v = .015*math.sin(2*math.pi*(220+channel*47)*frame/rate)
                struct.pack_into('<f',data,(frame*16+channel)*4,v)
        encoded = self.ffmpeg(['-f','f32le','-ar','48000','-ac','16','-i','pipe:0',
            '-af',Bridge.PAN,'-ar','48000','-c:a','dca','-strict','-2','-b:a','1411200',
            '-f','spdif','pipe:1'],data)
        self.assertEqual(encoded[:4], b'\x72\xf8\x1f\x4e')
        decoded = self.ffmpeg(['-f','spdif','-i','pipe:0','-f','f32le','pipe:1'],encoded)
        self.assertEqual(len(decoded) % 24,0)
        values = struct.unpack('<'+'f'*(len(decoded)//4),decoded)
        for channel in range(6):
            signal = values[channel::6]
            self.assertTrue(signal)
            self.assertTrue(all(math.isfinite(v) for v in signal))
            rms = math.sqrt(sum(v*v for v in signal)/len(signal))
            self.assertGreater(rms,.0001)

if __name__ == '__main__':
    unittest.main(verbosity=2)
