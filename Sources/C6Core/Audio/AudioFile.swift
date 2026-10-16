import Foundation

/// A WAV, AIFF or AIFC file as C6 1.51 parsed it (Mac WAV parser 0xd415, AIFF 0xe0ab,
/// AIFC 0xea1c, File Info 0xd860 / 0xe84f / 0xf345, DigiPRO reader 0xf582, SDS readers
/// 0xdb2f / 0xd24e / 0xddd3; spec `30-audio-digipro.md` §1–§6, `20-transfer.md` §2.4).
///
/// The container is detected by content magic only (`RIFF….WAVE`, `FORM….AIFF`,
/// `FORM….AIFC` at offset 0), never by extension. Supported encodings: WAV PCM (format 1, any
/// bit depth up to 32 in ⌈bits/8⌉ bytes, 8-bit unsigned) and IEEE float (format 3); AIFF
/// big-endian PCM; AIFC `NONE`, `sowt`, `fl32`, `fl64`.
///
/// Deviations from the original:
/// 1. **FIX — AIFC is readable for DigiPRO.** The original's DigiPRO reader has no AIFC branch
///    (container kind 3) and converts an uninitialised stack double (Mac) / NaN (Windows), although
///    the button is enabled. Here AIFC samples are read with the same decoders as the SDS path.
/// 2. **FIX — AIFC `sowt` has samples.** The original decodes `sowt` through the WAV reader
///    (0xda1a), which returns 0 unless the *WAV* format tag is 1 or 3 — silence (or stale-tag
///    garbage). Decoded here as little-endian two's-complement PCM (8-bit signed, as AIFC defines).
/// 3. **FIX — float64 WAV.** Format 3 with 64 bits is read as doubles (8 bytes per sample); the
///    original reads every float WAV as float32 (twice the frame count, noise). Sample length in
///    File Info is therefore the real frame count.
/// 4. **FIX — no uninitialised or NaN samples.** NaN float samples read as 0 (the original's
///    `maxss` turned them into −1.0); frames outside the sample data (a loop that runs past the
///    end, a negative index) read as 0 instead of whatever bytes follow; files with more than two
///    channels use channel 0 for DigiPRO too (the original left the value uninitialised).
/// 5. **FIX — marker indices.** AIFF marker ids outside 0…15 never index the 16-entry marker
///    table (the original writes/reads its stack array unchecked). An INST that follows a MARK and
///    names a marker that was not seen leaves that loop point unchanged.
/// 6. **FIX — no crashes or stale state on malformed files.** A missing `fmt `/`COMM` or
///    `data`/`SSND` chunk, or 0 channels, gives "Unknown Wave Format" / "Unknown AIFF\tFormat" /
///    "Unknown AIFC\tFormat"; PCM with 0 or more than 32 bits gives "… Not PCM or Float" (so
///    "AIFF: Not PCM or Float" is reachable). The original divided by zero (SIGFPE) or used the
///    previous file's globals. A `data`/`SSND` chunk that comes before the format chunk is sized
///    with the final format values. A sample rate ≤ 0 gives `samplePeriodNs` 0. Chunk sizes are
///    unsigned (no 32-bit pointer wrap-around), reads past the buffer return 0, an SSND smaller
///    than its 8-byte header has 0 frames, and a MARK count larger than the data stops at the end
///    of the buffer.
/// 7. **FIX — DigiPRO enabling.** `canConvertToDigiPRO` also requires 0 ≤ loopStart ≤ loopEnd
///    (at least one sample). The original enabled the button for an empty file or a reversed loop
///    and converted garbage.
/// 8. `samplePeriodNs` is always computed from the final sample rate. (C6's AIFF parser computed
///    it when SSND was seen; identical for every file whose COMM precedes SSND.)
/// 9. The stereo SDS mix `(L + R) / 2` is computed without 32-bit overflow (only reachable with
///    32-bit PCM).
/// 10. A file that fails to parse cannot be read at all. (The original's SDS sender ignored AIFF
///    and AIFC parse errors and sent from whatever the partial parse left.)
///
/// Kept on purpose (observable original behaviour): the exact File Info strings (including the
/// TAB in "Unknown AIFF\tFormat"); the `fmt ` rate wins over `smpl`'s dwSamplePeriod, and
/// period = (rate/2 + 10^9) / rate; inclusive loop ends (WAV `dwEnd`, AIFF end marker — so an
/// AIFF loop gets one sample more); "Bits: 24" for every float format; only the first `smpl`
/// loop, loop type = dwType & 0x7F; INST play mode 0 → 0x7F, 1 → 0, 2 (forward/backward) leaves
/// the previous type (0x7F); the AIFF chunk-order quirks (MARK is ignored unless an INST came
/// first; an SSND after INST+MARK resets the loop to the whole file but leaves Loop ON; the
/// marker-name pad byte is not skipped); `WAVE_FORMAT_EXTENSIBLE` and AIFC compression types
/// other than the four above ("twos", "in24", …) are rejected as "Not PCM or Float"; the 80-bit
/// rate parse (top 31 mantissa bits, truncated); the signed RIFF/FORM size capped to the buffer;
/// the DigiPRO amplitude scale 2 / 2^bits (float ×256, 32-bit PCM ×2; normalised away, it only
/// moves the 2^-16 silence threshold); DigiPRO stereo `(L + R) * 0.5` in Double, SDS stereo
/// `(L + R) / 2` truncated toward zero.
public struct AudioFile: Sendable {
    /// The parser globals C6 kept for the selected file (spec §2).
    public struct Info: Equatable, Sendable {
        public var container: AudioFormat
        public var channels: Int
        public var sampleRate: Int
        /// As C6 reports it: the PCM bit depth, or 24 for every float encoding.
        public var bits: Int
        /// Stored bytes per sample: ⌈bits/8⌉ for PCM, 4 / 8 for float32 / float64.
        public var bytesPerSample: Int
        /// (data bytes / bytesPerSample) / channels.
        public var numFrames: Int
        public var loopStart: Int
        /// Inclusive.
        public var loopEnd: Int
        /// A `smpl` loop or an AIFF marker was found.
        public var loopOn: Bool
        /// SDS semantics: 0 forward, 1 alternating, 0x7F off (WAV: dwType & 0x7F).
        public var loopType: Int
        /// (rate/2 + 10^9) / rate, from the format chunk's rate.
        public var samplePeriodNs: Int
    }

