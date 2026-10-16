import Foundation

// MIDI Sample Dump Standard messages as C6 1.51 built them (spec 20-transfer §2–4).
//
// Deviations from C6 (all on the encoding side; decoding accepts what C6 sent):
// 1. Extended name bytes (05 03) are 7-bit: non-ASCII characters are folded (é → e) or sent as
//    `?`, and the length byte is the real count (≤ 127). C6 copied MacRoman/ANSI bytes unmasked
//    and sent `strlen & 0x7F` as the length (quirk Q5).
// 2. The SPS-1UW slot byte is masked to 7 bits; C6 sent the sample number's low byte unmasked.
// 3. Non-ASCII characters in SPS-1UW names other than Å/Ä/Ö are folded (é → E) or become `?`;
//    C6 masked the MacRoman byte with 0x7F, which produced control characters.
// 4. Standard-header fields are clamped to 21 bits instead of wrapping (the sender refuses
//    samples longer than 2^21 − 1 words unless Extended SDS is on).

/// Byte order of the 14-bit sample number in the extended messages (05 05 header, 05 03 name).
///
/// C6 sent the high 7-bit group first (quirk Q4), unlike the CA-019 document and its own standard
/// header. Kept as the default for compatibility (Analog Rytm) until hardware says otherwise.
public enum SDSSampleNumberOrder: Sendable, Equatable {
    case msbFirst
    case lsbFirst
    /// What C6 sent.
    public static let c6: SDSSampleNumberOrder = .msbFirst

    func encode(_ n: Int) -> [UInt8] {
        let lo = UInt8(n & 0x7F), hi = UInt8((n >> 7) & 0x7F)
        return self == .msbFirst ? [hi, lo] : [lo, hi]
    }

    func decode(_ a: UInt8, _ b: UInt8) -> Int {
        self == .msbFirst ? Int(a & 0x7F) << 7 | Int(b & 0x7F) : Int(b & 0x7F) << 7 | Int(a & 0x7F)
    }
}

/// `F0 7E dd 01 sl sh ee p0 p1 p2 l0 l1 l2 s0 s1 s2 e0 e1 e2 tt F7` (21 bytes, §2.2).
public struct SDSDumpHeader: Equatable, Sendable {
    public var device: UInt8
    public var sampleNumber: Int
    public var bits: Int
    public var samplePeriodNs: Int
    public var length: Int
    public var loopStart: Int
    public var loopEnd: Int
    public var loopType: UInt8

    public init(device: UInt8, sampleNumber: Int, bits: Int, samplePeriodNs: Int, length: Int,
                loopStart: Int, loopEnd: Int, loopType: UInt8) {
        self.device = device; self.sampleNumber = sampleNumber; self.bits = bits
        self.samplePeriodNs = samplePeriodNs; self.length = length
        self.loopStart = loopStart; self.loopEnd = loopEnd; self.loopType = loopType
    }

    public init(sample: SDSSample, device: UInt8, sampleNumber: Int? = nil) {
        self.init(device: device, sampleNumber: sampleNumber ?? sample.sampleNumber, bits: sample.bits,
                  samplePeriodNs: sample.samplePeriodNs, length: sample.length,
                  loopStart: sample.loopStart, loopEnd: sample.loopEnd, loopType: sample.loopType)
    }
}

/// CA-019 Extended Dump Header as C6 built it (34 bytes, §3.1):
/// `F0 7E dd 05 05 <sn:2> ee <rate Hz:4> <fraction:4> <length:5> <loop start:5> <loop end:5> tt ch F7`.
public struct SDSExtendedDumpHeader: Equatable, Sendable {
    public var device: UInt8
    public var sampleNumber: Int
    public var bits: Int
    /// Integer part of the rate in Hz (28 bits).
    public var sampleRate: Int
    /// Fractional part of the rate in units of 2^-28 Hz (C6 always sent 0).
    public var rateFraction: Int
    public var length: Int
    public var loopStart: Int
    public var loopEnd: Int
    public var loopType: UInt8
    public var channels: Int

