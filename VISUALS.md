# Cinematic now-playing visuals

The HLS launcher includes a 1280×720 animated scene with a Metro / Windows Phone 8 sensibility: flat surfaces, big light type, one accent colour, calm motion. It is an original interpretation of that design language, not a replica, and no Microsoft code or artwork is bundled.

```sh
zsh Play-HLS-over-AirPlay.command --tv 192.168.1.100
# Plain background:
zsh Play-HLS-over-AirPlay.command --tv 192.168.1.100 --no-visuals
```

## The scene

- **Backdrop.** The artist photograph fills the frame, cover-fitted, with a very slow zoom and drift. It is graded slightly toward calm (a touch less saturation, a touch more contrast) and sits under a letterbox-style lighting layer: dark on the left to hold the type, lifting toward the right, with a soft vignette. When several photos are available they dissolve into one another every 24 seconds.
- **Accent colour.** Pulled from the hero photograph (its average colour, lifted in saturation and brightness). Near-grey photographs fall back to a warm amber. The accent appears in exactly three places: the `now playing` eyebrow, a short rule between title and artist, and the edge bar of the tile.
- **Tile.** When there are two or more photos, a flat 300 px square tile on the right shows the next one. Every 44 seconds it performs the classic live-tile flip to the following photo. It floats by a few pixels and casts a soft shadow; nothing is rounded or rotated.
- **Type.** Lowercase `now playing` eyebrow in the accent colour, then the song title in light weight (auto-sized from 76 pt down to 44 pt, at most two lines), the artist in regular weight, and the album dimmed beneath. On a track change the lines enter from the right with a quick ease-out and a short stagger, then settle into a slow drift. The previous frame cross-dissolves out over one second, so a change never cuts.
- **Chrome.** A spaced `SURROUND STREAM · DOLBY DIGITAL 5.1` mark bottom-left and the artwork credit bottom-right, both faint.

When starting `HLSBridge.py` directly, add `--visuals`. Song changes update the running renderer without restarting capture, encoding or HLS.

## Data and performance

`TileRenderer.swift` reads only the current Music track's title, artist, album artist and album through ScriptingBridge. macOS may ask permission to access Music. The player app can also hand Music metadata to the renderer when the background server itself is not allowed to ask. `TileVisuals.py` requests pictures in background workers. No Music audio is sent to artwork services. Text appears immediately; images follow as their downloads finish.

The renderer composites on the GPU with Core Image. Photographs are decoded off the render thread with ImageIO (downsampled to at most 1400 px) and swapped in with a dissolve when ready, so a track change never stalls a frame. The lighting, tile shadow, text lines and chrome are drawn once and cached as textures. Every frame is rendered into one reused buffer and written straight to the encoder; video follows backpressure from the encoder's captured-audio clock, with bounded queues and no independent sleep-based video clock.

## Artwork sources

Artist galleries come from [TheAudioDB](https://www.theaudiodb.com) through its [official free API](https://www.theaudiodb.com/free_music_api), using exact normalized artist-name matches. Its community database can supply up to three fanart images and a thumbnail. Apple Music public artist pages supply another portrait, located with Apple's iTunes artist search; matching album artwork is the fallback. Coverage varies and page structure can change. Failed artwork requests leave the dark base scene without restarting audio. The scene credits the sources. Individual photos retain their respective rights; see [TheAudioDB terms](https://www.theaudiodb.com/docs_terms_of_use.php). No third-party artwork is included in the repository.

Downloads and metadata stay in ignored `runtime/` directories. Gallery lookups are cached for seven days and throttled below the free API's documented 30 requests/minute limit. The cache retains at most 192 JPEGs or 320 MB and 48 gallery records. Runtime files can reveal listening history; do not publish them. Delete `runtime/artist-cache` to clear artwork.

## Verification and preview

The scene preserves the explicit channel fold, 48 kHz/384 kbit/s AC-3, one-second HLS segments and existing player buffer settings. `python3 test_visuals.py` uses synthetic audio and local test art to check 720p H.264, six active audio channels, continuous timestamps, metadata changes without an encoder restart and real-time progress. It does not access Music, the network or sound routing.

For a deterministic preview, supply a JSON object with `key`, `name`, `artist`, `album`, `imagePaths` (local absolute paths) and `artworkCredit`:

```sh
build/TileRenderer --snapshot scene.json preview.png 5
```

The final argument is animation time in seconds; use about `0.4` to see the entrance mid-flight and `5` for the settled layout. Personal preview images are artwork derivatives, not source assets for redistribution.
