@testable import C6Core
import Foundation
import Testing

/// Builders for synthetic WAV / AIFF / AIFC files. The DigiPRO pipeline vectors are built the
/// same way by `tools/golden_swift_files.py`.
enum AudioFixture {
    static func le16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] }
    static func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    static func be16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
    static func be32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * $0)) } }
    static func tag(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// RIFF chunk (little-endian size) with its pad byte.
    static func riffChunk(_ id: String, _ d: [UInt8]) -> [UInt8] { tag(id) + le32(d.count) + d + (d.count & 1 == 1 ? [0] : []) }
    /// IFF chunk (big-endian size) with its pad byte.
    static func iffChunk(_ id: String, _ d: [UInt8]) -> [UInt8] { tag(id) + be32(d.count) + d + (d.count & 1 == 1 ? [0] : []) }

    static func wav(_ chunks: [UInt8]...) -> [UInt8] {
        let body = tag("WAVE") + chunks.joined()
        return tag("RIFF") + le32(body.count) + body
    }
    static func form(_ type: String, _ chunks: [UInt8]...) -> [UInt8] {
        let body = tag(type) + chunks.joined()
        return tag("FORM") + be32(body.count) + body
    }

    static func fmt(tag t: Int = 1, channels: Int = 1, rate: Int = 44100, bits: Int = 16) -> [UInt8] {
        let bps = t == 3 ? bits / 8 : max(0, (bits - 1) / 8 + 1)
        return riffChunk("fmt ", le16(t) + le16(channels) + le32(rate) + le32(rate * channels * bps)
                         + le16(channels * bps) + le16(bits))
    }
    static func smpl(period: Int = 22675, loops: [(type: Int, start: Int, end: Int)]) -> [UInt8] {
        var d = le32(0) + le32(0) + le32(period) + le32(60) + le32(0) + le32(0) + le32(0) + le32(loops.count) + le32(0)
        for l in loops { d += le32(0) + le32(l.type) + le32(l.start) + le32(l.end) + le32(0) + le32(0) }
        return riffChunk("smpl", d)
    }
    static func data(_ d: [UInt8]) -> [UInt8] { riffChunk("data", d) }

    static func pcmLE(_ v: [Int], bytes: Int) -> [UInt8] { v.flatMap { x in (0..<bytes).map { UInt8(truncatingIfNeeded: x >> (8 * $0)) } } }
    static func pcmBE(_ v: [Int], bytes: Int) -> [UInt8] { v.flatMap { x in (0..<bytes).reversed().map { UInt8(truncatingIfNeeded: x >> (8 * $0)) } } }
    static func float32LE(_ v: [Double]) -> [UInt8] { v.flatMap { le32(Int(Float($0).bitPattern)) } }
    static func float32BE(_ v: [Double]) -> [UInt8] { v.flatMap { be32(Int(Float($0).bitPattern)) } }
    static func float64LE(_ v: [Double]) -> [UInt8] { v.flatMap { x in (0..<8).map { UInt8(truncatingIfNeeded: x.bitPattern >> (8 * $0)) } } }
    static func float64BE(_ v: [Double]) -> [UInt8] { v.flatMap { x in (0..<8).reversed().map { UInt8(truncatingIfNeeded: x.bitPattern >> (8 * $0)) } } }

    /// IEEE 80-bit extended for an integer rate (independent of `AudioWriter.extended80`).
    static func ext80(_ rate: Int) -> [UInt8] {
        var e = 0
        while (1 << (e + 1)) <= rate { e += 1 }
        let mantissa = UInt64(rate) << UInt64(63 - e)
        return be16(16383 + e) + (0..<8).map { UInt8(truncatingIfNeeded: mantissa >> UInt64(56 - 8 * $0)) }
    }
    static func comm(channels: Int = 1, frames: Int, bits: Int, rate: [UInt8] = ext80(44100), compression: String? = nil) -> [UInt8] {
        var d = be16(channels) + be32(frames) + be16(bits) + rate
        if let c = compression { d += tag(c) + [1, 0x78] } // compressionName "x" (pstring, even length)
        return iffChunk("COMM", d)
    }
    static func ssnd(_ pcm: [UInt8]) -> [UInt8] { iffChunk("SSND", be32(0) + be32(0) + pcm) }
    static func inst(playMode: Int = 1, begin: Int = 1, end: Int = 2) -> [UInt8] {
        iffChunk("INST", [60, 0, 0, 127, 1, 127] + be16(0) + be16(playMode) + be16(begin) + be16(end) + be16(0) + be16(0) + be16(0))
    }
    /// MARK chunk with spec-correct pstrings (pad byte when count byte + name is odd).
    static func mark(_ markers: [(id: Int, pos: Int, name: String)]) -> [UInt8] {
        var d = be16(markers.count)
        for m in markers {
            let n = tag(m.name)
            d += be16(m.id) + be32(m.pos) + [UInt8(n.count)] + n + ((n.count + 1) & 1 == 1 ? [0] : [])
        }
        return iffChunk("MARK", d)
    }
    static let fver = iffChunk("FVER", be32(0xA280_5140))

    // The three pipeline files of tools/golden_swift_files.py.
    static var wavStereo16: [UInt8] {
        let frames: [UInt8] = (0..<2000).flatMap { (k: Int) -> [UInt8] in
            let l: Int = ((k * 37) % 600) * 100 - 30000, r: Int = ((k * k) % 1000) * 30 - 15000
            return le16(l) + le16(r)
        }
        return wav(fmt(channels: 2, rate: 44100, bits: 16), data(frames), smpl(period: 22675, loops: [(0, 100, 699)]))
    }
    static var aiffMono24: [UInt8] {
        let pcm = pcmBE((0..<3000).map { k in ((k * 7919) % 8000 - 4000) * 1000 }, bytes: 3)
        return form("AIFF", comm(frames: 3000, bits: 24, rate: ext80(48000)), ssnd(pcm), inst(playMode: 1, begin: 1, end: 2),
                    mark([(1, 1000, "beg"), (2, 1999, "end")]))
    }
    static var wavFloat32: [UInt8] {
        wav(fmt(tag: 3, channels: 1, rate: 32000, bits: 32), data(float32LE((0..<2048).map { Double($0 % 512) / 256.0 - 1.0 })))
    }
}