    public init(device: UInt8, sampleNumber: Int, bits: Int, sampleRate: Int, rateFraction: Int = 0,
                length: Int, loopStart: Int, loopEnd: Int, loopType: UInt8, channels: Int = 1) {
        self.device = device; self.sampleNumber = sampleNumber; self.bits = bits
        self.sampleRate = sampleRate; self.rateFraction = rateFraction; self.length = length
        self.loopStart = loopStart; self.loopEnd = loopEnd; self.loopType = loopType; self.channels = channels
    }

    public init(sample: SDSSample, device: UInt8, sampleNumber: Int? = nil) {
        self.init(device: device, sampleNumber: sampleNumber ?? sample.sampleNumber, bits: sample.bits,
                  sampleRate: sample.sampleRate, length: sample.length, loopStart: sample.loopStart,
                  loopEnd: sample.loopEnd, loopType: sample.loopType, channels: max(1, sample.channels))
    }

    /// Rate in Hz including the fraction.
    public var exactSampleRate: Double { Double(sampleRate) + Double(rateFraction) / Double(1 << 28) }
}

/// `F0 7E dd 02 kk <120 data bytes> cs F7` (127 bytes, §2.3).
public struct SDSDataPacket: Equatable, Sendable {
    public static let byteCount = 127

    public var device: UInt8
    /// Packet number, 0…127 (wraps).
    public var number: UInt8
    /// The 120 data bytes.
    public var data: [UInt8]
    /// Checksum as transmitted (or computed, for packets built here).
    public var checksum: UInt8

    public init(device: UInt8, number: UInt8, data: [UInt8], checksum: UInt8) {
        self.device = device; self.number = number; self.data = data; self.checksum = checksum
    }

    /// Builds a packet and computes its checksum.
    public init(device: UInt8, number: UInt8, data: [UInt8]) {
        self.init(device: device, number: number, data: data,
                  checksum: SDSDataPacket.checksum(device: device, number: number, data: data))
    }

    /// Packet `index` (0-based) of `sample`; the packet number is `index mod 128`.
    public init(sample: SDSSample, index: Int, device: UInt8, format: SDSWordFormat) {
        let lo = min(sample.samples.count, index * format.samplesPerPacket)
        let hi = min(sample.samples.count, lo + format.samplesPerPacket)
        self.init(device: device, number: UInt8(index & 0x7F), data: format.encode(sample.samples[lo..<hi]))
    }

    /// XOR of `7E dd 02 kk` and the data bytes, masked to 7 bits (C6 M 0xb6f0).
    public static func checksum(device: UInt8, number: UInt8, data: [UInt8]) -> UInt8 {
        var cs: UInt8 = 0x7E ^ (device & 0x7F) ^ 0x02 ^ (number & 0x7F)
        for b in data { cs ^= b }
        return cs & 0x7F
    }

    public var isChecksumValid: Bool {
        data.count == SDSWordFormat.dataBytesPerPacket
            && checksum == SDSDataPacket.checksum(device: device, number: number, data: data)
    }
}

/// CA-019 Sample Name Transmission: `F0 7E dd 05 03 <sn:2> tl <tag…> nn <name…> F7` (§3.2).
public struct SDSSampleName: Equatable, Sendable {
    public var device: UInt8
    public var sampleNumber: Int
    public var languageTag: [UInt8]
    public var name: String

    public init(device: UInt8, sampleNumber: Int, name: String, languageTag: [UInt8] = []) {
        self.device = device; self.sampleNumber = sampleNumber; self.name = name; self.languageTag = languageTag
    }
}

/// A MIDI Sample Dump Standard message (universal non-real-time, `F0 7E …`).
public enum SDSMessage: Equatable, Sendable {
    case dumpHeader(SDSDumpHeader)                        // 01
    case dataPacket(SDSDataPacket)                        // 02
    case dumpRequest(device: UInt8, sampleNumber: Int)    // 03
    case extendedDumpHeader(SDSExtendedDumpHeader)        // 05 05
    case sampleName(SDSSampleName)                        // 05 03
    case eof(device: UInt8, packet: UInt8)                // 7B
    case wait(device: UInt8, packet: UInt8)               // 7C
    case cancel(device: UInt8, packet: UInt8)             // 7D
    case nak(device: UInt8, packet: UInt8)                // 7E
    case ack(device: UInt8, packet: UInt8)                // 7F

