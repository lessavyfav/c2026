import Foundation

/// MIDI 1.0 byte stream <-> Universal MIDI Packet helpers.
///
/// CoreMIDI's non-deprecated I/O APIs speak UMP. C6 only ever deals in MIDI 1.0
/// byte streams (SysEx files, SDS packets), so we translate at the edge:
/// SysEx travels as "Data 64" (message type 0x3) SysEx7 packets, 6 bytes each,
/// and everything else we care about (realtime, short messages) as type 0x1/0x2.
public enum UMP {
    public enum SysExStatus: UInt32 {
        case complete = 0, start = 1, `continue` = 2, end = 3
    }

    /// Encodes the payload of one SysEx message (bytes between F0 and F7, exclusive)
    /// into SysEx7 UMP word pairs.
    public static func sysEx7Words(payload: ArraySlice<UInt8>, group: UInt8 = 0) -> [UInt32] {
        var words: [UInt32] = []
        words.reserveCapacity((payload.count / 6 + 1) * 2)
        let chunks = stride(from: payload.startIndex, to: max(payload.endIndex, payload.startIndex + 1), by: 6)
        let count = max(1, (payload.count + 5) / 6)
        var index = 0
        for start in chunks {
            let end = min(start + 6, payload.endIndex)
            let status: SysExStatus
            if count == 1 { status = .complete }
            else if index == 0 { status = .start }
            else if index == count - 1 { status = .end }
            else { status = .continue }
            words.append(contentsOf: sysEx7Packet(status: status, bytes: payload[start..<end], group: group))
            index += 1
        }
        return words
    }

    public static func sysEx7Packet(status: SysExStatus, bytes: ArraySlice<UInt8>, group: UInt8 = 0) -> [UInt32] {
        precondition(bytes.count <= 6)
        var b = [UInt8](repeating: 0, count: 6)
        for (i, v) in bytes.enumerated() { b[i] = v & 0x7F }
        let w0 = (UInt32(0x3) << 28) | (UInt32(group & 0xF) << 24) | (status.rawValue << 20)
            | (UInt32(bytes.count) << 16) | (UInt32(b[0]) << 8) | UInt32(b[1])
        let w1 = (UInt32(b[2]) << 24) | (UInt32(b[3]) << 16) | (UInt32(b[4]) << 8) | UInt32(b[5])
        return [w0, w1]
    }

    /// Number of 32-bit words in a UMP whose first word is `w0`.
    public static func wordCount(_ w0: UInt32) -> Int {
        switch w0 >> 28 {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }
}

/// Turns a UMP word stream back into MIDI 1.0 messages. SysEx is reassembled into
/// complete `F0 … F7` byte arrays; other MIDI 1.0 messages are passed through as bytes.
public struct UMPToMIDI1Decoder {
    private var sysex: [UInt8] = []
    private var inSysEx = false

    public init() {}

    public mutating func reset() { sysex.removeAll(keepingCapacity: true); inSysEx = false }