    enum Encoding: Sendable, Equatable {
        /// WAV format 1: little-endian signed, but 8-bit unsigned.
        case wavPCM
        /// AIFC `sowt`: little-endian signed.
        case littleEndianPCM
        /// AIFF, AIFC `NONE`.
        case bigEndianPCM
        case float32LE, float64LE, float32BE, float64BE

        var isFloat: Bool {
            switch self {
            case .float32LE, .float64LE, .float32BE, .float64BE: return true
            default: return false
            }
        }
    }

    /// The whole file.
    public let bytes: [UInt8]
    public let info: Info
    let encoding: Encoding
    /// Offset of the first sample frame.
    let dataOffset: Int

    /// Parses `bytes`. Throws `AudioFileError`, whose `description` is C6's File Info text.
    public init(bytes: [UInt8]) throws {
        let r = ByteReader(bytes)
        let parsed: Parsed
        if r.count >= 12 && r.fourCC(0) == "RIFF" && r.fourCC(8) == "WAVE" {
            parsed = try Self.parseWAV(r)
        } else if r.count >= 12 && r.fourCC(0) == "FORM" && r.fourCC(8) == "AIFF" {
            parsed = try Self.parseAIFF(r, aifc: false)
        } else if r.count >= 12 && r.fourCC(0) == "FORM" && r.fourCC(8) == "AIFC" {
            parsed = try Self.parseAIFF(r, aifc: true)
        } else {
            throw AudioFileError.notAudio
        }
        self.bytes = bytes
        info = parsed.info
        encoding = parsed.encoding
        dataOffset = parsed.dataOffset
    }

    public init(contentsOf url: URL) throws {
        try self.init(bytes: [UInt8](Data(contentsOf: url)))
    }

