// Cinematic now-playing scene with a Metro / Windows Phone 8 sensibility:
// flat tiles, big light type, one accent colour, calm motion.
// Original work; no Microsoft artwork or code is bundled.
import AppKit
import Foundation
import ScriptingBridge
import CoreImage
import ImageIO

let width = 1280
let height = 720
let fm = FileManager.default

func writeJSON(_ value: [String:Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data + Data([10]))
    }
}

// MARK: - Music metadata (ScriptingBridge; title/artist/album only)

func watchMusic() {
    guard let app = SBApplication(bundleIdentifier: "com.apple.Music") else { exit(2) }
    app.timeout = 120
    var last = ""
    repeat {
        autoreleasepool {
            var info: [String:Any] = [:]
            if let track = app.value(forKey: "currentTrack") as? SBObject {
                for key in ["name", "artist", "albumArtist", "album"] {
                    if let value = track.value(forKey: key) as? String { info[key] = value }
                }
            }
            let key = ["name","artist","albumArtist","album"].map { info[$0] as? String ?? "" }.joined(separator: "\u{1f}")
            if key != last && !(info["name"] as? String ?? "").isEmpty {
                last = key
                info["key"] = key
                writeJSON(info)
            }
        }
        if CommandLine.arguments.contains("--once") { break }
        Thread.sleep(forTimeInterval: 0.7)
    } while true
}

// MARK: - Bitmap helpers (AppKit drawing is only used for text and cached textures)

func bitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                     colorSpaceName: .deviceRGB, bytesPerRow: w*4, bitsPerPixel: 32)!
}
func drawInto(_ image: NSBitmapImageRep, _ block: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    NSGraphicsContext.current?.imageInterpolation = .high
    block()
    NSGraphicsContext.restoreGraphicsState()
}
func texture(_ b: NSBitmapImageRep) -> CIImage { CIImage(cgImage: b.cgImage!) }

func text(_ value: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
          color: NSColor = .white, tracking: CGFloat = 0) {
    let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
    (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .kern: tracking, .paragraphStyle: p])
}
func measure(_ value: String, width: CGFloat, size: CGFloat, weight: NSFont.Weight, tracking: CGFloat) -> CGFloat {
    let p = NSMutableParagraphStyle(); p.lineBreakMode = .byWordWrapping
    return ceil((value as NSString).boundingRect(with: NSSize(width: width, height: 2000),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .kern: tracking, .paragraphStyle: p]).height)
}

// MARK: - Scene state (fed by JSON lines on stdin)

