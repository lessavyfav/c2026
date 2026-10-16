@testable import C6Core
import Testing

/// Synthetic message builders. They mirror the builders in `tools/c6_recognize.py` (and the
/// fixture script that produced the expected strings below from that reference model).
enum RecognitionFixture {
    static func header(_ dev: UInt8) -> [UInt8] { [0xF0, 0x00, 0x20, 0x3C, dev, 0x00] }

    /// An Elektron dump with a valid trailer; `checksumOffset` = 3 (MD/MM) or 4 (A4/AR, DigiPRO).
    static func dump(_ dev: UInt8, _ id: UInt8, _ payload: [UInt8], checksumOffset: Int) -> [UInt8] {
        let body = header(dev) + [id] + payload
        let m = 6
        let sum = body[(m + checksumOffset)...].reduce(0) { $0 + Int($1) } & 0x3FFF
        let length = body.count + 4 - m - 3
        return body + [UInt8(sum >> 7), UInt8(sum & 0x7F), UInt8((length >> 7) & 0x7F), UInt8(length & 0x7F), 0xF7]
    }

    static func nibbles(_ v: Int) -> [UInt8] { [UInt8((v >> 4) & 0xF), UInt8(v & 0xF)] }

    /// MD/MM OS-upgrade data message: 16-bit words packed into 3 MIDI bytes each.
    static func mdUpgradeData(_ dev: UInt8, words: [Int], header h: [Int] = [0x12, 0x34, 0x56]) -> [UInt8] {
        var body: [UInt8] = []
        var sum = h.reduce(0, +)
        for w in words {
            let b0 = (w >> 14) & 0x7F, b1 = (w >> 7) & 0x7F, b2 = w & 0x7F
            body += [UInt8(b0), UInt8(b1), UInt8(b2)]
            let v = b0 << 14 | b1 << 7 | b2
            sum += ((v >> 8) & 0xFF) + (v & 0xFF)
        }
        return header(dev) + [0x7E] + nibbles(sum & 0xFF) + nibbles(h[0]) + nibbles(h[1]) + nibbles(h[2]) + body + [0xF7]
    }

    /// MD/MM/OT OS-upgrade end message carrying the 24-bit byte total.
    static func upgradeEnd(_ dev: UInt8, total: Int) -> [UInt8] {
        header(dev) + [0x7F] + nibbles((total >> 16) & 0xFF) + nibbles((total >> 8) & 0xFF) + nibbles(total & 0xFF) + [0xF7]
    }

    /// Octatrack OS-upgrade data message: 8→7 packed payload.
    static func otUpgradeData(_ data: [Int], header h: [Int] = [0x01, 0x02, 0x03]) -> [UInt8] {
        let sum = (h.reduce(0, +) + data.reduce(0, +)) & 0xFF
        var body: [UInt8] = []
        for g in stride(from: 0, to: data.count, by: 7) {
            let group = data[g..<min(g + 7, data.count)]
            var msb = 0
            for (k, x) in group.enumerated() where x & 0x80 != 0 { msb |= 1 << (6 - k) }
            body.append(UInt8(msb))
            body += group.map { UInt8($0 & 0x7F) }
        }
        return header(5) + [0x7E] + nibbles(sum) + nibbles(h[0]) + nibbles(h[1]) + nibbles(h[2]) + body + [0xF7]
    }

