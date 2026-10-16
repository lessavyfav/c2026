import Foundation

/// Sample-memory arithmetic for a Machinedrum UW (and similar devices).
///
/// Model (checked against a real MD UW MKII on 2026-10-16): every sample takes 2 bytes per frame
/// whatever its bit depth — the scanned slots added up to 1,275,662 frames ≈ 2.55 MB on a nearly
/// full 2.5 MB unit, and Elektron note that 12-bit files take as much space as 16-bit. Sample
/// rate counts (a 22 kHz sample takes half the space of the same sound at 44.1 kHz). The memory is
/// shared with the RAM machines' buffers, so the device's own sample manager is the final word.
public struct SampleMemory: Equatable, Sendable {
    public var totalBytes: Int
    public var bytesPerFrame: Int = 2

    public init(totalBytes: Int, bytesPerFrame: Int = 2) {
        self.totalBytes = totalBytes; self.bytesPerFrame = bytesPerFrame
    }

    /// MD UW MKII / UW+ : 2.5 MB. MKI UW: 2 MB.
    public static let machinedrumUWMK2 = SampleMemory(totalBytes: 2_560 * 1024)
    public static let machinedrumUWMK1 = SampleMemory(totalBytes: 2_048 * 1024)

    public func bytes(frames: Int) -> Int { frames * bytesPerFrame }

    /// Memory used by the scanned slots.
    public func used(by slots: [SlotInfo]) -> Int { slots.reduce(0) { $0 + bytes(frames: $1.length) } }

    /// Result of loading `newFrames` (one entry per sample, in order) into `targetSlots`,
    /// replacing whatever those slots hold now.
    public struct Projection: Equatable, Sendable {
        public var usedNow: Int
        public var incoming: Int
        public var freed: Int
        public var total: Int
        public var usedAfter: Int { usedNow - freed + incoming }
        public var freeAfter: Int { total - usedAfter }
        public var fits: Bool { usedAfter <= total }
    }

    public func project(newFrames: [Int], into targetSlots: [Int?], current: [SlotInfo]) -> Projection {
        let bySlot = Dictionary(current.map { ($0.slot, $0) }, uniquingKeysWith: { a, _ in a })
        var incoming = 0, freed = 0
        var replaced = Set<Int>()
        for (frames, slot) in zip(newFrames, targetSlots) {
            guard let slot else { continue }   // not sent (past the last slot)
            incoming += bytes(frames: frames)
            if let old = bySlot[slot], replaced.insert(slot).inserted { freed += bytes(frames: old.length) }
        }
        return Projection(usedNow: used(by: current), incoming: incoming, freed: freed, total: totalBytes)
    }
}

extension C6Item {
    /// Frames and rate of an item as a sample (stereo files go mono).
    static func computeSampleFrames(type: RecognizedType, bytes: [UInt8]) -> (Int?, Int?) {
        switch type {
        case .wav, .aiff, .aifc:
            guard let a = try? AudioFile(bytes: bytes) else { return (nil, nil) }
            return (a.info.numFrames, a.info.sampleRate)
        case .sds:
            for m in SysExData(bytes: bytes).messages {
                if case let .dumpHeader(h)? = SDSMessage.decode(m) { return (h.length, SDSSample.rate(forPeriod: h.samplePeriodNs)) }
            }
            return (nil, nil)
        default: return (nil, nil)
        }
    }
}

public extension C6Item {
    /// Whether the 22 kHz option applies (the file's rate is above 22.05 kHz).
    var canHalveRate: Bool { isAudio && (sampleRate ?? 0) > Resampler.halfRate }
    /// The rate the sample will be sent at.
    var sendRate: Int? { canHalveRate && halfRate ? Resampler.halfRate : sampleRate }
    /// Whether the 2× option applies.
    var canDoubleSpeed: Bool { isAudio && (sampleFrames ?? 0) > 1 }

    /// Frames the sample takes on the device as it will be sent (after 22 kHz and/or 2×).
    var sendFrames: Int? {
        guard var f = sampleFrames else { return nil }
        if let r = sampleRate, let s = sendRate, s < r { f = Int((Double(f) * Double(s) / Double(r)).rounded(.up)) }
        if canDoubleSpeed && doubleSpeed { f = (f + 1) / 2 }
        return f
    }

    /// The SDS sample this item sends: mono per its Stereo button, loop per Loop, at `sendRate`,
    /// at double speed when `doubleSpeed`, and at most `maxBits` deep (the Machinedrum stores
    /// 16-bit, so deeper data only slows the transfer).
    func sdsSampleToSend(name: String?, maxBits: Int? = 16) -> SDSSample? {
        guard isAudio, let audio = try? AudioFile(bytes: bytes) else { return nil }
        var s = SDSSample(audio: audio, stereo: stereoMode, loop: loopMode, name: name)
        if let maxBits, s.bits > maxBits {
            let shift = Int32(s.bits - maxBits)
            s.samples = s.samples.map { $0 >> shift }
            s.bits = maxBits
        }
        if let rate = sendRate, rate < s.sampleRate { s = s.resampled(to: rate) }
        if canDoubleSpeed && doubleSpeed {
            // Same data as halving the rate, but the header keeps the rate: plays 2× fast/high.
            let rate = s.sampleRate
            s = s.resampled(to: rate / 2)
            s.sampleRateHz = rate
            s.samplePeriodNs = SDSSample.period(forRate: rate)
        }
        return s
    }

    /// What the play button plays: for samples, the device's view of it — mono, at the send rate,
    /// 12-bit when `asMachinedrum`, and for 2× samples played back an octave down (as with the
    /// device's pitch at −12) using `interpolation`; for sample dumps, their first sample.
    func previewAudio(asMachinedrum: Bool, interpolation: MachinedrumPreview.Interpolation = .hold) -> [UInt8]? {
        if isAudio {
            let double = canDoubleSpeed && doubleSpeed
            guard asMachinedrum || (canHalveRate && halfRate) || double else { return bytes }
            guard let s = sdsSampleToSend(name: nil) else { return nil }
            return MachinedrumPreview.wav(for: s, emulateDevice: asMachinedrum, octaveDown: double, interpolation: interpolation)
        }
        guard asMachinedrum, type == .sds else { return playableAudio }
        guard let wav = playableAudio, let a = try? AudioFile(bytes: wav) else { return nil }
        return MachinedrumPreview.wav(for: SDSSample(audio: a, stereo: .mix, loop: .file, name: nil), interpolation: interpolation)
    }
}

public enum ByteFormat {
    /// "412 kB", "1.25 MB" (1 kB = 1024 bytes, as Elektron quote memory).
    public static func memory(_ n: Int) -> String {
        let a = abs(n)
        if a < 1024 * 1024 { return "\(n < 0 ? "-" : "")\((a + 512) / 1024) kB" }
        return String(format: "%@%.2f MB", n < 0 ? "-" : "", Double(a) / 1024 / 1024)
    }
}
