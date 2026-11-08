# Handoff: finish on the Mac

Everything in branch `claude/serene-faraday-xndn81` was written in a Linux cloud session that could not build Swift or reach the Mac. The Python parts were tested there (`test_bridge.py` 5/5, `test_hls.py` passed). **The Swift changes have never been compiled.** The next session runs on the Mac, builds, fixes anything the compiler dislikes, verifies, reinstalls the Desktop package, and does a live check on the TV.

Part 1 is for the person. Part 2 is the prompt to paste into Claude Code. Part 3 is context for the session that receives it.

---

## Part 1: steps for the person (Terminal on the Mac)

Each grey box is one command. Paste it, press Return, wait for it to finish.

### 1. Stop the running stream

Double-click **Stop Surround Server.command** on the Desktop.

### 2. Open Terminal

`⌘ Space`, type `Terminal`, Return.

### 3. Install Claude Code (once)

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

Close Terminal completely (`⌘ Q`), open it again.

### 4. Get the code

Fresh copy in the home folder:

```bash
cd ~ && git clone https://github.com/kopiticatalan/apple-music-surround-hdmi.git
```

If the folder already exists, that command will say so; that's fine. Either way:

```bash
cd ~/apple-music-surround-hdmi && git fetch origin && git checkout claude/serene-faraday-xndn81 && git pull
```

### 5. Start Claude Code in that folder

```bash
claude
```

(If it says `command not found`, use `~/.local/bin/claude` instead.) Log in when asked.

### 6. Paste the prompt from Part 2

Copy the whole grey box in Part 2, paste it into Claude Code, Return. Approve the permission requests it shows. Click **Allow** on any macOS dialogs (Music access, local network). The first Swift build takes a minute or two. When it starts the stream and opens **Surround Stream**, pick the TV with the AirPlay button, play an Atmos song in Music, and look at the TV.

### 7. When you are happy with it

Quit Claude Code (`/exit`), then publish to `main`:

```bash
cd ~/apple-music-surround-hdmi && git checkout main && git merge claude/serene-faraday-xndn81 && git push
```

---

## Part 2: prompt to paste into Claude Code

```text
Read HANDOFF.md first and follow Part 3. Branch claude/serene-faraday-xndn81 is checked out.

Goal: build and verify the Swift changes on this Mac, fix any compile errors without changing behaviour, preview the new now-playing scene and polish it, then reinstall the Desktop package and do a live check.

Steps, in order:
1. zsh Build.command          (driver tests + AudioBridge + SinkProbe)
2. zsh Build-HLS.command      (TileRenderer + Surround Stream.app)
   If swiftc reports errors, fix them minimally and rebuild. The design intent is in VISUALS.md.
3. python3 test_bridge.py && python3 test_hls.py && python3 test_visuals.py && python3 test_service.py
4. Preview the scene: write a scene.json with real local photos (any 2–3 JPEGs from ~/Pictures or
   ~/Applications/Surround\ Stream/runtime/artist-cache/*.jpg), then
     build/TileRenderer --snapshot scene.json preview-settled.png 5
     build/TileRenderer --snapshot scene.json preview-entering.png 0.4
   Open the PNGs and judge them: clean, cinematic, Metro/WP8 flavour. Adjust TileRenderer.swift
   layout/colour if anything looks off (text clipping, tile placement, accent too loud), rebuild, re-snapshot.
   Show me the final preview before continuing.
5. Make sure no stream is running (zsh Stop-HLS.command), then python3 install_user.py to update
   ~/Applications/Surround Stream and the Desktop shortcuts.
6. Start it for real from the installed copy: cd ~/Applications/Surround\ Stream && zsh Start-HLS-Server.command
   (the TV address is saved there), then python3 HLSService.py --player. I will pick the TV and play an
   Atmos track in Music. Afterwards check runtime/hls-console.log and the newest runtime/hls-*/capture.log
   for "overflowed" or "underruns" lines and report them.
7. Commit the fixes on this branch with a clear message. Do not push to main.

Do not change the audio path: the 16→5.1 fold, limiter, AC-3/DTS settings, HLS timing and player offsets stay as they are.
```

---

## Part 3: context for the session

### What changed in this branch (commit `91e3022`)

