import Foundation

/// Monomachine DigiPRO waveform conversion, after C6 1.51's [DigiPRO] button (Mac 0x8530 →
/// message builder 0xf6ea → table generator 0xcafc; spec `30-audio-digipro.md` §7–§9; reference
/// model `tools/digipro_ref.py`).
///
/// The N input samples (the file's loop, or the whole file, at most 16384; see
/// `AudioFile.digiPROSamples`) are one period of a waveform. They are DC-removed, transformed
/// (radix-2 FFT, or Bluestein for other lengths), resampled to a 1024-bin spectrum, tapered above
/// harmonic 350, normalised, and rendered into a band-limited mip-map: 9 full-band tables
/// (1024 … 4 points) interleaved with 8 quarter-band tables (512 … 4), quantised to 16 bits,
/// 8→7-bit packed and framed as the 7027-byte SysEx `F0 00 20 3C 03 00 5D 01 01 <slot> <name>
/// <7008 bytes> <chk hi> <chk lo> 36 69 F7`.
///
/// `Mode.original` is bit-identical to the original Mac build (as modelled by
/// `digipro_ref.py`, original mode). `Mode.fixed` (the default) differs only by fixes 1–3 and is
/// bit-identical to `digipro_ref.py` with `fixed=True`.
///
/// Deviations from the original (in `.fixed`; 4–6 apply to both modes):
/// 1. **FIX — FFT bit reversal precision.** The original swaps through a `float` temporary
///    (Mac 0x77aa, also Windows), rounding every element moved down to float32. Here the swap is
///    exact. Effect on the output is at most ±1 LSB in a few words, and only for some inputs
///    (e.g. 1 of 3066 words for a 600-sample saw; none for the 1024/1500/2048-sample vectors).
/// 2. **FIX — 32768-point FFTs are reordered.** The original's bit-reversal counters are 16-bit
///    shorts, so for n = 32768 the loop never runs. That size is the Bluestein core for
///    non-power-of-two N in 8193…16383, whose waveforms came out scrambled.
/// 3. **FIX — spectrum copy for 684 ≤ N ≤ 1023.** The original moves the top N/2 bins up to
///    1024−N/2… with an ascending in-place copy whose source and destination overlap, so already
///    moved bins are copied again and the negative-frequency half is corrupted. Copied with
///    `memmove` semantics here.
/// 4. **Fresh work buffers.** The original reuses zero-filled global buffers; only N = 2 reads
///    stale contents. Here every conversion behaves like the first one after launch.
/// 5. **Input length is always defined.** More than 16384 samples: the first 16384 are used (as
///    the reader does). An empty input encodes like one silent sample (all-zero tables); the
///    original never got there with 0 samples, it would divide by zero and read garbage.
/// 6. **Checksum range.** Summed over bytes 10..<7022, the range the recognizer checks. The
///    original sums 10…7022 while byte 7022 still holds the packer's 0x00 remainder header, so
///    the value is identical and C6's own output validates; the generator/checker off-by-one
///    noted in `10-recognition.md` §8 has no effect.
///
/// Kept on purpose: the emphasis table and every constant, the 351…511 taper, normalisation by
/// the plain waveform's peak × 9.14025 (silence threshold 2^-16), `trunc(x · 32767)` without
/// clamping (values beyond ±32767 wrap), the 6-byte E/F interleave, the slot masked to 6 bits,
/// the position byte outside the checksum, the fixed length bytes `36 69`, and the 4-letter name
/// rule of `waveName(fromFileName:)`.
public enum DigiPRO {
    public enum Mode: Sendable, Equatable {
        /// Bit-exact C6 1.51 (Mac), including its three FFT/copy bugs.
        case original
        /// The original algorithm with fixes 1–3 above.
        case fixed
    }

    /// Size of a waveform message (0x1B73).
    public static let messageLength = 7027
    /// Longest input C6 converts (the loop must be ≤ 0x4000 samples).
    public static let maxSamples = 16384
    /// Elektron, Monomachine, message 0x5D, version 1.1.
    public static let header: [UInt8] = [0xF0, 0x00, 0x20, 0x3C, 0x03, 0x00, 0x5D, 0x01, 0x01]

