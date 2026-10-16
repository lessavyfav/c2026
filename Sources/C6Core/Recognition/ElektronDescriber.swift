import Foundation

/// File Info for Elektron dumps (spec §3) and OS upgrades (spec §5).
///
/// Every describer scans for `F0 00 20 3C <dev> 00 <id>` (resuming at the next byte, not after the
/// message), counts the dump IDs it knows, validates each dump's trailer and routes 0x7E / 0x7F to
/// the device's OS-upgrade parser.
enum ElektronDescriber {

    // MARK: Trailer check (MD 0xff36, MM 0x10493, A4 0x10ab9, AR 0x10fe0)

    /// `… <chk hi> <chk lo> <len hi> <len lo> F7`: 14-bit sum of the signed bytes in
    /// `[checksumStart, f-4)` and length field + 3 == f − m, where f is the first F7 at or after m.
    static func dumpOK(_ b: RecognitionBuffer, m: Int, checksumStart: Int) -> Bool {
        let f = b.firstF7(from: m)
        guard f < b.count else { return false } // original probes b[n]; treated as "not F7"
        let storedChecksum = (b.s8(f - 4) << 7) | b.s8(f - 3)
        let storedLength = ((b.s8(f - 2) << 7) | b.s8(f - 1)) + 3
        var sum = 0
        var k = checksumStart
        while k < f - 4 { sum += b.s8(k); k += 1 }
        return storedChecksum == (sum & 0x3FFF) && storedLength == f - m
    }

    // MARK: Machinedrum (0xfbbe) and Monomachine (0x10100)

    /// Counter slots in print order: Globals 0x50, Kits 0x52, Patterns 0x67, Songs 0x69,
    /// and (Monomachine only) DigiPRO waveform 0x5D.
    private static func mdSlot(_ id: UInt8, monomachine: Bool) -> Int? {
        switch id {
        case 0x50: return 0
        case 0x52: return 1
        case 0x67: return 2
        case 0x69: return 3
        case 0x5D where monomachine: return 4
        default: return nil
        }
    }

    static func describeMachinedrumFamily(_ b: RecognitionBuffer, device: ElektronDevice) -> String {
        let mm = device == .monomachine
        var normal = [Int](repeating: 0, count: 5), broken = normal
        var upg = UpgradeState()
        var digiPROPosition = 0
        for m in b.messageIDIndices(device: device.rawValue) {
            let id = b[m]
            if id == 0x7E { upg.n7E += 1; upgradeDataMachinedrum(b, m, &upg); continue }
            if id == 0x7F { upg.n7F += 1; upgradeEndNibble(b, m, &upg); continue }
            let slot = mdSlot(id, monomachine: mm)
            if let slot { normal[slot] += 1 }
            var checksumStart = m + 3
            if mm && id == 0x5D {
                checksumStart = m + 4
                // Latched before the checksum compare, only when an F7 exists (0x104ed..0x10504).
                if b.firstF7(from: m) < b.count { digiPROPosition = b.s8(m + 3) }
            }
            if !dumpOK(b, m: m, checksumStart: checksumStart), let slot {
                normal[slot] -= 1; broken[slot] += 1
            }
        }
        if upg.n7E != 0 { return upg.text(required7F: 1) }
        let counts = machinedrumCounts(normal, broken)
        if !mm { return counts }

        let others = normal[0..<4].reduce(0, +) + broken[0..<4].reduce(0, +)
        let dN = normal[4], dB = broken[4]
        var t = (others == 0 && dN + dB > 0) ? "" : counts
        if dN > 0 || dB > 0 {
            if dN == 1 && dB == 0 {
                t += "\nDigiPRO waveform at position \(digiPROPosition + 1)"
            } else if dN == 0 && dB == 1 {
                t += "\nDigiPRO waveform (broken)"
            } else {
                t += "\nNormal DPRO waveforms: \(dN), broken DPRO waveforms: \(dB)"
            }
        }
        return t
    }

    /// Mac 0x11850: note the space before the newline.
    static func machinedrumCounts(_ n: [Int], _ b: [Int]) -> String {
        "Normal Globals: \(n[0]) Kits: \(n[1]) Patterns: \(n[2]) Songs: \(n[3]) \n"
            + "Broken Globals: \(b[0]) Kits: \(b[1]) Patterns: \(b[2]) Songs: \(b[3])"
    }