    public enum SubID {
        public static let dumpHeader: UInt8 = 0x01
        public static let dataPacket: UInt8 = 0x02
        public static let dumpRequest: UInt8 = 0x03
        public static let extensions: UInt8 = 0x05
        public static let eof: UInt8 = 0x7B
        public static let wait: UInt8 = 0x7C
        public static let cancel: UInt8 = 0x7D
        public static let nak: UInt8 = 0x7E
        public static let ack: UInt8 = 0x7F
    }

    /// The message bytes. `order` applies to the extended messages only; the standard header and
    /// dump request always carry the sample number LSB first.
    public func bytes(order: SDSSampleNumberOrder = .c6) -> [UInt8] {
        switch self {
        case let .dumpHeader(h):
            return [0xF0, 0x7E, h.device & 0x7F, SubID.dumpHeader]
                + SDSMessage.lsb7(h.sampleNumber, 2) + [UInt8(h.bits & 0x7F)]
                + SDSMessage.lsb7(h.samplePeriodNs, 3) + SDSMessage.lsb7(h.length, 3)
                + SDSMessage.lsb7(h.loopStart, 3) + SDSMessage.lsb7(h.loopEnd, 3)
                + [h.loopType & 0x7F, 0xF7]
        case let .dataPacket(p):
            var out = [0xF0, 0x7E, p.device & 0x7F, SubID.dataPacket, p.number & 0x7F]
            out.reserveCapacity(SDSDataPacket.byteCount)
            out += p.data.prefix(SDSWordFormat.dataBytesPerPacket).map { $0 & 0x7F }
            if p.data.count < SDSWordFormat.dataBytesPerPacket {
                out += [UInt8](repeating: 0, count: SDSWordFormat.dataBytesPerPacket - p.data.count)
            }
            return out + [p.checksum & 0x7F, 0xF7]
        case let .dumpRequest(device, sn):
            return [0xF0, 0x7E, device & 0x7F, SubID.dumpRequest] + SDSMessage.lsb7(sn, 2) + [0xF7]
        case let .extendedDumpHeader(h):
            return [0xF0, 0x7E, h.device & 0x7F, SubID.extensions, 0x05]
                + order.encode(h.sampleNumber) + [UInt8(h.bits & 0x7F)]
                + SDSMessage.lsb7(h.sampleRate, 4) + SDSMessage.lsb7(h.rateFraction, 4)
                + SDSMessage.lsb7(h.length, 5) + SDSMessage.lsb7(h.loopStart, 5)
                + SDSMessage.lsb7(h.loopEnd, 5)
                + [h.loopType & 0x7F, UInt8(h.channels & 0x7F), 0xF7]
        case let .sampleName(n):
            let name = SDSMessage.asciiBytes(n.name, maxLength: 127)
            let tag = n.languageTag.prefix(127).map { $0 & 0x7F }
            return [0xF0, 0x7E, n.device & 0x7F, SubID.extensions, 0x03] + order.encode(n.sampleNumber)
                + [UInt8(tag.count)] + tag + [UInt8(name.count)] + name + [0xF7]
        case let .eof(d, p): return SDSMessage.handshake(SubID.eof, d, p)
        case let .wait(d, p): return SDSMessage.handshake(SubID.wait, d, p)
        case let .cancel(d, p): return SDSMessage.handshake(SubID.cancel, d, p)
        case let .nak(d, p): return SDSMessage.handshake(SubID.nak, d, p)
        case let .ack(d, p): return SDSMessage.handshake(SubID.ack, d, p)
        }
    }

