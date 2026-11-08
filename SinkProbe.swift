import CoreAudio
import Foundation

// Inventory and level meter for HDMI Lab. No audio recordings or driver installation.
// set-default changes the default output explicitly; metering opens only virtual mirror inputs.
func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func values<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ initial: T) -> [T] {
    var a = address(selector, scope), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var result = [T](repeating: initial, count: Int(size) / MemoryLayout<T>.stride)
    let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!) }
    return status == noErr ? result : []
}
func values<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> [T] {
    values(object, selector, kAudioObjectPropertyScopeGlobal, initial)
}
func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var a = address(selector), value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr else { return "?" }
    return (value?.takeRetainedValue() as String?) ?? "?"
}
func fourCC(_ value: UInt32) -> String {
    String(bytes: withUnsafeBytes(of: value.bigEndian, Array.init), encoding: .ascii) ?? String(value)
}
func format(_ f: AudioStreamBasicDescription) -> [String: Any] {
    ["id": fourCC(f.mFormatID), "rate": f.mSampleRate, "channels": f.mChannelsPerFrame,
     "bits": f.mBitsPerChannel, "flags": f.mFormatFlags, "bytesPerFrame": f.mBytesPerFrame,
     "bytesPerPacket": f.mBytesPerPacket, "framesPerPacket": f.mFramesPerPacket]
}
let system = AudioObjectID(kAudioObjectSystemObject)
func devices() -> [AudioObjectID] { values(system, kAudioHardwarePropertyDevices, AudioObjectID(0)) }
func streams(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioObjectID] {
    values(device, kAudioDevicePropertyStreams, scope, AudioObjectID(0))
}
func streamState(_ stream: AudioObjectID, available: Bool = false) -> [String: Any] {
    var result: [String: Any] = ["stream": stream]
    for (key, selector) in [("physical", kAudioStreamPropertyPhysicalFormat), ("virtual", kAudioStreamPropertyVirtualFormat)] {
        if let f = values(stream, selector, AudioStreamBasicDescription()).first { result[key] = format(f) }
    }
    if available {
        result["availablePhysical"] = values(stream, kAudioStreamPropertyAvailablePhysicalFormats, AudioStreamRangedDescription()).map { format($0.mFormat) }
        result["availableVirtual"] = values(stream, kAudioStreamPropertyAvailableVirtualFormats, AudioStreamRangedDescription()).map { format($0.mFormat) }
    }
    return result
}
let sampleDirectory = ProcessInfo.processInfo.environment["SINK_PROBE_DIR"]
var recordNumber = 0
let timestampFormatter = ISO8601DateFormatter()
func emit(_ record: [String: Any]) {
    var r = record
    r["time"] = timestampFormatter.string(from: Date())
    if let data = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) {
        if let sampleDirectory {
            try? FileManager.default.createDirectory(atPath: sampleDirectory, withIntermediateDirectories: true)
            let target = URL(fileURLWithPath: sampleDirectory).appendingPathComponent(String(format: "%05d.json", recordNumber))
            try? data.write(to: target, options: .atomic)
        }
        recordNumber += 1
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
let permitted = Set(["HDMI Lab 8ch Mirror", "HDMI Lab 16ch Mirror"])
let all = devices()
guard !all.isEmpty else {
    emit(["event": "blocked", "reason": "Core Audio returned zero devices. Run this executable locally in Terminal; a sandbox result cannot establish audio capability."])
    exit(77)
}
let selected = all.filter { permitted.contains(string($0, kAudioObjectPropertyName)) }
let names = Dictionary(uniqueKeysWithValues: all.map { ($0, string($0, kAudioObjectPropertyName)) })
func defaultName() -> String {
    let id = values(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)).first ?? 0
    return names[id] ?? "?"
}
let command = CommandLine.arguments.dropFirst().first ?? "600"
if command == "default-name" { print(defaultName()); exit(0) }
if command == "set-default" {
    let wanted = CommandLine.arguments.dropFirst(2).joined(separator: " ")
    guard var device = all.first(where: { names[$0] == wanted }) else { emit(["event":"error", "reason":"Exact output name not found", "name":wanted]); exit(1) }
    var a = address(kAudioHardwarePropertyDefaultOutputDevice)
    let status = AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device)
    emit(["event":"setDefault", "name":wanted, "status":status]); exit(status == noErr ? 0 : 1)
}
emit(["event": "inventory", "defaultOutput": defaultName(), "devices": all.map { d -> [String: Any] in
    ["id": d, "name": names[d]!, "uid": string(d, kAudioDevicePropertyDeviceUID),
     "transport": fourCC(values(d, kAudioDevicePropertyTransportType, UInt32(0)).first ?? 0),
     "output": streams(d, kAudioObjectPropertyScopeOutput).map { streamState($0, available: true) },
     "input": streams(d, kAudioObjectPropertyScopeInput).map { streamState($0, available: true) }]
}])
if CommandLine.arguments.dropFirst().first == "snapshot" { exit(0) }