| Area | File(s) | Change |
|---|---|---|
| Lifecycle | `HLSBridge.py`, `HLSService.py`, `HLSPlayer.swift`, `TileVisuals.py`, `test_service.py` | A second start while the server is running or still starting now waits and reports the live address (`wait_until_ready`) instead of exiting instantly or replacing the job; `HLSService.start` refuses to bootout a running job; any signal restores the previous output and only a pipeline crash (no signal) keeps the virtual sink; the player backs off after launching the server and stops after 20 retries; stale `music-now-playing.json` from an earlier session is ignored; `HLSService.py --start` merges saved server options with new flags; `--player` honours `HLS_RUNTIME`; `failure()` reports a signal as 128+n; `test_service.py` skips off macOS and covers the crash path by killing the server's ffmpeg children. |
| Polling | `Bridge.py`, `HLSBridge.py` | `Bridge.default_output()` uses `SinkProbe default-name` once a second; the full `inventory()` + `source_ready()` runs every `FORMAT_CHECK_SECONDS` (10). `StopBridge.py` reuses `active_bridge_pid`. |
| Capture | `AudioBridge.swift` | `Ring` rewritten: raw buffer, `memcpy` in ≤2 segments, lock held only for the copy. `Capture` validates every sample and copies into a 1 s ring in one pass with no allocation on the audio thread; a writer thread does the blocking pipe writes and logs ring overflows. `RawCapture` reuses a staging buffer. Play path shares `started`/`underruns` through `PlayState` (locked). |
| Meter | `SinkProbe.swift` | `scansHeaders` decided once per device; three-word history is a `UInt64` shift register; peaks walk frame by frame; cached `ISO8601DateFormatter`; `iec61937Headers` built from two counters (same output shape). |
| Visuals | `TileRenderer.swift`, `VISUALS.md` | Full redesign, see below. ImageIO decode on a background queue (`decodeQueue`), swapped in with a dissolve; one reused `frameBuffer` written with `write(2)`; cached `base`, `lighting`, `tileShadow`, text and chrome textures. |
| Docs | `CHANGELOG.md` (0.6.0), `INDEPENDENT-PLAYBACK.md`, `README-HLS.md` | Updated. |

### The scene (what it should look like)

1280×720. Full-bleed artist photo, cover-fit, slow zoom (1.08 ± 0.025) and drift, graded slightly calm (`CIColorControls` saturation 0.84, contrast 1.06). A cached lighting layer darkens the left for type and lifts toward the right, with a soft vignette. With ≥2 photos the backdrop dissolves to the next every 24 s (1.8 s dissolve).

Accent colour: average of the hero photo via `CIAreaAverage`, saturation clamped 0.55–0.82, brightness 0.93; near-grey photos fall back to amber `(0.95, 0.72, 0.44)`. It appears in three places only: the `now playing` eyebrow, a 44×2 rule between title and artist, and a 4 px bar on the tile's left edge.

Tile: with ≥2 photos, a flat 300×300 square at centre `(1046, 370)` showing the *next* photo, square-cropped favouring the upper part (faces). Every 44 s it does the live-tile flip (`scaleX = |cos πt|` over 0.75 s, image swap at the midpoint). Soft cached shadow under it. Hidden when there is only one photo.

Type block (bitmap 820×470 placed at canvas `(64, 150)`, text inset to x=84): lowercase `now playing` eyebrow (15 pt medium, tracking 3.2, accent, with a 7×7 accent square), title in `.light` auto-sized 76→44 pt to fit two lines in 740 px (kern −1.5), artist 30 pt regular at 94 % white, album 18 pt light at 56 % white. On a track change each line slides in from +110 px with `easeOut` over 0.9 s, staggered 0 / 0.08 / 0.22 / 0.34 s, then drifts ±6 px. The previous frame cross-dissolves out over 1.0 s on any change (track or photo set).

Chrome: `S U R R O U N D   S T R E A M   ·   D O L B Y   D I G I T A L   5 . 1` bottom-left at 36 % white; artwork credit bottom-right at 32 %.

### Things to watch when compiling

- `TileRenderer.swift` uses `CIImage(bitmapData:bytesPerRow:size:format:colorSpace:)`, `CIImage.empty()`, `NSGradient.draw(in:relativeCenterPosition:)`, `CGImageSourceCreateThumbnailAtIndex`, implicit `CGFloat`/`Double` mixing. All long-standing; any complaint is local.
- Coordinate system: CoreImage is y-up; the AppKit text bitmaps are drawn y-up into `NSBitmapImageRep` and wrapped with `CIImage(cgImage:)`, the same pattern the previous renderer used and that displayed correctly. Row order of the raw RGBA frames handed to FFmpeg is unchanged from before. If the TV picture is upside down, apply `CGAffineTransform(scaleX: 1, y: -1)` plus a translate before the final `gpu.render`, not in FFmpeg.
- `AudioBridge.swift`: `Ring` is shared by capture and play. `Capture.staging` is a raw pointer reused across callbacks. `Thread.qualityOfService` is set before `start()`.
- `SinkProbe.swift`: the `continue` inside the header loop continues the inner channel loop, as before.
- If `test_visuals.py` reports a blank frame, confirm `gpu.render(... toBitmap: frameBuffer ...)` runs before `emit()`/`savePNG()`.

### Things to judge in the preview

- Title never clips at two lines; long titles truncate with an ellipsis.
- Accent is visible but quiet. If it reads muddy, tune the clamp in `accentFrom`.
- Tile doesn't collide with long titles (title width is 740 px, tile starts at x=896).
- Lighting is dark enough on the left for white text over a bright photo.

### After the live check

Report whether `capture.log` shows `capture ring overflowed` (should not) and whether `hls-console.log` shows the route being restored repeatedly (should not). Commit on this branch only; the person merges to `main` themselves.