    /// Builds the 7027-byte DigiPRO waveform SysEx for one period of `samples` (Mac 0xf6ea).
    /// - Parameters:
    ///   - slot: 0-based waveform position; masked to 0…63 (C6 used the index of the file within
    ///     the converted selection, so the first file goes to slot 0, shown as "position 1").
    ///   - name: up to 4 characters, normally from `waveName(fromFileName:)`; each character's
    ///     code is masked to 7 bits, missing characters are spaces.
    public static func encode(samples: [Double], slot: Int, name: String, mode: Mode = .fixed) -> [UInt8] {
        let input = samples.isEmpty ? [0.0] : Array(samples.prefix(maxSamples))
        let tables = makeTables(input, fixed: mode == .fixed)
        let packed = pack7(quantize(main: tables.main, quarter: tables.quarter))

        var msg = [UInt8](repeating: 0, count: messageLength)
        msg.replaceSubrange(0..<header.count, with: header)
        msg[9] = UInt8(slot & 0x3F)
        let nm = nameBytes(name)
        for i in 0..<4 { msg[10 + i] = nm[i] & 0x7F }
        msg.replaceSubrange(14..<(14 + packed.count), with: packed) // 7009 bytes: 14…7022, last = 0x00
        let sum = msg[10..<0x1B6E].reduce(0) { $0 + Int($1) }
        msg[0x1B6E] = UInt8((sum >> 7) & 0x7F)
        msg[0x1B6F] = UInt8(sum & 0x7F)
        msg[0x1B70] = 0x36 // length 7017 = F7 index − message-ID index − 3
        msg[0x1B71] = 0x69
        msg[0x1B72] = 0xF7
        return msg
    }

    /// The 4-letter wave name C6 derives from a file name (Mac 0x8879..0x8952): of the base name
    /// (last path component without its last extension), characters 1–3 plus the **last**
    /// character, ASCII letters upper-cased, Å/å → `[`, Ä/ä → `\`, Ö/ö → `]`, other characters as
    /// their Mac Roman code masked to 7 bits, padded with spaces.
    /// `"kick.wav"` → `"KICK"`, `"ab.aif"` → `"AB  "`, `"Sawtooth"` → `"SAWH"`, `"åska.wav"` → `"[SKA"`.
    ///
    /// The name is precomposed (NFC) first so decomposed file-system names fold like composed
    /// ones; characters without a Mac Roman equivalent count as `?`.
    public static func waveName(fromFileName fileName: String) -> String {
        let base = baseName(of: fileName).precomposedStringWithCanonicalMapping
        let c = [UInt8](base.data(using: .macOSRoman, allowLossyConversion: true) ?? Data())
        var name: [UInt8] = [0x20, 0x20, 0x20, 0x20]
        for i in 0..<min(c.count, 4) {
            var ch = i <= 2 ? c[i] : c[c.count - 1]
            switch ch {
            case 0x8C, 0x81: ch = 0x5B // å Å
            case 0x8A, 0x80: ch = 0x5C // ä Ä
            case 0x9A, 0x85: ch = 0x5D // ö Ö
            case 0x61...0x7A: ch -= 0x20
            default: break
            }
            name[i] = ch & 0x7F
        }
        return String(decoding: name, as: UTF8.self)
    }

    /// Last path component without its last extension, as C6 cut it (search backwards for `/`,
    /// then for `.`).
    public static func baseName(of fileName: String) -> String {
        var s = Substring(fileName)
        if let slash = s.lastIndex(of: "/") { s = s[s.index(after: slash)...] }
        if let dot = s.lastIndex(of: ".") { s = s[..<dot] }
        return String(s)
    }

    /// The list entry's new name after conversion: the base name + `.syx`.
    public static func syxFileName(fromFileName fileName: String) -> String {
        baseName(of: fileName) + ".syx"
    }

    static func nameBytes(_ name: String) -> [UInt8] {
        var out: [UInt8] = [0x20, 0x20, 0x20, 0x20]
        for (i, scalar) in name.unicodeScalars.prefix(4).enumerated() {
            out[i] = UInt8(truncatingIfNeeded: scalar.value)
        }
        return out
    }

    // MARK: - Decoding / validation

    /// A decoded DigiPRO waveform message.
    public struct Dump: Equatable, Sendable {
        /// Byte 9: the 0-based slot (C6 displays it + 1).
        public let slot: Int
        /// Bytes 10…13.
        public let name: String
        /// The 9 full-band tables E (1024, 512, …, 4 words; 2044 in all).
        public let mainTable: [Int16]
        /// One quarter-band word per E pair: F levels 512 … 4 (1020 words) and two zeros.
        public let quarterTable: [Int16]
        /// Checksum and length pass C6's recognizer rule (see `isValid(_:)`).
        public let isValid: Bool

