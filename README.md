# HDMI Lab: Apple Music surround over HDMI or AirPlay

An experimental macOS virtual HDMI sink and live bridges that get Apple Music to render multichannel PCM, then fold it to 5.1 for an HDMI-connected sound system or an AirPlay-enabled TV.

**Observed working:** MacBook Air M1, macOS 27.2, Apple Music Atmos content, and a TV/soundbar path that accepts DTS. Independent surround and height channels were measured before conversion; the listener confirmed audible surround speakers over physical HDMI. Other Macs, Music versions, adapters and TVs are untested.

```mermaid
flowchart LR
    A[Apple Music Atmos] --> B[HDMI Lab 16ch: 9.1.6 PCM]
    B --> C[Virtual loopback input]
    C --> D[Fold 16 channels to 5.1]
    D --> E[FFmpeg DTS core encoder]
    E --> F[IEC 61937 over physical HDMI]
    F --> G[TV / sound system decodes DTS 5.1]
```

The HDMI output is **DTS core 5.1**, not Atmos passthrough or Dolby Digital. The conversion is lossy and does not preserve Atmos object metadata. Stereo tracks remain stereo; the bridge does not create surround content. The HDMI bridge saves no Music audio files. The optional HLS bridge described below uses a short rolling disk buffer that is removed on normal stop.

## Wireless surround over AirPlay

The repository also includes **AC-3 Dolby Digital 5.1 over live HLS**, using the same virtual capture and speaker fold. It was heard working on a Hisense 55U7H VIDAA TV without modifying the TV. The dedicated **Surround Stream** player reduced the listener-reported track-change delay from roughly ten seconds with QuickTime to about **2–4 seconds**. This is a listening estimate, not an instrumented acoustic measurement or a guarantee for other devices.

After installing and configuring the virtual device as below, start the HLS path with your TV's local IP address:

```sh
zsh Play-HLS-over-AirPlay.command --tv 192.168.1.100
```

The launcher opens the locally built player; choose your TV using its AirPlay button. Keep Music routed to **HDMI Lab 16ch**. Stop with `zsh Stop-HLS.command`. The existing DTS/HDMI path remains available; run one capture bridge at a time.

See [HLS setup and playback](README-HLS.md), [live HLS measurements](HLS-TEST-RESULTS.md), and [latency tuning and limits](LATENCY-NOTES.md). Both output paths are lossy 5.1 speaker beds and do not preserve Atmos objects.

The HLS launcher also includes cinematic now-playing visuals: artist photos, a gently moving backdrop, drifting photo prints and opposing title/artist motion. See [visual design and artwork sources](VISUALS.md). Use `--no-visuals` for the plain background.

## HDMI requirements

