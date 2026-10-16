import Foundation

/// One mono sample as carried by the MIDI Sample Dump Standard (spec 20-transfer §2).
///
/// `samples` are signed values right-justified to `bits` (e.g. −32768…32767 for 16 bits), the
/// form C6's file readers produced before building packets (§2.4).
public struct SDSSample: Equatable, Sendable {
    /// Loop type byte values (header field `tt`).
    public static let loopForward: UInt8 = 0x00
    public static let loopAlternating: UInt8 = 0x01
    public static let loopOff: UInt8 = 0x7F

    /// Signed sample words, right-justified to `bits`.
    public var samples: [Int32]
    /// Significant bits per word (SDS allows 8…28; the encoder accepts 1…28).
    public var bits: Int
    /// Sample period in nanoseconds (standard header field, 21 bits).
    public var samplePeriodNs: Int
    /// Exact rate in Hz when known (from the audio file, or an extended header). The extended
    /// header sends this; without it the rate is derived from `samplePeriodNs`.
    public var sampleRateHz: Int?
    /// Loop start / end word index (end inclusive).
    public var loopStart: Int
    public var loopEnd: Int
    /// 0 forward, 1 alternating (backward/forward), 0x7F off.
    public var loopType: UInt8
    /// Base name without directory or extension (used for the 05 03 name and the SPS-1UW name).
    /// Received names are in display form (`Å Ä Ö`, see `SDSMessage.spsDisplayName`).
    public var name: String?
    /// SDS sample number (slot) on the device.
    public var sampleNumber: Int
    /// Channel count; only extended headers carry it. Words are interleaved when > 1.
    public var channels: Int
    /// Machinedrum (SPS-1UW) name to send with the sample, overriding the file-name rule.
    public var mdName: String?

    public init(samples: [Int32], bits: Int, samplePeriodNs: Int, sampleRateHz: Int? = nil,
                loopStart: Int = 0, loopEnd: Int? = nil, loopType: UInt8 = SDSSample.loopOff,
                name: String? = nil, sampleNumber: Int = 0, channels: Int = 1) {
        self.samples = samples
        self.bits = bits
        self.samplePeriodNs = samplePeriodNs
        self.sampleRateHz = sampleRateHz
        self.loopStart = loopStart
        // C6's WAV parser default without a `smpl` loop: start 0, end = length − 1, type 7F.
        self.loopEnd = loopEnd ?? max(0, samples.count - 1)
        self.loopType = loopType
        self.name = name
        self.sampleNumber = sampleNumber
        self.channels = channels
    }

    /// Builds a sample from a rate in Hz; the period is rounded as C6 did (`(1e9 + rate/2) / rate`).
    public init(samples: [Int32], bits: Int, sampleRate: Int,
                loopStart: Int = 0, loopEnd: Int? = nil, loopType: UInt8 = SDSSample.loopOff,
                name: String? = nil, sampleNumber: Int = 0) {
        self.init(samples: samples, bits: bits, samplePeriodNs: SDSSample.period(forRate: sampleRate),
                  sampleRateHz: sampleRate, loopStart: loopStart, loopEnd: loopEnd, loopType: loopType,
                  name: name, sampleNumber: sampleNumber)
    }

    /// Number of words (C6's "sample length in words"; frames for mono).
    public var length: Int { samples.count }

    /// `sampleRateHz`, or the rate derived from the period.
    public var sampleRate: Int { sampleRateHz ?? SDSSample.rate(forPeriod: samplePeriodNs) }

    /// C6's period rounding (WAV parser M 0xd820): `(1e9 + rate/2) / rate`.
    public static func period(forRate rate: Int) -> Int {
        rate > 0 ? (1_000_000_000 + rate / 2) / rate : 0
    }

    /// Rate from a period as C6's receivers computed it, including the 44099→44100 and
    /// 48001→48000 fix-ups (spec §5.3). Period 0 yields 0 (the original divided by zero).
    public static func rate(forPeriod period: Int) -> Int {
        guard period > 0 else { return 0 }
        let r = (1_000_000_000 + period / 2) / period
        if r == 44099 { return 44100 }
        if r == 48001 { return 48000 }
        return r
    }