    static func u21(_ v: Int) -> [UInt8] { [UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)] }

    /// A4 (dev 6) / AR (dev 7) OS upgrade: start, `blocks` data blocks, end.
    static func analogUpgrade(_ dev: UInt8, seed: Int = 2, blocks: Int = 3, withEnd: Bool = true) -> [UInt8] {
        var msgs = header(dev) + [0x7F, 1, UInt8(seed)] + u21(0xF2) + u21(blocks) + [0xF7]
        for k in 0..<blocks {
            var body = [Int](repeating: 0, count: 121)
            let seq = u21(0xF2 + k)
            body[1] = Int(seq[0]); body[2] = Int(seq[1]); body[3] = Int(seq[2])
            for j in 4..<120 { body[j] = (j * 7 + k) & 0x7F }
            var c = 0
            if dev == 7 {
                for q in 0..<119 { c += (seed + q) ^ body[1 + q] }
                body[120] = (seed + c) & 0x7F
            } else {
                for q in 1..<120 { c += body[q] ^ q }
                body[120] = (c + seed) & 0x7F
            }
            msgs += header(dev) + [0x7E] + body[1...].map { UInt8($0) } + [0xF7]
        }
        if withEnd { msgs += header(dev) + [0x7F, 2, UInt8(seed)] + u21(0xF2) + u21(blocks) + [0xF7] }
        return msgs
    }

    /// Standard SDS: 21-byte header (16 bits, length 100, loop 0…50, loop off) and data packets.
    static func sds(packets: Int = 2, period: Int = 22676, corrupt: Int? = nil) -> [UInt8] {
        var out: [UInt8] = [0xF0, 0x7E, 0x00, 0x01, 0x00, 0x00, 16,
                            UInt8(period & 0x7F), UInt8((period >> 7) & 0x7F), UInt8(period >> 14),
                            100, 0, 0, 0, 0, 0, 50, 0, 0, 0x7F, 0xF7]
        for p in 0..<packets { out += sdsPacket(p, corrupt: corrupt == p) }
        return out
    }

    static func sdsPacket(_ p: Int, corrupt: Bool = false) -> [UInt8] {
        let data = (0..<120).map { UInt8((p + $0) & 0x7F) }
        var x = 0x7E ^ 0x00 ^ 0x02 ^ p
        for d in data { x ^= Int(d) }
        var pkt: [UInt8] = [0xF0, 0x7E, 0x00, 0x02, UInt8(p & 0x7F)] + data + [UInt8(x & 0x7F), 0xF7]
        if corrupt { pkt[10] ^= 1 }
        return pkt
    }

    static func le7(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (7 * $0)) & 0x7F) } }

    /// Extended Dump Header in the layout C6 builds (Win 0x4041c8): 34 bytes.
    static func extendedSDSHeader(bits: Int = 16, rate: Int = 44100, fraction: Int = 0, length: Int,
                                  loopStart: Int, loopEnd: Int, loopType: UInt8) -> [UInt8] {
        [0xF0, 0x7E, 0x00, 0x05, 0x05, 0x00, 0x00, UInt8(bits)] + le7(rate, 4) + le7(fraction, 4)
            + le7(length, 5) + le7(loopStart, 5) + le7(loopEnd, 5) + [loopType, 0x01, 0xF7]
    }

    /// Sample Name message C6 sends after an extended header.
    static let sdsName: [UInt8] = [0xF0, 0x7E, 0x00, 0x05, 0x03, 0x00, 0x00, 0x00, 0x04, 0x4B, 0x49, 0x43, 0x4B, 0xF7]
}

private typealias Fx = RecognitionFixture

private func info(_ bytes: [UInt8]) -> String { SysExRecognizer.describe(bytes) }
private func typeColumn(_ bytes: [UInt8]) -> String { SysExRecognizer.typeString(bytes) }

private func md(_ n: [Int], _ b: [Int]) -> String {
    "Normal Globals: \(n[0]) Kits: \(n[1]) Patterns: \(n[2]) Songs: \(n[3]) \nBroken Globals: \(b[0]) Kits: \(b[1]) Patterns: \(b[2]) Songs: \(b[3])"
}

private func a4(_ n: [Int], _ b: [Int]) -> String {
    "Normal Globals: \(n[0]) Kits: \(n[1]) Sounds: \(n[2])\n       Patterns: \(n[3]) Songs: \(n[4]) Settings: \(n[5])\n"
        + "Broken Globals: \(b[0]) Kits: \(b[1]) Sounds: \(b[2])\n       Patterns: \(b[3]) Songs: \(b[4]) Settings: \(b[5])"
}

