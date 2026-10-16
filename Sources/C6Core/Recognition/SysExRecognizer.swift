import Foundation

/// Recognition of a list item's byte buffer: the data browser's **Type** column and the
/// **File Info** text, after C6 1.51 (spec `10-recognition.md`; Mac i386 is the primary source,
/// Windows the cross-check).
///
/// Classification depends only on content (magic bytes), never on the file extension. The buffer
/// is the whole file or received blob, unmodified.
///
/// Deliberate deviations from the Mac original:
/// 1. **Analog Rytm Type.** Device 0x07 data shows Type `"AR"`, as in the Windows build
///    (Win 0x407236..0x407337). The Mac build never tests device 0x07 in the Type column and
///    shows `"-"`. File Info for AR was already implemented on Mac (0x10ca0) and is unchanged.
/// 2. **No stale Octatrack text.** An Octatrack buffer without any 0x7E upgrade message gets the
///    File Info text `""`. The original (Mac 0xfbb6, Win 0x4030e7) returns without setting the
///    text, so the previous selection's description stays on screen.
/// 3. **Extended SDS is recognised.** A buffer that starts with an Extended Dump Header
///    (`F0 7E dev 05 05 …`, which C6 itself sends when "Use Extended SDS" is on) gets Type `"SDS"`
///    and the SDS analysis line. Extended headers also start a new dump inside the packet scan, and
///    their fields come from the extended layout: bits at 7, rate in Hz at 8..11 (28-bit, rounded
///    with the 28-bit fraction at 12..15), length / loop start / loop end as 35-bit values at
///    16 / 21 / 26, loop type at 31. The original shows Type `"-"` and File Info `""`.
/// 4. **SDS period 0.** A Dump Header with sample period 0 shows `Sample Rate: 0`. The original
///    divides by the period (`idiv`) and crashes with SIGFPE.
/// 5. **Out-of-range reads.** Where the original reads past the end of the buffer (the `b[n]` F7
///    probe, A4/AR upgrade blocks read up to m+120, header fields of a short SDS buffer), this
///    implementation reads `0x00`. The original's uninitialised A4/AR upgrade state (`v1`, `v2`,
///    `seed`) is "unset" here, so a comparison against it fails and the upgrade reads as broken.
///    Buffers shorter than 12 bytes are never audio (the original reads past them).
///
/// Kept as in the original on purpose: the Mac File Info order (SID after A4/AR; Elektron before
/// audio, so a WAV whose body contains an Elektron header gets an Elektron description), the SDS
/// counting quirks (a bad packet checksum makes a dump neither correct nor broken; a missing packet
/// makes every later packet count as broken), the leading-newline DigiPRO text, and recognition of
/// a standard SDS header only at offset 0.
public enum SysExRecognizer {
    /// Type column (Mac 0x3e3b..0x408a, plus the Windows `"AR"` test). First match wins.
    public static func classify(_ bytes: [UInt8]) -> RecognizedType {
        let b = RecognitionBuffer(bytes)
        if let audio = audioFormat(b) {
            switch audio {
            case .wav: return .wav
            case .aiff: return .aiff
            case .aifc: return .aifc
            }
        }
        let devices = b.elektronDevices()
        if devices.contains(ElektronDevice.machinedrum.rawValue) { return .machinedrum }
        if devices.contains(ElektronDevice.monomachine.rawValue) { return .monomachine }
        if devices.contains(ElektronDevice.octatrack.rawValue) { return .octatrack }
        if devices.contains(ElektronDevice.sidstation.rawValue) { return .sidstation }
        if isSampleDump(b) { return .sds }
        if devices.contains(ElektronDevice.analogFour.rawValue) { return .analogFour }
        if devices.contains(ElektronDevice.analogRytm.rawValue) { return .analogRytm } // deviation 1
        return .unknown
    }

    /// The exact Type-column string (`"MD"`, `"AF"`, `"-"`, …).
    public static func typeString(_ bytes: [UInt8]) -> String { classify(bytes).typeString }

