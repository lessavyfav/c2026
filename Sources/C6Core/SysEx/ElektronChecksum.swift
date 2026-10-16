import Foundation

/// Validation of the trailer most Elektron dumps share:
/// `… <chk hi> <chk lo> <len hi> <len lo> F7`.
///
/// From C6 1.51 (Mac recognizer around 0xff51): the checksum is the 14-bit sum of the bytes from
/// three past the message ID (i.e. after ID, version, revision) up to the checksum itself, stored
/// as two 7-bit bytes; the length field equals (F7 index − message-ID index − 3).
public enum ElektronChecksum {
    /// Index of the message-ID byte in `F0 00 20 3C <dev> 00 <id> …`.
    public static let messageIDIndex = 6

    public static func isValid(_ msg: [UInt8], messageIDIndex idIndex: Int = messageIDIndex) -> Bool {
        guard msg.count >= idIndex + 8, msg.first == 0xF0, msg.last == 0xF7 else { return false }
        let f7 = msg.count - 1
        let storedSum = Int(msg[f7 - 4]) << 7 | Int(msg[f7 - 3])
        let storedLen = Int(msg[f7 - 2]) << 7 | Int(msg[f7 - 1])
        var sum = 0
        for i in (idIndex + 3)..<(f7 - 4) { sum += Int(msg[i]) }
        return (sum & 0x3FFF) == storedSum && storedLen + 3 == f7 - idIndex
    }
}
