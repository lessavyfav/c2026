import Foundation

/// Decides whether a received SysEx message is provably complete from its own structure.
///
/// Used by the spurious-EOX repair (`MIDI1StreamParser.repairSplitSysEx`): a message cut short by
/// CoreMIDI fails these checks and is held briefly for its continuation; everything else is
/// delivered without delay.
public enum SysExCompleteness {
    public static func isSelfEvidentlyComplete(_ m: [UInt8]) -> Bool {
        guard m.count >= 4, m.first == 0xF0, m.last == 0xF7 else { return false }
        if m[1] == 0x7E { return isCompleteSampleDumpMessage(m) }
        if TM1Message.parseStatus(m) != nil, m.count == 9 { return true }
        if m.count > 6, Array(m[1...3]) == Elektron.manufacturerID, ElektronChecksum.isValid(m) { return true }
        return false
    }

    /// MIDI Sample Dump Standard messages with a fixed size (and checksum where there is one).
    static func isCompleteSampleDumpMessage(_ m: [UInt8]) -> Bool {
        switch m[3] {
        case 0x7B...0x7F: return m.count == 6          // EOF / WAIT / CANCEL / NAK / ACK
        case 0x01: return m.count == 21                // dump header
        case 0x03: return m.count == 7                 // dump request
        case 0x02:                                     // data packet with XOR checksum
            guard m.count == 127 else { return false }
            var x: UInt8 = 0
            for b in m[1...124] { x ^= b }
            return (x & 0x7F) == m[125]
        default: return false
        }
    }
}
