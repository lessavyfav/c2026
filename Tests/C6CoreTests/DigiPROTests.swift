@testable import C6Core
import CryptoKit
import Foundation
import Testing

/// Golden vectors from `tools/golden_swift.py` / `tools/golden_swift_files.py` (run with
/// `python3 -I`): SHA-256 of the 7027-byte message from `digipro_ref.py` in its original mode
/// and with `fixed=True`. The first five are the vectors of spec §13.
enum DigiPROFixture {
    struct Vector: Sendable, CustomTestStringConvertible {
        let kind: String, n: Int, slot: Int, name: String, original: String, fixed: String
        init(_ kind: String, _ n: Int, _ slot: Int, _ name: String, original: String, fixed: String) {
            self.kind = kind; self.n = n; self.slot = slot; self.name = name; self.original = original; self.fixed = fixed
        }
        var testDescription: String { "\(kind)\(n)" }
        var samples: [Double] { DigiPROFixture.signal(kind, n) }
    }

    /// Same doubles as `sig()` in the Python scripts.
    static func signal(_ kind: String, _ n: Int) -> [Double] {
        switch kind {
        case "saw": return (0..<n).map { (Double($0) / Double(n)) * 2 - 1 }
        case "sin": return (0..<n).map { sin(2 * Double.pi * Double($0) / Double(n)) }
        case "sq": return (0..<n).map { $0 < n / 2 ? 1.0 : -1.0 }
        case "mix": return (0..<n).map { sin(2 * Double.pi * Double($0) / Double(n)) + 0.5 * sin(2 * Double.pi * 7 * Double($0) / Double(n)) }
        case "pcm":
            var x = 12345
            return (0..<n).map { _ in
                x = (x * 1_103_515_245 + 12345) & 0x7FFF_FFFF
                return Double((x >> 8) % 65536 - 32768) / 32768.0
            }
        default: fatalError(kind)
        }
    }