struct Snapshot {
    var title = "Apple Music", artist = "Surround Stream", album = "", key = "", credit = ""
    var pictures: [String] = []
    var updated = ProcessInfo.processInfo.systemUptime
}
final class Scene {
    let lock = NSLock(); var value = Snapshot()
    func update(_ info: [String:Any]) {
        lock.lock(); defer { lock.unlock() }
        let key = info["key"] as? String ?? ""
        if key != value.key {
            value.key = key; value.updated = ProcessInfo.processInfo.systemUptime
            value.title = info["name"] as? String ?? "Apple Music"
            value.artist = info["artist"] as? String ?? "Surround Stream"
            value.album = info["album"] as? String ?? ""
        }
        value.pictures = info["imagePaths"] as? [String] ?? (info["imagePath"] as? String).map { [$0] } ?? []
        value.credit = info["artworkCredit"] as? String ?? ""
    }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - Artwork decoding (ImageIO, thread-safe, off the render thread)

struct Accent { var r: Double, g: Double, b: Double }
let amber = Accent(r: 0.95, g: 0.72, b: 0.44)

struct ArtworkSet {
    var paths: [String] = []
    var backdrops: [CIImage] = []   // cover-fit sources, long edge ≤ 1400
    var tiles: [CIImage] = []       // square crops, exactly tileSize × tileSize
    var accent = amber
}

let tileSize = 300.0

func decode(_ path: String, maxPixel: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                    kCGImageSourceShouldCacheImmediately: true,
                                    kCGImageSourceThumbnailMaxPixelSize: maxPixel]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

func squareTile(_ image: CIImage) -> CIImage {
    let side = min(image.extent.width, image.extent.height)
    // Portraits: favour the upper part of the frame where faces usually are.
    let y = image.extent.height > image.extent.width ? image.extent.height - side - (image.extent.height - side) * 0.15 : image.extent.minY
    let crop = CGRect(x: image.extent.midX - side/2, y: max(image.extent.minY, y), width: side, height: side)
    let scale = tileSize / side
    return image.cropped(to: crop)
        .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        .cropped(to: CGRect(x: 0, y: 0, width: tileSize, height: tileSize))
}

func accentFrom(_ image: CIImage, _ context: CIContext) -> Accent {
    let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
    var px = [UInt8](repeating: 0, count: 4)
    context.render(average, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    let color = NSColor(calibratedRed: Double(px[0])/255, green: Double(px[1])/255, blue: Double(px[2])/255, alpha: 1)
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    if s < 0.08 { return amber }   // near-grey photographs get the warm house accent
    let lifted = NSColor(calibratedHue: h, saturation: min(0.82, max(0.55, s * 1.6)), brightness: 0.93, alpha: 1)
    return Accent(r: lifted.redComponent, g: lifted.greenComponent, b: lifted.blueComponent)
}

func loadArtwork(_ paths: [String], _ context: CIContext) -> ArtworkSet {
    var set = ArtworkSet(paths: paths)
    for path in paths {
        guard let cg = decode(path, maxPixel: 1400) else { continue }
        let image = CIImage(cgImage: cg)
        set.backdrops.append(image)
        set.tiles.append(squareTile(image))
    }
    if let hero = set.backdrops.last { set.accent = accentFrom(hero, context) }
    return set
}

// MARK: - Motion

func easeOut(_ t: Double) -> Double { let c = max(0, min(1, t)); return 1 - pow(1 - c, 3) }
func smooth(_ t: Double) -> Double { let c = max(0, min(1, t)); return c * c * (3 - 2 * c) }

// MARK: - Renderer

final class Renderer {
    let gpu = CIContext(options: [.cacheIntermediates: false])
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let canvas = CGRect(x: 0, y: 0, width: width, height: height)
    let rowBytes = width * 4
    let frameBytes = width * height * 4
    let frameBuffer: UnsafeMutableRawPointer

    // Artwork, prepared off-thread and swapped in when ready
    var artwork = ArtworkSet()
    var requested: [String] = []
    let artworkLock = NSLock()
    var pendingArtwork: ArtworkSet? = nil
    let decodeQueue = DispatchQueue(label: "artwork.decode", qos: .utility)

    // Per-track text layers
    var lastKey = ""
    var titleLayer: CIImage?, artistLayer: CIImage?, albumLayer: CIImage?, eyebrowLayer: CIImage?
    var chromeLayer: CIImage?, chromeKey = ""
    var accentLayer: CIImage?, accentKey = ""

    // Transition between visual states
    var oldFrame: CIImage?, transition = -100.0

    init() {
        frameBuffer = UnsafeMutableRawPointer.allocate(byteCount: frameBytes, alignment: 64)
        frameBuffer.initializeMemory(as: UInt8.self, repeating: 0, count: frameBytes)
    }

    // Cached textures ------------------------------------------------------

    lazy var base: CIImage = {
        let b = bitmap(width, height)
        drawInto(b) {
            NSGradient(colors: [NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1),
                                NSColor(calibratedRed: 0.02, green: 0.025, blue: 0.04, alpha: 1)])?
                .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -60)
        }
        return texture(b)
    }()

    /// Letterbox-style grade: dark on the left for type, lifting toward the tile, vignette.
    lazy var lighting: CIImage = {
        let b = bitmap(width, height)
        drawInto(b) {
            let all = NSRect(x: 0, y: 0, width: width, height: height)
            NSGradient(colors: [NSColor.black.withAlphaComponent(0.84), NSColor.black.withAlphaComponent(0.58),
                                NSColor.black.withAlphaComponent(0.16), NSColor.black.withAlphaComponent(0.10)])?
                .draw(in: all, angle: 0)
            NSGradient(colors: [NSColor.black.withAlphaComponent(0.72), NSColor.black.withAlphaComponent(0.0),
                                NSColor.black.withAlphaComponent(0.22)])?
                .draw(in: all, angle: 90)
            let vignette = NSGradient(colors: [NSColor.clear, NSColor.black.withAlphaComponent(0.42)])
            vignette?.draw(in: NSBezierPath(rect: all), relativeCenterPosition: NSPoint(x: 0.15, y: 0.05))
        }
        return texture(b)
    }()

    lazy var tileShadow: CIImage = {
        let pad = 80.0
        let b = bitmap(Int(tileSize + pad * 2), Int(tileSize + pad * 2))
        drawInto(b) {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 34
            shadow.shadowOffset = NSSize(width: 0, height: -16)
            shadow.set()
            NSColor.black.setFill()
            NSRect(x: pad, y: pad, width: tileSize, height: tileSize).fill()
        }
        return texture(b)
    }()