    /// C6's File Info text for a successfully parsed file (spec §5).
    public var infoText: String {
        let i = info
        let head = "Sample length: \(i.numFrames) Channels: \(i.channels) Sample Rate: \(i.sampleRate)\nBits: \(i.bits) Loop "
        guard i.loopOn else { return head + "OFF." }
        return head + (i.loopType == 0x7F ? "OFF" : "ON") + ". Loop start: \(i.loopStart) Loop end: \(i.loopEnd)"
    }

    /// File Info for any buffer: `infoText`, or the error text if it does not parse. Matches the
    /// `C6Item.audioDescriber` hook: `C6Item.audioDescriber = { _, b in AudioFile.describe(b) }`.
    public static func describe(_ bytes: [UInt8]) -> String {
        do { return try AudioFile(bytes: bytes).infoText } catch {
            return (error as? AudioFileError)?.description ?? "\(error)"
        }
    }

    /// Whether C6 enabled [DigiPRO]: loop (or whole file) of at most 16384 samples and at most two
    /// channels — plus deviation 7 (at least one sample, non-negative start).
    public var canConvertToDigiPRO: Bool {
        info.loopEnd - info.loopStart <= 0x3FFF && info.channels <= 2
            && info.loopStart >= 0 && info.loopEnd >= info.loopStart
    }

    /// Frame count the DigiPRO converter uses: loopEnd − loopStart + 1, at most 16384.
    public var digiPROSampleCount: Int {
        max(0, min(DigiPRO.maxSamples, info.loopEnd - info.loopStart + 1))
    }

    // MARK: - Sample readers

    /// One sample per frame for the SDS sender, as `bits`-wide signed integers
    /// (`raw >> (8 * bytesPerSample − bits)`; float → ×2^31, clamped, `>> 8` = 24-bit). Stereo:
    /// `.mix` → `(L + R) / 2` truncated toward zero, `.left`, `.right`; more than two channels →
    /// channel 0. `numFrames` values.
    public func sdsSamples(stereo: C6Item.StereoMode) -> [Int32] {
        let shift = Int32((info.bytesPerSample * 8 - info.bits) & 31)
        return (0..<info.numFrames).map { f in
            guard let base = frameOffset(f) else { return 0 }
            let bps = info.bytesPerSample
            if info.channels == 2 {
                let l = raw(at: base) >> shift, r = raw(at: base + bps) >> shift
                switch stereo {
                case .mix: return Int32((Int64(l) + Int64(r)) / 2)
                case .left: return l
                case .right: return r
                }
            }
            return raw(at: base) >> shift
        }
    }

    /// The doubles C6's [DigiPRO] button converts (Mac 0xf582): frames loopStart … loopStart + N − 1
    /// with N = `digiPROSampleCount`, each `2 / 2^bits × raw` (8/16/24-bit PCM in [−1, 1),
    /// float ±256, 32-bit PCM ×2 — the encoder normalises). Stereo: `.mix` → `(L + R) * 0.5`,
    /// `.left`, `.right`; more than two channels → channel 0.
    public func digiPROSamples(stereo: C6Item.StereoMode) -> [Double] {
        var scale = 1.0 / Double(UInt64(1) << UInt64(info.bits & 31))
        scale = scale + scale
        let bps = info.bytesPerSample
        return (0..<digiPROSampleCount).map { p in
            guard let base = frameOffset(info.loopStart + p) else { return 0 }
            if info.channels == 2 {
                let l = scale * Double(raw(at: base)), r = scale * Double(raw(at: base + bps))
                switch stereo {
                case .mix: return (l + r) * 0.5
                case .left: return l
                case .right: return r
                }
            }
            return scale * Double(raw(at: base))
        }
    }

    /// Byte offset of frame `f`, or nil outside the sample data.
    func frameOffset(_ f: Int) -> Int? {
        guard f >= 0, f < info.numFrames else { return nil }
        return dataOffset + f * info.channels * info.bytesPerSample
    }