    // MARK: Octatrack (0xf922)

    /// nil when the buffer holds no 0x7E upgrade data (the original then leaves the text unchanged).
    static func describeOctatrack(_ b: RecognitionBuffer) -> String? {
        var upg = UpgradeState()
        for m in b.messageIDIndices(device: ElektronDevice.octatrack.rawValue) {
            switch b[m] {
            case 0x7E: upg.n7E += 1; upgradeDataOctatrack(b, m, &upg)
            case 0x7F: upg.n7F += 1; upgradeEndNibble(b, m, &upg)
            default: break // other IDs are ignored, not validated
            }
        }
        return upg.n7E == 0 ? nil : upg.text(required7F: 1)
    }

    // MARK: Analog Four (0x1077e) and Analog Rytm (0x10ca0)

    /// Counter slots in print order: Globals 0x57, Kits 0x52, Sounds 0x53, Patterns 0x54,
    /// Songs 0x55, Settings 0x56.
    private static func analogSlot(_ id: UInt8) -> Int? {
        switch id {
        case 0x57: return 0
        case 0x52: return 1
        case 0x53: return 2
        case 0x54: return 3
        case 0x55: return 4
        case 0x56: return 5
        default: return nil
        }
    }

    static func describeAnalog(_ b: RecognitionBuffer, device: ElektronDevice) -> String {
        let ar = device == .analogRytm
        var normal = [Int](repeating: 0, count: 6), broken = normal
        var upg = UpgradeState()
        for m in b.messageIDIndices(device: device.rawValue) {
            let id = b[m]
            if id == 0x7E { upg.n7E += 1; upgradeDataAnalog(b, m, &upg, rytm: ar); continue }
            if id == 0x7F { upg.n7F += 1; upgradeControlAnalog(b, m, &upg, rytm: ar); continue }
            let slot = analogSlot(id)
            if let slot { normal[slot] += 1 }
            if !dumpOK(b, m: m, checksumStart: m + 4), let slot {
                normal[slot] -= 1; broken[slot] += 1
            }
        }
        if upg.n7E != 0 { return upg.text(required7F: 2) }
        return analogCounts(normal, broken)
    }

    /// Mac 0x1193c: seven spaces before each "Patterns".
    static func analogCounts(_ n: [Int], _ b: [Int]) -> String {
        "Normal Globals: \(n[0]) Kits: \(n[1]) Sounds: \(n[2])\n"
            + "       Patterns: \(n[3]) Songs: \(n[4]) Settings: \(n[5])\n"
            + "Broken Globals: \(b[0]) Kits: \(b[1]) Sounds: \(b[2])\n"
            + "       Patterns: \(b[3]) Songs: \(b[4]) Settings: \(b[5])"
    }

    // MARK: OS-upgrade parsers (spec §5)

    struct UpgradeState {
        var n7E = 0
        var n7F = 0
        /// Sticky per buffer.
        var broken = false
        /// MD/MM/OT: decoded payload bytes counted so far.
        var total = 0
        /// A4/AR: verified blocks.
        var good = 0
        /// A4/AR start-message fields; uninitialised stack variables in the original.
        var v1: Int?
        var v2: Int?
        var seed: Int?

        func text(required7F: Int) -> String {
            (n7F == required7F && !broken) ? InfoText.upgrade : InfoText.upgradeBroken
        }
    }

    /// MD/MM 0x7E data (MD 0xfd2e.., MM 0x10289..): nibble checksum over three nibble-encoded
    /// header bytes and the 16-bit words packed into 3 MIDI bytes each.
    static func upgradeDataMachinedrum(_ b: RecognitionBuffer, _ m: Int, _ u: inout UpgradeState) {
        if b[m + 1] == 0xF7 { return }
        let stored = b.nibblePair(m + 1)
        var sum = b.nibblePair(m + 3) + b.nibblePair(m + 5) + b.nibblePair(m + 7)
        let f = b.firstF7(from: m + 3)
        var idx = m + 9
        while idx < f - 2 && b[idx] != 0xF7 {
            let v = (b.s8(idx) << 14) | (b.s8(idx + 1) << 7) | b.s8(idx + 2)
            sum += ((v >> 8) & 0xFF) + (v & 0xFF)
            idx += 3
        }
        sum &= 0xFF
        if b[f] != 0xF7 { u.broken = true } else { u.total += (2 * (f - m) - 16) / 3 } // truncating, like C
        if stored != sum { u.broken = true }
    }