private let mdKit = Fx.dump(2, 0x52, [1, 1] + [UInt8](repeating: 5, count: 30), checksumOffset: 3)
private let mmKit = Fx.dump(3, 0x52, [1, 1] + [UInt8](repeating: 5, count: 30), checksumOffset: 3)
private let digiPRO = Fx.dump(3, 0x5D, [1, 1, 4] + [UInt8](repeating: 3, count: 40), checksumOffset: 4)
private let a4Sound = Fx.dump(6, 0x53, [1, 1, 0] + [UInt8](repeating: 7, count: 20), checksumOffset: 4)
private let arKit = Fx.dump(7, 0x52, [1, 1, 0] + [UInt8](repeating: 7, count: 20), checksumOffset: 4)

private func flipped(_ bytes: [UInt8], at i: Int, mask: UInt8 = 1) -> [UInt8] {
    var b = bytes
    b[i] ^= mask
    return b
}

@Suite struct RecognitionTypeColumnTests {
    @Test func elektronFamilies() {
        #expect(typeColumn(mdKit) == "MD")
        #expect(typeColumn(mmKit) == "MM")
        #expect(typeColumn(digiPRO) == "MM")
        #expect(typeColumn(Fx.otUpgradeData([1, 2]) + Fx.upgradeEnd(5, total: 2)) == "OT")
        #expect(typeColumn([0xF0, 0x00, 0x20, 0x3C, 0x01, 0x00, 0x10, 0xF7]) == "SID")
        #expect(typeColumn(a4Sound) == "AF")
        #expect(SysExRecognizer.classify(a4Sound) == .analogFour)
    }

    /// Deviation 1: the Mac build shows "-" here; Windows shows "AR".
    @Test func analogRytmShowsAR() {
        #expect(typeColumn(arKit) == "AR")
        #expect(SysExRecognizer.classify(Fx.analogUpgrade(7)) == .analogRytm)
        #expect(RecognizedType.analogRytm.elektronDevice == .analogRytm)
    }

    @Test func unknownDevicesAndEmpty() {
        #expect(typeColumn([0xF0, 0x00, 0x20, 0x3C, 0x04, 0x00, 0x01, 0xF7]) == "-") // TM-1
        #expect(typeColumn([]) == "-")
        #expect(typeColumn([0xF0, 0x00, 0x20, 0x3C, 0x02]) == "-") // header cut before the 00
        #expect(typeColumn([0xF0, 0x43, 0x10, 0x4C, 0x00, 0xF7]) == "-")
        #expect(info([0xF0, 0x00, 0x20, 0x3C, 0x04, 0x00, 0x01, 0xF7]) == "")
        #expect(info([]) == "")
    }

    @Test func headerAnywhereInBuffer() {
        #expect(typeColumn([0x00, 0x11, 0x22] + mdKit) == "MD")
        #expect(SysExRecognizer.hasElektronHeader([0x7F, 0x7F] + a4Sound, device: 6))
        #expect(!SysExRecognizer.hasElektronHeader(a4Sound, device: 7))
    }

    /// Type order: audio, MD, MM, OT, SID, SDS, AF, AR.
    @Test func typePrecedence() {
        #expect(typeColumn(mmKit + mdKit) == "MD")
        #expect(typeColumn(a4Sound + [0xF0, 0x00, 0x20, 0x3C, 0x01, 0x00, 0x10, 0xF7]) == "SID")
        #expect(typeColumn(Fx.sds() + a4Sound) == "SDS")
        #expect(typeColumn(Fx.sds() + mdKit) == "MD")
        #expect(typeColumn(arKit + a4Sound) == "AF")
    }