    /// Parses a complete `F0 7E … F7` message. Returns nil for anything else, including data
    /// packets that are not exactly 127 bytes (see `isDataPacket`).
    public static func decode(_ m: [UInt8], order: SDSSampleNumberOrder = .c6) -> SDSMessage? {
        guard m.count >= 5, m[0] == 0xF0, m[1] == 0x7E, m.last == 0xF7 else { return nil }
        let dev = m[2]
        let packet = m.count >= 6 ? m[4] : 0
        switch m[3] {
        case SubID.dumpHeader:
            guard m.count >= 21 else { return nil }
            return .dumpHeader(SDSDumpHeader(
                device: dev, sampleNumber: le7(m, 4, 2), bits: Int(m[6]), samplePeriodNs: le7(m, 7, 3),
                length: le7(m, 10, 3), loopStart: le7(m, 13, 3), loopEnd: le7(m, 16, 3), loopType: m[19]))
        case SubID.dataPacket:
            guard m.count == SDSDataPacket.byteCount else { return nil }
            return .dataPacket(SDSDataPacket(device: dev, number: m[4], data: Array(m[5..<125]), checksum: m[125]))
        case SubID.dumpRequest:
            guard m.count >= 7 else { return nil }
            return .dumpRequest(device: dev, sampleNumber: le7(m, 4, 2))
        case SubID.extensions:
            switch m[4] {
            case 0x05:
                guard m.count >= 34 else { return nil }
                return .extendedDumpHeader(SDSExtendedDumpHeader(
                    device: dev, sampleNumber: order.decode(m[5], m[6]), bits: Int(m[7]),
                    sampleRate: le7(m, 8, 4), rateFraction: le7(m, 12, 4), length: le7(m, 16, 5),
                    loopStart: le7(m, 21, 5), loopEnd: le7(m, 26, 5), loopType: m[31], channels: Int(m[32])))
            case 0x03:
                guard m.count >= 10 else { return nil }
                let tagLength = Int(m[7])
                let nnIndex = 8 + tagLength
                guard nnIndex < m.count - 1 else { return nil }
                let tag = Array(m[8..<nnIndex])
                let start = nnIndex + 1
                let end = min(m.count - 1, start + Int(m[nnIndex]))
                let name = start < end ? String(decoding: m[start..<end].map { $0 & 0x7F }, as: UTF8.self) : ""
                return .sampleName(SDSSampleName(device: dev, sampleNumber: order.decode(m[5], m[6]),
                                                 name: name, languageTag: tag))
            default:
                return nil
            }
        case SubID.eof: return .eof(device: dev, packet: packet)
        case SubID.wait: return .wait(device: dev, packet: packet)
        case SubID.cancel: return .cancel(device: dev, packet: packet)
        case SubID.nak: return .nak(device: dev, packet: packet)
        case SubID.ack: return .ack(device: dev, packet: packet)
        default: return nil
        }
    }

    /// True for anything that claims to be a data packet (`F0 7E dd 02 …`), well-formed or not.
    public static func isDataPacket(_ m: [UInt8]) -> Bool {
        m.count >= 5 && m[0] == 0xF0 && m[1] == 0x7E && m[3] == SubID.dataPacket
    }

    // MARK: - Machinedrum SPS-1UW name (§4)

    /// `F0 00 20 3C 02 00 73` — Machinedrum message 0x73 (sample name).
    public static let spsNamePrefix: [UInt8] = [0xF0, 0x00, 0x20, 0x3C, 0x02, 0x00, 0x73]

    /// `F0 00 20 3C 02 00 73 <slot> <c0 c1 c2 c3> F7` (13 bytes). `name` is the 4-character wire
    /// name (see `spsName(fromFileName:)`); it is padded with spaces / truncated to 4.
    public static func spsNameMessage(slot: Int, name: String) -> [UInt8] {
        var chars = name.prefix(4).map(spsByte)
        while chars.count < 4 { chars.append(0x20) }
        return spsNamePrefix + [UInt8(slot & 0x7F)] + chars + [0xF7]
    }