    /// MD/MM/OT 0x7F end: 24-bit nibble-encoded byte count must equal the running total.
    static func upgradeEndNibble(_ b: RecognitionBuffer, _ m: Int, _ u: inout UpgradeState) {
        if m < b.count - 6 {
            let val = (b.nibblePair(m + 1) << 16) | (b.nibblePair(m + 3) << 8) | b.nibblePair(m + 5)
            if val != u.total { u.broken = true }
        } else {
            u.broken = true
        }
    }

    /// OT 0x7E data (0xf9e6..): like MD, but the payload is 8→7 packed (MSB byte, then 7 bytes).
    static func upgradeDataOctatrack(_ b: RecognitionBuffer, _ m: Int, _ u: inout UpgradeState) {
        if b[m + 1] == 0xF7 { return }
        let stored = b.nibblePair(m + 1)
        var sum = b.nibblePair(m + 3) + b.nibblePair(m + 5) + b.nibblePair(m + 7)
        let f = b.firstF7(from: m + 3)
        var pos = 0, msb = 0, idx = m + 9
        while idx < f && b[idx] != 0xF7 {
            if pos == 0 {
                msb = b.s8(idx)
            } else {
                msb <<= 1
                sum += Int(b[idx]) | (msb & 0x80)
                u.total += 1 // counted even if the message turns out broken
            }
            pos += 1
            if pos == 8 { pos = 0 }
            idx += 1
        }
        if b[f] != 0xF7 { u.broken = true }
        if (sum & 0xFF) != stored { u.broken = true }
    }

    /// A4/AR 0x7E data block (A4 0x10924.., AR 0x10e46..):
    /// `F0 00 20 3C dev 00 7E seq:3 payload chk F7`, chk at m+120. No F7 or bounds check.
    static func upgradeDataAnalog(_ b: RecognitionBuffer, _ m: Int, _ u: inout UpgradeState, rytm: Bool) {
        guard let v1 = u.v1, b.u21(m + 1) == u.good + v1 else { u.broken = true; return }
        let s = (u.seed ?? 0) & 0xFF
        var c = 0
        let chk: Int
        if rytm {
            for k in 0..<119 { c += (s + k) ^ Int(b[m + 1 + k]) }
            chk = (s + c) & 0x7F
        } else {
            for k in 1...119 { c += Int(b[m + k]) ^ k }
            chk = (c + s) & 0x7F
        }
        guard chk == Int(b[m + 120]) else { u.broken = true; return }
        u.good += 1
    }

    /// A4/AR 0x7F control: `F0 00 20 3C dev 00 7F sub seed v1:3 v2:3 F7`; sub 1 = start, 2 = end.
    static func upgradeControlAnalog(_ b: RecognitionBuffer, _ m: Int, _ u: inout UpgradeState, rytm: Bool) {
        switch b[m + 1] {
        case 1:
            if b[m + 9] != 0xF7 {
                u.broken = true
            } else {
                let v1 = b.u21(m + 3)
                u.v1 = v1
                if v1 != 0xF2 { u.broken = true; return } // seed not latched on this path
                u.v2 = b.u21(m + 6)
            }
            u.seed = b.s8(m + 2)
            if rytm && b[m + 2] != 0x02 { u.broken = true }
        case 2:
            if b[m + 9] != 0xF7 {
                u.broken = true
            } else {
                let v1 = b.u21(m + 3)
                u.v1 = v1
                if v1 != 0xF2 { u.broken = true; return }
            }
            guard let v2 = u.v2 else { u.broken = true; return }
            if u.good != v2 { u.broken = true }
            if b.u21(m + 6) != v2 { u.broken = true }
        default:
            u.broken = true
        }
    }
}