    @Test func audioMagic() {
        let wav = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVEfmt ".utf8)
        let aiff = Array("FORM".utf8) + [0, 0, 0, 0] + Array("AIFFCOMM".utf8)
        let aifc = Array("FORM".utf8) + [0, 0, 0, 0] + Array("AIFCFVER".utf8)
        #expect(typeColumn(wav) == "WAV")
        #expect(typeColumn(aiff) == "AIFF")
        #expect(typeColumn(aifc) == "AIFC")
        #expect(SysExRecognizer.fileInfo(wav) == .audio(.wav))
        #expect(SysExRecognizer.fileInfo(aiff) == .audio(.aiff))
        #expect(SysExRecognizer.fileInfo(aifc) == .audio(.aifc))
        #expect(SysExRecognizer.describe(aiff) == "")
        #expect(SysExRecognizer.describe(wav, audioDescriber: { f, b in "\(f.rawValue) \(b.count)" }) == "WAV 16")
        // Shorter than 12 bytes: never audio.
        #expect(typeColumn(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAV".utf8)) == "-")
        #expect(typeColumn(Array("RIFX".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)) == "-")
    }

    /// Faithful quirk: Type tests audio first, File Info tests Elektron first.
    @Test func wavWithElektronHeaderInBody() {
        let wav = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8) + mdKit
        #expect(typeColumn(wav) == "WAV")
        #expect(info(wav) == md([0, 1, 0, 0], [0, 0, 0, 0]))
    }
}

@Suite struct ElektronFileInfoTests {
    @Test func machinedrumKit() {
        #expect(info(mdKit) == "Normal Globals: 0 Kits: 1 Patterns: 0 Songs: 0 \nBroken Globals: 0 Kits: 0 Patterns: 0 Songs: 0")
        #expect(info(mdKit + flipped(mdKit, at: 12)) == md([0, 1, 0, 0], [0, 1, 0, 0]))
    }

    @Test func machinedrumAllCountedIDs() {
        let buf = Fx.dump(2, 0x50, [1, 1] + [UInt8](repeating: 9, count: 10), checksumOffset: 3)
            + Fx.dump(2, 0x67, [1, 1] + [UInt8](repeating: 8, count: 10), checksumOffset: 3)
            + Fx.dump(2, 0x67, [1, 1] + [UInt8](repeating: 7, count: 10), checksumOffset: 3)
            + Fx.dump(2, 0x69, [1, 1] + [UInt8](repeating: 6, count: 10), checksumOffset: 3)
            + Fx.dump(2, 0x5A, [1, 1, 2], checksumOffset: 3) // not counted
        #expect(info(buf) == md([1, 0, 2, 1], [0, 0, 0, 0]))
    }

    @Test func machinedrumBrokenTrailers() {
        #expect(info(flipped(mdKit, at: mdKit.count - 2)) == md([0, 0, 0, 0], [0, 1, 0, 0])) // length field
        #expect(info(Array(mdKit.dropLast())) == md([0, 0, 0, 0], [0, 1, 0, 0]))           // no F7
        #expect(info(flipped(mdKit, at: mdKit.count - 4)) == md([0, 0, 0, 0], [0, 1, 0, 0])) // checksum
        // Version/revision bytes (m+1, m+2) are outside the MD checksum window.
        #expect(info(flipped(mdKit, at: 7)) == md([0, 1, 0, 0], [0, 0, 0, 0]))
        // Always printed, even with nothing counted.
        #expect(info(Fx.header(2)) == md([0, 0, 0, 0], [0, 0, 0, 0]))
    }

    @Test func mixedFamiliesDescribeFirstOnly() {
        #expect(info(mdKit + mmKit) == md([0, 1, 0, 0], [0, 0, 0, 0]))
    }

    @Test func monomachine() {
        #expect(info(mmKit) == md([0, 1, 0, 0], [0, 0, 0, 0]))
        // A lone DigiPRO waveform reads with a leading newline.
        #expect(info(digiPRO) == "\nDigiPRO waveform at position 5")
        #expect(info(flipped(digiPRO, at: 20)) == "\nDigiPRO waveform (broken)")
        let second = Fx.dump(3, 0x5D, [1, 1, 9] + [UInt8](repeating: 2, count: 40), checksumOffset: 4)
        #expect(info(digiPRO + second) == "\nNormal DPRO waveforms: 2, broken DPRO waveforms: 0")
        #expect(info(digiPRO + flipped(digiPRO, at: 20)) == "\nNormal DPRO waveforms: 1, broken DPRO waveforms: 1")
        #expect(info(mmKit + digiPRO) == md([0, 1, 0, 0], [0, 0, 0, 0]) + "\nDigiPRO waveform at position 5")
    }

