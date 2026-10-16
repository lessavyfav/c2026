import Foundation

/// File Info for MIDI Sample Dump Standard buffers (spec §4; Mac 0xabc4, Win 0x403dcf).
///
/// Used only when the buffer starts with a Dump Header and no Elektron or audio test matched.
/// The header line comes from the first header; a byte-wise state machine then counts correct and
/// broken dumps.
enum SampleDumpDescriber {
    enum HeaderKind: Equatable {
        /// `F0 7E dev 01 …` (21 bytes).
        case standard
        /// `F0 7E dev 05 05 …` (34 bytes; recognised here, not in the original — deviation 3).
        case extended
    }

    struct Header: Equatable {
        var bits: Int
        var rate: Int
        var length: Int
        var loopStart: Int
        var loopEnd: Int
        /// Loop type 0x7F.
        var loopOff: Bool
    }

    static func headerKind(_ b: RecognitionBuffer) -> HeaderKind? {
        guard b.count >= 4, b[0] == 0xF0, b[1] == 0x7E else { return nil }
        if b[3] == 0x01 { return .standard }
        if b.count >= 5, b[3] == 0x05, b[4] == 0x05 { return .extended }
        return nil
    }

    static func header(_ b: RecognitionBuffer, kind: HeaderKind) -> Header {
        switch kind {
        case .standard:
            let period = b.le7(7, length: 3) // sample period in ns
            // Signed int division in the original; period 0 crashed it (deviation 4).
            var rate = period == 0 ? 0 : (1_000_000_000 + (period >> 1)) / period
            if rate == 44099 { rate = 44100 } else if rate == 48001 { rate = 48000 }
            return Header(bits: Int(b[6]), rate: rate, length: b.le7(10, length: 3),
                          loopStart: b.le7(13, length: 3), loopEnd: b.le7(16, length: 3), loopOff: b[19] == 0x7F)
        case .extended:
            // F0 7E dev 05 05 <num:2> <bits> <rate Hz:4> <fraction:4> <length:5> <loop start:5>
            // <loop end:5> <loop type> <channels> F7 — the layout C6 builds (Win 0x4041c8..).
            var rate = b.le7(8, length: 4)
            if b.le7(12, length: 4) >= 1 << 27 { rate += 1 } // round with the 28-bit fraction
            return Header(bits: Int(b[7]), rate: rate, length: b.le7(16, length: 5),
                          loopStart: b.le7(21, length: 5), loopEnd: b.le7(26, length: 5), loopOff: b[31] == 0x7F)
        }
    }

    static func describe(_ b: RecognitionBuffer) -> String {
        guard let kind = headerKind(b) else { return "" }
        let h = header(b, kind: kind)

        // State machine (jump table 0x11b80). States: 0 idle, -4 after F0, -3 after 7E,
        // -2 sub-ID, -1 after sub-ID 05 (extended; deviation 3), 1 header body, 2 data packet.
        var state = 0, xor = 0, cnt = 0, flag = 0, expect = 0, good = 0, bad = 0
        for byte in b.bytes {
            let x = Int(byte)
            switch state {
            case 0:
                if x == 0xF0 { state = -4 }
            case -4:
                xor = 0x7E
                state = x == 0x7E ? -3 : 0
            case -3:
                xor ^= x // device number
                state = -2
            case -2:
                if x == 0x01 {
                    state = 1
                    if flag == 1 { good += 1 } // previous dump ends good
                } else if x == 0x05 {
                    state = -1
                } else {
                    state = x == 0x02 ? 2 : 0
                }
                xor ^= x
                cnt = 0
            case -1:
                if x == 0x05 {
                    state = 1
                    if flag == 1 { good += 1 }
                } else {
                    state = 0 // e.g. 05 03 sample name, 05 01/02 loop points
                }
            case 1:
                if x == 0xF7 { state = 0; expect = 0 }
                flag = 1
            case 2:
                if x == 0xF7 { // truncated packet
                    bad += 1; state = 0; flag = 0
                } else if cnt == 0 { // packet number
                    if x != expect { bad += 1; state = 0; flag = 0 }
                    expect += 1
                    if expect == 0x80 { expect = 0 }
                    cnt = 1
                    xor ^= x
                } else if cnt <= 0x78 { // 120 data bytes
                    xor ^= x
                    cnt += 1
                } else { // cnt == 0x79: checksum byte
                    state = 0
                    cnt = 0
                    if x != xor { flag = 0 }
                }
            default:
                break
            }
        }
        good += flag

        if bad == 1 && good == 0 { return InfoText.brokenSampleDump }
        if good == 1 && bad == 0 {
            return "Dump length: \(h.length) Sample Rate: \(h.rate)\n"
                + "Bits: \(h.bits) Loop \(h.loopOff ? "OFF" : "ON"). Loop start: \(h.loopStart) Loop end: \(h.loopEnd)"
        }
        return "\(good) correct and \(bad) broken sample dumps."
    }
}