- macOS, Xcode Command Line Tools (`xcode-select --install`), Python 3, and FFmpeg with the `dca` encoder and `spdif` muxer. With [Homebrew](https://brew.sh/) already installed: `brew install python ffmpeg`.
- An Apple Music subscription and an Atmos version of a track.
- A physical HDMI output advertising a 48 kHz, 16-bit, two-channel `cac3` compressed carrier. Your TV and downstream sound system must accept/pass DTS; the carrier alone cannot prove DTS support.
- Administrator access to install two user-space HAL driver bundles. Installation briefly restarts all Mac audio. No kernel extension or system security changes are used.

## Build and install

Download or clone the repository and open Terminal in its folder. GitHub ZIP downloads may not preserve executable permissions, so run the helpers through `zsh`:

```sh
zsh Build.command
python3 test_bridge.py
zsh Install.command
```

`Build.command` compiles the native architecture, generates ad hoc signed driver bundles and runs the 8/16-channel driver tests. It does not install anything. `Install.command` installs only `HDMILab8ch.driver` and `HDMILab16ch.driver` in `/Library/Audio/Plug-Ins/HAL`, backs up any earlier versions of those two bundles under `runtime/backups/`, then restarts Core Audio. Quit audio apps and stop any existing bridge before installation.

## Configure Music and the virtual device

1. Open **Audio MIDI Setup**. Set **HDMI Lab 16ch** and **HDMI Lab 16ch Mirror** to **48,000 Hz, 16-channel, 32-bit float PCM**. The output's speaker layout is 9.1.6, with sixteen distinct speaker assignments. The optional 8ch driver is a comparison device; the supplied bridge uses 16ch.
2. In Music settings, select **Dolby Atmos: Automatic**, **HDMI Passthrough: Off**, and **Song Transitions / AutoMix: Off**. These are the tested settings; labels may differ across Music versions.
3. Quit Music. Check and note the old value before setting the experimental preference:

   ```sh
   defaults read com.apple.Music multichannelAudioStrategy
   defaults write com.apple.Music multichannelAudioStrategy -int 0
   ```

   A missing-key message from the first command means there was no saved override. This is an undocumented Music preference observed on the tested version; it may change in later versions.

4. Select **HDMI Lab 16ch** as the Mac's sound output. Reopen Music and choose an Atmos track.

The virtual device needs an honest channel layout and usable PCM formats. There is no universal “enable every flag” switch. The tested combination matters, and the individual Music settings were not isolated in controlled trials.

## Play through HDMI

Connect the HDMI cable and configure the TV's audio passthrough for a DTS-capable route. Start with your receiver volume low while confirming the correct format, then run:

```sh
zsh Play-DTS-over-HDMI.command
```

Play the Atmos track in Music. The bridge captures the virtual mirror, folds it to 5.1, encodes DTS at **48 kHz / 1,411,200 bit/s**, and opens the physical HDMI compressed carrier exclusively. It keeps the Mac default output on the virtual sink because Music must continue feeding that device.

When several compatible HDMI outputs are attached, specify the exact name shown by Audio MIDI Setup:

```sh
DD51_HDMI='Your TV Name' zsh Play-DTS-over-HDMI.command
```

Keep the playback Terminal window open. Press **Control-C**, or run `zsh Stop-DTS.command`, to stop and restore the previous output. Choose your normal speakers manually if a device was unplugged before restoration. The bridge may capture other apps routed to the same default output too.

## Check that the source really has surround channels

Stop the playback bridge first. With the virtual sink selected and an Atmos song playing, run:

```sh
./build/SinkProbe 20
zsh Verify-Live-DTS.command
```

The first command reports per-channel peaks from the virtual mirror. The second runs a twenty-second live encode → IEC 61937 → decode check and writes six-channel levels under `runtime/runs/`; it does **not** test your physical HDMI decoder. Surround output can be quiet during a song, so test a passage with active surrounds. A successful encode of stereo material does not establish a multichannel source.

The local inventory includes device names and UIDs. Review diagnostics before posting them publicly. No telemetry or uploads are performed by these scripts.

## Troubleshooting and removal

| Symptom | What to check |
|---|---|
| Sound comes from the laptop | Mac output must be HDMI Lab 16ch while the bridge sends its separate stream to physical HDMI. Restart Music after selecting the sink. |
| Silence / unsupported format | Confirm the TV passes DTS, the sound system supports DTS, and HDMI is connected. A stereo-only PCM connection can still carry compressed 5.1, but not every TV supports it. |
| Only two source channels have levels | Confirm the Atmos track/version, Automatic mode, passthrough off, transitions off, strategy 0, and restart Music. |
| Overlapping/blank speaker assignments | Rebuild and reinstall this source version; the original experiment needed explicit channel descriptions. Do not assign multiple speakers to one channel. |
| Source is not safe PCM | Turn Music HDMI Passthrough off; reset both virtual streams to float PCM, 48 kHz. |
| Core Audio returns zero devices | Run the helpers locally in Terminal rather than a restricted environment. |
| Device doesn't appear after installation | Wait for Core Audio; a reboot may be needed. Do not disable system security. |

To remove the drivers, stop playback, quit Music and run `zsh Uninstall.command`. It moves only the two HDMI Lab bundles to `runtime/uninstalled/` and restarts Core Audio. Restore your recorded Music preference; if it was originally absent, use `defaults delete com.apple.Music multichannelAudioStrategy` while Music is closed. Then select your normal speakers.

## Source, explanation and evidence

- [How it works, including channel mapping and Music preference findings](HOW_IT_WORKS.md)
- [Measured results and verification limits](TEST_RESULTS.md)
- [License and attribution](NOTICE.md) — GPL-3.0; driver based on [BlackHole](https://github.com/ExistentialAudio/BlackHole).
- `HDMILab.c`: virtual sink and mirror; `AudioBridge.swift`: Core Audio capture/playback; `Bridge.py`: FFmpeg orchestration; `SinkProbe.swift`: device inventory/channel meter; `verify_driver.c` and `test_bridge.py`: tests.

This is a source-first experiment, not a polished audio product. Local bundles are not notarized releases. The public packaging has been built and tested without replacing the original driver during the working listening session. Improvements and reproducibility reports are welcome; include your OS/Music version, HDMI capabilities and anonymized channel measurements.
