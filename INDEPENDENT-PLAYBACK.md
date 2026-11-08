# Independent playback and Desktop shortcuts

Run `python3 install_user.py` from the source folder. It builds the local player and helpers, copies the runnable package to `~/Applications/Surround Stream`, and creates these Desktop shortcuts:

- **Surround Stream.app** opens the player. If the server is stopped, it can start the last saved server configuration automatically. Choose your TV with the AirPlay button.
- **Start Surround Server.command** starts only the capture, encoder and local HLS server.
- **Stop Surround Server.command** explicitly stops the server, cleans the rolling buffer and restores the previous sound output.

On a fresh installation, supply the TV address on the first server launch, for example `zsh Start-HLS-Server.command --tv 192.168.1.100`. Subsequent starts reuse the saved configuration. Keep Music playing into HDMI Lab 16ch. The player can read the current Music metadata for artist visuals; macOS may ask for access to Music and the local network.

After restarting the server, use Reconnect in the player. If AirPlay releases its destination while loading the replacement stream, choose the TV again with the AirPlay button. Local playback stays muted during that transition.

The server's background launcher uses a user-scoped macOS `launchd` job with the player app's associated bundle identity. macOS starts the server directly, so it is independent of ChatGPT, the launcher and Terminal. It is registered only for the current login session, with no root privileges and no automatic startup at login or boot. The runtime plist stays inside the installation folder. Starting the same server again does not create a second capture. `Stop-HLS.command` unloads the job after normal cleanup.

The runnable copy belongs under Applications: launching a background service directly from protected Documents/Desktop folders can be blocked by macOS. Source edits in the repository do not automatically update the installed copy; reinstall after rebuilding. Avoid modifying the installed files while actively streaming.

Any deliberate stop restores the previous sound output: the Stop shortcut, Control-C, closing the Terminal window, logging out, or the launcher giving up on a slow start. Only a crash of a pipeline stage (the encoder or capture ending on its own) leaves Music routed to the virtual sink, so the MacBook speakers never take over mid-song. The player pauses and mutes on a failed stream, mutes when AirPlay disconnects, and avoids retrying failed media locally. Reconnect can start a stopped server using the saved settings; while that server is still coming up the player waits for it instead of launching it again. Starting the server a second time while it is running or starting never replaces it; the second start simply waits and reports the live address. Closing the player stops AirPlay playback but leaves the server running until the Stop shortcut is used.

While the server runs, a scoped `caffeinate` assertion prevents idle system sleep. Active AirPlay playback also holds a user-initiated, latency-critical activity assertion to prevent App Nap. GPU compositing remains enabled. These assertions end with their owning processes; global battery or energy settings are not changed. The display can still sleep. Use the Stop shortcut when finished.

`python3 test_service.py` verifies a temporary synthetic localhost service is owned by macOS (parent PID 1), continues after its launcher exits, serves HLS, cleans up on explicit stop and handles unexpected termination without choosing speaker fallback. It does not change audio routing. The visual and original HLS integration checks remain separate.

Apple references: [launchd agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html), [local network privacy and associated bundle identity](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