    /// The stored sample at `offset` as C6's 32-bit `raw` value, before the SDS shift or the
    /// DigiPRO scale (WAV 0xda1a, AIFF 0xd39a / 0xd24e, AIFC 0xdc3a).
    func raw(at offset: Int) -> Int32 {
        let n = info.bytesPerSample
        guard offset >= 0, offset + n <= bytes.count else { return 0 }
        switch encoding {
        case .wavPCM:
            return n == 1 ? Int32(bytes[offset]) - 128 : integer(at: offset, count: n, bigEndian: false)
        case .littleEndianPCM:
            return integer(at: offset, count: n, bigEndian: false)
        case .bigEndianPCM:
            return integer(at: offset, count: n, bigEndian: true)
        case .float32LE, .float32BE:
            let bits = UInt32(bitPattern: integer(at: offset, count: 4, bigEndian: encoding == .float32BE))
            return Self.floatRaw(Double(Float(bitPattern: bits)))
        case .float64LE, .float64BE:
            var bits: UInt64 = 0
            for k in 0..<8 {
                let byte = UInt64(bytes[offset + (encoding == .float64BE ? k : 7 - k)])
                bits = bits << 8 | byte
            }
            return Self.floatRaw(Double(bitPattern: bits))
        }
    }

    /// Signed integer of `count` (1…4) bytes, sign-extended from its top byte.
    private func integer(at offset: Int, count: Int, bigEndian: Bool) -> Int32 {
        var v: UInt32 = 0
        for k in 0..<count {
            v = v << 8 | UInt32(bytes[offset + (bigEndian ? k : count - 1 - k)])
        }
        let unused = UInt32(32 - 8 * count)
        return Int32(bitPattern: v << unused) >> unused
    }

    /// Float → 2^31-scaled integer: max(x, −1), values above 0.9999998807 → 1 − 2^−23, × 2^31,
    /// truncated (0xda1a). NaN → 0 (deviation 4).
    static func floatRaw(_ x: Double) -> Int32 {
        if x.isNaN { return 0 }
        var d = x > -1.0 ? x : -1.0
        if d > 0.9999998807 { d = 0.99999988079071044921875 }
        return Int32(d * 2147483648.0)
    }

    // MARK: - Parsers

    struct Parsed {
        var info: Info
        var encoding: Encoding
        var dataOffset: Int
    }

    /// The parser globals while walking the chunks.
    private struct State {
        let container: AudioFormat
        var formatSeen = false
        var channels = 0
        var rate = 44100
        var bits = 0
        var bytesPerSample = 0
        var encoding: Encoding
        var dataOffset: Int?
        var numFrames: Int?
        var pendingDataBytes = 0
        /// C6's "samplePeriod != 0": loop points have been set (by `smpl` or the data chunk).
        var loopSet = false
        var loopStart = 0
        /// nil = the last frame (resolved once the frame count is known).
        var loopEnd: Int?
        var loopOn = false
        var loopType = 0x7F

        init(container: AudioFormat, encoding: Encoding) {
            self.container = container
            self.encoding = encoding
        }

        mutating func dataChunk(offset: Int, bytes: Int, resetLoopType: Bool) {
            dataOffset = offset
            if formatSeen && channels > 0 && bytesPerSample > 0 {
                numFrames = (bytes / bytesPerSample) / channels
            } else {
                numFrames = nil
                pendingDataBytes = bytes
            }
            if !loopSet {
                loopSet = true
                loopStart = 0
                loopEnd = numFrames.map { $0 - 1 }
                if resetLoopType { loopType = 0x7F }
            }
        }

        func finish() throws -> Parsed {
            guard formatSeen, let dataOffset, channels > 0 else { throw AudioFileError.unknownFormat(container) }
            if !encoding.isFloat {
                guard (1...32).contains(bits) else { throw AudioFileError.notPCMOrFloat(container) }
            }
            let frames = numFrames ?? (pendingDataBytes / bytesPerSample) / channels
            let period = rate > 0 ? (rate / 2 + 1_000_000_000) / rate : 0
            let info = Info(container: container, channels: channels, sampleRate: rate, bits: bits,
                            bytesPerSample: bytesPerSample, numFrames: frames,
                            loopStart: loopStart, loopEnd: loopEnd ?? frames - 1,
                            loopOn: loopOn, loopType: loopType, samplePeriodNs: period)
            return Parsed(info: info, encoding: encoding, dataOffset: dataOffset)
        }
    }