    /// The DigiPRO header C6's generator writes (`… 5D 01 01 slot`), checksum from m+4.
    @Test func digiPROChecksumWindowStartsAtSlot() {
        let wave = Fx.dump(3, 0x5D, [1, 1, 0x3F] + (0..<64).map { UInt8($0 & 0x7F) }, checksumOffset: 4)
        #expect(info(wave) == "\nDigiPRO waveform at position 64")
        // Built with the MD window (m+3) the slot byte is summed too, so it reads broken.
        let mdWindow = Fx.dump(3, 0x5D, [1, 1, 0x3F] + (0..<64).map { UInt8($0 & 0x7F) }, checksumOffset: 3)
        #expect(info(mdWindow) == "\nDigiPRO waveform (broken)")
    }

    @Test func sidstation() {
        #expect(info([0xF0, 0x00, 0x20, 0x3C, 0x01, 0x00, 0x10, 0xF7]) == "SIDSTATION")
    }

    @Test func analogFourAllCategories() {
        let good = Fx.dump(6, 0x57, [1, 1, 0, 1], checksumOffset: 4) + Fx.dump(6, 0x52, [1, 1, 0, 2], checksumOffset: 4)
            + Fx.dump(6, 0x52, [1, 1, 0, 3], checksumOffset: 4) + Fx.dump(6, 0x53, [1, 1, 0, 4], checksumOffset: 4)
            + Fx.dump(6, 0x54, [1, 1, 0, 5], checksumOffset: 4) + Fx.dump(6, 0x55, [1, 1, 0, 6], checksumOffset: 4)
            + Fx.dump(6, 0x56, [1, 1, 0, 7], checksumOffset: 4)
        let brokenPattern = flipped(Fx.dump(6, 0x54, [1, 1, 0, 5] + [UInt8](repeating: 9, count: 10), checksumOffset: 4),
                                    at: 15, mask: 2)
        #expect(info(good + brokenPattern) == a4([1, 2, 1, 1, 1, 1], [0, 0, 0, 1, 0, 0]))
    }