    /// Applies the Loop button (File / On / Off) the way C6's header builder did (§2.2):
    /// On with no loop end loops the whole sample forward; On forces type 00, Off forces 7F,
    /// File keeps the file's type (masked to 7 bits).
    public func applyingLoopMode(_ mode: C6Item.LoopMode) -> SDSSample {
        var s = self
        if s.loopEnd == 0 && mode == .on {
            s.loopEnd = max(0, length - 1); s.loopStart = 0
        }
        switch mode {
        case .file: s.loopType &= 0x7F
        case .on: s.loopType = SDSSample.loopForward
        case .off: s.loopType = SDSSample.loopOff
        }
        return s
    }

    /// Mono words from decoded channels, per the Stereo button (§2.4): L+R → `(L + R) / 2`
    /// truncated toward zero, Left → channel 0, Right → channel 1; more than two channels → channel 0.
    public static func monoWords(from channels: [[Int32]], mode: C6Item.StereoMode) -> [Int32] {
        guard let first = channels.first else { return [] }
        guard channels.count == 2 else { return first }
        let l = channels[0], r = channels[1]
        switch mode {
        case .left: return l
        case .right: return r
        case .mix:
            let n = min(l.count, r.count)
            return (0..<n).map { Int32((Int64(l[$0]) + Int64(r[$0])) / 2) }
        }
    }
}

/// Word layout of SDS data packets for a bit depth (spec §2.1 table, §2.3 encoding).
///
/// Every packet carries 120 data bytes: ≤14 bits → 2 bytes × 60 words, ≤21 → 3 × 40, ≤28 → 4 × 30.
/// Each word is offset binary, left-justified in `7 × bytesPerWord` bits, sent MSB group first.
public struct SDSWordFormat: Equatable, Sendable {
    public static let dataBytesPerPacket = 120

    public let bits: Int
    public let bytesPerWord: Int
    public let samplesPerPacket: Int

    public init?(bits: Int) {
        guard (1...28).contains(bits) else { return nil }
        self.bits = bits
        bytesPerWord = bits <= 14 ? 2 : bits <= 21 ? 3 : 4
        samplesPerPacket = SDSWordFormat.dataBytesPerPacket / bytesPerWord
    }

    private var shift: Int { 7 * bytesPerWord - bits }
    private var offset: Int64 { Int64(1) << (bits - 1) }
    public var minValue: Int32 { Int32(-offset) }
    public var maxValue: Int32 { Int32(offset - 1) }

    /// Packets needed for `length` words.
    public func packetCount(forLength length: Int) -> Int {
        (length + samplesPerPacket - 1) / samplesPerPacket
    }

    /// Encodes up to `samplesPerPacket` words into the 120 packet data bytes. Missing words are
    /// zero (mid-scale), as C6 padded the last packet; values outside the range are clamped.
    public func encode<C: Collection>(_ values: C) -> [UInt8] where C.Element == Int32 {
        var out = [UInt8]()
        out.reserveCapacity(SDSWordFormat.dataBytesPerPacket)
        var it = values.makeIterator()
        for _ in 0..<samplesPerPacket {
            let v = Int64(min(max(it.next() ?? 0, minValue), maxValue))
            let u = (v + offset) << shift
            for k in stride(from: bytesPerWord - 1, through: 0, by: -1) {
                out.append(UInt8((u >> (7 * k)) & 0x7F))
            }
        }
        return out
    }

    /// Decodes the 120 data bytes of a packet into `samplesPerPacket` signed words.
    public func decode<C: Collection>(_ data: C) -> [Int32] where C.Element == UInt8 {
        var out = [Int32]()
        out.reserveCapacity(samplesPerPacket)
        var it = data.makeIterator()
        for _ in 0..<samplesPerPacket {
            var w: Int64 = 0
            for _ in 0..<bytesPerWord { w = (w << 7) | Int64((it.next() ?? 0) & 0x7F) }
            out.append(Int32((w >> shift) - offset))
        }
        return out
    }
}
