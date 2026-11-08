# Results from the working setup

Date: 2026-11-08. Hardware: MacBook Air M1, macOS 27.2, physical HDMI to a TV and DTS-capable surround sound system. Original local driver: HDMI Lab 0.1.1 build 2. One hardware setup was tested; this is not a compatibility certification.

## Source PCM before encoding

Apple Music played the Atmos version of “Dancing In The Flames” by The Weeknd. A 192-record source measurement window contained 191 records with activity in both surround and height groups. All sixteen channels were nonzero at some point.

| Channel | Maximum absolute PCM sample |
|---|---:|
| L | 0.414727 |
| R | 0.382593 |
| C | 0.013607 |
| LFE | 0.053999 |
| Ls | 0.224547 |
| Rs | 0.193893 |
| Rls | 0.074125 |
| Rrs | 0.089804 |
| Lw | 0.157445 |
| Rw | 0.157411 |
| Ltf | 0.056235 |
| Rtf | 0.056782 |
| Ltm | 0.136425 |
| Rtm | 0.159753 |
| Ltr | 0.045608 |
| Rtr | 0.052613 |

This distinguishes an active multichannel source from a sixteen-channel container with only stereo content. It does not prove every speaker label acoustically; these are measurements before the sound system.

## Live DTS round trip

A separate twenty-second test captured Music's PCM, folded it to 5.1, encoded DTS, packaged IEC 61937, decoded it, and measured the decoded channels. No Music recording was retained.

| Decoded channel | RMS dBFS | Peak dBFS |
|---|---:|---:|
| Front left | -18.862993 | -7.858080 |
| Front right | -18.934823 | -7.515791 |
| Centre | -60.964525 | -37.994065 |
| LFE | -43.294780 | -23.703773 |
| Surround left | -28.929462 | -12.503589 |
| Surround right | -29.122482 | -14.201209 |

All six channels were active. This confirms the encode/decode path; it does not test the HDMI cable, TV's passthrough, or receiver.

## Physical playback

The HDMI backend successfully set the advertised 48 kHz two-channel sixteen-bit `cac3` carrier and streamed IEC 61937. After restoring Music's default route to the virtual sink, the listener reported that playback came from the sound system and the surrounds were audible, then confirmed the result was working.

No receiver format-display reading or isolated acoustic speaker-by-speaker measurement was recorded. The claim is successful audible surround on this setup, supported by source and encoded-channel measurements.

## Public package validation

The source build runs in-process driver tests for both 8 and 16 channels. `python3 test_bridge.py` runs the synthetic matrix and DTS round-trip checks without installed drivers, live Music, or HDMI. It reports failures as a nonzero exit code; if FFmpeg is unavailable, it reports that the round-trip check was skipped.

Original private run logs, device UIDs, account data, absolute home paths, runtime state and copyrighted music files are excluded from this repository.
