# Changes

## 0.5.0 — independent playback and Desktop shortcuts, 2026-11-08

- Background streaming runs in a user launchd job associated with the player app, outside ChatGPT or Terminal. No login or boot autostart is installed.
- A user installer places the runnable package under Applications and creates Desktop shortcuts for the app, server and stop control.
- Unexpected server termination keeps Music on the virtual output. Failed media is paused/muted; Reconnect can restart the saved server configuration.
- Scoped keep-awake and latency-critical activity assertions support continuous playback. Global power preferences remain unchanged.
- The player can supply Music metadata to the renderer. Added isolated service-lifecycle checks.

## 0.4.0 — cinematic artist visuals, 2026-11-08

- Live Music metadata drives 720p artist photography, slow zoom, layered drifting prints and opposing text motion inspired by Windows Phone 8 live tiles.
- GPU compositing with decoded textures, cached lighting/shadows and audio-clock backpressure keeps the visual pipeline real time.
- Asynchronous Apple Music portraits and TheAudioDB galleries, exact artist matching, local bounded caching and source credits. No artwork is bundled.
- Visuals enabled by the HLS launcher; `--no-visuals` retains the plain background. Synthetic visual integration covers six active AC-3 channels and continuous audio timestamps.

## 0.3.0 — experimental AirPlay HLS output, 2026-11-08

- Live AC-3 5.1 HLS output from the existing virtual surround capture, with one-second audio-clock-paced segments and bounded cleanup.
- Locally built Surround Stream AirPlay controller with live-offset controls and automatic local muting to prevent feedback.
- Configurable TV address, start/stop/build helpers, synthetic HLS integration checks and listening/latency notes.
- Observed on Hisense 55U7H VIDAA; listener-reported track-change delay improved to about 2–4 seconds with the dedicated player. Other receivers and long-duration reliability remain untested.
- Original DTS/HDMI workflow and driver source preserved. No compiled apps, runtime state, logs or music buffers are included.

## 0.2.0 — public source package, 2026-11-08

- Portable source builds for the native Mac architecture, with driver loopback tests.
- Generic HDMI discovery, explicit speaker assignments and guarded IEC 61937 playback.
- Build/install/uninstall/play/stop helpers and detailed reproducibility notes.
- Removed personal paths, local logs, saved preferences, artwork and compiled binaries.
- Verification restores the prior audio route and no longer depends on a chat session.

## 0.1.1 — locally verified experiment

- Corrected explicit channel descriptions for 7.1 and 9.1.6.
- Measured independent Apple Music surround/height PCM channels.
- Verified a live DTS encode/decode round trip and audible HDMI surround playback.

The public source package has build and synthetic tests. Its portability changes have not been installed over the original listening setup during publication.