    /// File Info (Mac dispatch 0x413e). Audio files are handed back as `.audio` for the audio module.
    public static func fileInfo(_ bytes: [UInt8]) -> FileInfo {
        let b = RecognitionBuffer(bytes)
        let devices = b.elektronDevices()
        if devices.contains(ElektronDevice.machinedrum.rawValue) {
            return .text(ElektronDescriber.describeMachinedrumFamily(b, device: .machinedrum))
        }
        if devices.contains(ElektronDevice.monomachine.rawValue) {
            return .text(ElektronDescriber.describeMachinedrumFamily(b, device: .monomachine))
        }
        if devices.contains(ElektronDevice.octatrack.rawValue) {
            return .text(ElektronDescriber.describeOctatrack(b) ?? "") // deviation 2
        }
        if devices.contains(ElektronDevice.analogFour.rawValue) {
            return .text(ElektronDescriber.describeAnalog(b, device: .analogFour))
        }
        if devices.contains(ElektronDevice.analogRytm.rawValue) {
            return .text(ElektronDescriber.describeAnalog(b, device: .analogRytm))
        }
        if devices.contains(ElektronDevice.sidstation.rawValue) { return .text(InfoText.sidstation) }
        if let audio = audioFormat(b) { return .audio(audio) }
        if isSampleDump(b) { return .text(SampleDumpDescriber.describe(b)) }
        return .text("")
    }

    /// The File Info text. `audioDescriber` supplies the WAV/AIFF/AIFC description (owned by the
    /// audio module); without one, audio files describe as `""`.
    public static func describe(_ bytes: [UInt8],
                                audioDescriber: (AudioFormat, [UInt8]) -> String = { _, _ in "" }) -> String {
        switch fileInfo(bytes) {
        case let .text(t): return t
        case let .audio(format): return audioDescriber(format, bytes)
        }
    }

    // MARK: Primitive predicates (spec §1.2)

    /// `RIFF….WAVE`, `FORM….AIFF` or `FORM….AIFC` at offset 0; nil for anything else.
    public static func audioFormat(of bytes: [UInt8]) -> AudioFormat? { audioFormat(RecognitionBuffer(bytes)) }

    /// Some `F0 00 20 3C <device> 00` anywhere in the buffer, all six bytes inside it (Mac 0xf7e7).
    public static func hasElektronHeader(_ bytes: [UInt8], device: UInt8) -> Bool {
        RecognitionBuffer(bytes).elektronDevices().contains(device)
    }

    /// The buffer starts with an SDS Dump Header (`F0 7E dev 01`, Mac 0xaba4) or an Extended Dump
    /// Header (`F0 7E dev 05 05`, deviation 3).
    public static func isSampleDump(_ bytes: [UInt8]) -> Bool { isSampleDump(RecognitionBuffer(bytes)) }

    static func audioFormat(_ b: RecognitionBuffer) -> AudioFormat? {
        guard b.count >= 12 else { return nil }
        if b.hasTag("RIFF", at: 0) && b.hasTag("WAVE", at: 8) { return .wav }
        if b.hasTag("FORM", at: 0) && b.hasTag("AIFF", at: 8) { return .aiff }
        if b.hasTag("FORM", at: 0) && b.hasTag("AIFC", at: 8) { return .aifc }
        return nil
    }

    static func isSampleDump(_ b: RecognitionBuffer) -> Bool {
        SampleDumpDescriber.headerKind(b) != nil
    }
}

// MARK: - Public types

/// Elektron device byte in `F0 00 20 3C <dev> 00 …` that C6 recognises.
public enum ElektronDevice: UInt8, CaseIterable, Sendable {
    case sidstation = 0x01
    case machinedrum = 0x02
    case monomachine = 0x03
    case octatrack = 0x05
    /// Analog Four (Analog Keys is believed to share this ID).
    case analogFour = 0x06
    case analogRytm = 0x07
}

/// Audio container formats; their File Info belongs to the audio module.
public enum AudioFormat: String, CaseIterable, Sendable {
    case wav = "WAV", aiff = "AIFF", aifc = "AIFC"
}

/// The data browser's Type column. `rawValue` is C6's exact string.
public enum RecognizedType: String, CaseIterable, Sendable {
    case wav = "WAV", aiff = "AIFF", aifc = "AIFC"
    case machinedrum = "MD"
    case monomachine = "MM"
    case octatrack = "OT"
    case sidstation = "SID"
    case sds = "SDS"
    case analogFour = "AF"
    case analogRytm = "AR"
    case unknown = "-"