    static let vectors: [Vector] = [
        .init("saw", 600, 0, "SAW ", original: "b6e48e6fc796d9cdee6045f363b9989f7b1074c1f18e1b24a20c10f825965b6e",
              fixed: "d55f9b90b72e1560ddee73ca772785ce30f8ef8ab6c16c0eb9763e59597ebd49"),
        .init("sin", 1024, 0, "SINE", original: "b26693609137b206f2b5ad1210a48f3fc6cd62fd34f590cd4c15e75624bdd19a",
              fixed: "b26693609137b206f2b5ad1210a48f3fc6cd62fd34f590cd4c15e75624bdd19a"),
        .init("saw", 1000, 3, "S1K ", original: "1517d5731c0b8aaecb6a9c44076a3d55eb5ba4b8ad89bdf83136558d9270d770",
              fixed: "d0b5801f66418e3220f860f410fea8018bf89a171efbe159a4fc209cb5ed5965"),
        .init("mix", 1500, 63, "MIX ", original: "bd6c6d679b80db5af0087725f49eff5d00cfda614d72e73ea339310ea61e3a2f",
              fixed: "bd6c6d679b80db5af0087725f49eff5d00cfda614d72e73ea339310ea61e3a2f"),
        .init("sq", 2048, 1, "SQR ", original: "0198efb637d3dcf71791170a9331d9ef1693644601c9727e3d64ed365620425b",
              fixed: "0198efb637d3dcf71791170a9331d9ef1693644601c9727e3d64ed365620425b"),
        .init("saw", 1, 2, "ONE ", original: "ee4b301b298a76e1ebf045776d752a9164e9f87b36a322b5c1b1d2e94ed75ced",
              fixed: "ee4b301b298a76e1ebf045776d752a9164e9f87b36a322b5c1b1d2e94ed75ced"),
        .init("pcm", 2, 4, "TWO ", original: "c1f15881d2a1dfe9b4b6ce20d02013b8374b391827d630c9140eb8d616ff0209",
              fixed: "c1f15881d2a1dfe9b4b6ce20d02013b8374b391827d630c9140eb8d616ff0209"),
        .init("pcm", 3, 5, "THR ", original: "aab45e343d5b32ffccaebd82b5f91eabc501655f4e1a82299562240118a4966a",
              fixed: "aab45e343d5b32ffccaebd82b5f91eabc501655f4e1a82299562240118a4966a"),
        .init("sq", 512, 6, "Q512", original: "7dbf771a60002a9978cfd3573a8587e50f87de2b9fb43951838afe12599e9d4e",
              fixed: "7dbf771a60002a9978cfd3573a8587e50f87de2b9fb43951838afe12599e9d4e"),
        .init("saw", 683, 7, "S683", original: "3acd45ad3f0ddb2de296666f96b1c0467f9d8dc9e97389c1c14251df1edbe0f5",
              fixed: "c8b55a11b2a2c24ec330ef60e49f8d2036cef137abee29816b19540e792ca223"),
        .init("pcm", 684, 8, "P684", original: "c52bbf5c05dfe813ef55f5ad8b1d7a7b1b3246de122e8da2ebcdd9c10179b5cc",
              fixed: "33b0cf80d382ea761364330721690a166f102914d2c7225b16c8ad7fa5562dca"),
        .init("sq", 1023, 9, "Q1K-", original: "98d1adc94ae5c086e6dc14de8606569e2b459d858f4e921afc62f23d54cfca8b",
              fixed: "5f03f92abb00713797593becc074dabd25f074ad70ec5324aa94b459c9bcb4f0"),
        .init("pcm", 4096, 10, "P4K ", original: "e31af66b8b4c32a05ffd31bbe4a4c22e9ace539a55de4f1a16e87618dfa23125",
              fixed: "e31af66b8b4c32a05ffd31bbe4a4c22e9ace539a55de4f1a16e87618dfa23125"),
        .init("saw", 8192, 11, "S8K ", original: "006914e132739e4661e2bf0a657f74e53f3cba5bef694bddcb07a06066d37a5c",
              fixed: "006914e132739e4661e2bf0a657f74e53f3cba5bef694bddcb07a06066d37a5c"),
        .init("pcm", 8193, 12, "P8K1", original: "5b5b1ad3bb318054e9da346f6443aa2f502bbc91496a24826c2267b04a45a606",
              fixed: "93ea6a7d5e0cdb74a085f23d15ca090d06e69b894fb3b95c031e65ebb8ce0873"),
        .init("sin", 10000, 13, "S10K", original: "95b36a508761d9a6817f846983d5952363441296d5e8cb5bcfa16670184c59bf",
              fixed: "257ab34429e4cbd1c8d8395b676a5222f309a37869b489d5474ccf3ef57b7046"),
        .init("saw", 16383, 14, "S16-", original: "363afcf2f9642677370d995aba9dc8766f05f1a6699b2fcb1d540e1bae453e5b",
              fixed: "ddcf7aa9581f489a642dd93cf41fb1e5a9b736174d7e6ea38724eb35cd1aeac7"),
        .init("pcm", 16384, 15, "P16K", original: "119c1918ea07869fb2b4051b2d3319f4e9959694a97ccbe6c9450cd723dc6021",
              fixed: "119c1918ea07869fb2b4051b2d3319f4e9959694a97ccbe6c9450cd723dc6021"),
    ]

    static func sha256(_ b: [UInt8]) -> String {
        SHA256.hash(data: Data(b)).map { String(format: "%02x", $0) }.joined()
    }
}

private typealias DFx = DigiPROFixture

@Suite struct DigiPROEncoderTests {
    @Test(arguments: DigiPROFixture.vectors)
    func goldenVectors(_ v: DigiPROFixture.Vector) {
        let x = v.samples
        let original = DigiPRO.encode(samples: x, slot: v.slot, name: v.name, mode: .original)
        let fixed = DigiPRO.encode(samples: x, slot: v.slot, name: v.name)
        #expect(DFx.sha256(original) == v.original)
        #expect(DFx.sha256(fixed) == v.fixed)
        #expect(original.count == 7027 && fixed.count == 7027)
        #expect(DigiPRO.isValid(original) && DigiPRO.isValid(fixed))
    }

    /// Spec §13 decoded words and checksum bytes (original mode).
    @Test func decodedSpecVectors() throws {
        let sine = DigiPRO.encode(samples: DFx.signal("sin", 1024), slot: 0, name: "SINE", mode: .original)
        let d = try #require(DigiPRO.Dump(sine))
        #expect(Array(d.mainTable.prefix(6)) == [0, 19, 38, 57, 76, 95])
        #expect(Array(d.quarterTable.prefix(3)) == [0, 38, 76])
        #expect(d.mainTable.count == 2044 && d.quarterTable.count == 1022 && d.quarterTable.suffix(2) == [0, 0])
        #expect(Array(sine[0x1B6E...0x1B6F]) == [0x71, 0x3A])
        // A full-scale sine ends at about 32767 · T[2] / T[1023] ≈ 3106 in E1024.
        #expect(d.mainTable.prefix(1024).max() == 3106)

        let saw = try #require(DigiPRO.Dump(DigiPRO.encode(samples: DFx.signal("saw", 600), slot: 0, name: "SAW ", mode: .original)))
        #expect(Array(saw.mainTable.prefix(6)) == [-3275, -3495, -1869, -2110, -3002, -2510])
        #expect(Array(saw.quarterTable.prefix(3)) == [-1279, -3182, -2990])
        let sq = DigiPRO.encode(samples: DFx.signal("sq", 2048), slot: 1, name: "SQR ", mode: .original)
        #expect(Array(sq[0x1B6E...0x1B6F]) == [0x17, 0x42])
        #expect(Array(try #require(DigiPRO.Dump(sq)).mainTable.prefix(3)) == [1864, 4051, 1712])
    }

