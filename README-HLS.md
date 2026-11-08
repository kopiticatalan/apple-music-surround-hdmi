# Apple Music surround over AirPlay HLS

A working experimental Mac-side HLS output for [Apple Music surround HDMI](https://github.com/kopiticatalan/apple-music-surround-hdmi). It reuses the virtual surround sink and capture, folds the rendered channels to 5.1, then serves Dolby Digital to the TV through AirPlay media playback.

**Live listening confirmed on 8 November 2026:** MacBook Air M1, macOS 27.2, installed HDMI Lab 16ch driver, Apple Music Atmos content, Hisense 55U7H VIDAA named your TV. The listener confirmed that the music and surround speakers sounded right. No TV modification was needed.

```text
Apple Music Atmos render → HDMI Lab 16ch → virtual mirror capture
    → explicit 16-to-6 fold → AC-3 5.1 encoder → local live HLS
    → Surround Stream AirPlay media playback → your TV / sound system
```

The output is lossy **Dolby Digital 5.1, 48 kHz, 384 kbit/s**, with a small H.264 video track. Atmos object metadata is not retained. Stereo material is not turned into true surround. The original DTS/HDMI implementation remains available; see [README.md](README.md).

## Requirements

- The existing **HDMI Lab 16ch** and **HDMI Lab 16ch Mirror** devices, configured for **48 kHz, 16-channel, 32-bit float PCM**. This HLS extension does not reinstall drivers. For initial driver setup, use the original HDMI instructions.
- Python 3.9+, FFmpeg with `ac3`, `libx264`, and HLS support, and Xcode Command Line Tools for building the Swift helpers. The visual renderer uses macOS Core Image and normal GPU access.
- An Apple Music subscription and an Atmos track. Use the settings established for the original experiment: Atmos Automatic, HDMI Passthrough Off, Song Transitions/AutoMix Off, and the existing experimental `multichannelAudioStrategy=0` preference. This bridge does not change Music preferences.
- The Mac and TV on the same LAN. Supply the TV address with `--tv` or `HLS_TV_IP`. The double-click launcher asks for it when no active session or environment setting supplies it.

## Start playback

1. Select **HDMI Lab 16ch** as the Mac sound output and start an Atmos song in Music. The Music mini-player should show Dolby Atmos. Stop the old DTS/HDMI bridge before switching to this output path.
2. Double-click **Play-HLS-over-AirPlay.command**, or run it from Terminal:

   ```sh
   zsh Play-HLS-over-AirPlay.command --tv 192.168.1.100
   ```

   It builds missing Swift helpers, starts the background capture/server, and opens **Surround Stream.app**. Nothing is installed. The app reads the current HLS URL automatically.

3. In **Surround Stream**, use the AirPlay button to choose **your TV**. The TV displays the animated artist scene while the music plays. Keep the buffer mode on **Fast** for the tested setup. The displayed mode duration is a requested offset, not a guaranteed audible delay.
4. Leave Music playing into **HDMI Lab 16ch**. Select the TV inside Surround Stream's media AirPlay picker. Selecting the TV as the Mac's general sound output would move Music away from the surround capture device.

Surround Stream automatically mutes local playback so its decoded audio cannot feed back into the virtual capture sink. **Play Live** resumes at the live edge; **Go Live** explicitly clears accumulated delay; **Reconnect** loads a new URL after the bridge is restarted. Closing the app stops its playback; Stop-HLS.command stops capture and serving.

QuickTime remains a fallback: open the URL from `runtime/ACTIVE-HLS.json` with Command-L, pause local playback, choose your TV in its AirPlay picker, then play. Its larger receiver buffer still produced roughly ten seconds of delay during testing. Keep any fallback HLS player on the TV while capture is running, because its local playback can feed back into the capture sink.

For a changed TV address or occupied server port:

```sh
zsh Play-HLS-over-AirPlay.command --tv 192.168.1.101 --port 8766
```

The HLS address is session-specific and changes on restart. Requests are accepted only from the Mac, localhost, and the specified TV address. Do not use a second capture bridge at the same time.

## Artist visuals

The launcher enables cinematic artist photography, very slow zoom, drifting photo prints and opposing song/artist text motion. Artwork follows the current Music track. Photos load asynchronously from Apple Music and TheAudioDB, with local caching and on-screen credits. Use `--no-visuals` for the plain background, or add `--visuals` when starting HLSBridge.py directly. See [visual design, artwork sources and privacy](VISUALS.md).

## Stop

Pause or close Surround Stream, then double-click **Stop-HLS.command**, or run:

```sh
zsh Stop-HLS.command
```

This stops capture, encoding and HTTP serving, removes the rolling music segments, and restores the Mac output that was selected when HLS started. Foreground mode (`python3 HLSBridge.py`) also supports Control-C. A force kill or power failure can interrupt cleanup; stop normally when possible.

## Buffering and diagnostics

- One-second segments, a twelve-second live playlist, and roughly 24 seconds of retained segments bound the disk buffer. Retained files are a recovery buffer, not a mandatory playback delay. HLS temporarily writes compressed music to disk and deletes it on normal stop. There is no upload, permanent music archive, or Internet-facing service.
- After the latency changes, the listener reported **about 2–4 seconds** on track changes, compared with roughly ten seconds using QuickTime. This is a listening estimate, not an instrumented acoustic measurement. Long-duration clock drift has not been measured. See [LATENCY-NOTES.md](LATENCY-NOTES.md).
- The video track follows the captured audio clock. It no longer runs on a separate real-time input clock. The 5.1 fold, 48 kHz sample rate and 384 kbit/s AC-3 settings are unchanged.
- `runtime/ACTIVE-HLS.json` reports the current URL, latest segment, uptime and per-client request counts. Capture/encoder logs are in that session's runtime directory. They contain diagnostics, not PCM recordings. Review private device/network metadata before sharing logs.
- If there is silence, check that Music is playing, its output remains HDMI Lab 16ch, the source has surround activity, and Surround Stream is still playing on the TV. A quiet centre or LFE channel during a passage is normal.
- The player's clock-based delay estimate can differ from the heard track-change delay. It is diagnostic metadata from the media timeline, not a measurement of sound at the speakers. The app does not repeatedly seek during normal playback. It retries a stalled play command without seeking; an explicit resume, reconnect or Go Live can reposition to live.
- If the TV's address changes, stop and restart with `--tv` set to its new address. If the Mac sleeps, a device is unplugged, or the stream ends, restart the bridge and reopen its new URL.

## Verification

```sh
zsh Build-HLS.command
python3 test_hls.py
python3 test_visuals.py
python3 test_bridge.py
```

`Build-HLS.command` builds the Swift capture/inventory helpers and the local player app. `test_hls.py` runs about seventeen seconds of quiet synthetic sixteen-channel input on a separate localhost server. It checks six-channel AC-3 delivery, continuous audio packet timestamps across segment boundaries, playlist advancement, bounded pruning, HTTP path controls, and stop cleanup. It does not capture Music, change sound routing, or interrupt the running bridge. The existing `test_bridge.py` checks the shared channel fold and original DTS path.

The live test also measured activity in all sixteen Music source channels, probed an actual served segment as AC-3 5.1(side), observed repeated successful TV segment requests, and obtained the listener's confirmation. See [HLS-TEST-RESULTS.md](HLS-TEST-RESULTS.md).

## Source and license

`HLSBridge.py` adds the HLS encoder, restricted local HTTP serving, lifecycle, bounded buffering and cleanup. `HLSPlayer.swift` and `build_player.py` provide the local AirPlay player. The bridge reuses `Bridge.py`'s explicit fold and preflight checks and `AudioBridge.swift`'s virtual PCM capture. The original driver, tests, build/install helpers and explanatory files are preserved. GPL-3.0; see [LICENSE](LICENSE), [NOTICE.md](NOTICE.md), and the original BlackHole attribution.

References: [Apple AirPlay media and AC-3 variants](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AirPlayGuide/PreparingYourMediaforAirPlay/PreparingYourMediaforAirPlay.html), [FFmpeg HLS muxer](https://ffmpeg.org/ffmpeg-formats.html#hls-2).
