# Changes

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