    @Test func framing() throws {
        let msg = DigiPRO.encode(samples: DFx.signal("saw", 600), slot: 64 + 5, name: "Ab\u{C5}")
        #expect(Array(msg[0..<9]) == [0xF0, 0x00, 0x20, 0x3C, 0x03, 0x00, 0x5D, 0x01, 0x01])
        #expect(msg[9] == 5)
        #expect(Array(msg[10..<14]) == [0x41, 0x62, 0x45, 0x20]) // 0xC5 & 0x7F, space padded
        #expect(Array(msg[0x1B70...]) == [0x36, 0x69, 0xF7])
        #expect(msg[14..<0x1B72].allSatisfy { $0 < 0x80 })
        let d = try #require(DigiPRO.Dump(msg))
        #expect(d.slot == 5 && d.name == "AbE " && d.isValid)
        // The position byte is not covered by the checksum.
        let other = DigiPRO.encode(samples: DFx.signal("saw", 600), slot: 6, name: "Ab\u{C5}")
        #expect((0..<7027).filter { msg[$0] != other[$0] } == [9])
    }

    /// C6's own recognizer accepts the output (the generator/checker range difference is moot).
    @Test func recognizedAsDigiPROWave() {
        let msg = DigiPRO.encode(samples: DFx.signal("sin", 1024), slot: 0, name: "SINE")
        #expect(SysExRecognizer.typeString(msg) == "MM")
        #expect(SysExRecognizer.describe(msg) == "\nDigiPRO waveform at position 1")
        #expect(SysExRecognizer.describe(DigiPRO.encode(samples: [1, 2, 3], slot: 41, name: "X")) == "\nDigiPRO waveform at position 42")
        var broken = msg
        broken[500] ^= 0x01
        #expect(!DigiPRO.isValid(broken) && DigiPRO.Dump(broken)?.isValid == false)
        #expect(SysExRecognizer.describe(broken) == "\nDigiPRO waveform (broken)")
        #expect(DigiPRO.Dump(Array(msg.prefix(7000))) == nil)
    }

    @Test func inputLength() {
        #expect(DigiPRO.encode(samples: [], slot: 0, name: "") == DigiPRO.encode(samples: [0.5], slot: 0, name: ""))
        let long = DFx.signal("pcm", 17000)
        #expect(DigiPRO.encode(samples: long, slot: 0, name: "L") == DigiPRO.encode(samples: Array(long.prefix(16384)), slot: 0, name: "L"))
        // A constant input is silence after DC removal: every table word is 0.
        let silent = DigiPRO.Dump(DigiPRO.encode(samples: [Double](repeating: 0.3, count: 777), slot: 0, name: ""))
        #expect(silent?.mainTable.allSatisfy { $0 == 0 } == true && silent?.quarterTable.allSatisfy { $0 == 0 } == true)
    }

    /// The fixes in action: one band-limited period gives the same tables at any length in
    /// `.fixed`, while the original corrupts N = 684…1023 and non-power-of-two N > 8192.
    @Test func fixedModeIsLengthIndependent() throws {
        func words(_ x: [Double], _ mode: DigiPRO.Mode) throws -> [Int] {
            let d = try #require(DigiPRO.Dump(DigiPRO.encode(samples: x, slot: 0, name: "T", mode: mode)))
            return (d.mainTable + d.quarterTable).map(Int.init)
        }
        func maxDiff(_ a: [Int], _ b: [Int]) -> Int { zip(a, b).map { abs($0 - $1) }.max() ?? 0 }
        func tone(_ n: Int) -> [Double] {
            (0..<n).map { sin(2 * Double.pi * Double($0) / Double(n)) + 0.5 * cos(2 * Double.pi * 490 * Double($0) / Double(n)) }
        }
        func cosine(_ n: Int) -> [Double] { (0..<n).map { cos(2 * Double.pi * Double($0) / Double(n)) } }

        let tone2000 = try words(tone(2000), .fixed)
        #expect(maxDiff(try words(tone(1000), .fixed), tone2000) <= 1)
        #expect(maxDiff(try words(tone(1024), .fixed), tone2000) <= 1)
        #expect(maxDiff(try words(tone(1000), .original), tone2000) > 1000)

        let cos1024 = try words(cosine(1024), .fixed)
        #expect(maxDiff(try words(cosine(10000), .fixed), cos1024) <= 1)
        #expect(maxDiff(try words(cosine(12345), .fixed), cos1024) <= 1)
        #expect(maxDiff(try words(cosine(10000), .original), cos1024) > 1000)
    }
}