    /// Mac 0xd415.
    private static func parseWAV(_ r: ByteReader) throws -> Parsed {
        let riffSize = min(Int(Int32(bitPattern: r.le32(4))), r.count - 8)
        let end = 8 + riffSize
        var st = State(container: .wav, encoding: .wavPCM)
        var p = 12
        while true {
            let id = r.fourCC(p), size = Int(r.le32(p + 4)), d = p + 8, next = d + size
            if next > end { throw AudioFileError.chunkSizeError(.wav) }
            switch id {
            case "fmt ":
                let tag = r.le16(d)
                guard tag == 1 || tag == 3 else { throw AudioFileError.notPCMOrFloat(.wav) } // 0xFFFE too
                st.formatSeen = true
                st.channels = r.le16(d + 2)
                st.rate = Int(Int32(bitPattern: r.le32(d + 4)))
                st.bits = r.le16(d + 14)
                if tag == 1 {
                    st.bytesPerSample = ((st.bits - 1) >> 3) + 1
                    st.encoding = .wavPCM
                } else {
                    let wide = st.bits == 64 // deviation 3
                    st.bytesPerSample = wide ? 8 : 4
                    st.encoding = wide ? .float64LE : .float32LE
                    st.bits = 24
                }
            case "data":
                st.dataChunk(offset: d, bytes: size, resetLoopType: true)
            case "smpl":
                if Int32(bitPattern: r.le32(d + 8)) > 0 { st.loopSet = true } // dwSamplePeriod
                if r.le32(d + 28) != 0 { // cSampleLoops: first loop only
                    st.loopType = Int(r[d + 40] & 0x7F)
                    st.loopStart = Int(Int32(bitPattern: r.le32(d + 44)))
                    st.loopEnd = Int(Int32(bitPattern: r.le32(d + 48)))
                    st.loopOn = true
                }
            default:
                break
            }
            var n = next
            if size & 1 == 1 { n += 1 }
            if !(riffSize > n - 8) { break }
            p = n
        }
        return try st.finish()
    }

    /// Mac 0xe0ab (AIFF) and 0xea1c (AIFC).
    private static func parseAIFF(_ r: ByteReader, aifc: Bool) throws -> Parsed {
        let container: AudioFormat = aifc ? .aifc : .aiff
        let formSize = min(Int(Int32(bitPattern: r.be32(4))), r.count - 8)
        let end = 8 + formSize
        var st = State(container: container, encoding: .bigEndianPCM)
        var instBegin = -1, instEnd = 0, markersSeen = false
        var markerPos = [Int?](repeating: nil, count: 16)
        var p = 12
        while true {
            let id = r.fourCC(p), size = Int(r.be32(p + 4)), d = p + 8, next = d + size
            if next > end { throw AudioFileError.chunkSizeError(container) }
            switch id {
            case "COMM":
                st.formatSeen = true
                st.channels = r.be16(d) // numSampleFrames (d+2) is ignored
                st.bits = r.be16(d + 6)
                st.bytesPerSample = ((st.bits - 1) >> 3) + 1
                st.rate = extended80(r, at: d + 8)
                if aifc {
                    switch r.fourCC(d + 18) {
                    case "NONE": st.encoding = .bigEndianPCM
                    case "sowt": st.encoding = .littleEndianPCM
                    case "fl32": st.encoding = .float32BE; st.bytesPerSample = 4; st.bits = 24
                    case "fl64": st.encoding = .float64BE; st.bytesPerSample = 8; st.bits = 24
                    default: throw AudioFileError.notPCMOrFloat(.aifc)
                    }
                }
            case "SSND": // offset / blockSize fields ignored
                st.dataChunk(offset: d + 8, bytes: max(0, size - 8), resetLoopType: false)
            case "INST":
                let mode = r.be16(d + 8) // sustainLoop.playMode
                if mode == 0 { st.loopType = 0x7F } else if mode == 1 { st.loopType = 0 }
                instBegin = r.be16(d + 10)
                instEnd = r.be16(d + 12)
                if markersSeen {
                    if instBegin < 16, let v = markerPos[instBegin] { st.loopStart = v }
                    if instEnd < 16, let v = markerPos[instEnd] { st.loopEnd = v }
                }
            case "MARK" where instBegin >= 0: // ignored unless an INST came first
                var q = d + 2
                for _ in 0..<r.be16(d) {
                    guard q + 7 <= r.count else { break }
                    let mid = r.be16(q), pos = Int(Int32(bitPattern: r.be32(q + 2)))
                    q += 7 + Int(r[q + 6]) // pstring pad byte not skipped (kept)
                    if mid <= 15 { markerPos[mid] = pos }
                    if mid == instBegin { st.loopStart = pos }
                    if mid == instEnd { st.loopEnd = pos }
                    markersSeen = true
                    st.loopOn = true
                }
            default:
                break
            }
            var n = next
            if size & 1 == 1 { n += 1 }
            if !(formSize > n - 8) { break }
            p = n
        }
        return try st.finish()
    }

