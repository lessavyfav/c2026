@testable import C6Core
import Foundation
import Testing

@Suite struct DumpNamerTests {
    /// Builds an Elektron dump like the Machinedrum's: header, ID, version 40, revision 01, position, name…
    func md(_ id: UInt8, pos: Int, name: String = "", device: UInt8 = 0x02, size: Int = 60) -> [UInt8] {
        var nameBytes = Array(name.utf8.prefix(16)); nameBytes += [UInt8](repeating: 0, count: 16 - nameBytes.count)
        let body: [UInt8] = [0x40, 0x01, UInt8(pos)] + nameBytes + [UInt8](repeating: 0x10, count: size)
        return [0xF0, 0x00, 0x20, 0x3C, device, 0x00, id] + body + [0x00, 0x00, 0x00, 0x00, 0xF7]
    }

    @Test func singleKitUsesNumberAndName() {
        #expect(DumpNamer.describe(SysExData(messages: [md(0x52, pos: 0, name: "BELLKIT")])) == "MD Kit 01 BELLKIT")
    }

    @Test func contiguousKitsAsARange() {
        let kits = (0..<64).map { md(0x52, pos: $0, name: "K\($0)") }
        #expect(DumpNamer.describe(SysExData(messages: kits)) == "MD Kits 01–64")
    }

    @Test func patternsUseBankLetters() {
        #expect(DumpNamer.describe(SysExData(messages: [md(0x67, pos: 17)])) == "MD Pattern B02")
        let all = (0..<128).map { md(0x67, pos: $0) }
        #expect(DumpNamer.describe(SysExData(messages: all)) == "MD Patterns A01–H16")
    }

    @Test func fullBackupCountsEachKind() {
        let msgs = (0..<8).map { md(0x50, pos: $0) } + (0..<64).map { md(0x52, pos: $0) }
            + [md(0x67, pos: 3), md(0x67, pos: 9)] + [md(0x69, pos: 0, name: "LIVE")]
        #expect(DumpNamer.describe(SysExData(messages: msgs)) == "MD Globals 01–08, Kits 01–64, 2 Patterns, Song 01 LIVE")
    }

    @Test func emptyKitSlotHasNoName() {
        var empty = md(0x52, pos: 62)
        for i in 10..<26 { empty[i] = 0x7F }
        #expect(DumpNamer.describe(SysExData(messages: [empty])) == "MD Kit 63")
    }

    @Test func otherDevicesAndUnknown() {
        #expect(DumpNamer.describe(SysExData(messages: [md(0x53, pos: 0, device: 0x06)])) == "A4 Sound")
        #expect(DumpNamer.describe(SysExData(messages: [TM1Message.statusRequest])) == nil)
    }

    @Test func shortCodes() {
        let kits = (0..<64).map { md(0x52, pos: $0) }
        let backup = (0..<8).map { md(0x50, pos: $0) } + kits + [md(0x67, pos: 0), md(0x67, pos: 1)] + [md(0x69, pos: 0)]
        #expect(DumpNamer.code(SysExData(messages: kits)) == "MDK")
        #expect(DumpNamer.code(SysExData(messages: [md(0x52, pos: 0, name: "BELLKIT")])) == "MDK01")
        #expect(DumpNamer.code(SysExData(messages: [md(0x67, pos: 0)])) == "MDPA01")
        #expect(DumpNamer.code(SysExData(messages: [md(0x69, pos: 4)])) == "MDS05")
        #expect(DumpNamer.code(SysExData(messages: (0..<8).map { md(0x50, pos: $0) })) == "MDG")
        #expect(DumpNamer.code(SysExData(messages: (0..<8).map { md(0x50, pos: $0) } + kits + [md(0x67, pos: 0), md(0x67, pos: 1)])) == "MDGKP")
        #expect(DumpNamer.code(SysExData(messages: backup)) == "MDGKPS")
        // Order is fixed (G K P S) whatever order the dump arrives in.
        #expect(DumpNamer.code(SysExData(messages: [md(0x67, pos: 0), md(0x52, pos: 1)])) == "MDKP")
        #expect(DumpNamer.code(SysExData(messages: [md(0x52, pos: 0), md(0x67, pos: 0, device: 0x03)])) == "MDK01+MMPA01")
        #expect(DumpNamer.code(SysExData(messages: [TM1Message.statusRequest])) == nil)
    }

    @Test func fileNames() {
        let d = Date(timeIntervalSince1970: 1_792_166_340)   // fixed instant; the time shown depends on the zone
        let kits = SysExData(messages: (0..<64).map { md(0x52, pos: $0) })
        let name = DumpNamer.fileName(for: kits, date: d)
        #expect(name.hasPrefix("MDK 20") && name.hasSuffix(".syx") && !name.contains(":"))
        #expect(name.count == "MDK 2026-10-16 12.19.syx".count)
        #expect(DumpNamer.fileName(for: kits, date: d, taken: [name]) == name.replacingOccurrences(of: ".syx", with: " 2.syx"))
        let other = DumpNamer.fileName(for: SysExData(messages: [[0xF0, 0x43, 0x10, 0xF7]]), date: d)
        #expect(other.hasPrefix("Received 20"))
    }
}