        /// Decodes a message that starts with the Monomachine 0x5D header and is at least
        /// 7027 bytes long; nil otherwise.
        public init?(_ msg: [UInt8]) {
            guard msg.count >= DigiPRO.messageLength, Array(msg[0..<7]) == Array(DigiPRO.header[0..<7]) else { return nil }
            slot = Int(msg[9])
            name = String(decoding: msg[10..<14].map { $0 & 0x7F }, as: UTF8.self)
            var raw = [UInt8]()
            raw.reserveCapacity(6132)
            var p = 14
            while p + 8 <= 14 + 7008 {
                let msbs = msg[p]
                for i in 0..<7 { raw.append(msg[p + 1 + i] | (msbs & (1 << (6 - i)) != 0 ? 0x80 : 0)) }
                p += 8
            }
            var e = [Int16](), f = [Int16]()
            e.reserveCapacity(2044); f.reserveCapacity(1022)
            for g in 0..<1022 {
                let b = raw[(6 * g)..<(6 * g + 6)].map { UInt16($0) }
                e.append(Int16(bitPattern: b[0] << 8 | b[1]))
                e.append(Int16(bitPattern: b[3] << 8 | b[4]))
                f.append(Int16(bitPattern: b[2] << 8 | b[5]))
            }
            mainTable = e
            quarterTable = f
            isValid = DigiPRO.isValid(msg)
        }
    }

    /// C6's validation of a DigiPRO message (MM branch of the recognizer, Mac 0x10100 with the
    /// 0x5D special case 0x104ed): with `f` = the first F7 after the message ID, the 14-bit sum
    /// of bytes 10 ..< f−4 (signed) equals `msg[f−4] << 7 | msg[f−3]`, and the length field
    /// `msg[f−2] << 7 | msg[f−1]` + 3 equals f − 6.
    public static func isValid(_ msg: [UInt8]) -> Bool {
        guard msg.count > 14, Array(msg[0..<7]) == Array(header[0..<7]),
              let f = msg[7...].firstIndex(of: 0xF7), f >= 14 else { return false }
        let stored = Int(Int8(bitPattern: msg[f - 4])) << 7 | Int(Int8(bitPattern: msg[f - 3]))
        let length = (Int(Int8(bitPattern: msg[f - 2])) << 7 | Int(Int8(bitPattern: msg[f - 1]))) + 3
        let sum = msg[10..<(f - 4)].reduce(0) { $0 + Int(Int8(bitPattern: $1)) } & 0x3FFF
        return sum == stored && length == f - 6
    }

    // MARK: - Table generator (Mac 0xcafc)

    /// Returns E (2044 doubles: full-band tables 1024 … 4) and F (2044: quarter-band tables of the
    /// same sizes; F[0..<1024] is computed but never emitted).
    static func makeTables(_ x: [Double], fixed: Bool) -> (main: [Double], quarter: [Double]) {
        let t = emphasis
        let n0 = x.count
        precondition(n0 >= 1 && n0 <= maxSamples)
        var a = [Double](repeating: 0, count: maxSamples)
        var b = [Double](repeating: 0, count: maxSamples)
        for k in 0..<n0 { a[k] = x[k]; b[k] = 0 }

        // 1. DC removal
        var acc = 0.0
        for k in 0..<n0 { acc += a[k] }
        let mean = acc / Double(n0)
        for k in 0..<n0 { a[k] = a[k] - mean }

        // 2. forward DFT of the whole period
        FFT.transform(&a, &b, n0, inverse: false, fixed: fixed)

        // 3. to 1024 bins: keep the lowest h positive and the h highest (negative) bins
        let h = n0 > 1023 ? 512 : n0 / 2
        if fixed {
            let sa = Array(a[(n0 - h)..<n0]), sb = Array(b[(n0 - h)..<n0])
            for j in 0..<h { a[1024 - h + j] = sa[j]; b[1024 - h + j] = sb[j] }
        } else {
            for j in 0..<h { // ascending and in place: overlaps for 684 <= N <= 1023
                a[1024 - h + j] = a[n0 - h + j]
                b[1024 - h + j] = b[n0 - h + j]
            }
        }
        let h2 = n0 / 2
        if h2 < 1024 - h2 {
            for k in h2..<(1024 - h2) { a[k] = 0; b[k] = 0 }
        }
        a[512] = 0; b[512] = 0

        // 4. taper harmonics 351…511 and their mirrors 673…513 (0xcc65)
        for i in 350...510 {
            let v = (Double(i) - 350.0) * -0.006172839506172839 + 1.0
            let w = v * v
            let k = i - 350
            a[351 + k] = w * a[351 + k]
            b[351 + k] = w * b[351 + k]
            a[673 - k] = w * a[673 - k]
            b[673 - k] = w * b[673 - k]
        }

        // 5. normalise by the peak of the plain 1024-point waveform
        var c = Array(a[0..<1024]), d = Array(b[0..<1024])
        FFT.radix2(&c, &d, 1024, inverse: true, fixed: fixed)
        var peak = 0.0
        for k in 0..<1024 {
            let v = abs(c[k])
            peak = peak > v ? peak : v // maxsd
        }
        if !(peak >= 1.52587890625e-05) { peak = 1.0 } // 2^-16; NaN -> 1
        let scale = 1.0 / (peak * t[1023])
        for k in 0..<1024 { a[k] = scale * a[k]; b[k] = scale * b[k] }

        // 6 + 7. nine levels n = 1024 … 4 with emphasis T[harmonic * 2048 / n]
        var e = [Double](repeating: 0, count: 2044)
        var f = [Double](repeating: 0, count: 2044)
        var offE = 0, offF = 0, n = 1024, s = 2
        while true {
            let half = n / 2, quarter = n / 4
            // full band: harmonics < n/2
            c = [Double](repeating: 0, count: n)
            d = [Double](repeating: 0, count: n)
            for j in 0..<half {
                let tj = t[j * s]
                c[j] = tj * a[j]
                d[j] = tj * b[j]
            }
            c[half] = 0; d[half] = 0
            for m in 1..<half {
                let tm = t[m * s]
                d[n - m] = tm * b[1024 - m]
                c[n - m] = tm * a[1024 - m]
            }
            FFT.radix2(&c, &d, n, inverse: true, fixed: fixed)
            for k in 0..<n { e[offE + k] = (c[k] + c[k]) / Double(s) }
            offE += n
            // quarter band: harmonics < n/4, same emphasis indices
            c = [Double](repeating: 0, count: n)
            d = [Double](repeating: 0, count: n)
            for j in 0..<half {
                if j < quarter {
                    let tj = t[j * s]
                    d[j] = tj * b[j]
                    c[j] = tj * a[j]
                } else {
                    c[j] = 0; d[j] = 0
                }
            }
            c[half] = 0; d[half] = 0
            for m in 1..<half {
                if m < quarter {
                    let tm = t[m * s]
                    c[n - m] = tm * a[1024 - m]
                    d[n - m] = tm * b[1024 - m]
                } else {
                    c[n - m] = 0; d[n - m] = 0
                }
            }
            FFT.radix2(&c, &d, n, inverse: true, fixed: fixed)
            for k in 0..<n { f[offF + k] = (c[k] + c[k]) / Double(s) }
            offF += n
            s <<= 1
            if half > 2 { n = half } else { break }
        }
        return (e, f)
    }