private typealias Fx = AudioFixture

private func parse(_ b: [UInt8]) throws -> AudioFile { try AudioFile(bytes: b) }

private func parseError(_ b: [UInt8]) -> AudioFileError? {
    do { _ = try AudioFile(bytes: b); return nil } catch { return error as? AudioFileError }
}

@Suite struct AudioFileWAVTests {
    @Test func pcm16MonoWithoutLoop() throws {
        let f = try parse(Fx.wav(Fx.fmt(), Fx.data(Fx.pcmLE([0, 1000, -32768, 32767], bytes: 2))))
        #expect(f.info == AudioFile.Info(container: .wav, channels: 1, sampleRate: 44100, bits: 16, bytesPerSample: 2,
                                         numFrames: 4, loopStart: 0, loopEnd: 3, loopOn: false, loopType: 0x7F,
                                         samplePeriodNs: 22676))
        #expect(f.infoText == "Sample length: 4 Channels: 1 Sample Rate: 44100\nBits: 16 Loop OFF.")
        #expect(f.canConvertToDigiPRO)
        #expect(f.sdsSamples(stereo: .mix) == [0, 1000, -32768, 32767])
        let expected: [Double] = [0, 1000.0 / 32768, -1, 32767.0 / 32768]
        #expect(f.digiPROSamples(stereo: .mix) == expected)
    }

    @Test func pcm8IsUnsigned() throws {
        let f = try parse(Fx.wav(Fx.fmt(bits: 8), Fx.data([0, 128, 255])))
        #expect(f.info.bytesPerSample == 1 && f.info.numFrames == 3)
        #expect(f.sdsSamples(stereo: .mix) == [-128, 0, 127])
        #expect(f.digiPROSamples(stereo: .mix) == [-1, 0, 127.0 / 128])
    }

    @Test func pcm24Stereo() throws {
        let l = [-3, 8_388_607, -8_388_608, 5], r = [0, 8_388_607, -8_388_607, -6]
        let interleaved = zip(l, r).flatMap { [$0, $1] }
        let f = try parse(Fx.wav(Fx.fmt(channels: 2, rate: 48000, bits: 24), Fx.data(Fx.pcmLE(interleaved, bytes: 3))))
        #expect(f.info.channels == 2 && f.info.numFrames == 4 && f.info.bytesPerSample == 3)
        #expect(f.infoText == "Sample length: 4 Channels: 2 Sample Rate: 48000\nBits: 24 Loop OFF.")
        // SDS: C integer division truncates toward zero ((-3 + 0) / 2 == -1, not -2).
        #expect(f.sdsSamples(stereo: .mix) == [-1, 8_388_607, -8_388_607, 0])
        #expect(f.sdsSamples(stereo: .left) == l.map { Int32($0) })
        #expect(f.sdsSamples(stereo: .right) == r.map { Int32($0) })
        // DigiPRO: (L + R) * 0.5 in Double.
        let s = 2.0 / 16_777_216
        #expect(f.digiPROSamples(stereo: .mix) == zip(l, r).map { (s * Double($0) + s * Double($1)) * 0.5 })
        #expect(f.digiPROSamples(stereo: .left) == l.map { s * Double($0) })
        #expect(f.digiPROSamples(stereo: .right) == r.map { s * Double($0) })
    }

    @Test func pcm12And32Bit() throws {
        // 12 bits in 2 bytes, left-justified: SDS shifts right by 4, DigiPRO scales raw by 2/2^12.
        let f12 = try parse(Fx.wav(Fx.fmt(bits: 12), Fx.data(Fx.pcmLE([0x1230, -16], bytes: 2))))
        #expect(f12.info.bits == 12 && f12.info.bytesPerSample == 2)
        #expect(f12.sdsSamples(stereo: .mix) == [0x123, -1])
        #expect(f12.digiPROSamples(stereo: .mix) == [Double(0x1230) / 2048, -16.0 / 2048])
        // 32-bit PCM: `1 << 32` wraps to 1 in the original, so the DigiPRO scale is 2 (kept).
        let f32 = try parse(Fx.wav(Fx.fmt(channels: 2, bits: 32), Fx.data(Fx.pcmLE([Int(Int32.max), Int(Int32.max), -7, 2], bytes: 4))))
        #expect(f32.info.bits == 32 && f32.info.bytesPerSample == 4)
        #expect(f32.sdsSamples(stereo: .mix) == [Int32.max, -2]) // no Int32 overflow (deviation 9)
        #expect(f32.digiPROSamples(stereo: .left) == [2 * Double(Int32.max), -14])
    }

    @Test func float32AndFloat64() throws {
        let values = [0.5, -1.5, 1.0, Double.nan, -0.25, 0.9999999]
        let expectedSDS: [Int32] = [4_194_304, -8_388_608, 8_388_607, 0, -2_097_152, 8_388_607]
        let expectedDigi = [128.0, -256.0, 2_147_483_392.0 / 8_388_608, 0, -64, 2_147_483_392.0 / 8_388_608]
        let f32 = try parse(Fx.wav(Fx.fmt(tag: 3, bits: 32), Fx.data(Fx.float32LE(values))))
        #expect(f32.info.bits == 24 && f32.info.bytesPerSample == 4 && f32.info.numFrames == 6)
        #expect(f32.infoText == "Sample length: 6 Channels: 1 Sample Rate: 44100\nBits: 24 Loop OFF.")
        #expect(f32.sdsSamples(stereo: .mix) == expectedSDS)
        #expect(f32.digiPROSamples(stereo: .mix) == expectedDigi)
        // float64 is read as doubles (the original read it as float32).
        let f64 = try parse(Fx.wav(Fx.fmt(tag: 3, bits: 64), Fx.data(Fx.float64LE(values))))
        #expect(f64.info.bits == 24 && f64.info.bytesPerSample == 8 && f64.info.numFrames == 6)
        #expect(f64.sdsSamples(stereo: .mix) == expectedSDS)
        #expect(f64.digiPROSamples(stereo: .mix) == expectedDigi)
    }

    @Test func smplLoop() throws {
        let pcm = Fx.data(Fx.pcmLE(Array(0..<40), bytes: 2))
        let f = try parse(Fx.wav(Fx.fmt(), pcm, Fx.smpl(loops: [(1, 10, 20), (0, 0, 5)])))
        #expect(f.info.loopOn && f.info.loopType == 1 && f.info.loopStart == 10 && f.info.loopEnd == 20)
        #expect(f.infoText == "Sample length: 40 Channels: 1 Sample Rate: 44100\nBits: 16 Loop ON. Loop start: 10 Loop end: 20")
        // DigiPRO takes the (inclusive) loop: 11 samples.
        #expect(f.digiPROSamples(stereo: .mix) == (10...20).map { Double($0) / 32768 })
        // dwType 0x7F / 0xFF reads as "off" but the loop points are shown; only the low byte & 0x7F counts.
        let off = try parse(Fx.wav(Fx.fmt(), pcm, Fx.smpl(loops: [(0xFF, 2, 3)])))
        #expect(off.infoText == "Sample length: 40 Channels: 1 Sample Rate: 44100\nBits: 16 Loop OFF. Loop start: 2 Loop end: 3")
        #expect(try parse(Fx.wav(Fx.fmt(), pcm, Fx.smpl(loops: [(0x102, 2, 3)]))).info.loopType == 2)
        // cSampleLoops == 0: no loop.
        #expect(try parse(Fx.wav(Fx.fmt(), pcm, Fx.smpl(loops: []))).infoText.hasSuffix("Loop OFF."))
    }

    @Test func smplBeforeData() throws {
        let pcm = Fx.data(Fx.pcmLE(Array(0..<40), bytes: 2))
        // A non-zero dwSamplePeriod marks the loop as set, so the data chunk keeps it.
        let kept = try parse(Fx.wav(Fx.fmt(), Fx.smpl(period: 22675, loops: [(0, 5, 9)]), pcm))
        #expect(kept.infoText.hasSuffix("Loop ON. Loop start: 5 Loop end: 9"))
        // Period 0: the data chunk resets the loop to the whole file (and type to off), Loop stays on.
        let reset = try parse(Fx.wav(Fx.fmt(), Fx.smpl(period: 0, loops: [(0, 5, 9)]), pcm))
        #expect(reset.infoText.hasSuffix("Loop OFF. Loop start: 0 Loop end: 39"))
        #expect(reset.info.loopOn)
    }

    @Test func fmtRateWins() throws {
        let f = try parse(Fx.wav(Fx.fmt(rate: 48000), Fx.data(Fx.pcmLE([1, 2], bytes: 2)), Fx.smpl(period: 22675, loops: [(0, 0, 1)])))
        #expect(f.info.sampleRate == 48000 && f.info.samplePeriodNs == 20833)
        #expect(try parse(Fx.wav(Fx.fmt(rate: 22050), Fx.data([0, 0]))).info.samplePeriodNs == 45351)
    }

    @Test func oddChunksArePadded() throws {
        // Odd-sized unknown chunk first, odd-sized 8-bit data, then smpl: all found.
        let f = try parse(Fx.wav(Fx.riffChunk("LIST", [1, 2, 3]), Fx.fmt(bits: 8), Fx.data([10, 20, 30]),
                                 Fx.smpl(loops: [(0, 1, 2)])))
        #expect(f.info.numFrames == 3 && f.info.loopOn && f.info.loopStart == 1 && f.info.loopEnd == 2)
        #expect(f.sdsSamples(stereo: .mix) == [-118, -108, -98])
    }

    @Test func riffSizeIsCappedAndLimitsTheWalk() throws {
        let body = Fx.fmt() + Fx.data(Fx.pcmLE([1, 2, 3], bytes: 2))
        var big = Fx.wav(Array(body))
        big.replaceSubrange(4..<8, with: Fx.le32(1_000_000)) // larger than the file: capped
        #expect(try parse(big).info.numFrames == 3)
        // RIFF size that ends before a trailing smpl chunk: the smpl is never reached.
        let withSmpl = Fx.wav(body, Fx.smpl(loops: [(0, 0, 1)]))
        var short = withSmpl
        short.replaceSubrange(4..<8, with: Fx.le32(4 + body.count))
        #expect(try parse(withSmpl).info.loopOn)
        #expect(try !parse(short).info.loopOn)
    }

    @Test func dataBeforeFmtUsesTheFinalFormat() throws {
        let f = try parse(Fx.wav(Fx.data(Fx.pcmLE([1, 2, 3, 4], bytes: 2)), Fx.fmt(channels: 2)))
        #expect(f.info.numFrames == 2 && f.info.loopEnd == 1)
        #expect(f.sdsSamples(stereo: .right) == [2, 4])
    }

    @Test func moreThanTwoChannelsUseChannelZero() throws {
        let f = try parse(Fx.wav(Fx.fmt(channels: 3), Fx.data(Fx.pcmLE([1, 2, 3, 4, 5, 6], bytes: 2))))
        #expect(f.sdsSamples(stereo: .right) == [1, 4])
        let expected: [Double] = [1.0 / 32768, 4.0 / 32768]
        #expect(f.digiPROSamples(stereo: .mix) == expected)
        #expect(!f.canConvertToDigiPRO)
    }

    @Test func loopPastTheEndReadsSilence() throws {
        let f = try parse(Fx.wav(Fx.fmt(), Fx.data(Fx.pcmLE([1, 2, 3, 4, 5], bytes: 2)), Fx.smpl(loops: [(0, 2, 8)])))
        #expect(f.digiPROSamples(stereo: .mix) == [3, 4, 5, 0, 0, 0, 0].map { Double($0) / 32768 })
    }

    @Test func digiPROEnabling() throws {
        func file(loop: (Int, Int)?, frames: Int = 20000, channels: Int = 1) throws -> AudioFile {
            let pcm = Fx.data([UInt8](repeating: 0, count: frames * channels * 2))
            if let loop { return try parse(Fx.wav(Fx.fmt(channels: channels), pcm, Fx.smpl(loops: [(0, loop.0, loop.1)]))) }
            return try parse(Fx.wav(Fx.fmt(channels: channels), pcm))
        }
        #expect(try file(loop: (0, 16383)).canConvertToDigiPRO)
        #expect(try !file(loop: (0, 16384)).canConvertToDigiPRO)
        #expect(try file(loop: (100, 16483)).canConvertToDigiPRO)
        #expect(try file(loop: nil, frames: 16384).canConvertToDigiPRO)
        #expect(try !file(loop: nil, frames: 16385).canConvertToDigiPRO)
        #expect(try file(loop: nil, frames: 16385).digiPROSampleCount == 16384)
        #expect(try file(loop: nil, frames: 100, channels: 2).canConvertToDigiPRO)
        #expect(try !file(loop: nil, frames: 100, channels: 3).canConvertToDigiPRO)
        // Deviation 7: empty files and reversed loops stay disabled.
        #expect(try !file(loop: nil, frames: 0).canConvertToDigiPRO)
        #expect(try !file(loop: (20, 10)).canConvertToDigiPRO)
        #expect(try file(loop: (20, 10)).digiPROSamples(stereo: .mix).isEmpty)
    }

    @Test func errors() {
        let pcm = Fx.data(Fx.pcmLE([1], bytes: 2))
        #expect(parseError(Fx.wav(Fx.fmt(tag: 2), pcm)) == .notPCMOrFloat(.wav))
        #expect(parseError(Fx.wav(Fx.fmt(tag: 0xFFFE), pcm)) == .notPCMOrFloat(.wav))
        var truncated = Fx.wav(Fx.fmt(), Fx.data(Fx.pcmLE(Array(0..<100), bytes: 2)))
        truncated.removeLast(50)
        #expect(parseError(truncated) == .chunkSizeError(.wav))
        #expect(parseError(Fx.wav(Fx.fmt())) == .unknownFormat(.wav))
        #expect(parseError(Fx.wav(pcm)) == .unknownFormat(.wav))
        #expect(parseError(Fx.wav(Fx.fmt(channels: 0), pcm)) == .unknownFormat(.wav))
        #expect(parseError(Fx.wav(Fx.fmt(bits: 0), pcm)) == .notPCMOrFloat(.wav))
        #expect(parseError(Fx.wav(Fx.fmt(bits: 40), pcm)) == .notPCMOrFloat(.wav))
        #expect(parseError(Array("RIFF\u{0}\u{0}\u{0}\u{0}WAV".utf8)) == .notAudio)
        #expect(parseError(Array("RIFF\u{0}\u{0}\u{0}\u{0}AVI LIST".utf8)) == .notAudio)
        // RIFF size with the top bit set is negative in the original's signed compare.
        var negative = Fx.wav(Fx.fmt(), pcm)
        negative.replaceSubrange(4..<8, with: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(parseError(negative) == .chunkSizeError(.wav))
        // A chunk size near 2^32 does not wrap around.
        var huge = Fx.wav(Fx.fmt(), Fx.riffChunk("junk", [0, 0]), pcm)
        huge.replaceSubrange((12 + 24 + 4)..<(12 + 24 + 8), with: [0xF8, 0xFF, 0xFF, 0xFF])
        #expect(parseError(huge) == .chunkSizeError(.wav))
    }

    @Test func errorStrings() {
        #expect(AudioFileError.notAudio.description == "Unknown Wave Format")
        #expect(AudioFileError.unknownFormat(.wav).description == "Unknown Wave Format")
        #expect(AudioFileError.unknownFormat(.aiff).description == "Unknown AIFF\tFormat")
        #expect(AudioFileError.unknownFormat(.aifc).description == "Unknown AIFC\tFormat")
        #expect(AudioFileError.chunkSizeError(.wav).description == "Wave: Chunk size error")
        #expect(AudioFileError.chunkSizeError(.aiff).description == "AIFF: Chunk size error")
        #expect(AudioFileError.chunkSizeError(.aifc).description == "AIFC: Chunk size error")
        #expect(AudioFileError.notPCMOrFloat(.wav).description == "Wave: Not PCM or Float")
        #expect(AudioFileError.notPCMOrFloat(.aiff).description == "AIFF: Not PCM or Float")
        #expect(AudioFileError.notPCMOrFloat(.aifc).description == "AIFC: Not PCM or Float")
        #expect(AudioFile.describe(Fx.wav(Fx.fmt(tag: 2))) == "Wave: Not PCM or Float")
        #expect(AudioFile.describe(Fx.wav(Fx.fmt(), Fx.data([0, 0]))) == "Sample length: 1 Channels: 1 Sample Rate: 44100\nBits: 16 Loop OFF.")
    }

    @Test func contentsOfURL() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("c6-audio-\(UUID().uuidString).aif")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(Fx.wav(Fx.fmt(), Fx.data(Fx.pcmLE([5, 6], bytes: 2)))).write(to: url)
        let f = try AudioFile(contentsOf: url) // detected by content, not by the .aif extension
        #expect(f.info.container == .wav && f.sdsSamples(stereo: .mix) == [5, 6])
    }
}

