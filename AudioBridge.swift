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

// MARK: - capture

final class Capture {
    let dev: AudioObjectID
    var procID: AudioDeviceIOProcID?
    let out = FileHandle.standardOutput
    init(_ d: AudioObjectID) { dev = d }
    func start() {
        let st = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { [self] _, inData, _, _, _ in
            _ = self.dev // Keep the capture owner alive while the I/O block is installed.
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let b = abl.first, let p = b.mData else { return }
            let ch = Int(b.mNumberChannels)
            let frames = Int(b.mDataByteSize) / (ch * 4)
            // Encoded mirror words are stored as integer-valued floats. Refuse
            // those buffers rather than treating a bitstream as PCM audio.
            let check = p.assumingMemoryBound(to: Float.self)
            for i in 0..<(frames * ch) {
                if !check[i].isFinite || abs(check[i]) > 4 {
                    log("Source is not safe PCM; turn Music HDMI Passthrough off.")
                    exit(2)
                }
            }
            let src = p.assumingMemoryBound(to: Float.self)
            let n = CAPTURE_CH
            var buf = [Float](repeating: 0, count: frames * n)
            for f in 0..<frames {
                for c in 0..<min(n, ch) { buf[f * n + c] = src[f * ch + c] }
            }
            buf.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(1, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    if written <= 0 { exit(0) }
                    offset += written
                }
            }
        }
        guard st == noErr else { log("capture IOProc error \(st)"); exit(1) }
        AudioDeviceStart(dev, procID)
        log("capturing from \(deviceName(dev))")
    }
}

final class RawCapture {
    let dev: AudioObjectID
    var procID: AudioDeviceIOProcID?
    init(_ d: AudioObjectID) { dev = d }
    func start() {
        let st = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { [self] _, inData, _, _, _ in
            _ = self.dev // Keep the capture owner alive while the I/O block is installed.
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let b = abl.first, let p = b.mData else { return }
            let ch = Int(b.mNumberChannels)
            let frames = Int(b.mDataByteSize) / (ch * 4)
            let src = p.assumingMemoryBound(to: Float.self)
            var buf = [Int16](repeating: 0, count: frames * 2)
            for f in 0..<frames {
                for c in 0..<min(2, ch) {
                    let v = src[f * ch + c]
                    buf[f * 2 + c] = Int16(max(-32768, min(32767, v.rounded())))
                }
            }
            buf.withUnsafeBytes { raw in
                let r = write(1, raw.baseAddress, raw.count)
                if r < 0 { exit(0) }
            }
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

final class Ring {
    var buf: [UInt8]
    var r = 0, w = 0, count = 0
    let lock = NSLock()
    init(_ n: Int) { buf = [UInt8](repeating: 0, count: n) }
    func write(_ p: UnsafeRawBufferPointer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if count + p.count > buf.count { return false }
        for b in p { buf[w] = b; w = (w + 1) % buf.count }
        count += p.count
        return true
    }
    func read(into dst: UnsafeMutableRawPointer, _ n: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let m = min(n, count)
        let d = dst.assumingMemoryBound(to: UInt8.self)
        for i in 0..<m { d[i] = buf[r]; r = (r + 1) % buf.count }
        count -= m
        return m
    }
    var filled: Int { lock.lock(); defer { lock.unlock() }; return count }
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
    var started = false
    var underruns = 0
    let st = AudioDeviceCreateIOProcIDWithBlock(&playProcID, hdmi, nil) { _, _, _, outData, _ in
        let abl = UnsafeMutableAudioBufferListPointer(outData)
        for b in abl {
            guard let p = b.mData else { continue }
            let n = Int(b.mDataByteSize)
            let got = started ? ring.read(into: p, n) : 0
            if got < n {
                memset(p + got, 0, n - got)
                if started { underruns += 1 }
            }
        }
    }
    guard st == noErr else { log("play IOProc error \(st)"); restoreHDMI?(); exit(1) }
    AudioDeviceStart(hdmi, playProcID)

    // Reader thread: stdin -> ring
    let reader = Thread {
        var chunk = [UInt8](repeating: 0, count: 6144)
        while true {
            let r = chunk.withUnsafeMutableBytes { read(0, $0.baseAddress, $0.count) }
            if r <= 0 { break }
            chunk.withUnsafeBytes { raw in
                let slice = UnsafeRawBufferPointer(rebasing: raw[0..<r])
                while !ring.write(slice) { usleep(2000) }
            }
            if !started && ring.filled >= 6144 * 4 { started = true; log("streaming IEC 61937 audio to \(deviceName(hdmi))") }
        }
        log("input ended (underruns: \(underruns))")
        restoreHDMI?(); exit(0)
    }
    reader.start()
    Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
        if underruns > 0 { log("underruns so far: \(underruns)") }
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
