# Live HLS results — 8 November 2026

These are the initial bring-up measurements. The later one-second, audio-clock-based stream and dedicated player are documented in [LATENCY-NOTES.md](LATENCY-NOTES.md); that configuration is now the default.

## Observed working

- MacBook Air M1, macOS 27.2, installed HDMI Lab 16ch driver and mirror, 48 kHz/16-channel/float32.
- Apple Music playing the Dolby Atmos version of “Dancing In The Flames”. The existing Music multichannel strategy preference was 0; it was not changed.
- Hisense 55U7H VIDAA on the local network. QuickTime reported live external playback on your TV.
- The old DTS/HDMI bridge was stopped through its own cleanup helper before HLS was started.
- HLS used AC-3 5.1(side), 48 kHz, 384 kbit/s and H.264 640×360/24 video.
- At a live verification snapshot 143 seconds after startup, the TV had made 96 HTTP requests, including 52 successful segment requests. Twenty-four music segments were retained, matching the bounded buffer design.
- The user confirmed: **“Yes—music and surrounds sound right”**, in response to a question about live music, surround output and absence of echo/repeated audio.

## Source measurements

Twenty seconds of virtual-mirror metering measured these peak amplitudes in driver channel order:

```text
L/R:        0.52733 / 0.54126
C/LFE:      0.00374 / 0.04979
Ls/Rs:      0.11393 / 0.12075
Lrs/Rrs:    0.02945 / 0.03442
Lw/Rw:      0.10479 / 0.10548
Ltf/Rtf:    0.03183 / 0.02999
Ltm/Rtm:    0.04049 / 0.03877
Ltr/Rtr:    0.02135 / 0.02381
```

Every source channel showed activity. These are level measurements, not recordings or proof of exact speaker orientation.

An actual live segment probed as six-channel AC-3 5.1(side). Its decoded RMS levels in dBFS were approximately -28.47, -28.86, -64.75, silence, -33.23 and -32.73. The short sampled passage had a silent LFE channel; this does not imply that the source LFE was always silent or that six channels must always contain signal.

## Automated checks

- Synthetic HLS integration: passed. Six active decoded audio channels; media sequence advanced from 0 to 5; old segments were pruned; requests without the session path or for source files were rejected; normal stop removed the media directory and active-state file.
- Existing shared conversion/preflight tests: all five passed, including individual source-channel fold destinations and the original DTS encode/decode path.
- The two Swift helpers compiled locally. No drivers were reinstalled and no TV firmware/settings were modified.

## Cinematic visuals follow-up

- The dedicated player delivered the 1280×720 H.264 scene with AC-3, six channels at 48 kHz, verified from an actual served segment. At about 82 seconds the TV had fetched 68 segments successfully; the encoder reported no dropped video frames.
- The current artist gallery supplied five photos. The listener confirmed **“Looks good; music is smooth”** after the cinematic layout was enabled on the TV.
- The offline multi-photo integration passed with visible encoded video, six active synthetic audio channels, continuous audio timestamps and a metadata change without restarting the encoder. Over its short run, encoder progress was approximately 1.06× with no dropped frames. Normal macOS GPU access is required for this visual check.
- The existing isolated HLS delivery/cleanup regression also passed again. The visual design, sources, caching and limits are documented in [VISUALS.md](VISUALS.md). These checks do not establish long-term acoustic latency or frame-accurate metadata/audio synchronization.

## Independent installation follow-up

- The running server was verified with parent PID 1, outside the launcher's process tree. The installed player reported active TV playback, rate 1 and no playback error; the visual controller loaded a five-photo artist gallery.
- All three Desktop shortcuts resolved to the runnable package under Applications. Both the server's scoped keep-awake assertion and the player's real-time playback activity assertion were present.
- An isolated synthetic launchd test verified operation after the launcher exited, successful HTTP delivery, explicit-stop cleanup, and unexpected-interrupt cleanup without selecting speaker fallback. The ordinary HLS delivery/cleanup check passed again with six active audio channels and continuous packet timestamps.
- Closing ChatGPT itself must be checked by the user after the agent turn ends; the independent process ownership and short-lived launcher test establish that the server has no ChatGPT parent-process dependency.

## Limits

This is a live experimental listening result, not a long-duration reliability test. End-to-end latency, synchronization against another room, long-run clock drift, reconnect after sleep, and different devices remain unmeasured. This path encodes a 5.1 speaker bed and does not preserve Atmos objects. The HLS service was intentionally left running for the user; Stop-HLS.command performs cleanup and restores the previous Mac output.
