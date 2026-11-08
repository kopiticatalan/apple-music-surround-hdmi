// Small AirPlay media player with explicit live buffering controls.
// Local playback is always muted so it cannot feed back into the capture sink.
import AppKit
import AVKit
import AVFoundation
import CoreMedia

@MainActor
final class StreamPlayer: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let player = AVPlayer()
    var window: NSWindow!
    let routeLabel = NSTextField(labelWithString: "Choose your TV using AirPlay")
    let delayLabel = NSTextField(labelWithString: "Connecting to the live stream…")
    let actionButton = NSButton(title: "Pause", target: nil, action: nil)
    let mode = NSPopUpButton()
    var statusObservation: NSKeyValueObservation?
    var routeObservation: NSKeyValueObservation?
    var timer: Timer?
    var wantsPlayback = true
    var seeking = false
    var lastRecovery = Date.distantPast
    var lastSeekReason = ""
    var seekCount = 0
    var serverLaunch: Process?
    var hasUsedAirPlay = false
    var powerActivity: NSObjectProtocol?
    var metadataWorker: Process?
    let root = Bundle.main.bundleURL.deletingLastPathComponent()
    var runtime: URL { root.appendingPathComponent("runtime") }
    var targetOffset: Double { [2.0, 3.0, 6.0][mode.indexOfSelectedItem] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()
        startMetadata()
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true
        routeObservation = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let active = self.player.isExternalPlaybackActive
                self.player.isMuted = !active || self.player.currentItem?.status == .failed
                if active { self.hasUsedAirPlay = true }
                else if self.hasUsedAirPlay { self.player.pause() }
                self.routeLabel.stringValue = active ? "Playing on AirPlay" : "Choose your TV using AirPlay · local audio muted"
                if active && self.wantsPlayback { self.seekLive(reason: "AirPlay connected") }
            }
        }
        reconnect()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatus() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func startMetadata() {
        try? FileManager.default.createDirectory(at:runtime,withIntermediateDirectories:true)
        let task = Process(),pipe = Pipe()
        task.executableURL = root.appendingPathComponent("build/TileRenderer")
        task.arguments = ["--now-playing"];task.standardOutput = pipe
        let target = runtime.appendingPathComponent("music-now-playing.json")
        let logURL = runtime.appendingPathComponent("music-metadata.log")
        FileManager.default.createFile(atPath:logURL.path,contents:nil)
        task.standardError = try? FileHandle(forWritingTo:logURL)
        do { try task.run();metadataWorker = task }
        catch { return }
        Thread.detachNewThread {
            var pending = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let end = pending.firstIndex(of:10) {
                    let line = pending.prefix(upTo:end)
                    if (try? JSONSerialization.jsonObject(with:line)) != nil {
                        try? Data(line).write(to:target,options:.atomic)
                    }
                    pending.removeSubrange(...end)
                }
            }
        }
    }

    func makeWindow() {
        let appMenu = NSMenu()
        let item = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit Surround Stream", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu
        appMenu.addItem(item)
        NSApp.mainMenu = appMenu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 410),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Surround Stream"
        window.delegate = self
        window.center()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        let title = NSTextField(labelWithString: "Apple Music Surround")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        stack.addArrangedSubview(title)
        let subtitle = NSTextField(labelWithString: "Dolby Digital 5.1 · Live AirPlay")
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(subtitle)
        let video = AVPlayerView()
        video.player = player
        video.controlsStyle = .none
        video.translatesAutoresizingMaskIntoConstraints = false
        video.heightAnchor.constraint(equalToConstant: 170).isActive = true
        video.widthAnchor.constraint(equalToConstant: 572).isActive = true
        stack.addArrangedSubview(video)
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 12
        let picker = AVRoutePickerView(frame: NSRect(x: 0, y: 0, width: 36, height: 32))
        picker.player = player
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.widthAnchor.constraint(equalToConstant: 36).isActive = true
        picker.heightAnchor.constraint(equalToConstant: 32).isActive = true
        picker.setAccessibilityLabel("AirPlay destination")
        controls.addArrangedSubview(picker)
        actionButton.target = self
        actionButton.action = #selector(togglePlay)
        controls.addArrangedSubview(actionButton)
        controls.addArrangedSubview(NSButton(title: "Go Live", target: self, action: #selector(goLive)))
        controls.addArrangedSubview(NSButton(title: "Reconnect", target: self, action: #selector(reconnect)))
        mode.addItems(withTitles: ["Fast · 2 seconds", "Balanced · 3 seconds", "Stable · 6 seconds"])
        mode.target = self
        mode.action = #selector(changeMode)
        controls.addArrangedSubview(mode)
        stack.addArrangedSubview(controls)
        routeLabel.font = .systemFont(ofSize: 12)
        delayLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(routeLabel)
        stack.addArrangedSubview(delayLabel)
        window.makeKeyAndOrderFront(nil)
    }

    func configure(_ item: AVPlayerItem) {
        item.preferredForwardBufferDuration = 1
        item.configuredTimeOffsetFromLive = CMTime(seconds: targetOffset, preferredTimescale: 600)
        item.automaticallyPreservesTimeOffsetFromLive = false
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
    }

    @objc func reconnect() {
        guard serverLaunch == nil else { return }
        let stateURL = runtime.appendingPathComponent("ACTIVE-HLS.json")
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              state["ready"] as? Bool == true,
              let modified = try? stateURL.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,
              Date().timeIntervalSince(modified)<8,
              let address = state["url"] as? String, let url = URL(string: address) else {
            startSavedServer()
            return
        }
        let item = AVPlayerItem(url: url)
        configure(item)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard item === self.player.currentItem else { return }
                if item.status == .readyToPlay && self.wantsPlayback {
                    self.player.isMuted = !self.player.isExternalPlaybackActive
                    if self.player.isExternalPlaybackActive { self.seekLive(reason: "stream ready") }
                    else { self.player.isMuted = true; self.player.playImmediately(atRate: 1) }
                } else if item.status == .failed {
                    self.player.pause()
                    self.player.isMuted = true
                    self.wantsPlayback = false
                    self.actionButton.title = "Play Live"
                    self.delayLabel.stringValue = item.error?.localizedDescription ?? "Playback failed. Press Reconnect."
                }
            }
        }
        player.isMuted = true
        player.replaceCurrentItem(with: item)
        wantsPlayback = true
        actionButton.title = "Pause"
        // External playback may not load a replacement item until playback is
        // requested. Stay muted while loading; readyToPlay unmutes only AirPlay.
        player.playImmediately(atRate:1)
    }

    func startSavedServer() {
        player.pause();player.isMuted = true
        guard let data = try? Data(contentsOf:runtime.appendingPathComponent("SERVICE-HLS.json")),
              let config = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let command = config["restartCommand"] as? [String],let executable = command.first else {
            delayLabel.stringValue = "Start the Desktop server shortcut, then press Reconnect."
            return
        }
        let task = Process();task.executableURL = URL(fileURLWithPath:executable)
        task.arguments = Array(command.dropFirst());task.currentDirectoryURL = root
        let logURL = runtime.appendingPathComponent("server-launch.log")
        FileManager.default.createFile(atPath:logURL.path,contents:nil)
        let log = try? FileHandle(forWritingTo:logURL)
        task.standardOutput = log;task.standardError = log
        task.terminationHandler = { [weak self] task in
            try? log?.close()
            DispatchQueue.main.async {
                guard let self else { return }
                self.serverLaunch = nil
                if task.terminationStatus == 0 { self.reconnect() }
                else { self.delayLabel.stringValue = "Server could not start. Check runtime/server-launch.log." }
            }
        }
        serverLaunch = task;delayLabel.stringValue = "Starting the independent stream server…"
        do { try task.run() }
        catch { serverLaunch = nil;delayLabel.stringValue = error.localizedDescription;try? log?.close() }
    }

    @objc func changeMode() {
        if let item = player.currentItem { configure(item) }
        seekLive(reason: "buffer mode changed")
    }

    @objc func togglePlay() {
        wantsPlayback.toggle()
        actionButton.title = wantsPlayback ? "Pause" : "Play Live"
        if wantsPlayback { seekLive(reason: "resume") }
        else { player.pause() }
    }

    @objc func goLive() { seekLive(reason: "Go Live button") }

    func seekLive(reason: String) {
        guard let item = player.currentItem, item.status == .readyToPlay, !seeking else { return }
        configure(item)
        seeking = true
        lastSeekReason = reason
        seekCount += 1
        player.seek(to: .positiveInfinity, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.seeking = false
                if self.wantsPlayback { self.player.playImmediately(atRate: 1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+3) { [weak self] in self?.seeking = false }
    }

    func updateStatus() {
        guard let item = player.currentItem else { return }
        let active = wantsPlayback && player.isExternalPlaybackActive && item.status == .readyToPlay
        if active && powerActivity == nil {
            powerActivity = ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.latencyCritical,.idleSystemSleepDisabled],
                reason:"Realtime surround AirPlay playback")
        } else if !active,let activity = powerActivity {
            ProcessInfo.processInfo.endActivity(activity);powerActivity = nil
        }
        let now = Date()
        let current = player.currentTime().seconds
        let ranges = item.seekableTimeRanges.map(\.timeRangeValue)
        let edge = ranges.last.map { CMTimeRangeGetEnd($0).seconds }
        let dateLag = item.currentDate().map { now.timeIntervalSince($0) }
        let edgeLag = edge.map { $0-current }
        if let lag = dateLag, lag.isFinite {
            delayLabel.stringValue = String(format: "Playback time is about %.1f s behind the stream clock", max(0,lag))
        } else if let lag = edgeLag, lag.isFinite {
            delayLabel.stringValue = String(format: "About %.1f s behind available live media", max(0,lag))
        } else if item.status != .failed {
            delayLabel.stringValue = "Waiting for live playback timing…"
        }
        if !player.isExternalPlaybackActive || item.status == .failed { player.isMuted = true }
        if item.status == .failed { player.pause() }
        if wantsPlayback && item.status == .readyToPlay && player.isExternalPlaybackActive && !seeking && player.rate == 0 && now.timeIntervalSince(lastRecovery)>2 {
            // Retry a stalled play command without seeking or repeatedly skipping audio.
            lastRecovery = now
            player.playImmediately(atRate: 1)
        }
        let status: [String: Any] = [
            "time": now.timeIntervalSince1970,
            "externalPlayback": player.isExternalPlaybackActive,
            "localMuted": player.isMuted,
            "rate": player.rate,
            "wantsPlayback": wantsPlayback,
            "timeControlStatus": player.timeControlStatus.rawValue,
            "currentTime": current.isFinite ? current : -1,
            "liveEdge": edge?.isFinite == true ? edge! : -1,
            "programmeDateLagSeconds": dateLag?.isFinite == true ? dateLag! : -1,
            "liveEdgeLagSeconds": edgeLag?.isFinite == true ? edgeLag! : -1,
            "targetOffsetSeconds": targetOffset,
            "seekCount": seekCount,
            "lastSeekReason": lastSeekReason,
            "status": item.status.rawValue,
            "error": item.error?.localizedDescription ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: runtime.appendingPathComponent("player-status.json"), options: .atomic)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return true }
    func applicationWillTerminate(_ notification: Notification) {
        player.pause();timer?.invalidate()
        metadataWorker?.terminate()
        if let activity = powerActivity { ProcessInfo.processInfo.endActivity(activity) }
    }
}

@main
struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = StreamPlayer()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