    @Test func analogFourSound() {
        #expect(info(a4Sound) == "Normal Globals: 0 Kits: 0 Sounds: 1\n       Patterns: 0 Songs: 0 Settings: 0\n"
            + "Broken Globals: 0 Kits: 0 Sounds: 0\n       Patterns: 0 Songs: 0 Settings: 0")
        // A4/AR checksums start at m+4: a trailer computed from m+3 fails.
        #expect(info(Fx.dump(6, 0x52, [1, 1, 5] + [UInt8](repeating: 7, count: 20), checksumOffset: 3))
            == a4([0, 0, 0, 0, 0, 0], [0, 1, 0, 0, 0, 0]))
    }

    @Test func analogRytmKit() {
        #expect(info(arKit) == a4([0, 1, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0]))
    }

    /// Deviation 2: the original leaves the previous File Info text on screen.
    @Test func octatrackWithoutUpgradeIsEmpty() {
        let ot: [UInt8] = [0xF0, 0x00, 0x20, 0x3C, 0x05, 0x00, 0x52, 1, 2, 3, 0xF7]
        #expect(typeColumn(ot) == "OT")
        #expect(SysExRecognizer.fileInfo(ot) == .text(""))
        #expect(ElektronDescriber.describeOctatrack(RecognitionBuffer(ot)) == nil)
    }

    /// File Info order: MD, MM, OT, A4, AR, SID, audio, SDS.
    @Test func fileInfoPrecedence() {
        let sid: [UInt8] = [0xF0, 0x00, 0x20, 0x3C, 0x01, 0x00, 0x10, 0xF7]
        #expect(info(sid + a4Sound) == a4([0, 0, 1, 0, 0, 0], [0, 0, 0, 0, 0, 0]))
        #expect(info(sid + arKit) == a4([0, 1, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0]))
        #expect(info(arKit + a4Sound) == a4([0, 0, 1, 0, 0, 0], [0, 0, 0, 0, 0, 0]))
        #expect(info(Fx.sds() + a4Sound) == a4([0, 0, 1, 0, 0, 0], [0, 0, 0, 0, 0, 0]))
    }

    /// The real Machinedrum returned a 1233-byte kit (`F0 00 20 3C 02 00 52 40 01 00 …`) that
    /// `ElektronChecksum.isValid` accepted; this is a synthetic equivalent.
    @Test func machinedrumKitOfHardwareSize() {
        var msg: [UInt8] = [0xF0, 0x00, 0x20, 0x3C, 0x02, 0x00, 0x52, 0x40, 0x01, 0x00]
        while msg.count < 1228 { msg.append(UInt8((msg.count * 37 + 11) & 0x7F)) }
        let sum = msg[9...].reduce(0) { $0 + Int($1) } & 0x3FFF
        let length = 1232 - 6 - 3
        msg += [UInt8(sum >> 7), UInt8(sum & 0x7F), UInt8(length >> 7), UInt8(length & 0x7F), 0xF7]

        #expect(msg.count == 1233)
        #expect(ElektronChecksum.isValid(msg))
        #expect(typeColumn(msg) == "MD")
        #expect(info(msg) == md([0, 1, 0, 0], [0, 0, 0, 0]))
        #expect(SysExDescriber.describe(SysExData(bytes: msg)) == md([0, 1, 0, 0], [0, 0, 0, 0]))

        // The recognizer's trailer check and ElektronChecksum agree on corruption.
        for i in [9, 600, 1227, 1228, 1229, 1230, 1231] {
            let bad = flipped(msg, at: i)
            #expect(!ElektronChecksum.isValid(bad))
            #expect(info(bad) == md([0, 0, 0, 0], [0, 1, 0, 0]))
        }
        // Bytes before the checksum window (version/revision) don't matter to either.
        #expect(ElektronChecksum.isValid(flipped(msg, at: 7)))
        #expect(info(flipped(msg, at: 8)) == md([0, 1, 0, 0], [0, 0, 0, 0]))
    }

    @Test func describerWiredThroughSysExData() {
        #expect(SysExDescriber.describe(SysExData(bytes: digiPRO)) == "\nDigiPRO waveform at position 5")
        #expect(SysExDescriber.describe(SysExData(bytes: Fx.analogUpgrade(7))) == "Sysex Upgrade")
        #expect(SysExDescriber.describe(SysExData(messages: [])) == "")
    }
}

@Suite struct OSUpgradeRecognitionTests {
    private static let mdUpgrade = Fx.mdUpgradeData(2, words: [0x1234, 0xFFFF, 0x0001]) + Fx.mdUpgradeData(2, words: [0xABCD, 0x7F7F])

    @Test func machinedrum() {
        let up = Self.mdUpgrade
        #expect(info(up + Fx.upgradeEnd(2, total: 10)) == "Sysex Upgrade")
        #expect(info(up + Fx.upgradeEnd(2, total: 9)) == "Sysex Upgrade (Broken!)")
        #expect(info(up) == "Sysex Upgrade (Broken!)")                      // no end message
        #expect(info(up + Fx.upgradeEnd(2, total: 10) + Fx.upgradeEnd(2, total: 10)) == "Sysex Upgrade (Broken!)")
        #expect(info(flipped(up, at: 18) + Fx.upgradeEnd(2, total: 10)) == "Sysex Upgrade (Broken!)")
        // Upgrade text wins over dump counts.
        #expect(info(mdKit + up + Fx.upgradeEnd(2, total: 10)) == "Sysex Upgrade")
        #expect(typeColumn(up) == "MD")
    }

