import Foundation

/// Writes received SDS samples as WAV or AIFF, after C6 1.51's receive path for Rec Format
/// WAV / AIFF (Mac 0xc271 / 0xba16; spec `20-transfer.md` §5.3).
///
/// Input: one mono sample per frame as a signed integer `bits` wide (the SDS word with its
/// offset removed). Samples are left-justified into ⌈bits/8⌉ bytes (`v << (8·bytes − bits)`):
/// little-endian in WAV (8-bit as unsigned offset binary), big-endian in AIFF.
///
/// * WAV: `fmt ` PCM, 1 channel, rate, byteRate = bytes × rate, blockAlign = bytes,
///   bitsPerSample = 8 × bytes (the container size, as C6 wrote it); `data`; then a 60-byte
///   `smpl` chunk (sample period in ns, unity note 60, one loop) when a loop is given and its type
///   is not 0x7F.
/// * AIFF: `COMM` (1 channel, frames, sampleSize = bits, 80-bit rate), `SSND`, then — for a loop
///   whose type is not 0x7F — `INST` (base note 60, full key/velocity range, sustain loop between
///   markers 1 and 2) and `MARK` (marker 1 "beg" = loop start, marker 2 "end" = loop end).
///
/// Loop ends are inclusive in both formats, as C6 wrote and reads them (correct for WAV `smpl`;
/// AIFF players treat the end marker as exclusive, so they play one sample less).
///
/// Deviations from the original writer:
/// 1. **FIX — 80-bit sample rate.** The original wrote `00 <e>` instead of `40 <e>` for the
///    exponent (Q10), i.e. a rate around 2^-16383. Written correctly here.
/// 2. **Loop type is kept.** An alternating SDS loop (type 1) becomes `smpl` dwType 1 / INST play
///    mode 2 (forward/backward); C6 always wrote a forward loop. (C6's AIFF reader, and therefore
///    `AudioFile`, maps play mode 2 to "Loop OFF" — a kept reader quirk.)
/// 3. **Marker ids 1 and 2, no length marker.** C6 wrote markers 0, 1, 2 (loop start, loop end,
///    length); AIFF requires positive ids and the length marker is not referenced by anything.
///    The markers have 3-character names so no pstring pad byte is needed, which keeps them
///    readable by C6's own MARK parser (it does not skip pad bytes).
/// 4. **Chunk order COMM, SSND, INST, MARK.** C6's AIFF parser loses loop points when INST/MARK
///    come before SSND; this order survives it (and any spec-compliant reader).
/// 5. `bits` outside 1…32 is clamped into that range; a sample rate ≤ 0 is written as 0 (and a
///    sample period of 0).
public enum AudioWriter {
    /// Loop start / end (inclusive) in frames and SDS loop type (0 forward, 1 alternating,
    /// 0x7F off).
    public typealias Loop = (start: Int, end: Int, type: Int)

    /// `.aifc` is written as plain AIFF (C6's Rec Format offered only WAV and AIFF).
    public static func write(_ format: AudioFormat, samples: [Int32], bits: Int, sampleRate: Int,
                             loop: Loop? = nil) -> [UInt8] {
        switch format {
        case .wav: return wav(samples: samples, bits: bits, sampleRate: sampleRate, loop: loop)
        case .aiff, .aifc: return aiff(samples: samples, bits: bits, sampleRate: sampleRate, loop: loop)
        }
    }

    public static func wav(samples: [Int32], bits: Int, sampleRate: Int, loop: Loop? = nil) -> [UInt8] {
        let bits = min(max(bits, 1), 32), bytes = (bits - 1) / 8 + 1, shift = 8 * bytes - bits
        let rate = max(sampleRate, 0)
        var data = [UInt8]()
        data.reserveCapacity(samples.count * bytes)
        for v in samples {
            let w = Int64(v) << shift
            if bytes == 1 {
                data.append(UInt8(truncatingIfNeeded: w + 128))
            } else {
                for k in 0..<bytes { data.append(UInt8(truncatingIfNeeded: w >> (8 * k))) }
            }
        }
        var body = Array("WAVE".utf8)
        body += chunk("fmt ", le16(1) + le16(1) + le32(rate) + le32(bytes * rate) + le16(bytes) + le16(8 * bytes))
        body += chunk("data", data)
        if let loop, loop.type != 0x7F {
            var smpl = le32(0) + le32(0) + le32(period(rate)) + le32(60) + le32(0) + le32(0) + le32(0)
            smpl += le32(1) + le32(0) // cSampleLoops, cbSamplerData
            smpl += le32(0) + le32(loop.type) + le32(loop.start) + le32(loop.end) + le32(0) + le32(0)
            body += chunk("smpl", smpl)
        }
        return Array("RIFF".utf8) + le32(body.count) + body
    }

    public static func aiff(samples: [Int32], bits: Int, sampleRate: Int, loop: Loop? = nil) -> [UInt8] {
        let bits = min(max(bits, 1), 32), bytes = (bits - 1) / 8 + 1, shift = 8 * bytes - bits
        var ssnd = be32(0) + be32(0) // offset, blockSize
        ssnd.reserveCapacity(8 + samples.count * bytes)
        for v in samples {
            let w = Int64(v) << shift
            for k in (0..<bytes).reversed() { ssnd.append(UInt8(truncatingIfNeeded: w >> (8 * k))) }
        }
        var body = Array("AIFF".utf8)
        body += chunk("COMM", be16(1) + be32(samples.count) + be16(bits) + extended80(sampleRate), bigEndian: true)
        body += chunk("SSND", ssnd, bigEndian: true)
        if let loop, loop.type != 0x7F {
            let playMode = loop.type == 1 ? 2 : 1
            var inst: [UInt8] = [60, 0, 0, 127, 1, 127] // base note, detune, low/high note, low/high velocity
            inst += be16(0) // gain
            inst += be16(playMode) + be16(1) + be16(2) // sustain loop: markers 1 → 2
            inst += be16(0) + be16(0) + be16(0) // release loop: none
            body += chunk("INST", inst, bigEndian: true)
            var mark = be16(2)
            mark += be16(1) + be32(loop.start) + [3] + Array("beg".utf8)
            mark += be16(2) + be32(loop.end) + [3] + Array("end".utf8)
            body += chunk("MARK", mark, bigEndian: true)
        }
        return Array("FORM".utf8) + be32(body.count) + body
    }

    /// IEEE 754 80-bit extended big-endian for a non-negative integer rate (0 → all zeros).
    public static func extended80(_ rate: Int) -> [UInt8] {
        guard rate > 0 else { return [UInt8](repeating: 0, count: 10) }
        let r = UInt64(rate)
        let e = 63 - r.leadingZeroBitCount
        let exponent = 16383 + e
        let mantissa = r << UInt64(63 - e)
        return [UInt8(exponent >> 8), UInt8(exponent & 0xFF)] + (0..<8).map { UInt8(truncatingIfNeeded: mantissa >> (56 - 8 * $0)) }
    }

    static func period(_ rate: Int) -> Int { rate > 0 ? (rate / 2 + 1_000_000_000) / rate : 0 }

    /// `id`, size (little-endian for RIFF, big-endian for IFF), payload, pad byte if odd.
    private static func chunk(_ id: String, _ payload: [UInt8], bigEndian: Bool = false) -> [UInt8] {
        var out = Array(id.utf8) + (bigEndian ? be32(payload.count) : le32(payload.count)) + payload
        if payload.count & 1 == 1 { out.append(0) }
        return out
    }

    private static func le16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] }
    private static func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    private static func be16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
    private static func be32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * $0)) } }
}