@Suite struct AudioFileAIFFTests {
    static let pcm3000 = Fx.pcmBE((0..<3000).map { ($0 * 13) % 2000 - 1000 }, bytes: 2)

    @Test func pcm16WithSustainLoop() throws {
        let f = try parse(Fx.form("AIFF", Fx.comm(frames: 3000, bits: 16), Fx.ssnd(Self.pcm3000), Fx.inst(),
                                  Fx.mark([(1, 1000, "beg"), (2, 1512, "end")])))
        #expect(f.info == AudioFile.Info(container: .aiff, channels: 1, sampleRate: 44100, bits: 16, bytesPerSample: 2,
                                         numFrames: 3000, loopStart: 1000, loopEnd: 1512, loopOn: true, loopType: 0,
                                         samplePeriodNs: 22676))
        #expect(f.infoText == "Sample length: 3000 Channels: 1 Sample Rate: 44100\nBits: 16 Loop ON. Loop start: 1000 Loop end: 1512")
        // The end marker is treated as inclusive: one sample more than the AIFF loop (kept).
        let s = f.digiPROSamples(stereo: .mix)
        #expect(s.count == 513)
        #expect(s.first == Double((1000 * 13) % 2000 - 1000) / 32768 && s.last == Double((1512 * 13) % 2000 - 1000) / 32768)
        #expect(f.sdsSamples(stereo: .mix).prefix(3) == [-1000, -987, -974])
    }

    @Test func signedSamples() throws {
        let f8 = try parse(Fx.form("AIFF", Fx.comm(frames: 3, bits: 8), Fx.ssnd([0x80, 0x00, 0x7F])))
        #expect(f8.sdsSamples(stereo: .mix) == [-128, 0, 127])
        #expect(f8.digiPROSamples(stereo: .mix) == [-1, 0, 127.0 / 128])
        let f20 = try parse(Fx.form("AIFF", Fx.comm(channels: 2, frames: 1, bits: 20), Fx.ssnd(Fx.pcmBE([-16 << 4, 7 << 4], bytes: 3))))
        #expect(f20.info.bytesPerSample == 3)
        #expect(f20.sdsSamples(stereo: .mix) == [-4] && f20.sdsSamples(stereo: .left) == [-16])
    }

    @Test func chunkOrderQuirks() throws {
        let comm = Fx.comm(frames: 3000, bits: 16), ssnd = Fx.ssnd(Self.pcm3000)
        let inst = Fx.inst(), mark = Fx.mark([(1, 1000, "beg"), (2, 1512, "end")])
        // INST + MARK before SSND: SSND resets the points to the whole file, Loop stays ON.
        let early = try parse(Fx.form("AIFF", comm, inst, mark, ssnd))
        #expect(early.infoText.hasSuffix("Loop ON. Loop start: 0 Loop end: 2999"))
        // MARK before INST is ignored.
        let markFirst = try parse(Fx.form("AIFF", comm, ssnd, mark, inst))
        #expect(markFirst.infoText.hasSuffix("Bits: 16 Loop OFF."))
        #expect(!markFirst.info.loopOn && markFirst.info.loopEnd == 2999)
        // A second INST after MARK looks the points up in the marker table.
        let again = try parse(Fx.form("AIFF", comm, ssnd, inst, mark, Fx.inst(begin: 2, end: 1)))
        #expect(again.info.loopStart == 1512 && again.info.loopEnd == 1000)
    }

    @Test func playModes() throws {
        func file(_ mode: Int) throws -> AudioFile {
            try parse(Fx.form("AIFF", Fx.comm(frames: 3000, bits: 16), Fx.ssnd(Self.pcm3000), Fx.inst(playMode: mode),
                              Fx.mark([(1, 10, "beg"), (2, 20, "end")])))
        }
        #expect(try file(1).infoText.hasSuffix("Loop ON. Loop start: 10 Loop end: 20"))
        #expect(try file(0).infoText.hasSuffix("Loop OFF. Loop start: 10 Loop end: 20"))
        #expect(try file(2).info.loopType == 0x7F) // forward/backward is not mapped (kept)
    }

    @Test func markerNamePadByteIsNotSkipped() throws {
        // An empty marker name is 1 count byte + 1 pad byte; C6 skips only 7 + count bytes, so the
        // next marker is misread and the loop end keeps its whole-file default (kept quirk).
        let f = try parse(Fx.form("AIFF", Fx.comm(frames: 3000, bits: 16), Fx.ssnd(Self.pcm3000), Fx.inst(),
                                  Fx.mark([(1, 100, ""), (2, 500, "end")])))
        #expect(f.info.loopStart == 100 && f.info.loopEnd == 2999 && f.info.loopOn)
        // Odd-length names (count + name even) need no pad and parse correctly.
        let ok = try parse(Fx.form("AIFF", Fx.comm(frames: 3000, bits: 16), Fx.ssnd(Self.pcm3000), Fx.inst(),
                                   Fx.mark([(1, 100, "a"), (2, 500, "end")])))
        #expect(ok.info.loopStart == 100 && ok.info.loopEnd == 500)
    }

    @Test func outOfRangeMarkerIDsDoNotCrash() throws {
        let f = try parse(Fx.form("AIFF", Fx.comm(frames: 3000, bits: 16), Fx.ssnd(Self.pcm3000),
                                  Fx.inst(begin: 300, end: 0xFFFF), Fx.mark([(300, 7, "abc"), (0xFFFF, 9, "abc")]),
                                  Fx.inst(begin: 400, end: 0x8000)))
        #expect(f.info.loopStart == 7 && f.info.loopEnd == 9 && f.info.loopOn)
        // A MARK count larger than the data stops at the end of the buffer.
        var mark = Fx.mark([(1, 5, "abc")])
        mark.replaceSubrange(8..<10, with: Fx.be16(60000))
        let g = try parse(Fx.form("AIFF", Fx.comm(frames: 3000, bits: 16), Fx.ssnd(Self.pcm3000), Fx.inst(), mark))
        #expect(g.info.loopStart == 5)
    }

    @Test func sampleRates() throws {
        func rate(_ ext: [UInt8]) throws -> AudioFile.Info {
            try parse(Fx.form("AIFF", Fx.comm(frames: 1, bits: 16, rate: ext), Fx.ssnd([0, 0]))).info
        }
        #expect(try rate(Fx.ext80(44100)).sampleRate == 44100)
        #expect(try rate(Fx.ext80(48000)).sampleRate == 48000)
        #expect(try rate(Fx.ext80(96000)).sampleRate == 96000)
        #expect(try rate(Fx.ext80(8000)).sampleRate == 8000)
        // 22050.5 Hz: the fraction is truncated.
        #expect(try rate([0x40, 0x0D, 0xAC, 0x45, 0, 0, 0, 0, 0, 0]).sampleRate == 22050)
        // The original writer's missing 0x40 exponent byte still parses (the shift count is masked).
        #expect(try rate([0x00, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0]).sampleRate == 44100)
        let zero = try rate([UInt8](repeating: 0, count: 10))
        #expect(zero.sampleRate == 0 && zero.samplePeriodNs == 0)
        #expect(try rate([0x7F, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 0]).sampleRate == Int(Int32.min)) // 1e88 → cvttsd2si
    }

    @Test func oddChunkSizes() throws {
        // 8-bit SSND with an odd payload, then an odd unknown chunk, then INST/MARK.
        let f = try parse(Fx.form("AIFF", Fx.comm(frames: 3, bits: 8), Fx.ssnd([1, 2, 3]), Fx.iffChunk("APPL", [9]),
                                  Fx.inst(), Fx.mark([(1, 0, "beg"), (2, 2, "end")])))
        #expect(f.info.numFrames == 3 && f.info.loopOn && f.info.loopEnd == 2)
        #expect(f.sdsSamples(stereo: .mix) == [1, 2, 3])
    }

    @Test func errors() {
        let pcm = Fx.ssnd([0, 0])
        var truncated = Fx.form("AIFF", Fx.comm(frames: 3000, bits: 16), Fx.ssnd(Self.pcm3000))
        truncated.removeLast(10)
        #expect(parseError(truncated) == .chunkSizeError(.aiff))
        #expect(parseError(Fx.form("AIFF", pcm)) == .unknownFormat(.aiff))
        #expect(parseError(Fx.form("AIFF", Fx.comm(frames: 1, bits: 16))) == .unknownFormat(.aiff))
        #expect(parseError(Fx.form("AIFF", Fx.comm(frames: 1, bits: 40), pcm)) == .notPCMOrFloat(.aiff))
        #expect(parseError(Fx.form("AIFC", Fx.fver, Fx.comm(frames: 1, bits: 16, compression: "twos"), pcm)) == .notPCMOrFloat(.aifc))
        #expect(parseError(Fx.form("AIFC", Fx.fver, Fx.comm(frames: 1, bits: 16, compression: "NONE"))) == .unknownFormat(.aifc))
        var aifc = Fx.form("AIFC", Fx.fver, Fx.comm(frames: 1, bits: 16, compression: "NONE"), pcm)
        aifc.removeLast()
        #expect(parseError(aifc) == .chunkSizeError(.aifc))
        #expect(parseError(Array("FORM\u{0}\u{0}\u{0}\u{4}8SVX".utf8)) == .notAudio)
        #expect(AudioFile.describe(truncated) == "AIFF: Chunk size error")
    }
}