    public var typeString: String { rawValue }

    public var audioFormat: AudioFormat? {
        switch self {
        case .wav: return .wav
        case .aiff: return .aiff
        case .aifc: return .aifc
        default: return nil
        }
    }

    public var elektronDevice: ElektronDevice? {
        switch self {
        case .machinedrum: return .machinedrum
        case .monomachine: return .monomachine
        case .octatrack: return .octatrack
        case .sidstation: return .sidstation
        case .analogFour: return .analogFour
        case .analogRytm: return .analogRytm
        default: return nil
        }
    }
}

/// Result of the File Info dispatch.
public enum FileInfo: Equatable, Sendable {
    /// The final text for the File Info box (may contain newlines, may be empty).
    case text(String)
    /// A WAV/AIFF/AIFC file: the audio module builds the description.
    case audio(AudioFormat)
}

// MARK: - Exact strings (Mac __cstring 0x11828.., identical on Windows)

enum InfoText {
    static let upgrade = "Sysex Upgrade"
    static let upgradeBroken = "Sysex Upgrade (Broken!)"
    static let sidstation = "SIDSTATION"
    static let brokenSampleDump = "Broken sample dump."
}

// MARK: - Buffer access

/// Read-only view of the buffer. Out-of-range reads return 0 (the original reads past the `Ptr`).
struct RecognitionBuffer {
    let bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var count: Int { bytes.count }

    subscript(_ i: Int) -> UInt8 { i >= 0 && i < bytes.count ? bytes[i] : 0 }

    /// Signed-char read (`movsbl`).
    func s8(_ i: Int) -> Int { Int(Int8(bitPattern: self[i])) }

    /// Nibble pair → byte: `(b[i] & 0xF) << 4 | (b[i+1] & 0xF)`.
    func nibblePair(_ i: Int) -> Int { Int(self[i] & 0x0F) << 4 | Int(self[i + 1] & 0x0F) }

    /// Unsigned 21-bit big-endian 7-bit field: `b[i] << 14 + b[i+1] << 7 + b[i+2]`.
    func u21(_ i: Int) -> Int { (Int(self[i]) << 14) + (Int(self[i + 1]) << 7) + Int(self[i + 2]) }

    /// Little-endian 7-bit field of `length` bytes (SDS headers).
    func le7(_ i: Int, length: Int) -> Int {
        var v = 0
        for k in 0..<length { v |= Int(self[i + k]) << (7 * k) }
        return v
    }

    func hasTag(_ tag: String, at offset: Int) -> Bool {
        let t = Array(tag.utf8)
        guard offset >= 0, offset + t.count <= count else { return false }
        return bytes[offset..<(offset + t.count)].elementsEqual(t)
    }

    /// First index ≥ `start` holding F7, or `count` if there is none.
    func firstF7(from start: Int) -> Int {
        var f = max(start, 0)
        while f < count && bytes[f] != 0xF7 { f += 1 }
        return f
    }

    /// Device bytes for which a complete `F0 00 20 3C <dev> 00` exists somewhere in the buffer
    /// (one pass; equivalent to calling the original's per-device matcher for each device).
    func elektronDevices() -> Set<UInt8> {
        var found = Set<UInt8>()
        var i = 0
        let n = count
        while i + 5 < n {
            if bytes[i] == 0xF0, bytes[i + 1] == 0x00, bytes[i + 2] == 0x20, bytes[i + 3] == 0x3C, bytes[i + 5] == 0x00 {
                found.insert(bytes[i + 4])
            }
            i += 1
        }
        return found
    }

    /// The describers' scan loop: index of the message-ID byte (`i + 6`) of every
    /// `F0 00 20 3C <dev> 00` with at least one byte after it.
    func messageIDIndices(device: UInt8) -> [Int] {
        var out: [Int] = []
        var i = 0
        let n = count
        while i + 6 < n {
            if bytes[i] == 0xF0, bytes[i + 1] == 0x00, bytes[i + 2] == 0x20, bytes[i + 3] == 0x3C,
               bytes[i + 4] == device, bytes[i + 5] == 0x00 {
                out.append(i + 6)
            }
            i += 1
        }
        return out
    }
}
