# Latency tuning — 8 November 2026

## Result

The listener reported **about 2–4 seconds** between changing tracks in Apple Music and hearing the change on your TV after switching to the dedicated Surround Stream player. The preceding QuickTime test still had **about ten seconds** of delay even after shortening HLS segments. These are user listening estimates; no microphone-based end-to-end measurement was made.

Playback was left running in Surround Stream, in Fast mode, using the same AC-3 5.1 encoding settings and channel fold as before. The prototype is not a guarantee of sub-four-second latency on every network, track change, or receiver.

## Changes

- One-second segments instead of two-second segments. The live playlist now spans twelve seconds; approximately 24 seconds of media files remain available for recovery. Keeping old files does not force the player to render all of them.
- The small video track is generated from a silent branch of the captured audio, so both tracks share one clock. The earlier separately paced color input had logged periodic lag/catch-up events.
- Reduced the raw input queue and probing budget. AC-3 remains 48 kHz, six channels, 384 kbit/s; the existing speaker fold and limiter are unchanged.
- Added an initial near-live playlist hint and HTTP keep-alive. This is ordinary HLS with shorter segments, not a claim of implementing the full LL-HLS partial-segment protocol.
- Added encoder progress and per-client segment-request telemetry. Requesting the newest segment does not prove that the receiver is already playing it.
- Replaced QuickTime as the recommended playback controller with the small local **Surround Stream.app**, built from the included Swift source. It requests a one-second forward buffer and a two-second live offset in Fast mode, starts promptly, and keeps paused live state current. These are preferences; the receiver can impose its own buffering.
- The player seeks to live when connecting, explicitly resuming, changing buffer mode, or pressing Go Live. It does not run repeated automatic seeks during normal playback. A stalled play command is retried without seeking. Local playback is muted automatically to avoid capture feedback.

## Validation

- Synthetic integration passed: six active decoded AC-3 channels; one-second HLS target duration; continuous AC-3 packet timestamps across three adjacent segments; live sequence advancement; bounded pruning; HTTP path restrictions; cleanup.
- The revised live stream retained AC-3 5.1(side) at 48 kHz with H.264 640×360/25 video. The encoder reported zero dropped video frames during the observed test and no separate-video catch-up warnings.
- The native player compiled, connected to your TV, reported external playback active, and unmuted only after the AirPlay route became active. Go Live was exercised successfully.
- User listening comparison: QuickTime approximately ten seconds; Surround Stream approximately two to four seconds. Audio quality remained on the established encoding path. Long-duration stalls and Wi-Fi interruptions remain untested.

`runtime/player-status.json` records the player's programme-date and seekable-window estimates. Its displayed clock estimate can differ from the heard track-change delay; it is not an acoustic latency measurement. QuickTime's elapsed time also cannot be compared directly with bridge uptime because the timelines have different origins.

References: [Apple configuredTimeOffsetFromLive](https://developer.apple.com/documentation/avfoundation/avplayeritem/configuredtimeoffsetfromlive), [Apple preferredForwardBufferDuration](https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredforwardbufferduration), [FFmpeg HLS muxer](https://ffmpeg.org/ffmpeg-formats.html#hls-2).
