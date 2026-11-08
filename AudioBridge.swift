// Core Audio backend for the HDMI Lab DTS bridge.
// capture: full-width PCM mirror -> stdout.
// play: IEC 61937 frames -> an exact-named physical HDMI device.

import CoreAudio
import Foundation

let HDMI_MATCH = ProcessInfo.processInfo.environment["DD51_HDMI"] ?? ""
let BH_MATCH = ProcessInfo.processInfo.environment["DD51_SRC"] ?? "HDMI Lab 16ch Mirror"
// Driver order: L R C LFE Ls Rs Rls Rrs Lw Rw Ltf Rtf Ltm Rtm Ltr Rtr.
// Folded by explicit channel indices in Bridge.py.
let CAPTURE_CH = Int(ProcessInfo.processInfo.environment["DD51_CH"] ?? "16") ?? 16

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getArray<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ def: T) -> [T] {
    var a = addr(sel, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var arr = [T](repeating: def, count: Int(size) / MemoryLayout<T>.stride)
    let status = arr.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0.baseAddress!) }
    return status == noErr ? arr : []
}

func getValue<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ def: T) -> T {
    getArray(id, sel, scope, def).first ?? def
}

@discardableResult
func setValue<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ v: T) -> OSStatus {
    var a = addr(sel, scope)
    var val = v
    return withUnsafeBytes(of: &val) { AudioObjectSetPropertyData(id, &a, 0, nil, UInt32($0.count), $0.baseAddress!) }
}

func deviceName(_ id: AudioObjectID) -> String {
    var a = addr(kAudioObjectPropertyName)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var name: Unmanaged<CFString>? = nil
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name) == noErr, let n = name else { return "?" }
    return n.takeRetainedValue() as String
}

func allDevices() -> [AudioObjectID] {
    getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, AudioObjectID(0))
}

func find(_ match: String) -> AudioObjectID? {
    let devs = allDevices()
    if let exact = devs.first(where: { deviceName($0).uppercased() == match.uppercased() }) { return exact }
    return nil // Exact names only: never confuse a sink with its mirror.
}

func fourcc(_ v: UInt32) -> String {
    String(bytes: withUnsafeBytes(of: v.bigEndian, Array.init), encoding: .ascii) ?? "?"
}

func describe(_ f: AudioStreamBasicDescription) -> String {
    "\(f.mChannelsPerFrame)ch \(Int(f.mSampleRate))Hz \(f.mBitsPerChannel)bit \(fourcc(f.mFormatID)) flags=0x\(String(f.mFormatFlags, radix: 16))"
}

func outputStream(_ dev: AudioObjectID) -> AudioObjectID? {
    getArray(dev, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, AudioObjectID(0)).first
}

// MARK: - info

func cmdInfo() {
    for d in allDevices() { log("device \(d): \(deviceName(d))") }
    guard let hdmi = find(HDMI_MATCH), let s = outputStream(hdmi) else { log("HDMI device '\(HDMI_MATCH)' not found"); exit(1) }
    log("HDMI current: " + describe(getValue(s, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())))
    for r in getArray(s, kAudioStreamPropertyAvailablePhysicalFormats, kAudioObjectPropertyScopeGlobal, AudioStreamRangedDescription()) {
        log("  avail: " + describe(r.mFormat))
    }
    if let bh = find(BH_MATCH) {
        log("Virtual source rate: \(getValue(bh, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0)))")
    }
    let def: AudioObjectID = getValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0))
    log("default output: \(deviceName(def))")
}

// MARK: - byte ring (lock held only for memcpy; no allocation after init)

final class Ring {
    private let buf: UnsafeMutableRawPointer
    let capacity: Int
    private var r = 0, w = 0, count = 0
    private let lock = NSLock()
    init(_ n: Int) {
        capacity = n
        buf = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 16)
        buf.initializeMemory(as: UInt8.self, repeating: 0, count: n)
    }
    deinit { buf.deallocate() }
    /// Copies `n` bytes in at most two segments. Returns false (and copies nothing) when full.
    func write(_ src: UnsafeRawPointer, _ n: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if count + n > capacity { return false }
        let first = min(n, capacity - w)
        memcpy(buf + w, src, first)
        if n > first { memcpy(buf, src + first, n - first) }
        w = (w + n) % capacity
        count += n
        return true
    }
    func write(_ p: UnsafeRawBufferPointer) -> Bool {
        guard let base = p.baseAddress, p.count > 0 else { return true }
        return write(base, p.count)
    }
    /// Copies up to `n` bytes out in at most two segments; returns the number copied.
    func read(into dst: UnsafeMutableRawPointer, _ n: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let m = min(n, count)
        if m == 0 { return 0 }
        let first = min(m, capacity - r)
        memcpy(dst, buf + r, first)
        if m > first { memcpy(dst + first, buf, m - first) }
        r = (r + m) % capacity
        count -= m
        return m
    }
    var filled: Int { lock.lock(); defer { lock.unlock() }; return count }
}

// MARK: - capture