final class InputMeter {
    let device: AudioObjectID
    let name: String
    // Decided once: only the virtual mirrors carry possible IEC 61937 headers.
    let scansHeaders: Bool
    var proc: AudioDeviceIOProcID?
    let lock = NSLock()
    var peaks = [Float](repeating: 0, count: 32)
    var callbacks: UInt64 = 0
    var frames: UInt64 = 0
    var ac3Bursts = 0
    var eac3Bursts = 0
    // Last three 16-bit words as a shift register; no per-sample array shuffling.
    var history: UInt64 = 0
    var historyCount = 0
    var rejectedBuffers = 0
    init(_ d: AudioObjectID, _ n: String) {
        device = d; name = n
        scansHeaders = n == "Atmos Sink Mirror" || n.hasPrefix("HDMI Lab")
    }
    func start() {
        guard let s = streams(device, kAudioObjectPropertyScopeInput).first,
              let f = values(s, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()).first,
              f.mFormatID == kAudioFormatLinearPCM, f.mBitsPerChannel == 32,
              f.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 else {
            emit(["event": "meterUnavailable", "device": name, "reason": "Input is not interleaved float32 PCM"]); return
        }
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { [self] _, data, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
            guard let b = buffers.first, let raw = b.mData, b.mNumberChannels > 0 else { return }
            let ch = Int(b.mNumberChannels), count = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            guard ch <= 32, count % ch == 0 else { return }
            let src = raw.assumingMemoryBound(to: Float.self)
            lock.lock(); defer { lock.unlock() }
            callbacks += 1; frames += UInt64(count / ch)
            // Peaks: walk frame by frame so the channel index needs no modulo.
            var i = 0
            while i < count {
                for c in 0..<ch {
                    let v = src[i + c]
                    if v.isFinite && abs(v) > peaks[c] { peaks[c] = abs(v) }
                }
                i += ch
            }
            guard scansHeaders else { return }
            // The existing Atmos Sink converts raw Int16 words to exact float
            // integer values in its mirror. Match headers only, retain no payload.
            // history holds the previous three words: bits 32–47 oldest, 0–15 newest.
            i = 0
            while i < count {
                for c in 0..<min(2, ch) {
                    let v = src[i + c]
                    guard v.isFinite, v >= -32768, v <= 32767 else { history = 0; historyCount = 0; continue }
                    let word = UInt64(UInt16(bitPattern: Int16(v.rounded())))
                    if historyCount >= 3 {
                        let pa = (history >> 32) & 0xffff, pb = (history >> 16) & 0xffff, pc = history & 0xffff
                        if pa == 0xf872 && pb == 0x4e1f {
                            let type = pc & 0x1f
                            if word > 0 && type == 1 { ac3Bursts += 1 }
                            else if word > 0 && type == 21 { eac3Bursts += 1 }
                        }
                    } else {
                        historyCount += 1
                    }
                    history = ((history << 16) | word) & 0xffff_ffff_ffff
                }
                i += ch
            }
        }
        guard status == noErr, let proc else { emit(["event": "meterError", "device": name, "createStatus": status]); return }
        let start = AudioDeviceStart(device, proc)
        emit(["event": "meterStart", "device": name, "status": start])
    }
    func report() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var bursts: [String: Int] = [:]
        if ac3Bursts > 0 { bursts["AC3"] = ac3Bursts }
        if eac3Bursts > 0 { bursts["EAC3"] = eac3Bursts }
        let result: [String: Any] = ["name": name, "callbacks": callbacks, "frames": frames,
                                    "peakByChannel": peaks, "iec61937Headers": bursts]
        peaks = [Float](repeating: 0, count: 32)
        return result
    }
    func stop() { if let proc { AudioDeviceStop(device, proc); AudioDeviceDestroyIOProcID(device, proc) } }
}
// Meter the separate mirror, rather than attaching to Atmos Sink's output stream.
let meters = selected.filter { names[$0] != "Atmos Sink" && !(names[$0]!.hasPrefix("HDMI Lab") && !names[$0]!.hasSuffix("Mirror")) }.map { InputMeter($0, names[$0]!) }
meters.forEach { $0.start() }
let seconds = min(1800, max(1, Int(CommandLine.arguments.dropFirst().first ?? "600") ?? 600))
for _ in 0..<seconds {
    Thread.sleep(forTimeInterval: 1)
    emit(["event": "sample", "defaultOutput": defaultName(), "meters": meters.map { $0.report() },
          "outputs": selected.map { d -> [String: Any] in ["name": names[d]!, "streams": streams(d, kAudioObjectPropertyScopeOutput).map { streamState($0) }] }])
}
meters.forEach { $0.stop() }
emit(["event": "finished", "seconds": seconds])
