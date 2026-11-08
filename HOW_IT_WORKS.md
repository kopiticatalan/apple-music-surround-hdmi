# How Apple Music became DTS 5.1 over HDMI

## In simple language

The TV offered the Mac a normal stereo audio route. The downstream sound system could decode compressed surround, but that did not automatically make Music provide useful surround PCM.

We built a pretend surround receiver inside the Mac. It tells Core Audio that it is an HDMI device with sixteen individually assigned speakers, arranged as 9.1.6. Apple Music rendered its Atmos version of a song into those speaker channels.

The driver also provides a virtual input, like an internal cable. Our bridge reads this input, combines the sixteen speaker feeds into the six feeds a 5.1 system needs, compresses them as DTS, and sends that digital stream to the real HDMI connection. The TV/sound system decodes the stream and plays the speakers.

We checked the audio twice: the virtual input contained independent surround and height channel activity, and a live DTS encode/decode check contained six active channels. Finally, the listener heard the surrounds on the physical sound system. These establish different parts of the path; none of them alone proves every part works on a different machine.

## 1. The virtual receiver

The driver is a modified [BlackHole](https://github.com/ExistentialAudio/BlackHole) HAL plug-in. The starting checkout was commit `e2b22aaaba4e507a097131704bf96dabc004d9cf`. Original copyright and license notices are retained. This repository contains the modified source, so builds do not depend on that checkout remaining on disk.

The public names are `HDMI Lab 16ch` and `HDMI Lab 16ch Mirror`. The main device has an output; the mirror has an input. A second build provides the corresponding 8ch/7.1 devices for comparison.

The changes include HDMI transport reporting, full-width Float32 PCM, compressed output carrier format descriptions, format-change handling, and explicit preferred channel layouts. Output capability flags are descriptive Core Audio properties, not a guarantee that an application will select an Atmos stream.

The first layout attempt used a named layout tag with no explicit speaker descriptions. Audio MIDI Setup showed blank assignments and an overlapping-channel error. The working version uses `kAudioChannelLayoutTag_UseChannelDescriptions`, a count of sixteen, and distinct labels for every speaker. This mattered more than indiscriminately setting properties to “yes.”

| Index, zero based | Speaker |
|---:|---|
| 0, 1 | Left, right |
| 2 | Centre |
| 3 | LFE/subwoofer |
| 4, 5 | Left surround, right surround |
| 6, 7 | Left rear surround, right rear surround |
| 8, 9 | Left wide, right wide |
| 10, 11 | Left top front, right top front |
| 12, 13 | Left top middle, right top middle |
| 14, 15 | Left top rear, right top rear |

The tested PCM format is sixteen interleaved 32-bit float channels at 48 kHz. The driver supports additional sample rates for experimentation; the bridge intentionally refuses a mismatched source format.

## 2. Getting Music to render PCM

The observed combination was Dolby Atmos **Automatic**, HDMI Passthrough **Off**, Song Transitions **Off**, and `multichannelAudioStrategy=0`. Music was reopened with the virtual sink selected as the default output.

Reading the installed Music executable's strategy branches and their own diagnostic strings identified this enum on the tested version:

| Value | Observed meaning |
|---:|---|
| 0 | Match multichannel track preference to the device |
| 1 | Prefer stereo |
| 2 | Prefer AC-3 exclusive passthrough |
| 3 | Prefer exclusive passthrough |

We did not patch Music. The undocumented preference selects existing behavior. Its meaning and availability may change, and the experiment did not prove that every setting is individually necessary. The settings above are a reproducible starting point, not a universal specification.

Turning passthrough off is deliberate: this bridge expects Music's rendered PCM. It does not decode an Atmos bitstream. Integer-valued encoded carrier words in the mirror are unsuitable as PCM; the capture backend rejects non-finite or implausibly large sample values.

## 3. Measuring the source

`SinkProbe.swift` can list devices and their formats, select a default output, or meter only the named virtual mirror inputs. Metering keeps per-channel peaks and counters, not audio recordings. Inventory includes local device names and identifiers; the public package excludes the original inventories and logs.

The working test played the Atmos version of “Dancing In The Flames” by The Weeknd. Music's diagnostics identified an Atmos source variant and a 9.1.6 layout. Over the measured interval, surround and height channels were repeatedly nonzero, rather than merely existing as silent channels. See [the numerical results](TEST_RESULTS.md).

Nonzero levels establish signal presence. They do not by themselves prove speaker orientation, artistic intent or perfect channel separation. The driver loopback tests separately check that channel values survive independently.

## 4. Folding 9.1.6 to 5.1

The sound system needs front left/right, centre, LFE and surround left/right. The bridge uses this explicit matrix, with zero-based source indices:

```text
FL  = c0 + 0.707*c8 + 0.707*c10
FR  = c1 + 0.707*c9 + 0.707*c11
FC  = c2
LFE = c3
SL  = c4 + 0.707*c6 + 0.707*c12 + 0.707*c14
SR  = c5 + 0.707*c7 + 0.707*c13 + 0.707*c15
```

The coefficients fold wide, rear and height feeds into the nearest available speaker groups. A limiter at 0.95 prevents the summed output from exceeding the chosen ceiling; it does not automatically increase gain. This is a pragmatic fixed matrix, not a Dolby reference renderer. The renderer has already produced the sixteen speaker feeds inside Music.

Explicit indices are important: FFmpeg's named 9.1.6 channel order need not match this driver's order. Treating the input as an arbitrary named layout could put feeds in the wrong places.

## 5. DTS encoding and the HDMI carrier

FFmpeg receives `f32le`, sixteen channels, 48 kHz, applies the matrix and limiter, then uses:

```text
-ar 48000 -c:a dca -strict -2 -b:a 1411200 -f spdif
```

`dca` produces DTS core 5.1. `spdif` packages the frames as IEC 61937 bursts; the same framing is sent over HDMI here. The conversion is lossy and carries six speaker channels, with no Atmos objects or original Atmos metadata.

The Swift playback backend opens the exact physical HDMI device, obtains exclusive/hog access, and switches its stream to the advertised 48 kHz `kAudioFormat60958AC3`/`cac3` carrier. Despite the API's AC-3 name, the supplied IEC 61937 payload is DTS. The backend checks two carrier channels, sixteen-bit words and four bytes per frame before starting.

Consequently, a log saying `2ch 48000Hz 16bit cac3` describes the **digital carrier**, not a stereo programme. The decoded payload has six programme channels. The TV must still understand/pass DTS; advertising this carrier does not establish that capability.

The tested HDMI path advertised only two PCM channels. That did not prevent compressed DTS 5.1. A different path supporting multichannel PCM directly may not need this re-encoding approach at all.

## 6. The routing detail that fixed the final problem

Initially the listener heard the MacBook's own speakers. Starting exclusive physical HDMI playback had changed the default output route. Music consequently stopped feeding the virtual receiver.

Restoring the default to **HDMI Lab 16ch after the bitstream started** fixed that behavior. The saved bridge rechecks the route once per second and puts it back on the virtual device while running. The bridge's physical stream is separate from the default output Music uses.

Control-C or the stop helper terminates the pipeline, restores the HDMI format and releases hog mode, then restores the previous default output. Force-killing a process or unplugging hardware can prevent normal restoration; select a normal output manually if that occurs.

## 7. What is tested, and what remains experimental

`verify_driver.c` runs callbacks in-process without installation. It checks PCM/carrier formats, format-change commits, sixteen/eight distinct layout labels, preservation of encoded words, and independent PCM loopback channels. `test_bridge.py` checks format/device rejection, the measurement parser, the numerical fold matrix, and a synthetic encode→carrier→decode round trip.

The original local driver (0.1.1) was measured with Music and heard through physical HDMI. Public package 0.2.0 retains that audio path while adding portable builds, generic device selection, source-only distribution and independent cleanup. Those public packaging changes were compiled and tested without reinstalling over the listening session. Intel builds and other OS/application versions have not been listened to.

The HAL and callbacks are experimental code, with blocking I/O and allocations that could be improved for production audio. Dropouts or latency may vary with load and hardware. This project supplies a reproducible experiment and a usable starting point for further development.
