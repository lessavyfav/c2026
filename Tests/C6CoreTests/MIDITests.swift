@testable import C6Core
import Testing

/// Records what a protocol engine sends, and lets a test inject replies.
final class MockTransport: MIDITransport {
    var onReceive: (([UInt8]) -> Void)?
    private(set) var sent: [(bytes: [UInt8], at: UInt64?)] = []
    var autoReply: (([UInt8]) -> [UInt8]?)?
    private var parser = MIDI1StreamParser()

    func sendStream(_ bytes: ArraySlice<UInt8>, at hostTime: UInt64?) {
        sent.append((Array(bytes), hostTime))
        parser.feed(bytes) { msg in
            if let reply = autoReply?(msg) { onReceive?(reply) }
        }
    }

    func flushScheduled() {}
    var allBytes: [UInt8] { sent.flatMap { $0.bytes } }
}

@Suite struct UMPTests {
    func roundTrip(_ msg: [UInt8], fragments: Int = 1) -> [[UInt8]] {
        var enc = MIDI1ToUMPEncoder()
        var words: [UInt32] = []
        let size = max(1, msg.count / fragments)
        var i = 0
        while i < msg.count { words += enc.encode(msg[i..<min(msg.count, i + size)]); i += size }
        var dec = UMPToMIDI1Decoder()
        var out: [[UInt8]] = []
        words.withUnsafeBufferPointer { dec.decode($0) { out.append($0) } }
        return out
    }

    @Test(arguments: [0, 1, 5, 6, 7, 12, 13, 300, 70_000])
    func sysexRoundTrip(payloadLength: Int) {
        let msg = [0xF0] + (0..<payloadLength).map { UInt8($0 % 128) } + [0xF7]
        #expect(roundTrip(msg) == [msg])
        #expect(roundTrip(msg, fragments: 7) == [msg])
    }

    @Test func shortMessagesPassThrough() {
        #expect(roundTrip([0x90, 0x3C, 0x64]) == [[0x90, 0x3C, 0x64]])
        #expect(roundTrip([0xC1, 0x05]) == [[0xC1, 0x05]])
    }

    /// What CoreMIDI delivers when a TM-1 keep-alive lands inside a dump: a spurious F7 before the
    /// FE, then the rest of the message as loose data bytes. Captured pattern from real hardware.
    @Test func repairsSysExSplitBySpuriousEOX() {
        var p = MIDI1StreamParser(repairSplitSysEx: true)
        var out: [[UInt8]] = []
        p.feed([0xF0, 0x00, 0x20, 0x3C, 0x01, 0x02, 0xF7]) { out.append($0) }
        #expect(out.isEmpty && p.hasPending)                 // held back
        p.feed([0xFE, 0x03, 0x04, 0xF7, 0xF0, 0x05, 0xF7]) { out.append($0) }
        p.flush { out.append($0) }
        #expect(out == [[0xF0, 0x00, 0x20, 0x3C, 0x01, 0x02, 0x03, 0x04, 0xF7], [0xF0, 0x05, 0xF7]])
        #expect(p.repairedCount == 1)
    }

    /// Handshakes and checksum-valid messages must not wait for the repair window.
    @Test func selfEvidentlyCompleteMessagesAreNotHeld() {
        var p = MIDI1StreamParser(repairSplitSysEx: true)
        var out: [[UInt8]] = []
        p.feed([0xF0, 0x7E, 0x00, 0x7F, 0x05, 0xF7]) { out.append($0) }                       // SDS ACK
        p.feed([0xF0, 0x00, 0x20, 0x3C, 0x04, 0x00, 0x02, 0x08, 0xF7]) { out.append($0) }   // TM-1 status
        var pkt: [UInt8] = [0xF0, 0x7E, 0x00, 0x02, 0x01] + [UInt8](repeating: 0x11, count: 120)
        pkt.append(pkt[1...].reduce(0, ^) & 0x7F); pkt.append(0xF7)
        p.feed(pkt) { out.append($0) }                                                         // SDS data packet
        #expect(out.count == 3 && !p.hasPending)
        // A data packet with a bad checksum could be a cut-off message: held.
        var bad = pkt; bad[10] ^= 1
        p.feed(bad) { out.append($0) }
        #expect(out.count == 3 && p.hasPending)
    }

    @Test func noRepairWithoutFlagOrForGenuineEnds() {
        var plain = MIDI1StreamParser()
        var out: [[UInt8]] = []
        plain.feed([0xF0, 0x01, 0xF7, 0xFE, 0x02, 0xF7]) { out.append($0) }
        #expect(out == [[0xF0, 0x01, 0xF7]])
        var r = MIDI1StreamParser(repairSplitSysEx: true)
        out = []
        r.feed([0xF0, 0x01, 0xF7, 0x90, 0x3C, 0x40]) { out.append($0) }   // a status byte confirms the F7
        #expect(out == [[0xF0, 0x01, 0xF7]] && !r.hasPending)
    }