    /// Mac 0xd1a1: 1022 groups `[E_i hi, E_i lo, F hi, E_i+1 hi, E_i+1 lo, F lo]` = 6132 bytes,
    /// with F = F[1024 + i/2] (quarter-band level n/2 next to full-band level n) and 0 for the
    /// last two groups.
    static func quantize(main e: [Double], quarter f: [Double]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(6132)
        var i = 0
        while i != 2044 {
            let v0 = truncateToInt32(e[i] * 32767.0)
            let v1 = i <= 0x7F7 ? truncateToInt32(f[1024 + (i >> 1)] * 32767.0) : 0
            let v2 = truncateToInt32(e[i + 1] * 32767.0)
            out.append(UInt8(truncatingIfNeeded: v0 >> 8))
            out.append(UInt8(truncatingIfNeeded: v0))
            out.append(UInt8(truncatingIfNeeded: v1 >> 8))
            out.append(UInt8(truncatingIfNeeded: v2 >> 8))
            out.append(UInt8(truncatingIfNeeded: v2))
            out.append(UInt8(truncatingIfNeeded: v1))
            i += 2
        }
        return out
    }

    /// `cvttsd2si`: truncate toward zero; NaN or out of range → 0x80000000.
    static func truncateToInt32(_ x: Double) -> Int32 {
        if x.isNaN || x >= 2147483648.0 || x <= -2147483649.0 { return Int32.min }
        return Int32(x)
    }

    /// Mac 0xb72c: each 7 bytes → one MSB byte (bit 6 = MSB of the first byte … bit 0 = the
    /// seventh) + the 7 low-7-bit bytes. A remainder of r ≤ 6 bytes gets its own header; r == 0
    /// still emits a 0x00 header (6132 bytes → 876 blocks + one 0x00 = 7009 bytes).
    static func pack7(_ raw: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(raw.count / 7 * 8 + 8)
        var p = 0
        while raw.count - p > 6 {
            var msbs: UInt8 = 0
            for i in 0..<7 where raw[p + i] & 0x80 != 0 { msbs |= 1 << (6 - i) }
            out.append(msbs)
            for i in 0..<7 { out.append(raw[p + i] & 0x7F) }
            p += 7
        }
        var msbs: UInt8 = 0
        for i in 0..<(raw.count - p) where raw[p + i] & 0x80 != 0 { msbs |= 1 << (6 - i) }
        out.append(msbs)
        for i in 0..<(raw.count - p) { out.append(raw[p + i] & 0x7F) }
        return out
    }
}