@Suite struct AudioFileAIFCTests {
    static let l = [-32768, -3, 100, 32767], r = [0, 0, -101, 32767]
    static var interleaved: [Int] { zip(l, r).flatMap { [$0, $1] } }
    static var reference: AudioFile {
        get throws { try parse(Fx.wav(Fx.fmt(channels: 2), Fx.data(Fx.pcmLE(interleaved, bytes: 2)))) }
    }

    private func expectSameSamples(_ f: AudioFile, _ g: AudioFile) {
        for mode in C6Item.StereoMode.allCases {
            #expect(f.sdsSamples(stereo: mode) == g.sdsSamples(stereo: mode))
            #expect(f.digiPROSamples(stereo: mode) == g.digiPROSamples(stereo: mode))
        }
    }

    @Test func noneReadsLikeAIFF() throws {
        let pcm = Fx.ssnd(Fx.pcmBE(Self.interleaved, bytes: 2))
        let aifc = try parse(Fx.form("AIFC", Fx.fver, Fx.comm(channels: 2, frames: 4, bits: 16, compression: "NONE"), pcm))
        let aiff = try parse(Fx.form("AIFF", Fx.comm(channels: 2, frames: 4, bits: 16), pcm))
        #expect(aifc.info.container == .aifc && aifc.canConvertToDigiPRO)
        #expect(aifc.infoText == "Sample length: 4 Channels: 2 Sample Rate: 44100\nBits: 16 Loop OFF.")
        expectSameSamples(aifc, aiff)
        expectSameSamples(aifc, try Self.reference)
        #expect(aifc.digiPROSamples(stereo: .left) == Self.l.map { Double($0) / 32768 }) // fix: not uninitialised
    }

