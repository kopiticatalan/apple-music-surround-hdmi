# Cinematic now-playing visuals

The HLS launcher includes a 1280×720 animated scene: artist photography, a slowly changing backdrop, gently drifting photo prints when several images are available, warm accents and a responsive song/artist layout. Titles enter from opposite sides, settle into a slow glide and accelerate out. This is an original interpretation of the [Windows Phone 8 Music+Video wide-tile motion](https://www.youtube.com/watch?v=94vMjutqQcE), rather than an exact replica. No Microsoft code or artwork is bundled.

```sh
zsh Play-HLS-over-AirPlay.command --tv 192.168.1.100
# Plain background:
zsh Play-HLS-over-AirPlay.command --tv 192.168.1.100 --no-visuals
```

When starting `HLSBridge.py` directly, add `--visuals`. Stop the existing bridge before switching the video mode; use Reconnect in Surround Stream after a restart. Song changes update the running renderer without restarting capture, encoding or HLS.

`TileRenderer.swift` reads only the current Music track's title, artist, album artist and album through ScriptingBridge. macOS may ask permission to access Music. `TileVisuals.py` requests pictures in background workers. No Music audio is sent to artwork services. Text appears immediately; images follow as their downloads finish. Video follows backpressure from the encoder's captured-audio clock, with bounded queues and no independent sleep-based video clock.

Artist galleries come from [TheAudioDB](https://www.theaudiodb.com) through its [official free API](https://www.theaudiodb.com/free_music_api), using exact normalized artist-name matches. Its community database can supply up to three fanart images and a thumbnail. Apple Music public artist pages supply another portrait, located with Apple's iTunes artist search; matching album artwork is the fallback. Coverage varies and page structure can change. Failed artwork requests leave a neutral backdrop without restarting audio. The scene credits the sources. Individual photos retain their respective rights; see [TheAudioDB terms](https://www.theaudiodb.com/docs_terms_of_use.php). No third-party artwork is included in the repository.

Downloads and metadata stay in ignored `runtime/` directories. Gallery lookups are cached for seven days and throttled below the free API's documented 30 requests/minute limit. The cache retains at most 192 JPEGs or 320 MB and 48 gallery records. Runtime files can reveal listening history; do not publish them. Delete `runtime/artist-cache` to clear artwork.

The scene preserves the explicit channel fold, 48 kHz/384 kbit/s AC-3, one-second HLS segments and existing player buffer settings. Image decoding, lighting and soft shadows are cached rather than recomputed each frame. `python3 test_visuals.py` uses synthetic audio and local test art to check 720p H.264, six active audio channels, continuous timestamps, metadata changes without an encoder restart and real-time progress. It does not access Music, the network or sound routing.

For a deterministic preview, supply a JSON object with `key`, `name`, `artist`, `album`, `imagePaths` (local absolute paths) and `artworkCredit`:

```sh
build/TileRenderer --snapshot scene.json preview.png 5
```

The final argument is animation time in seconds. Personal preview images are artwork derivatives, not source assets for redistribution.