    @Test func streamParserSplitsAndDropsRealtime() {
        var p = MIDI1StreamParser()
        var out: [[UInt8]] = []
        p.feed([0xF0, 0x01, 0xF8, 0x02, 0xF7, 0xFE, 0xF0, 0x03, 0xF7]) { out.append($0) }
        #expect(out == [[0xF0, 0x01, 0x02, 0xF7], [0xF0, 0x03, 0xF7]])
    }
}

@Suite struct TurboTests {
    @Test func messagesMatchC6() {
        #expect(TM1Message.statusRequest == [0xF0, 0x00, 0x20, 0x3C, 0x04, 0x00, 0x01, 0xF7])
        #expect(TM1Message.setSpeed(.x20) == [0xF0, 0x00, 0x20, 0x3C, 0x04, 0x00, 0x03, 0x0B, 0xF7])
        // The reply observed from a real TM-1 with a Machinedrum attached.
        #expect(TM1Message.parseStatus([0xF0, 0x00, 0x20, 0x3C, 0x04, 0x00, 0x02, 0x08, 0xF7]) == .x10)
        #expect(TM1Message.parseStatus([0xF0, 0x00, 0x20, 0x3C, 0x02, 0x00, 0x02, 0x08, 0xF7]) == nil)
    }

    @Test func speedTable() {
        #expect(TurboSpeed.allCases.map(\.label) == ["1×", "2×", "3.3×", "4×", "5×", "6.7×", "8×", "10×", "13.3×", "16×", "20×"])
        #expect(TurboSpeed.x20.baud == 625_000)
        #expect(TurboSpeed(code: 0) == .x1)
    }

    @Test func controllerNegotiates() {
        let t = MockTransport()
        let tm1 = TM1Controller(transport: t)
        t.onReceive = { tm1.handle($0) }
        // Fake TM-1 whose device supports at most 10x.
        t.autoReply = { msg in
            if msg == TM1Message.statusRequest { return [0xF0, 0x00, 0x20, 0x3C, 0x04, 0x00, 0x02, 0x01, 0xF7] }
            if msg.count == 9, Array(msg.prefix(7)) == [0xF0, 0x00, 0x20, 0x3C, 0x04, 0x00, 0x03] {
                return [0xF0, 0x00, 0x20, 0x3C, 0x04, 0x00, 0x02, min(msg[7], 8), 0xF7]
            }
            return nil
        }
        #expect(tm1.queryStatus() == .x1)
        #expect(tm1.setSpeed(.x20) == .x10)
        #expect(tm1.speed == .x10)
    }

    @Test func noTM1TimesOut() {
        let tm1 = TM1Controller(transport: MockTransport())
        #expect(tm1.queryStatus(timeout: 0.05) == nil)
        #expect(!tm1.isPresent)
    }
}

@Suite struct PacingTests {
    @Test func pacesAtLineRate() {
        let t = MockTransport()
        var sender = PacedSender(transport: t, options: .init(bytesPerSecond: 31_250)) // 10x
        sender.options.lookahead = 0.005
        let data = [UInt8](repeating: 0x10, count: 3_125) // 0.1 s at 10x
        let start = HostTime.now
        let (result, _) = sender.send(([0xF0] + data + [0xF7])[...])
        let elapsed = HostTime.seconds(fromTicks: HostTime.now - start)
        #expect(result == .completed)
        #expect(elapsed > 0.095 && elapsed < 0.2)
        #expect(t.allBytes.count == data.count + 2)
        // Timestamps increase monotonically and span ~0.1 s.
        let stamps = t.sent.compactMap(\.at)
        #expect(stamps == stamps.sorted())
        #expect(abs(HostTime.seconds(fromTicks: stamps.last! - stamps.first!) - 0.1) < 0.01)
    }

    @Test func cancelStopsEarly() {
        let t = MockTransport()
        let sender = PacedSender(transport: t, options: .init(bytesPerSecond: 3_125))
        let start = HostTime.now
        let (result, _) = sender.send([UInt8](repeating: 0, count: 10_000)[...], isCancelled: {
            HostTime.seconds(fromTicks: HostTime.now - start) > 0.05
        })
        #expect(result == .cancelled)
        #expect(HostTime.seconds(fromTicks: HostTime.now - start) < 0.2)
    }
}