    /// Parses a 0x73 name message; the name comes back in display form (`[ \ ]` → `Å Ä Ö`),
    /// trailing spaces kept as C6 did.
    public static func parseSPSName(_ m: [UInt8]) -> (slot: UInt8, name: String)? {
        guard m.count == 13, Array(m.prefix(7)) == spsNamePrefix, m[12] == 0xF7 else { return nil }
        return (m[7], spsDisplayName(m[8..<12].map { $0 & 0x7F }))
    }

    /// The 4-letter SPS-1UW name C6 derived from a file name (Mac M 0x31f5): directory and last
    /// extension removed, then characters 1–3 plus the last character, upper-cased, with
    /// `Å Ä Ö` → `[ \ ]` (the Machinedrum's codes for them), space-padded.
    /// `"kick.wav"` → `KICK`, `"snare01.aif"` → `SNA1`, `"hh.wav"` → `HH  `, `"åska.wav"` → `[SKA`.
    public static func spsName(fromFileName fileName: String) -> String {
        spsName(fromBaseName: baseName(ofFileName: fileName))
    }

    /// As `spsName(fromFileName:)` for a name that has no directory or extension.
    public static func spsName(fromBaseName base: String) -> String {
        let chars = Array(base)
        var out = [UInt8](repeating: 0x20, count: 4)
        for i in 0..<min(chars.count, 4) {
            out[i] = spsByte(i <= 2 ? chars[i] : chars[chars.count - 1])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Maps the wire characters `[ \ ]` back to `Å Ä Ö` (C6 receive, §4.3).
    public static func spsDisplayName<C: Collection>(_ wire: C) -> String where C.Element == UInt8 {
        String(wire.map { b -> Character in
            switch b {
            case 0x5B: return "Å"
            case 0x5C: return "Ä"
            case 0x5D: return "Ö"
            default: return Character(Unicode.Scalar(b & 0x7F))
            }
        })
    }

    /// File name without directory and without its last extension (C6: after the last `/`,
    /// before the last `.`).
    public static func baseName(ofFileName fileName: String) -> String {
        var s = Substring(fileName)
        if let slash = s.lastIndex(of: "/") { s = s[s.index(after: slash)...] }
        if let dot = s.lastIndex(of: ".") { s = s[..<dot] }
        return String(s)
    }

    static func spsByte(_ c: Character) -> UInt8 {
        switch c {
        case "Å", "å": return 0x5B
        case "Ä", "ä": return 0x5C
        case "Ö", "ö": return 0x5D
        default:
            guard let a = asciiByte(c) else { return 0x3F } // "?"
            return (a >= 0x61 && a <= 0x7A) ? a - 0x20 : a  // toupper, C locale
        }
    }

    // MARK: - Helpers

    /// 7-bit ASCII for a character, folding diacritics (é → e); nil if there is no ASCII form.
    static func asciiByte(_ c: Character) -> UInt8? {
        if let a = c.asciiValue { return a }
        let folded = String(c).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        if folded.count == 1, let a = folded.first?.asciiValue { return a }
        return nil
    }

    /// 7-bit bytes for a name (non-ASCII characters folded or replaced by `?`).
    static func asciiBytes(_ s: String, maxLength: Int) -> [UInt8] {
        Array(s.map { asciiByte($0) ?? 0x3F }.prefix(maxLength))
    }

    static func handshake(_ sub: UInt8, _ device: UInt8, _ packet: UInt8) -> [UInt8] {
        [0xF0, 0x7E, device & 0x7F, sub, packet & 0x7F, 0xF7]
    }

    /// `count` 7-bit groups, least significant first; the value is clamped to what fits.
    static func lsb7(_ value: Int, _ count: Int) -> [UInt8] {
        let v = min(max(0, value), (1 << (7 * count)) - 1)
        return (0..<count).map { UInt8((v >> (7 * $0)) & 0x7F) }
    }

    static func le7(_ m: [UInt8], _ at: Int, _ count: Int) -> Int {
        var v = 0
        for i in 0..<count { v |= Int(m[at + i] & 0x7F) << (7 * i) }
        return v
    }
}