@Suite struct DigiPROFFTTests {
    /// Naive DFT of a few bins.
    private func dft(_ re: [Double], _ im: [Double], bins: [Int]) -> [(Double, Double)] {
        let n = re.count
        return bins.map { k in
            var sr = 0.0, si = 0.0
            for j in 0..<n {
                let a = -2 * Double.pi * Double((k * j) % n) / Double(n)
                sr += re[j] * cos(a) - im[j] * sin(a)
                si += re[j] * sin(a) + im[j] * cos(a)
            }
            return (sr, si)
        }
    }

    @Test(arguments: [4, 8, 1024, 3, 12, 1000, 1500, 10000, 16383])
    func fixedTransformMatchesDFT(n: Int) {
        var x = 7
        func rnd() -> Double { x = (x * 1_103_515_245 + 12345) & 0x7FFF_FFFF; return Double(x) / Double(0x4000_0000) - 1 }
        let re0 = (0..<n).map { _ in rnd() }, im0 = (0..<n).map { _ in rnd() }
        var re = re0 + [Double](repeating: 0, count: max(0, 4 - n)), im = im0 + [Double](repeating: 0, count: max(0, 4 - n))
        DigiPRO.FFT.transform(&re, &im, n, inverse: false, fixed: true)
        let bins = Array(Set([0, 1, 2, n / 3, n / 2, n - 1].filter { $0 < n })).sorted()
        for (k, (r, i)) in zip(bins, dft(re0, im0, bins: bins)) {
            #expect(abs(re[k] - r) < 1e-8 * Double(n) && abs(im[k] - i) < 1e-8 * Double(n), "bin \(k)")
        }
        // Inverse of the forward transform returns the input.
        DigiPRO.FFT.transform(&re, &im, n, inverse: true, fixed: true)
        #expect(zip(re.prefix(n), re0).allSatisfy { abs($0 - $1) < 1e-9 })
    }

    /// The original's 32768-point core does no bit reversal: a one-cycle cosine of 10000 samples
    /// lands near bin 8192 instead of bins 1 and 9999 (spec §9).
    @Test func originalScramblesLargeBluestein() {
        let n = 10000
        func peak(fixed: Bool) -> Int {
            var re = (0..<n).map { cos(2 * Double.pi * Double($0) / Double(n)) }, im = [Double](repeating: 0, count: n)
            DigiPRO.FFT.transform(&re, &im, n, inverse: false, fixed: fixed)
            let power: [Double] = (0..<n).map { re[$0] * re[$0] + im[$0] * im[$0] }
            return power.indices.max { power[$0] < power[$1] }!
        }
        #expect([1, 9999].contains(peak(fixed: true)))
        #expect(![1, 9999].contains(peak(fixed: false)))
    }
}

@Suite struct DigiPRONameTests {
    @Test func waveNames() {
        #expect(DigiPRO.waveName(fromFileName: "kick.wav") == "KICK")
        #expect(DigiPRO.waveName(fromFileName: "ab.aif") == "AB  ")
        #expect(DigiPRO.waveName(fromFileName: "Sawtooth") == "SAWH")
        #expect(DigiPRO.waveName(fromFileName: "saw lead.wav") == "SAWD")
        #expect(DigiPRO.waveName(fromFileName: "snare01.aif") == "SNA1")
        #expect(DigiPRO.waveName(fromFileName: "hh.wav") == "HH  ")
        #expect(DigiPRO.waveName(fromFileName: "/Users/x/Samples.v2/åska.wav") == "[SKA")
        #expect(DigiPRO.waveName(fromFileName: "a\u{30A}ska.wav") == "[SKA") // decomposed å
        #expect(DigiPRO.waveName(fromFileName: "ÄÖå.wav") == "\\][ ")
        #expect(DigiPRO.waveName(fromFileName: "Ödla.aiff") == "]DLA")
        #expect(DigiPRO.waveName(fromFileName: "x.tar.gz") == "X.TR")
        #expect(DigiPRO.waveName(fromFileName: ".wav") == "    ")
        #expect(DigiPRO.waveName(fromFileName: "dir.v2/noext") == "NOET")
        #expect(DigiPRO.waveName(fromFileName: "café.wav") == "CAF\u{0E}") // é is Mac Roman 0x8E
        #expect(DigiPRO.syxFileName(fromFileName: "/tmp/kick.wav") == "kick.syx")
        #expect(DigiPRO.baseName(of: "a/b.c/d.e.f") == "d.e")
    }
}