final class Capture {
    let dev: AudioObjectID
    var procID: AudioDeviceIOProcID?
    // One second of 16-channel float PCM. The audio thread only memcpy's into
    // this; a separate thread does the blocking pipe writes.
    let ring = Ring(48000 * CAPTURE_CH * 4)
    var staging: UnsafeMutablePointer<Float>? = nil
    var stagingCount = 0
    var overflows = 0
    var reportedOverflows = 0
    init(_ d: AudioObjectID) { dev = d }

    func start() {
        let st = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { [self] _, inData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let b = abl.first, let p = b.mData else { return }
            let ch = Int(b.mNumberChannels)
            guard ch > 0 else { return }
            let frames = Int(b.mDataByteSize) / (ch * 4)
            let src = p.assumingMemoryBound(to: Float.self)
            let n = CAPTURE_CH
            // Single pass: validate every sample (encoded mirror words arrive as
            // integer-valued floats; refuse those rather than encoding a bitstream
            // as PCM) and, when the channel counts match, hand the buffer straight
            // to the ring with no intermediate copy.
            let total = frames * ch
            var i = 0
            while i < total {
                let v = src[i]
                if !(v.isFinite && abs(v) <= 4) {
                    log("Source is not safe PCM; turn Music HDMI Passthrough off.")
                    exit(2)
                }
                i += 1
            }
            var ok: Bool
            if n == ch {
                ok = self.ring.write(UnsafeRawPointer(src), total * 4)
            } else {
                let need = frames * n
                if self.staging == nil || self.stagingCount < need {
                    // Core Audio keeps the buffer size constant; this runs once.
                    self.staging?.deallocate()
                    self.staging = UnsafeMutablePointer<Float>.allocate(capacity: need)
                    self.stagingCount = need
                }
                let dst = self.staging!
                let copy = min(n, ch)
                for f in 0..<frames {
                    let s = src + f * ch, d = dst + f * n
                    for c in 0..<copy { d[c] = s[c] }
                    if n > copy { for c in copy..<n { d[c] = 0 } }
                }
                ok = self.ring.write(UnsafeRawPointer(dst), need * 4)
            }
            if !ok { self.overflows += 1 }
        }
        guard st == noErr else { log("capture IOProc error \(st)"); exit(1) }
        let writer = Thread { [self] in
            let chunkSize = 65536
            let chunk = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
            defer { chunk.deallocate() }
            while true {
                let got = self.ring.read(into: chunk, chunkSize)
                if got == 0 { usleep(3000); continue }
                var offset = 0
                while offset < got {
                    let written = write(1, chunk + offset, got - offset)
                    if written < 0 && errno == EINTR { continue }
                    if written <= 0 { exit(0) } // downstream closed the pipe
                    offset += written
                }
                if self.overflows != self.reportedOverflows {
                    self.reportedOverflows = self.overflows
                    log("capture ring overflowed; dropped buffers so far: \(self.reportedOverflows)")
                }
            }
        }
        writer.qualityOfService = .userInteractive
        writer.start()
        AudioDeviceStart(dev, procID)
        log("capturing from \(deviceName(dev))")
    }
}

final class RawCapture {
    let dev: AudioObjectID
    var procID: AudioDeviceIOProcID?
    var staging: UnsafeMutablePointer<Int16>? = nil
    var stagingCount = 0
    init(_ d: AudioObjectID) { dev = d }
    func start() {
        let st = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { [self] _, inData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let b = abl.first, let p = b.mData else { return }
            let ch = Int(b.mNumberChannels)
            guard ch > 0 else { return }
            let frames = Int(b.mDataByteSize) / (ch * 4)
            let src = p.assumingMemoryBound(to: Float.self)
            if self.staging == nil || self.stagingCount < frames * 2 {
                self.staging?.deallocate()
                self.staging = UnsafeMutablePointer<Int16>.allocate(capacity: frames * 2)
                self.stagingCount = frames * 2
            }
            let buf = self.staging!
            for f in 0..<frames {
                for c in 0..<min(2, ch) {
                    let v = src[f * ch + c]
                    buf[f * 2 + c] = Int16(max(-32768, min(32767, v.rounded())))
                }
                if ch < 2 { buf[f * 2 + 1] = 0 }
            }
            let r = write(1, buf, frames * 4)
            if r < 0 { exit(0) }
        }
        guard st == noErr else { log("raw capture IOProc error \(st)"); exit(1) }
        AudioDeviceStart(dev, procID)
        log("raw bitstream capture from \(deviceName(dev)) @ \(getValue(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0))) Hz")
    }
}

func cmdCaptureRaw() {
    signal(SIGPIPE, SIG_IGN)
    guard let bh = find(BH_MATCH) else { log("source device '\(BH_MATCH)' not found"); exit(1) }
    let c = RawCapture(bh)
    c.start()
    dispatchMain()
}

func cmdCapture() {
    signal(SIGPIPE, SIG_IGN)
    guard let bh = find(BH_MATCH) else { log("Virtual source not found"); exit(1) }
    let c = Capture(bh)
    c.start()
    dispatchMain()
}

// MARK: - play (IEC 61937 to HDMI, exclusive; payload supplied by FFmpeg)