    /// Feeds words; calls `emit` for each complete MIDI 1.0 message.
    public mutating func decode(_ words: UnsafeBufferPointer<UInt32>, emit: ([UInt8]) -> Void) {
        var i = 0
        while i < words.count {
            let w0 = words[i]
            let n = UMP.wordCount(w0)
            guard i + n <= words.count else { return }
            switch w0 >> 28 {
            case 0x1: // system common / realtime
                let status = UInt8((w0 >> 16) & 0xFF)
                let d1 = UInt8((w0 >> 8) & 0x7F), d2 = UInt8(w0 & 0x7F)
                switch status {
                case 0xF1, 0xF3: emit([status, d1])
                case 0xF2: emit([status, d1, d2])
                default: emit([status])
                }
            case 0x2: // MIDI 1.0 channel voice
                let status = UInt8((w0 >> 16) & 0xFF)
                let d1 = UInt8((w0 >> 8) & 0x7F), d2 = UInt8(w0 & 0x7F)
                switch status & 0xF0 {
                case 0xC0, 0xD0: emit([status, d1])
                default: emit([status, d1, d2])
                }
            case 0x3: // SysEx7
                let w1 = words[i + 1]
                let status = (w0 >> 20) & 0xF
                let count = Int((w0 >> 16) & 0xF)
                let bytes: [UInt8] = [
                    UInt8((w0 >> 8) & 0xFF), UInt8(w0 & 0xFF),
                    UInt8(w1 >> 24), UInt8((w1 >> 16) & 0xFF), UInt8((w1 >> 8) & 0xFF), UInt8(w1 & 0xFF),
                ]
                let payload = bytes.prefix(min(count, 6))
                switch status {
                case 0: // complete in one packet
                    emit([0xF0] + payload + [0xF7]); inSysEx = false; sysex.removeAll(keepingCapacity: true)
                case 1: // start
                    sysex.removeAll(keepingCapacity: true); sysex.append(0xF0); sysex.append(contentsOf: payload); inSysEx = true
                case 2: // continue
                    if inSysEx { sysex.append(contentsOf: payload) }
                case 3: // end
                    if inSysEx { sysex.append(contentsOf: payload); sysex.append(0xF7); emit(sysex) }
                    inSysEx = false; sysex.removeAll(keepingCapacity: true)
                default: break
                }
            default: break // MIDI 2.0 / utility messages are not used by C6
            }
            i += n
        }
    }
}

/// Splits a MIDI 1.0 byte stream (e.g. a .syx file, or loose bytes) into messages.
/// Realtime bytes inside SysEx are dropped, as C6 did for 0xF8/0xFE.
///
/// **Spurious-EOX repair** (`repairSplitSysEx`, used for live input): on current macOS, when a
/// TurboMIDI Active Sensing byte (FE) arrives from a TM-1 in the middle of a SysEx dump, CoreMIDI's
/// USB MIDI path inserts an F7 before the FE and delivers the rest of the dump as loose data bytes
/// (observed with a Machinedrum at 10×: ~1 kit in 4 cut). Data bytes after an F7 have no other
/// legal meaning (EOX clears running status), so the parser holds each completed SysEx back until
/// the next non-realtime byte: a data byte means the F7 was spurious and the message continues.
/// Call `flush` once the line has gone quiet to release the held message.
public struct MIDI1StreamParser {
    private var buffer: [UInt8] = []
    private var inSysEx = false
    private var pending: [UInt8]?
    public var repairSplitSysEx: Bool
    public private(set) var repairedCount = 0

    public init(repairSplitSysEx: Bool = false) { self.repairSplitSysEx = repairSplitSysEx }

    /// Whether a completed SysEx is being held back (see `flush`).
    public var hasPending: Bool { pending != nil }

    public mutating func feed<S: Sequence>(_ bytes: S, emit: ([UInt8]) -> Void) where S.Element == UInt8 {
        for b in bytes {
            if b >= 0xF8 { continue } // realtime: ignore (C6 filtered F8 clock and FE active sensing)
            if b == 0xF0 {
                flush(emit: emit)
                buffer.removeAll(keepingCapacity: true); buffer.append(b); inSysEx = true
            } else if b == 0xF7 {
                if inSysEx {
                    buffer.append(b)
                    // Hold back only messages that might have been cut short; ones whose own
                    // structure proves they're whole (handshakes, valid checksums) go out at once,
                    // so SDS ACK round trips aren't delayed by the repair window.
                    if repairSplitSysEx && !SysExCompleteness.isSelfEvidentlyComplete(buffer) { pending = buffer } else { emit(buffer) }
                }
                buffer.removeAll(keepingCapacity: true); inSysEx = false
            } else if b < 0x80 {
                if inSysEx {
                    buffer.append(b)
                } else if var p = pending {
                    p.removeLast() // drop the spurious F7 and continue the message
                    buffer = p; buffer.append(b); inSysEx = true; pending = nil
                    repairedCount += 1
                }
                // otherwise a stray data byte: ignore
            } else {
                flush(emit: emit)
                if inSysEx { buffer.removeAll(keepingCapacity: true); inSysEx = false } // aborted SysEx
            }
        }
    }

    /// Emits a held-back SysEx (call when no more input is expected for now).
    public mutating func flush(emit: ([UInt8]) -> Void) {
        if let p = pending { pending = nil; emit(p) }
    }
}