    @Test func sowtIsLittleEndian() throws {
        let f = try parse(Fx.form("AIFC", Fx.fver, Fx.comm(channels: 2, frames: 4, bits: 16, compression: "sowt"),
                                  Fx.ssnd(Fx.pcmLE(Self.interleaved, bytes: 2))))
        expectSameSamples(f, try Self.reference) // fix: the original sent silence
        let s8 = try parse(Fx.form("AIFC", Fx.fver, Fx.comm(frames: 2, bits: 8, compression: "sowt"), Fx.ssnd([0xFF, 0x01])))
        #expect(s8.sdsSamples(stereo: .mix) == [-1, 1])
    }

    @Test func floats() throws {
        let values = [0.5, -1.5, 1.0, Double.nan, -0.25]
        let wav = try parse(Fx.wav(Fx.fmt(tag: 3, bits: 32), Fx.data(Fx.float32LE(values))))
        let fl32 = try parse(Fx.form("AIFC", Fx.fver, Fx.comm(frames: 5, bits: 32, compression: "fl32"), Fx.ssnd(Fx.float32BE(values))))
        let fl64 = try parse(Fx.form("AIFC", Fx.fver, Fx.comm(frames: 5, bits: 64, compression: "fl64"), Fx.ssnd(Fx.float64BE(values))))
        #expect(fl32.info.bits == 24 && fl32.info.bytesPerSample == 4 && fl32.info.numFrames == 5)
        #expect(fl64.info.bits == 24 && fl64.info.bytesPerSample == 8 && fl64.info.numFrames == 5)
        #expect(fl64.infoText == "Sample length: 5 Channels: 1 Sample Rate: 44100\nBits: 24 Loop OFF.")
        expectSameSamples(fl32, wav)
        expectSameSamples(fl64, wav)
    }