    func opacity(_ image: CIImage, _ alpha: Double) -> CIImage {
        if alpha >= 1 { return image }
        if alpha <= 0 { return CIImage.empty() }
        return image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
    }

    /// Cover-fit a backdrop with zoom and a gentle pan, graded for calm.
    func backdrop(_ image: CIImage, zoom: Double, pan: Double) -> CIImage {
        let scale = max(Double(width) / image.extent.width, Double(height) / image.extent.height) * zoom
        let w = image.extent.width * scale, h = image.extent.height * scale
        return image
            .transformed(by: CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                tx: (Double(width) - w) / 2 + pan - image.extent.minX * scale,
                ty: (Double(height) - h) / 2 - (h - Double(height)) * 0.10 - image.extent.minY * scale))
            .cropped(to: canvas)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.84, kCIInputContrastKey: 1.06,
                                                           kCIInputBrightnessKey: -0.015])
    }

    // Artwork swap ---------------------------------------------------------

    func requestArtwork(_ paths: [String], now: Double, synchronous: Bool) {
        if paths == artwork.paths || paths == requested { return }
        requested = paths
        if synchronous {
            apply(loadArtwork(paths, gpu), now: now)
            return
        }
        let context = gpu
        decodeQueue.async { [self] in
            let set = loadArtwork(paths, context)
            self.artworkLock.lock(); self.pendingArtwork = set; self.artworkLock.unlock()
        }
    }
    func apply(_ set: ArtworkSet, now: Double) {
        guard set.paths == requested else { return }   // superseded while decoding
        snapshotForTransition(now: now)
        artwork = set
    }
    func takePendingArtwork(now: Double) {
        artworkLock.lock(); let set = pendingArtwork; pendingArtwork = nil; artworkLock.unlock()
        if let set { apply(set, now: now) }
    }
    func snapshotForTransition(now: Double) {
        let data = Data(bytes: frameBuffer, count: frameBytes)
        oldFrame = CIImage(bitmapData: data, bytesPerRow: rowBytes, size: canvas.size, format: .RGBA8, colorSpace: colorSpace)
        transition = now
    }

    // Text layers ----------------------------------------------------------

    let textLeft: CGFloat = 84
    let textWidth: CGFloat = 740
    let blockOrigin = CGPoint(x: 64, y: 150)   // text bitmap origin on the canvas
    let blockSize = NSSize(width: 820, height: 470)

    func textLayers(_ s: Snapshot, accent: Accent) {
        let inset = textLeft - blockOrigin.x
        // Shrink from 76 pt until the title fits two lines at that size (two lines at 76 pt is about 196 px).
        func twoLines(_ size: CGFloat) -> CGFloat { measure("Ag\nAg", width: textWidth, size: size, weight: .light, tracking: -1.5) }
        var size: CGFloat = 76
        while size > 44 && measure(s.title, width: textWidth, size: size, weight: .light, tracking: -1.5) > twoLines(size) { size -= 2 }
        let titleHeight = min(twoLines(size), measure(s.title, width: textWidth, size: size, weight: .light, tracking: -1.5))
        let titleBottom: CGFloat = 164
        let accentColor = NSColor(calibratedRed: accent.r, green: accent.g, blue: accent.b, alpha: 1)

        let title = bitmap(Int(blockSize.width), Int(blockSize.height))
        drawInto(title) {
            // Word-wrap to at most two lines; anything beyond the last visible line ends in an ellipsis.
            // (.byTruncatingTail in NSString drawing collapses to a single line, so wrap + truncatesLastVisibleLine.)
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byWordWrapping
            (s.title as NSString).draw(with: NSRect(x: inset, y: titleBottom, width: textWidth, height: titleHeight + 4),
                options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
                attributes: [.font: NSFont.systemFont(ofSize: size, weight: .light), .foregroundColor: NSColor.white,
                             .kern: -1.5, .paragraphStyle: p])
        }
        let artist = bitmap(Int(blockSize.width), Int(blockSize.height))
        drawInto(artist) {
            accentColor.withAlphaComponent(0.9).setFill()
            NSRect(x: inset, y: 146, width: 44, height: 2).fill()
            text(s.artist, rect: NSRect(x: inset, y: 92, width: textWidth, height: 42), size: 30, weight: .regular,
                 color: .white.withAlphaComponent(0.94), tracking: 0.2)
        }
        let album = bitmap(Int(blockSize.width), Int(blockSize.height))
        drawInto(album) {
            text(s.album, rect: NSRect(x: inset, y: 50, width: textWidth, height: 28), size: 18, weight: .light,
                 color: .white.withAlphaComponent(0.56), tracking: 0.4)
        }
        let eyebrow = bitmap(Int(blockSize.width), Int(blockSize.height))
        drawInto(eyebrow) {
            let y = titleBottom + titleHeight + 24
            accentColor.setFill()
            NSRect(x: inset, y: y + 4, width: 7, height: 7).fill()
            text("now playing", rect: NSRect(x: inset + 18, y: y - 3, width: 300, height: 22), size: 15, weight: .medium,
                 color: accentColor, tracking: 3.2)
        }
        titleLayer = texture(title); artistLayer = texture(artist); albumLayer = texture(album); eyebrowLayer = texture(eyebrow)
    }

    func chrome(_ s: Snapshot) -> CIImage {
        let key = s.credit
        if let layer = chromeLayer, chromeKey == key { return layer }
        chromeKey = key
        let b = bitmap(width, height)
        drawInto(b) {
            text("S U R R O U N D   S T R E A M   ·   D O L B Y   D I G I T A L   5 . 1",
                 rect: NSRect(x: 84, y: 44, width: 700, height: 20), size: 10, weight: .medium,
                 color: .white.withAlphaComponent(0.36), tracking: 0.4)
            if !s.credit.isEmpty {
                let p = NSMutableParagraphStyle(); p.alignment = .right; p.lineBreakMode = .byTruncatingHead
                (s.credit as NSString).draw(in: NSRect(x: 760, y: 44, width: 436, height: 20),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .regular),
                                     .foregroundColor: NSColor.white.withAlphaComponent(0.32), .kern: 0.4, .paragraphStyle: p])
            }
        }
        chromeLayer = texture(b)
        return chromeLayer!
    }

    func accentBar(_ accent: Accent) -> CIImage {
        let key = "\(accent.r),\(accent.g),\(accent.b)"
        if let layer = accentLayer, accentKey == key { return layer }
        accentKey = key
        accentLayer = CIImage(color: CIColor(red: accent.r, green: accent.g, blue: accent.b))
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: tileSize))
        return accentLayer!
    }

    // Frame ----------------------------------------------------------------

    /// Renders into frameBuffer. `elapsed` is time since the track changed.
    func frame(_ s: Snapshot, elapsed: Double, now: Double, synchronous: Bool = false) {
        requestArtwork(s.pictures, now: now, synchronous: synchronous)
        if !synchronous { takePendingArtwork(now: now) }
        if lastKey != s.key || titleLayer == nil {
            if titleLayer != nil { snapshotForTransition(now: now) }
            lastKey = s.key
            textLayers(s, accent: artwork.accent)
        }
        let art = artwork
        var image = base

        // Backdrop: slow zoom and drift; dissolve to the next photo every 24 s.
        if !art.backdrops.isEmpty {
            let period = 24.0, dissolve = 1.8
            let cycle = elapsed / period
            let index = Int(cycle) % art.backdrops.count, next = (index + 1) % art.backdrops.count
            let zoom = 1.08 + 0.025 * sin(elapsed / 83)
            image = backdrop(art.backdrops[index], zoom: zoom, pan: 14 * sin(elapsed / 57))
            if art.backdrops.count > 1 {
                let blend = smooth((cycle - floor(cycle) - (1 - dissolve / period)) / (dissolve / period))
                if blend > 0 {
                    image = opacity(backdrop(art.backdrops[next], zoom: 1.08, pan: -12 * sin(elapsed / 61)), blend)
                        .composited(over: image)
                }
            }
        }
        image = lighting.composited(over: image)

        // Flat Metro tile on the right, with a live-tile flip to the next photo.
        if art.tiles.count > 1 {
            // The flip closes each 44 s period, so the first one lands at 44 s rather than during the text entrance.
            let flipPeriod = 44.0, flipDuration = 0.75
            let turn = elapsed / flipPeriod
            let phase = (turn - floor(turn)) * flipPeriod
            var tileIndex = (Int(turn) + 1) % art.tiles.count
            var scaleX = 1.0
            if phase > flipPeriod - flipDuration {
                let t = (phase - (flipPeriod - flipDuration)) / flipDuration
                scaleX = max(0.02, abs(cos(.pi * t)))   // never a singular transform
                if t >= 0.5 { tileIndex = (tileIndex + 1) % art.tiles.count }
            }
            let cx = 1046.0 + 5 * sin(elapsed / 29), cy = 370.0 + 4 * sin(elapsed / 13)
            let shadowOffset = tileShadow.extent.width / 2
            let shadow = tileShadow.transformed(by: CGAffineTransform(translationX: cx - shadowOffset, y: cy - shadowOffset))
            image = opacity(shadow, 0.55 * scaleX).composited(over: image)
            let around = CGAffineTransform(translationX: cx, y: cy).scaledBy(x: scaleX, y: 1)
                .translatedBy(x: -tileSize / 2, y: -tileSize / 2)
            image = art.tiles[tileIndex].transformed(by: around).composited(over: image)
            image = accentBar(art.accent).transformed(by: around).composited(over: image)
        }

        image = chrome(s).composited(over: image)

        // Turnstile entrance: slide in from the right with a fade, staggered per line.
        let drift = 6 * sin(elapsed / 19)
        func place(_ layer: CIImage?, delay: Double) -> CIImage? {
            guard let layer else { return nil }
            let t = easeOut((elapsed - delay) / 0.9)
            if t <= 0 { return nil }
            let x = blockOrigin.x + drift + 110 * (1 - t)
            return opacity(layer.transformed(by: CGAffineTransform(translationX: x, y: blockOrigin.y)), t)
        }
        for layer in [place(eyebrowLayer, delay: 0.0), place(titleLayer, delay: 0.08),
                      place(artistLayer, delay: 0.22), place(albumLayer, delay: 0.34)] {
            if let layer { image = layer.composited(over: image) }
        }

        // Cross-dissolve from the previous visual state.
        if let previous = oldFrame, now - transition < 1.0 {
            image = opacity(previous, 1 - smooth((now - transition) / 1.0)).composited(over: image)
        } else {
            oldFrame = nil
        }
        gpu.render(image, toBitmap: frameBuffer, rowBytes: rowBytes, bounds: canvas, format: .RGBA8, colorSpace: colorSpace)
    }

    func savePNG(_ url: URL) {
        var planes: [UnsafeMutablePointer<UInt8>?] = [frameBuffer.assumingMemoryBound(to: UInt8.self)]
        let rep = NSBitmapImageRep(bitmapDataPlanes: &planes, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: rowBytes, bitsPerPixel: 32)
        if let png = rep?.representation(using: .png, properties: [:]) { try? png.write(to: url, options: .atomic) }
    }

    /// Writes the frame to stdout; exits quietly when the encoder closes the pipe.
    func emit() {
        var offset = 0
        while offset < frameBytes {
            let written = write(1, frameBuffer + offset, frameBytes - offset)
            if written < 0 && errno == EINTR { continue }
            if written <= 0 { exit(0) }
            offset += written
        }
    }
}