    @Test func monomachine() {
        #expect(info(Fx.mdUpgradeData(3, words: [0x0102, 0x0304]) + Fx.upgradeEnd(3, total: 4)) == "Sysex Upgrade")
        #expect(info(Fx.mdUpgradeData(3, words: [0x0102, 0x0304]) + Fx.upgradeEnd(3, total: 5)) == "Sysex Upgrade (Broken!)")
    }

    @Test func octatrack() {
        let ot = Fx.otUpgradeData([0x00, 0x81, 0xFF, 0x10, 0x20, 0x30, 0x40, 0x99, 0x7F]) + Fx.otUpgradeData([0xC3, 0x01])
        #expect(info(ot + Fx.upgradeEnd(5, total: 11)) == "Sysex Upgrade")
        #expect(info(ot + Fx.upgradeEnd(5, total: 12)) == "Sysex Upgrade (Broken!)")
        #expect(info(flipped(ot, at: 17) + Fx.upgradeEnd(5, total: 11)) == "Sysex Upgrade (Broken!)")
        #expect(info(ot) == "Sysex Upgrade (Broken!)")
    }

    @Test(arguments: [UInt8(6), 7])
    func analogFourAndRytm(dev: UInt8) {
        #expect(info(Fx.analogUpgrade(dev)) == "Sysex Upgrade")
        #expect(info(flipped(Fx.analogUpgrade(dev), at: 40)) == "Sysex Upgrade (Broken!)")
        // Two 0x7F messages (start and end) are required.
        #expect(info(Fx.analogUpgrade(dev, withEnd: false)) == "Sysex Upgrade (Broken!)")
        #expect(info(Array(Fx.analogUpgrade(dev).dropLast(150))) == "Sysex Upgrade (Broken!)")
        #expect(info(Fx.analogUpgrade(dev, blocks: 1)) == "Sysex Upgrade")
        // A third 0x7F message breaks it.
        #expect(info(Fx.analogUpgrade(dev, blocks: 2) + Array(Fx.analogUpgrade(dev, blocks: 2).suffix(16)))
            == "Sysex Upgrade (Broken!)")
        // The block count in the end message must match the start message.
        var wrongCount = Fx.analogUpgrade(dev, blocks: 2)
        wrongCount[wrongCount.count - 2] = 3
        #expect(info(wrongCount) == "Sysex Upgrade (Broken!)")
        // The start message's first field must be 0xF2.
        var wrongStart = Fx.analogUpgrade(dev, blocks: 2)
        wrongStart[11] = 0x73
        #expect(info(wrongStart) == "Sysex Upgrade (Broken!)")
    }

    /// Analog Rytm upgrades must use seed 0x02; Analog Four accepts any seed.
    @Test func analogSeedCheck() {
        #expect(info(Fx.analogUpgrade(6, seed: 3)) == "Sysex Upgrade")
        #expect(info(Fx.analogUpgrade(7, seed: 3)) == "Sysex Upgrade (Broken!)")
    }

    /// A data block before any start message compares against the unset start fields: broken.
    @Test func analogBlockWithoutStart() {
        let full = Fx.analogUpgrade(6, blocks: 1)
        let start = Array(full.prefix(16)), block = Array(full[16..<(16 + 128)]), end = Array(full.suffix(16))
        #expect(start.count + block.count + end.count == full.count)
        #expect(info(block + start + end) == "Sysex Upgrade (Broken!)")
    }
}

@Suite struct SampleDumpRecognitionTests {
    @Test func singleDump() {
        #expect(typeColumn(Fx.sds()) == "SDS")
        #expect(info(Fx.sds()) == "Dump length: 100 Sample Rate: 44100\nBits: 16 Loop OFF. Loop start: 0 Loop end: 50")
        var loopOn = Fx.sds()
        loopOn[19] = 0x00
        #expect(info(loopOn) == "Dump length: 100 Sample Rate: 44100\nBits: 16 Loop ON. Loop start: 0 Loop end: 50")
        // A header with no packets counts as correct.
        #expect(info(Fx.sds(packets: 0)) == info(Fx.sds()))
    }

