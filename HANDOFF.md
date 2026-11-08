# Handoff: finish on the Mac

Everything in this branch was written in a Linux cloud session that could not build Swift or reach the Mac. The Python parts were tested there (`test_bridge.py` 5/5, `test_hls.py` passed). **The Swift changes have never been compiled.** The next session runs on the Mac, builds, fixes anything the compiler dislikes, verifies, and reinstalls.

## How to start the new session (on the Mac)

Option A, Terminal:

```bash
cd ~/path/to/apple-music-surround-hdmi
git fetch origin && git checkout claude/serene-faraday-xndn81 && git pull
claude
```

Option B, Claude desktop app: open Claude Code, choose this repository folder.

Then paste the prompt below.

## Prompt to paste

```text
Read HANDOFF.md first and follow it. Branch claude/serene-faraday-xndn81 is checked out.

Goal: build and verify the Swift changes on this Mac, fix any compile errors without changing behaviour, preview the new now-playing scene and polish it, then reinstall the Desktop package.

Steps, in order:
1. zsh Build.command          (driver tests + AudioBridge + SinkProbe)
2. zsh Build-HLS.command      (TileRenderer + Surround Stream.app)
   If swiftc reports errors, fix them minimally and rebuild. The design intent is in VISUALS.md.
3. python3 test_bridge.py && python3 test_hls.py && python3 test_visuals.py && python3 test_service.py
4. Preview the scene: write a scene.json with real local photos (any 2–3 JPEGs in ~/Pictures or
   runtime/artist-cache/*.jpg), then
     build/TileRenderer --snapshot scene.json preview-settled.png 5
     build/TileRenderer --snapshot scene.json preview-entering.png 0.4
   Open the PNGs and judge them: clean, cinematic, Metro/WP8 flavour. Adjust TileRenderer.swift
   layout/colour if anything looks off (text clipping, tile placement, accent too loud), rebuild, re-snapshot.
5. Stop any running stream (zsh Stop-HLS.command), then python3 install_user.py to update
   ~/Applications/Surround Stream and the Desktop shortcuts.
6. Start it for real: zsh Start-HLS-Server.command (TV address is saved), open Surround Stream from
   the Desktop, pick the TV, play an Atmos track in Music, and confirm audio and the new visuals on the TV.
   Check runtime/hls-console.log and the run's capture.log for "overflowed" or "underruns" lines.
7. Commit the fixes on this branch with a clear message. Do not push to main.

Do not change the audio path: the 16→5.1 fold, limiter, AC-3/DTS settings, HLS timing and player offsets stay as they are.
```

## What changed (so the next session knows where to look)

| Area | File(s) | Change |
|---|---|---|
| Lifecycle | `HLSBridge.py`, `HLSService.py`, `HLSPlayer.swift`, `TileVisuals.py`, `test_service.py` | Second start waits for a starting server instead of exiting instantly; `HLSService.start` refuses to kill a running job; any signal restores the previous output, only a crash keeps the virtual sink; player backs off after launching the server; stale `music-now-playing.json` ignored; `--start` merges saved options; `--player` honours `HLS_RUNTIME`; `failure()` reports signals as 128+n; test guards for macOS and covers the crash path. |
| Polling | `Bridge.py`, `HLSBridge.py` | Route check uses `SinkProbe default-name` every second; full inventory every 10 s. |
| Capture | `AudioBridge.swift` | `Ring` rewritten with `memcpy` segments; `Capture` validates+copies in one pass into a 1 s ring, writer thread does pipe I/O; `RawCapture` reuses a staging buffer; play path shares `started`/`underruns` through a lock. |
| Meter | `SinkProbe.swift` | Header scan decided per device, shift-register history, cached date formatter. |
| Visuals | `TileRenderer.swift`, `VISUALS.md` | Full redesign (see VISUALS.md); ImageIO decode on a background queue; reused frame buffer; cached textures. |
| Docs | `CHANGELOG.md`, `INDEPENDENT-PLAYBACK.md`, `README-HLS.md` | Updated for the above. |

## Things to watch when compiling

- `TileRenderer.swift` uses `CIImage(bitmapData:bytesPerRow:size:format:colorSpace:)`, `CIImage.empty()`, `NSGradient.draw(in:relativeCenterPosition:)`, `CGImageSourceCreateThumbnailAtIndex`. All are long-standing APIs; if one is flagged, the fix is local.
- `AudioBridge.swift`: the new `Ring` is used by both capture and play. `Capture.staging` is a raw pointer reused across callbacks (allocation happens once).
- `SinkProbe.swift`: `report()` now builds the `iec61937Headers` dictionary from two counters; output shape is unchanged.
- If `test_visuals.py` reports a blank frame, check that `gpu.render(... toBitmap:)` is writing into `frameBuffer` and that `savePNG` sees the same buffer.

## Known limits

- Row order of the raw RGBA frames is the same as the previous renderer (CIContext → buffer → FFmpeg rawvideo); if the TV picture is upside down, flip with `CGAffineTransform(scaleX: 1, y: -1)` before the final render, not in FFmpeg.
- The accent colour is the artwork's average; for very dark or very busy photos it can land on a muddy hue. The clamp in `accentFrom` (saturation 0.55–0.82, brightness 0.93) is where to tune.