// MARK: - Entry points

func render(folder: URL) {
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let scene = Scene(), renderer = Renderer()
    renderer.frame(scene.snapshot(), elapsed: 3, now: ProcessInfo.processInfo.systemUptime, synchronous: true)
    renderer.savePNG(folder.appendingPathComponent("background.png"))
    renderer.savePNG(folder.appendingPathComponent("text.png"))
    Thread.detachNewThread {
        while let line = readLine() {
            if let data = line.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String:Any] {
                scene.update(value)
            }
        }
        exit(0)
    }
    while true {
        autoreleasepool {
            let now = ProcessInfo.processInfo.systemUptime, s = scene.snapshot()
            renderer.frame(s, elapsed: now - s.updated, now: now)
            renderer.emit()
            // The bounded pipe is paced by the encoder's audio clock. No second clock.
        }
    }
}

if CommandLine.arguments.contains("--now-playing") { watchMusic() }
else if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--render" {
    render(folder: URL(fileURLWithPath: CommandLine.arguments[2]))
} else if CommandLine.arguments.count >= 4 && CommandLine.arguments[1] == "--snapshot" {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let info = try JSONSerialization.jsonObject(with: data) as! [String:Any]
    let scene = Scene(); scene.update(info)
    let elapsed = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4]) ?? 4 : 4
    let renderer = Renderer(); let now = ProcessInfo.processInfo.systemUptime
    renderer.frame(scene.snapshot(), elapsed: elapsed, now: now - 2, synchronous: true)
    renderer.frame(scene.snapshot(), elapsed: elapsed, now: now, synchronous: true)
    renderer.savePNG(URL(fileURLWithPath: CommandLine.arguments[3]))
} else {
    fputs("Usage: TileRenderer --now-playing [--once] | --render folder | --snapshot scene.json output.png [seconds]\n", stderr)
    exit(1)
}
