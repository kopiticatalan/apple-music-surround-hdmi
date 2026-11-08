# Changes

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