    /// The original's 80-bit extended → int conversion (top 31 mantissa bits, truncated).
    static func extended80(_ r: ByteReader, at o: Int) -> Int {
        let e0 = Int(r[o])
        let ex = (e0 & 0x7F) << 8 | Int(r[o + 1])
        let mant = Int32(r[o + 2]) << 23 | Int32(r[o + 3]) << 15 | Int32(r[o + 4]) << 7 | Int32(r[o + 5]) >> 1
        var v: Double
        if ex | Int(mant) == 0 {
            v = 0
        } else if ex == 0x7FFF {
            v = 1e88
        } else {
            v = Double(mant >> Int32((0x401D - ex) & 31))
        }
        if e0 & 0x80 != 0 { v = -v }
        return Int(DigiPRO.truncateToInt32(v))
    }
}

/// Audio parse failures; `description` is C6's File Info text.
public enum AudioFileError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Not `RIFF….WAVE`, `FORM….AIFF` or `FORM….AIFC`.
    case notAudio
    /// Parser result 0 / −1, or a missing format/data chunk (deviation 6).
    case unknownFormat(AudioFormat)
    /// −2: a chunk runs past the RIFF/FORM size.
    case chunkSizeError(AudioFormat)
    /// −3: unsupported WAV format tag or AIFC compression type (or a PCM bit depth outside 1…32).
    case notPCMOrFloat(AudioFormat)

    public var description: String {
        switch self {
        case .notAudio, .unknownFormat(.wav): return "Unknown Wave Format"
        case .unknownFormat(.aiff): return "Unknown AIFF\tFormat"
        case .unknownFormat(.aifc): return "Unknown AIFC\tFormat"
        case let .chunkSizeError(f): return "\(Self.prefix(f)): Chunk size error"
        case let .notPCMOrFloat(f): return "\(Self.prefix(f)): Not PCM or Float"
        }
    }

    private static func prefix(_ f: AudioFormat) -> String {
        switch f {
        case .wav: return "Wave"
        case .aiff: return "AIFF"
        case .aifc: return "AIFC"
        }
    }
}

/// Bounds-safe byte access: reads past the end return 0.
struct ByteReader {
    let bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var count: Int { bytes.count }
    subscript(i: Int) -> UInt8 { i >= 0 && i < bytes.count ? bytes[i] : 0 }
    func le16(_ o: Int) -> Int { Int(self[o]) | Int(self[o + 1]) << 8 }
    func be16(_ o: Int) -> Int { Int(self[o]) << 8 | Int(self[o + 1]) }
    func le32(_ o: Int) -> UInt32 {
        UInt32(self[o]) | UInt32(self[o + 1]) << 8 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24
    }
    func be32(_ o: Int) -> UInt32 {
        UInt32(self[o]) << 24 | UInt32(self[o + 1]) << 16 | UInt32(self[o + 2]) << 8 | UInt32(self[o + 3])
    }
    func fourCC(_ o: Int) -> String {
        String(decoding: (0..<4).map { self[o + $0] }, as: UTF8.self)
    }
}