/// File → `AudioFile.digiPROSamples` → `DigiPRO.encode`, against `read_audio_for_digipro` +
/// `digipro_sysex` (tools/golden_swift_files.py; slot = stereo mode index).
@Suite struct DigiPROPipelineTests {
    private func run(_ file: [UInt8], fileName: String, fileHash: String, stereo: C6Item.StereoMode,
                     original: String, fixed: String) throws {
        #expect(DFx.sha256(file) == fileHash)
        let f = try AudioFile(bytes: file)
        #expect(f.canConvertToDigiPRO)
        let x = f.digiPROSamples(stereo: stereo)
        let slot = C6Item.StereoMode.allCases.firstIndex(of: stereo)!
        let name = DigiPRO.waveName(fromFileName: fileName)
        #expect(DFx.sha256(DigiPRO.encode(samples: x, slot: slot, name: name, mode: .original)) == original)
        #expect(DFx.sha256(DigiPRO.encode(samples: x, slot: slot, name: name, mode: .fixed)) == fixed)
    }

    @Test func wavStereo16() throws {
        let file = AudioFixture.wavStereo16, hash = "1d7b8baa563a4157fd78c37c75d27de8674265e308424fd840f1b88027596699"
        #expect(try AudioFile(bytes: file).digiPROSamples(stereo: .mix).prefix(3) == [-0.5340576171875, -0.385589599609375, -0.2362060546875])
        #expect(DigiPRO.waveName(fromFileName: "loop wave.wav") == "LOOE")
        try run(file, fileName: "loop wave.wav", fileHash: hash, stereo: .mix,
                original: "c42daf2ee7b2d1b0aa3333b51fa5f04da5f2f4981854caf1ddff9ce487ecfc73",
                fixed: "c42daf2ee7b2d1b0aa3333b51fa5f04da5f2f4981854caf1ddff9ce487ecfc73")
        try run(file, fileName: "loop wave.wav", fileHash: hash, stereo: .left,
                original: "2524fc4d2a00c0473ba5b070036642116b5133ca12053e696c53890813c2b4e6",
                fixed: "2524fc4d2a00c0473ba5b070036642116b5133ca12053e696c53890813c2b4e6")
        try run(file, fileName: "loop wave.wav", fileHash: hash, stereo: .right,
                original: "fb7bf612234c57b092e0656b3c574db32b640ee927aba4a68c54069c1acedab2",
                fixed: "fb7bf612234c57b092e0656b3c574db32b640ee927aba4a68c54069c1acedab2")
    }

    @Test func aiffMono24WithLoop() throws {
        let f = try AudioFile(bytes: AudioFixture.aiffMono24)
        #expect(f.info.loopStart == 1000 && f.info.loopEnd == 1999 && f.info.sampleRate == 48000 && f.digiPROSampleCount == 1000)
        try run(AudioFixture.aiffMono24, fileName: "bass synth.aif",
                fileHash: "da2fec7638ca5ce4f1171f4ce61cdd5369886adf2990e81f2f204938469ba499", stereo: .mix,
                original: "73f3736704f1dc3fde29487664e01f845e3ec19613177d34101c609a62d56488",
                fixed: "1ed6190768643147d49b56af04982ff24f1c1305589011920177ec56024eb96a")
    }

    @Test func wavFloat32() throws {
        #expect(try AudioFile(bytes: AudioFixture.wavFloat32).digiPROSamples(stereo: .mix).prefix(3) == [-256, -255, -254])
        try run(AudioFixture.wavFloat32, fileName: "Float Saw.wav",
                fileHash: "c22349b6db6c1836e7b107a42261ab3386f5678612ded7418684bc07cf65b9ba", stereo: .mix,
                original: "06be1230e2dfa125bf8d8b1f6f3ddb0021d4da268c42a946a8cd577ec93851bc",
                fixed: "06be1230e2dfa125bf8d8b1f6f3ddb0021d4da268c42a946a8cd577ec93851bc")
    }
}