    @Test func loops() throws {
        let f = try parse(Fx.form("AIFC", Fx.fver, Fx.comm(frames: 3000, bits: 16, compression: "NONE"),
                                  Fx.ssnd(AudioFileAIFFTests.pcm3000), Fx.inst(), Fx.mark([(1, 10, "beg"), (2, 20, "end")])))
        #expect(f.infoText == "Sample length: 3000 Channels: 1 Sample Rate: 44100\nBits: 16 Loop ON. Loop start: 10 Loop end: 20")
        #expect(f.digiPROSamples(stereo: .mix).count == 11)
    }
}

@Suite struct AudioWriterTests {
    @Test func wavLayout() {
        let b = AudioWriter.wav(samples: [1, -2], bits: 16, sampleRate: 44100)
        #expect(b == Fx.tag("RIFF") + Fx.le32(40) + Fx.tag("WAVEfmt ") + Fx.le32(16) + Fx.le16(1) + Fx.le16(1)
                + Fx.le32(44100) + Fx.le32(88200) + Fx.le16(2) + Fx.le16(16) + Fx.tag("data") + Fx.le32(4) + [1, 0, 0xFE, 0xFF])
        let looped = AudioWriter.wav(samples: [1, 2, 3], bits: 8, sampleRate: 1000, loop: (start: 0, end: 2, type: 0))
        // 3 bytes of data + pad, then a 60-byte smpl chunk.
        #expect(looped.count == 12 + 24 + 8 + 4 + 8 + 60)
        #expect(Array(looped[48..<52]) == Fx.tag("smpl") && Array(looped[52..<56]) == Fx.le32(60))
        #expect(Array(looped[(56 + 8)..<(56 + 16)]) == Fx.le32(1_000_000) + Fx.le32(60)) // period, unity note
    }

    @Test func aiffLayout() {
        let b = AudioWriter.aiff(samples: [1, -2], bits: 16, sampleRate: 44100)
        let comm = Fx.tag("COMM") + Fx.be32(18) + Fx.be16(1) + Fx.be32(2) + Fx.be16(16)
            + [0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0] // with the 0x40 the original omitted
        let ssnd = Fx.tag("SSND") + Fx.be32(12) + Fx.be32(0) + Fx.be32(0) + [0, 1, 0xFF, 0xFE]
        #expect(b == Fx.tag("FORM") + Fx.be32(4 + comm.count + ssnd.count) + Fx.tag("AIFF") + comm + ssnd)
        #expect(AudioWriter.extended80(48000) == [0x40, 0x0E, 0xBB, 0x80, 0, 0, 0, 0, 0, 0])
        #expect(AudioWriter.extended80(1) == [0x3F, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 0])
        #expect(AudioWriter.extended80(0) == [UInt8](repeating: 0, count: 10))
        for rate in [8000, 22050, 32000, 44100, 96000, 192_000] { #expect(AudioWriter.extended80(rate) == Fx.ext80(rate)) }
    }

    /// Signed `bits`-wide test samples covering both extremes.
    static func samples(bits: Int, count: Int = 300) -> [Int32] {
        let lo = -(1 << (bits - 1)), hi = (1 << (bits - 1)) - 1
        return (0..<count).map { k in Int32(k == 0 ? lo : k == 1 ? hi : (k * 7919) % (hi - lo + 1) + lo) }
    }

    @Test(arguments: [8, 12, 14, 16, 20, 24, 28])
    func wavRoundTrip(bits: Int) throws {
        let s = Self.samples(bits: bits)
        let f = try AudioFile(bytes: AudioWriter.wav(samples: s, bits: bits, sampleRate: 44100, loop: (start: 10, end: 199, type: 0)))
        let container = 8 * ((bits - 1) / 8 + 1)
        #expect(f.info == AudioFile.Info(container: .wav, channels: 1, sampleRate: 44100, bits: container,
                                         bytesPerSample: container / 8, numFrames: 300, loopStart: 10, loopEnd: 199,
                                         loopOn: true, loopType: 0, samplePeriodNs: 22676))
        // WAV stores the container size as bitsPerSample, so values come back left-justified.
        #expect(f.sdsSamples(stereo: .mix) == s.map { $0 << Int32(container - bits) })
    }

    @Test(arguments: [8, 12, 14, 16, 20, 24, 28])
    func aiffRoundTrip(bits: Int) throws {
        let s = Self.samples(bits: bits, count: 301)
        let f = try AudioFile(bytes: AudioWriter.aiff(samples: s, bits: bits, sampleRate: 48000, loop: (start: 10, end: 199, type: 0)))
        #expect(f.info == AudioFile.Info(container: .aiff, channels: 1, sampleRate: 48000, bits: bits,
                                         bytesPerSample: (bits - 1) / 8 + 1, numFrames: 301, loopStart: 10, loopEnd: 199,
                                         loopOn: true, loopType: 0, samplePeriodNs: 20833))
        #expect(f.sdsSamples(stereo: .mix) == s)
        #expect(f.infoText == "Sample length: 301 Channels: 1 Sample Rate: 48000\nBits: \(bits) Loop ON. Loop start: 10 Loop end: 199")
    }

    @Test func loopTypes() throws {
        let s = Self.samples(bits: 16, count: 50)
        let alt = try AudioFile(bytes: AudioWriter.wav(samples: s, bits: 16, sampleRate: 44100, loop: (start: 1, end: 40, type: 1)))
        #expect(alt.info.loopOn && alt.info.loopType == 1)
        for fmt in [AudioFormat.wav, .aiff] {
            let off = try AudioFile(bytes: AudioWriter.write(fmt, samples: s, bits: 16, sampleRate: 44100, loop: (start: 1, end: 40, type: 0x7F)))
            #expect(!off.info.loopOn && off.info.loopStart == 0 && off.info.loopEnd == 49)
            let none = try AudioFile(bytes: AudioWriter.write(fmt, samples: s, bits: 16, sampleRate: 44100))
            #expect(none.infoText.hasSuffix("Loop OFF.") && none.sdsSamples(stereo: .mix) == s)
        }
        // AIFF alternating loop: written as play mode 2, which C6's reader leaves at 0x7F.
        let aiffAlt = try AudioFile(bytes: AudioWriter.aiff(samples: s, bits: 16, sampleRate: 44100, loop: (start: 1, end: 40, type: 1)))
        #expect(aiffAlt.info.loopOn && aiffAlt.info.loopType == 0x7F && aiffAlt.info.loopEnd == 40)
    }

    @Test func emptyAndOddSizes() throws {
        for fmt in [AudioFormat.wav, .aiff] {
            let empty = try AudioFile(bytes: AudioWriter.write(fmt, samples: [], bits: 16, sampleRate: 44100))
            #expect(empty.info.numFrames == 0 && !empty.canConvertToDigiPRO)
            let odd = AudioWriter.write(fmt, samples: [1, 2, 3], bits: 24, sampleRate: 44100, loop: (start: 0, end: 2, type: 0))
            #expect(odd.count % 2 == 0)
            let f = try AudioFile(bytes: odd)
            #expect(f.info.numFrames == 3 && f.info.loopOn && f.info.loopEnd == 2)
        }
    }
}