    @Test func counts() {
        #expect(info(Fx.sds() + Fx.sds()) == "2 correct and 0 broken sample dumps.")
        // Faithful quirk: a bad packet checksum makes the dump neither correct nor broken.
        #expect(info(Fx.sds(packets: 3, corrupt: 1)) == "0 correct and 0 broken sample dumps.")
        // Faithful quirk: after a missing packet every later packet counts as broken.
        let four = Fx.sds(packets: 4)
        #expect(info(Array(four[..<(21 + 127)] + four[(21 + 2 * 127)...])) == "0 correct and 2 broken sample dumps.")
        // The second dump is the only one counted, so the header line is shown.
        #expect(info(Fx.sds(packets: 3, corrupt: 1) + Fx.sds()) == info(Fx.sds()))
    }

    @Test func truncatedPacket() {
        #expect(info(Array(Fx.sds(packets: 1)[..<(21 + 50)]) + [0xF7]) == "Broken sample dump.")
    }

    /// Faithful: only a header at offset 0 is recognised, so a leading ACK defeats it.
    @Test func leadingMessageDefeatsRecognition() {
        let buf: [UInt8] = [0xF0, 0x7E, 0x00, 0x7F, 0x00, 0xF7] + Fx.sds()
        #expect(typeColumn(buf) == "-")
        #expect(info(buf) == "")
        #expect(typeColumn([0xF0, 0x7E, 0x00]) == "-")
    }

    @Test(arguments: [(22676, 44100), (22675, 44101), (20833, 48000), (20834, 47998), (31250, 32000), (62500, 16000)])
    func sampleRate(period: Int, rate: Int) {
        #expect(info(Fx.sds(packets: 1, period: period))
            == "Dump length: 100 Sample Rate: \(rate)\nBits: 16 Loop OFF. Loop start: 0 Loop end: 50")
    }

    /// Deviation 4: the original crashes (integer divide by zero).
    @Test func periodZero() {
        #expect(info(Fx.sds(packets: 1, period: 0)) == "Dump length: 100 Sample Rate: 0\nBits: 16 Loop OFF. Loop start: 0 Loop end: 50")
    }

    /// Deviation 3: Extended Dump Headers (what C6 sends with "Use Extended SDS").
    @Test func extendedHeader() {
        let hdr = Fx.extendedSDSHeader(length: 3_000_000, loopStart: 1000, loopEnd: 2_999_999, loopType: 0x00)
        #expect(hdr.count == 34)
        let dump = hdr + Fx.sdsName + Fx.sdsPacket(0) + Fx.sdsPacket(1)
        #expect(typeColumn(dump) == "SDS")
        #expect(SysExRecognizer.isSampleDump(dump))
        #expect(info(dump) == "Dump length: 3000000 Sample Rate: 44100\nBits: 16 Loop ON. Loop start: 1000 Loop end: 2999999")

        let off = Fx.extendedSDSHeader(bits: 24, rate: 47999, fraction: 1 << 27, length: 10, loopStart: 0, loopEnd: 9, loopType: 0x7F)
        #expect(info(off) == "Dump length: 10 Sample Rate: 48000\nBits: 24 Loop OFF. Loop start: 0 Loop end: 9")

        // Extended and standard headers both start a dump.
        #expect(info(dump + Fx.sds()) == "2 correct and 0 broken sample dumps.")
        #expect(info(Fx.sds() + dump) == "2 correct and 0 broken sample dumps.")
        #expect(info(hdr + Fx.sdsPacket(0) + Fx.sdsPacket(1, corrupt: true) + Fx.sdsPacket(3)) == "Broken sample dump.")
    }
}