/// Playback state shared between the stdin reader and the HDMI I/O thread.
final class PlayState {
    private let lock = NSLock()
    private var startedValue = false
    private var underrunValue = 0
    var started: Bool {
        get { lock.lock(); defer { lock.unlock() }; return startedValue }
        set { lock.lock(); startedValue = newValue; lock.unlock() }
    }
    func noteUnderrun() { lock.lock(); underrunValue += 1; lock.unlock() }
    var underruns: Int { lock.lock(); defer { lock.unlock() }; return underrunValue }
}

var restoreHDMI: (() -> Void)?

func cmdPlay() {
    guard let hdmi = find(HDMI_MATCH), let s = outputStream(hdmi) else { log("HDMI device not found"); exit(1) }
    let original = getValue(s, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())
    let avail = getArray(s, kAudioStreamPropertyAvailablePhysicalFormats, kAudioObjectPropertyScopeGlobal, AudioStreamRangedDescription())
    let carrierFormats = avail.map { $0.mFormat }
    let suitable = carrierFormats.first { f in
        let carrier = f.mFormatID == kAudioFormat60958AC3 && f.mSampleRate == 48000
        let packing = f.mChannelsPerFrame == 2 && f.mBitsPerChannel == 16 && f.mBytesPerFrame == 4
        return carrier && packing
    }
    guard var ac3 = suitable else {
        log("HDMI device offers no 48 kHz AC-3 format"); exit(1)
    }

    var pid = pid_t(getpid())
    let hog = setValue(hdmi, kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, pid)
    let mix = setValue(hdmi, kAudioDevicePropertySupportsMixing, kAudioObjectPropertyScopeGlobal, UInt32(0))
    var a = addr(kAudioStreamPropertyPhysicalFormat)
    let fmt = AudioObjectSetPropertyData(s, &a, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &ac3)
    Thread.sleep(forTimeInterval: 0.5)
    let now = getValue(s, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())
    log("hog=\(hog) mixingOff=\(mix) setAC3=\(fmt)  now: \(describe(now))")

    guard fmt == noErr, now.mFormatID == kAudioFormat60958AC3,
          now.mSampleRate == 48000, now.mChannelsPerFrame == 2,
          now.mBitsPerChannel == 16, now.mBytesPerFrame == 4 else {
        var oldFormat = original
        _ = AudioObjectSetPropertyData(s, &a, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &oldFormat)
        setValue(hdmi, kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, pid_t(-1))
        log("The physical sink did not enter the required IEC 61937 format. Stopping.")
        exit(2)
    }
    var playProcID: AudioDeviceIOProcID?
    restoreHDMI = {
        if let proc = playProcID {
            AudioDeviceStop(hdmi, proc); AudioDeviceDestroyIOProcID(hdmi, proc)
            playProcID = nil
        }
        var o = original
        var a2 = addr(kAudioStreamPropertyPhysicalFormat)
        AudioObjectSetPropertyData(s, &a2, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &o)
        setValue(hdmi, kAudioDevicePropertySupportsMixing, kAudioObjectPropertyScopeGlobal, UInt32(1))
        pid = -1
        setValue(hdmi, kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, pid)
        log("HDMI restored to \(describe(original))")
    }
    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { restoreHDMI?(); exit(0) }
        source.resume(); signalSources.append(source)
    }

    let ring = Ring(6144 * 64)
    let state = PlayState()
    let st = AudioDeviceCreateIOProcIDWithBlock(&playProcID, hdmi, nil) { _, _, _, outData, _ in
        let abl = UnsafeMutableAudioBufferListPointer(outData)
        let started = state.started
        for b in abl {
            guard let p = b.mData else { continue }
            let n = Int(b.mDataByteSize)
            let got = started ? ring.read(into: p, n) : 0
            if got < n {
                memset(p + got, 0, n - got)
                if started { state.noteUnderrun() }
            }
        }
    }
    guard st == noErr else { log("play IOProc error \(st)"); restoreHDMI?(); exit(1) }
    AudioDeviceStart(hdmi, playProcID)

    // Reader thread: stdin -> ring
    let reader = Thread {
        let chunkSize = 6144
        let chunk = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { chunk.deallocate() }
        while true {
            let r = read(0, chunk, chunkSize)
            if r < 0 && errno == EINTR { continue }
            if r <= 0 { break }
            while !ring.write(UnsafeRawPointer(chunk), r) { usleep(2000) }
            if !state.started && ring.filled >= 6144 * 4 {
                state.started = true
                log("streaming IEC 61937 audio to \(deviceName(hdmi))")
            }
        }
        log("input ended (underruns: \(state.underruns))")
        restoreHDMI?(); exit(0)
    }
    reader.qualityOfService = .userInteractive
    reader.start()
    Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
        let n = state.underruns
        if n > 0 { log("underruns so far: \(n)") }
    }
    withExtendedLifetime(signalSources) { RunLoop.main.run() }
}

// MARK: - main

switch CommandLine.arguments.dropFirst().first ?? "info" {
case "capture": cmdCapture()
case "capture-raw": cmdCaptureRaw()
case "play": cmdPlay()
default: cmdInfo()
}
