@testable import C6Core
import Foundation
import Testing

// MARK: - Test helpers

/// Deterministic PRNG for test data.
private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A sample with random words over the full range (first three words: min, max, 0).
private func makeSample(bits: Int, count: Int, seed: UInt64 = 1, name: String? = nil,
                        sampleNumber: Int = 0, rate: Int = 44100) -> SDSSample {
    let f = SDSWordFormat(bits: bits)!
    var rng = SplitMix64(state: seed)
    let lo = Int64(f.minValue), span = UInt64(Int64(f.maxValue) - lo + 1)
    var words = (0..<count).map { _ in Int32(lo + Int64(rng.next() % span)) }
    if count >= 3 { words[0] = f.minValue; words[1] = f.maxValue; words[2] = 0 }
    return SDSSample(samples: words, bits: bits, sampleRate: rate, loopStart: count / 4, loopEnd: count - 1,
                     loopType: SDSSample.loopForward, name: name, sampleNumber: sampleNumber)
}

private func fastOptions(handshake: Bool = true) -> SDSSender.Options {
    var o = SDSSender.Options()
    o.handshake = handshake
    o.lineRate = 1_000_000          // keeps tests quick; the pacing test uses its own rate
    o.headerReplyTimeout = 0.3
    return o
}

/// A scripted SDS receiving device: parses what the sender transmits and answers each header
/// and data packet according to `script`.
private final class SimulatedDevice: MIDITransport {
    enum Kind: Equatable {
        case header(sampleNumber: Int)
        /// `nth` counts data packets received so far (resends included), from 0.
        case packet(number: UInt8, nth: Int)
    }
    enum Action { case ack, nak, cancel, silent, waitThenAck(Double) }

    var onReceive: (([UInt8]) -> Void)?
    /// Where replies go (the sender's `handle`).
    var deliver: (([UInt8]) -> Void)?
    let device: UInt8
    let script: (Kind) -> Action

    private let lock = NSLock()
    private var parser = MIDI1StreamParser()
    private var _messages: [[UInt8]] = []
    private var _starts: [UInt64] = []
    private var nth = 0

    init(device: UInt8 = 0, script: @escaping (Kind) -> Action = { _ in .ack }) {
        self.device = device
        self.script = script
    }

    var messages: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return _messages }
    /// Scheduled time of the first byte of each paced message.
    var messageStarts: [UInt64] { lock.lock(); defer { lock.unlock() }; return _starts }
    var packets: [SDSDataPacket] {
        messages.compactMap { if case let .dataPacket(p)? = SDSMessage.decode($0) { return p } else { return nil } }
    }
    var packetCount: Int { lock.lock(); defer { lock.unlock() }; return nth }

    func sendStream(_ bytes: ArraySlice<UInt8>, at hostTime: UInt64?) {
        var complete: [[UInt8]] = []
        lock.lock()
        if bytes.first == 0xF0, let t = hostTime { _starts.append(t) }
        parser.feed(bytes) { complete.append($0) }
        _messages += complete
        lock.unlock()
        complete.forEach(react)
    }

    func flushScheduled() {}

    private func react(_ m: [UInt8]) {
        let kind: Kind
        switch SDSMessage.decode(m) {
        case let .dumpHeader(h)?: kind = .header(sampleNumber: h.sampleNumber)
        case let .extendedDumpHeader(h)?: kind = .header(sampleNumber: h.sampleNumber)
        case let .dataPacket(p)?:
            lock.lock(); kind = .packet(number: p.number, nth: nth); nth += 1; lock.unlock()
        default: return
        }
        var pkt: UInt8 = 0
        if case let .packet(n, _) = kind { pkt = n }
        let dev = device
        switch script(kind) {
        case .ack: deliver?(SDSMessage.ack(device: dev, packet: pkt).bytes())
        case .nak: deliver?(SDSMessage.nak(device: dev, packet: pkt).bytes())
        case .cancel: deliver?(SDSMessage.cancel(device: dev, packet: pkt).bytes())
        case .silent: break
        case let .waitThenAck(seconds):
            deliver?(SDSMessage.wait(device: dev, packet: pkt).bytes())
            let d = deliver
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                d?(SDSMessage.ack(device: dev, packet: pkt).bytes())
            }
        }
    }
}

/// A one-way MIDI cable: parses what is sent and hands complete messages to `deliver`,
/// optionally altering them (`transform`, called with the message index).
private final class Wire: MIDITransport {
    var onReceive: (([UInt8]) -> Void)?
    var deliver: (([UInt8]) -> Void)?
    var transform: (([UInt8], Int) -> [UInt8])?
    private let lock = NSLock()
    private var parser = MIDI1StreamParser()
    private var _sent: [[UInt8]] = []

    var sent: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return _sent }

    func sendStream(_ bytes: ArraySlice<UInt8>, at hostTime: UInt64?) {
        var complete: [[UInt8]] = []
        lock.lock()
        parser.feed(bytes) { complete.append($0) }
        var out: [[UInt8]] = []
        for m in complete {
            out.append(transform?(m, _sent.count) ?? m)
            _sent.append(m)
        }
        lock.unlock()
        out.forEach { deliver?($0) }
    }

    func flushScheduled() {}
}

private func expectSameAudio(_ got: SDSSample, _ want: SDSSample, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(got.samples == want.samples, sourceLocation: sourceLocation)
    #expect(got.bits == want.bits, sourceLocation: sourceLocation)
    #expect(got.samplePeriodNs == want.samplePeriodNs, sourceLocation: sourceLocation)
    #expect(got.loopStart == want.loopStart, sourceLocation: sourceLocation)
    #expect(got.loopEnd == want.loopEnd, sourceLocation: sourceLocation)
    #expect(got.loopType == want.loopType, sourceLocation: sourceLocation)
}

// MARK: - Encoding

@Suite struct SDSEncodingTests {
    @Test func wordFormatTable() {
        let table: [(Int, Int, Int)] = [(8, 2, 60), (12, 2, 60), (14, 2, 60), (15, 3, 40), (16, 3, 40),
                                       (20, 3, 40), (21, 3, 40), (22, 4, 30), (24, 4, 30), (28, 4, 30)]
        for (bits, bpw, spp) in table {
            let f = SDSWordFormat(bits: bits)
            #expect(f?.bytesPerWord == bpw && f?.samplesPerPacket == spp, "bits \(bits)")
        }
        #expect(SDSWordFormat(bits: 29) == nil)
        #expect(SDSWordFormat(bits: 0) == nil)
        #expect(SDSWordFormat(bits: 16)!.packetCount(forLength: 81) == 3)
    }

    /// Offset binary, left-justified, MSB group first (spec §2.3), worked by hand.
    @Test func sampleWordsByHand() {
        let f16 = SDSWordFormat(bits: 16)!
        let p16 = f16.encode([0, -32768, 32767] as [Int32])
        #expect(Array(p16.prefix(9)) == [0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7F, 0x7F, 0x60])
        #expect(p16.count == 120)
        #expect(Array(p16[9..<12]) == [0x40, 0x00, 0x00]) // padding is mid-scale (v = 0)

        #expect(Array(SDSWordFormat(bits: 8)!.encode([0, 127, -128] as [Int32]).prefix(6))
            == [0x40, 0x00, 0x7F, 0x40, 0x00, 0x00])
        #expect(Array(SDSWordFormat(bits: 12)!.encode([0, 2047] as [Int32]).prefix(4)) == [0x40, 0x00, 0x7F, 0x7C])
        #expect(Array(SDSWordFormat(bits: 20)!.encode([0, 524_287] as [Int32]).prefix(6))
            == [0x40, 0x00, 0x00, 0x7F, 0x7F, 0x7E])
        #expect(Array(SDSWordFormat(bits: 24)!.encode([0, -1] as [Int32]).prefix(8))
            == [0x40, 0x00, 0x00, 0x00, 0x3F, 0x7F, 0x7F, 0x70])
        // Out-of-range values are clamped.
        #expect(Array(SDSWordFormat(bits: 8)!.encode([1000] as [Int32]).prefix(2)) == [0x7F, 0x40])
    }

    @Test(arguments: [8, 12, 14, 16, 20, 21, 24, 28])
    func packetRoundTrip(bits: Int) throws {
        let sample = makeSample(bits: bits, count: 333, seed: UInt64(bits))
        let f = try #require(SDSWordFormat(bits: bits))
        var decoded: [Int32] = []
        for k in 0..<f.packetCount(forLength: sample.length) {
            let bytes = SDSMessage.dataPacket(SDSDataPacket(sample: sample, index: k, device: 3, format: f)).bytes()
            #expect(bytes.count == 127)
            guard case let .dataPacket(p)? = SDSMessage.decode(bytes) else { Issue.record("not a packet"); return }
            #expect(p.isChecksumValid && p.number == UInt8(k) && p.device == 3)
            decoded += f.decode(p.data)
        }
        #expect(Array(decoded.prefix(sample.length)) == sample.samples)
        #expect(decoded.dropFirst(sample.length).allSatisfy { $0 == 0 })
    }

    @Test func checksumsByHand() {
        // 16-bit silence: data is 40 00 00 × 40 → the 0x40s cancel out; cs = 7E ^ 00 ^ 02 ^ 00.
        let silence16 = SDSWordFormat(bits: 16)!.encode([] as [Int32])
        #expect(SDSDataPacket(device: 0, number: 0, data: silence16).checksum == 0x7C)
        // 8-bit silence (40 00 × 60), device 1, packet 5: 7E ^ 01 ^ 02 ^ 05 = 0x78.
        let silence8 = SDSWordFormat(bits: 8)!.encode([] as [Int32])
        let bytes = SDSMessage.dataPacket(SDSDataPacket(device: 1, number: 5, data: silence8)).bytes()
        #expect(Array(bytes.prefix(7)) == [0xF0, 0x7E, 0x01, 0x02, 0x05, 0x40, 0x00])
        #expect(Array(bytes.suffix(2)) == [0x78, 0xF7])
        var broken = bytes
        broken[50] ^= 0x01
        guard case let .dataPacket(p)? = SDSMessage.decode(broken) else { Issue.record("not a packet"); return }
        #expect(!p.isChecksumValid)
        #expect(SDSMessage.decode(Array(bytes.prefix(100)) + [0xF7]) == nil)
        #expect(SDSMessage.isDataPacket(Array(bytes.prefix(100)) + [0xF7]))
    }

    /// 16 bits, 44.1 kHz (period 22676 ns), 1000 words, loop 0…999 off, sample number 300.
    @Test func dumpHeaderByHand() {
        let header = SDSDumpHeader(device: 0, sampleNumber: 300, bits: 16, samplePeriodNs: 22676, length: 1000,
                                   loopStart: 0, loopEnd: 999, loopType: 0x7F)
        let bytes: [UInt8] = [0xF0, 0x7E, 0x00, 0x01, 0x2C, 0x02, 0x10, 0x14, 0x31, 0x01, 0x68, 0x07, 0x00,
                              0x00, 0x00, 0x00, 0x67, 0x07, 0x00, 0x7F, 0xF7]
        #expect(SDSMessage.dumpHeader(header).bytes() == bytes)
        #expect(SDSMessage.decode(bytes) == .dumpHeader(header))
        #expect(SDSSample.period(forRate: 44100) == 22676)
        #expect(SDSSample.rate(forPeriod: 22676) == 44100) // 44099 fix-up
        #expect(SDSSample.rate(forPeriod: SDSSample.period(forRate: 48000)) == 48000)
        let s = SDSSample(samples: [Int32](repeating: 0, count: 1000), bits: 16, sampleRate: 44100, sampleNumber: 300)
        #expect(SDSDumpHeader(sample: s, device: 0) == header) // default loop: 0…length−1, off
    }

    @Test func extendedHeaderAndNameByHand() {
        let h = SDSExtendedDumpHeader(device: 0, sampleNumber: 300, bits: 16, sampleRate: 44100, length: 1000,
                                      loopStart: 0, loopEnd: 999, loopType: 0x7F)
        let c6: [UInt8] = [0xF0, 0x7E, 0x00, 0x05, 0x05, 0x02, 0x2C, 0x10, 0x44, 0x58, 0x02, 0x00,
                           0x00, 0x00, 0x00, 0x00, 0x68, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                           0x67, 0x07, 0x00, 0x00, 0x00, 0x7F, 0x01, 0xF7]
        #expect(c6.count == 34)
        #expect(SDSMessage.extendedDumpHeader(h).bytes() == c6) // default order = C6's (MSB first)
        #expect(SDSMessage.decode(c6) == .extendedDumpHeader(h))
        var lsb = c6; lsb[5] = 0x2C; lsb[6] = 0x02
        #expect(SDSMessage.extendedDumpHeader(h).bytes(order: .lsbFirst) == lsb)
        #expect(SDSMessage.decode(lsb, order: .lsbFirst) == .extendedDumpHeader(h))

        let name = SDSSampleName(device: 0, sampleNumber: 300, name: "kick")
        let nameBytes: [UInt8] = [0xF0, 0x7E, 0x00, 0x05, 0x03, 0x02, 0x2C, 0x00, 0x04, 0x6B, 0x69, 0x63, 0x6B, 0xF7]
        #expect(SDSMessage.sampleName(name).bytes() == nameBytes)
        #expect(SDSMessage.decode(nameBytes) == .sampleName(name))
        // 7-bit names: diacritics folded, length byte is the real count, at most 127 characters.
        #expect(Array(SDSMessage.sampleName(SDSSampleName(device: 0, sampleNumber: 1, name: "café")).bytes()[8...12])
            == [0x04, 0x63, 0x61, 0x66, 0x65])
        let long = SDSMessage.sampleName(SDSSampleName(device: 0, sampleNumber: 1, name: String(repeating: "a", count: 130))).bytes()
        #expect(long[8] == 127 && long.count == 9 + 127 + 1)
    }

    @Test func handshakeAndRequestMessages() {
        #expect(SDSMessage.ack(device: 5, packet: 3).bytes() == [0xF0, 0x7E, 0x05, 0x7F, 0x03, 0xF7])
        #expect(SDSMessage.nak(device: 5, packet: 3).bytes() == [0xF0, 0x7E, 0x05, 0x7E, 0x03, 0xF7])
        #expect(SDSMessage.cancel(device: 5, packet: 3).bytes() == [0xF0, 0x7E, 0x05, 0x7D, 0x03, 0xF7])
        #expect(SDSMessage.wait(device: 5, packet: 3).bytes() == [0xF0, 0x7E, 0x05, 0x7C, 0x03, 0xF7])
        #expect(SDSMessage.eof(device: 5, packet: 3).bytes() == [0xF0, 0x7E, 0x05, 0x7B, 0x03, 0xF7])
        #expect(SDSMessage.dumpRequest(device: 0, sampleNumber: 300).bytes() == [0xF0, 0x7E, 0x00, 0x03, 0x2C, 0x02, 0xF7])
        for m: SDSMessage in [.ack(device: 5, packet: 3), .nak(device: 1, packet: 127), .cancel(device: 0, packet: 0),
                              .wait(device: 2, packet: 9), .eof(device: 3, packet: 4),
                              .dumpRequest(device: 0, sampleNumber: 300)] {
            #expect(SDSMessage.decode(m.bytes()) == m)
        }
        #expect(SDSMessage.decode([0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7]) == nil) // identity request
    }

    @Test func spsNameMessage() {
        #expect(SDSMessage.spsNameMessage(slot: 5, name: "KICK")
            == [0xF0, 0x00, 0x20, 0x3C, 0x02, 0x00, 0x73, 0x05, 0x4B, 0x49, 0x43, 0x4B, 0xF7])
        let hh = SDSMessage.spsNameMessage(slot: 200, name: "HH")
        #expect(hh[7] == 200 & 0x7F)
        #expect(Array(hh[8...11]) == [0x48, 0x48, 0x20, 0x20])
        let parsed = SDSMessage.parseSPSName([0xF0, 0x00, 0x20, 0x3C, 0x02, 0x00, 0x73, 0x02, 0x5B, 0x53, 0x4B, 0x41, 0xF7])
        #expect(parsed?.slot == 2 && parsed?.name == "ÅSKA")
        #expect(SDSMessage.parseSPSName([0xF0, 0x00, 0x20, 0x3C, 0x02, 0x00, 0x52, 0x02, 0x5B, 0x53, 0x4B, 0x41, 0xF7]) == nil)
    }

    @Test func spsNameFromFileName() {
        #expect(SDSMessage.spsName(fromFileName: "kick.wav") == "KICK")
        #expect(SDSMessage.spsName(fromFileName: "snare01.aif") == "SNA1")
        #expect(SDSMessage.spsName(fromFileName: "hh.wav") == "HH  ")
        #expect(SDSMessage.spsName(fromFileName: "åska.wav") == "[SKA")
        #expect(SDSMessage.spsName(fromFileName: "A\u{30A}SKÖ.wav") == "[SK]")   // decomposed Å
        #expect(SDSMessage.spsName(fromFileName: "/Samples/Bass.Drum.wav") == "BASM")
        #expect(SDSMessage.spsName(fromFileName: "Clap") == "CLAP")
        #expect(SDSMessage.spsName(fromFileName: "café.wav") == "CAFE")
        #expect(SDSMessage.spsName(fromFileName: "ärt") == "\\RT ")
        #expect(SDSMessage.spsName(fromBaseName: "ÅSKA") == "[SKA")              // received names re-send as sent
        #expect(SDSMessage.baseName(ofFileName: "/a/b.c/d.e.wav") == "d.e")
    }

    @Test func loopModeAndStereo() {
        let s = SDSSample(samples: [1, 2, 3, 4], bits: 16, samplePeriodNs: 22676, loopStart: 2, loopEnd: 0, loopType: 0x81)
        let on = s.applyingLoopMode(.on)
        #expect(on.loopStart == 0 && on.loopEnd == 3 && on.loopType == 0)
        #expect(s.applyingLoopMode(.off).loopType == 0x7F)
        #expect(s.applyingLoopMode(.file).loopType == 0x01 && s.applyingLoopMode(.file).loopEnd == 0)
        #expect(SDSSample.monoWords(from: [[3, -3, 32767], [0, 0, 32767]], mode: .mix) == [1, -1, 32767])
        #expect(SDSSample.monoWords(from: [[1], [2]], mode: .right) == [2])
        #expect(SDSSample.monoWords(from: [[1], [2], [3]], mode: .right) == [1])
    }
}

// MARK: - Sender against a simulated device

@Suite(.serialized) struct SDSSenderTests {
    private func run(_ device: SimulatedDevice, _ samples: [SDSSample], options: SDSSender.Options,
                     isCancelled: @escaping () -> Bool = { false }) -> (SDSSender.Report, Double, [SDSSender.Progress]) {
        let sender = SDSSender(transport: device, options: options)
        device.deliver = { sender.handle($0) }
        var progress: [SDSSender.Progress] = []
        let start = HostTime.now
        let report = sender.send(samples, progress: { progress.append($0) }, isCancelled: isCancelled)
        return (report, HostTime.seconds(fromTicks: HostTime.now - start), progress)
    }

    @Test func handshakeSuccessWithAutoIncrement() throws {
        let device = SimulatedDevice(device: 3)
        var o = fastOptions(); o.deviceNumber = 3; o.startSampleNumber = 5
        let a = makeSample(bits: 16, count: 100, seed: 1), b = makeSample(bits: 8, count: 130, seed: 2)
        let (report, _, progress) = run(device, [a, b], options: o)
        #expect(report.outcome == .completed)
        #expect(report.samplesCompleted == 2 && report.sampleNumbers == [5, 6])
        #expect(report.packetsSent == 6 && report.resends == 0 && report.timeouts == 0 && report.openLoopSamples == 0)
        #expect(device.packets.map(\.number) == [0, 1, 2, 0, 1, 2])
        #expect(device.packets.allSatisfy { $0.isChecksumValid && $0.device == 3 })
        let headers = device.messages.compactMap { m -> SDSDumpHeader? in
            if case let .dumpHeader(h)? = SDSMessage.decode(m) { return h } else { return nil }
        }
        #expect(headers == [SDSDumpHeader(sample: a, device: 3, sampleNumber: 5), SDSDumpHeader(sample: b, device: 3, sampleNumber: 6)])
        let f16 = SDSWordFormat(bits: 16)!
        #expect(Array(device.packets.prefix(3).flatMap { f16.decode($0.data) }.prefix(100)) == a.samples)
        let last = try #require(progress.last)
        #expect(last.bytesDone == last.bytesTotal && last.bytesTotal == 2 * 21 + 6 * 127)
        #expect(last.sampleIndex == 1 && last.samplesDone == 130 && last.samplesTotal == 130)
    }

    @Test func nakResendsTheNakedPacket() {
        // NAK the first arrival of packet 1; ACK everything else.
        let device = SimulatedDevice { kind in kind == .packet(number: 1, nth: 1) ? .nak : .ack }
        let s = makeSample(bits: 16, count: 160)
        let (report, _, _) = run(device, [s], options: fastOptions())
        #expect(report.outcome == .completed)
        #expect(report.resends == 1 && report.packetsSent == 5)
        #expect(device.packets.map(\.number) == [0, 1, 1, 2, 3])
        #expect(device.packets[1] == device.packets[2])
    }

    @Test func staleNakIsIgnored() {
        // A NAK naming a packet that was not just sent is ignored; the ACK after it counts.
        let device = SimulatedDevice()
        var o = fastOptions(); o.packetReplyTimeout = 0.5 // the real ACK follows 20 ms later
        let sender = SDSSender(transport: device, options: o)
        device.deliver = { m in
            if case let .ack(_, p)? = SDSMessage.decode(m), p == 2 {
                sender.handle(SDSMessage.nak(device: 0, packet: 0).bytes())
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { sender.handle(m) }
                return
            }
            sender.handle(m)
        }
        let report = sender.send([makeSample(bits: 16, count: 160)])
        #expect(report.outcome == .completed && report.resends == 0 && report.timeouts == 0)
    }

    @Test func nakToHeaderResendsHeader() {
        let headerSeen = Counter()
        let device = SimulatedDevice { kind in
            if case .header = kind { return headerSeen.increment() == 0 ? .nak : .ack }
            return .ack
        }
        let (report, _, _) = run(device, [makeSample(bits: 16, count: 40)], options: fastOptions())
        #expect(report.outcome == .completed && report.resends == 1)
        #expect(device.messages.filter { $0.count == 21 }.count == 2)
    }

    @Test func tooManyNaksFails() {
        let device = SimulatedDevice(device: 2) { kind in if case .packet = kind { return .nak }; return .ack }
        var o = fastOptions(); o.deviceNumber = 2; o.maxResends = 3
        let (report, _, _) = run(device, [makeSample(bits: 16, count: 160)], options: o)
        guard case .failed = report.outcome else { Issue.record("expected failure, got \(report.outcome)"); return }
        #expect(device.packets.count == 4)
        #expect(device.messages.last == [0xF0, 0x7E, 0x02, 0x7D, 0x00, 0xF7])
    }

    @Test func waitPausesUntilAck() {
        let device = SimulatedDevice { kind in kind == .packet(number: 1, nth: 1) ? .waitThenAck(0.3) : .ack }
        let (report, elapsed, _) = run(device, [makeSample(bits: 16, count: 160)], options: fastOptions())
        #expect(report.outcome == .completed)
        #expect(report.waits == 1 && report.timeouts == 0 && report.packetsSent == 4)
        #expect(elapsed >= 0.3 && elapsed < 2)
    }

    @Test func waitCeilingFails() {
        let device = SimulatedDevice { kind in
            if kind == .packet(number: 0, nth: 0) { return .waitThenAck(5) } // ACK comes too late
            return .ack
        }
        var o = fastOptions(); o.waitTimeout = 0.1
        let (report, elapsed, _) = run(device, [makeSample(bits: 16, count: 160)], options: o)
        guard case .failed = report.outcome else { Issue.record("expected failure, got \(report.outcome)"); return }
        #expect(elapsed < 1)
        #expect(device.messages.last == SDSMessage.cancel(device: 0, packet: 0).bytes())
    }

    @Test func cancelByDevice() {
        let device = SimulatedDevice { kind in kind == .packet(number: 1, nth: 1) ? .cancel : .ack }
        let (report, _, _) = run(device, [makeSample(bits: 16, count: 400), makeSample(bits: 16, count: 40)], options: fastOptions())
        #expect(report.outcome == .remotelyCancelled)
        #expect(report.outcome.statusText == "Remotely cancelled.")
        #expect(device.packets.map(\.number) == [0, 1])
        #expect(report.samplesCompleted == 0 && report.sampleNumbers == [0])
        #expect(!device.messages.contains(where: isCancel))
    }

    @Test func cancelByDeviceInOpenLoop() {
        let device = SimulatedDevice { kind in kind == .packet(number: 2, nth: 2) ? .cancel : .silent }
        let (report, _, _) = run(device, [makeSample(bits: 16, count: 4000)], options: fastOptions(handshake: false))
        #expect(report.outcome == .remotelyCancelled)
        #expect(device.packets.count <= 4)
    }

    @Test func packetTimeoutFallsBackToOpenLoop() {
        // Silent on packets 1 and 4: each costs one timeout; the ACKs in between restore closed loop.
        let device = SimulatedDevice { kind in
            if case let .packet(_, nth) = kind, nth == 1 || nth == 4 { return .silent }
            return .ack
        }
        let (report, elapsed, _) = run(device, [makeSample(bits: 16, count: 320)], options: fastOptions())
        #expect(report.outcome == .completed)
        #expect(report.timeouts == 2 && report.resends == 0)
        #expect(device.packets.map(\.number) == [0, 1, 2, 3, 4, 5, 6, 7])
        #expect(elapsed < 1)
    }

    @Test func deviceGoesQuietMidTransfer() {
        let device = SimulatedDevice { kind in
            if case let .packet(_, nth) = kind, nth >= 2 { return .silent }
            return .ack
        }
        let (report, elapsed, _) = run(device, [makeSample(bits: 16, count: 4000)], options: fastOptions())
        #expect(report.outcome == .completed && report.timeouts == 1 && report.packetsSent == 100)
        #expect(elapsed < 1)
    }

    @Test func noHeaderReplyMeansOpenLoop() {
        // Replies from another device number do not count.
        let device = SimulatedDevice(device: 9)
        var o = fastOptions(); o.headerReplyTimeout = 0.1
        let (report, elapsed, _) = run(device, [makeSample(bits: 24, count: 300)], options: o)
        #expect(report.outcome == .completed && report.openLoopSamples == 1 && report.timeouts == 0)
        #expect(device.packets.count == 10)
        #expect(elapsed >= 0.1 && elapsed < 1)
    }

    @Test func localCancelSendsCancel() {
        let device = SimulatedDevice(device: 4)
        var o = fastOptions(); o.deviceNumber = 4
        let (report, _, _) = run(device, [makeSample(bits: 16, count: 4000)], options: o,
                                 isCancelled: { device.packetCount >= 3 })
        #expect(report.outcome == .cancelled)
        #expect(device.packets.count == 3)
        #expect(device.messages.last == [0xF0, 0x7E, 0x04, 0x7D, 0x02, 0xF7])
    }

    @Test func cancelMethodDuringWait() {
        let device = SimulatedDevice { kind in kind == .packet(number: 0, nth: 0) ? .waitThenAck(10) : .ack }
        let sender = SDSSender(transport: device, options: fastOptions())
        device.deliver = { sender.handle($0) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { sender.cancel() }
        let start = HostTime.now
        let report = sender.send([makeSample(bits: 16, count: 400)])
        #expect(report.outcome == .cancelled)
        #expect(HostTime.seconds(fromTicks: HostTime.now - start) < 1)
        #expect(device.messages.last == SDSMessage.cancel(device: 0, packet: 0).bytes())
    }

    @Test func handshakeOffIgnoresReplies() {
        let device = SimulatedDevice { _ in .nak }
        let (report, _, _) = run(device, [makeSample(bits: 12, count: 600)], options: fastOptions(handshake: false))
        #expect(report.outcome == .completed && report.resends == 0 && report.packetsSent == 10)
    }

    @Test func refusesUnsendableSamples() {
        let device = SimulatedDevice()
        let wide = SDSSample(samples: [0], bits: 32, samplePeriodNs: 20833)
        #expect(run(device, [wide], options: fastOptions()).0.outcome == .failed("Unsupported sample format: 32 bits"))
        let long = SDSSample(samples: [Int32](repeating: 0, count: 1 << 21), bits: 8, samplePeriodNs: 20833)
        guard case .failed = run(device, [long], options: fastOptions()).0.outcome else { Issue.record("expected failure"); return }
        #expect(device.messages.isEmpty)
    }

    @Test func headerBufferMatchesC6() {
        var o = fastOptions(); o.extendedSDS = true; o.sendSPS1UWName = true; o.deviceNumber = 1
        let s = makeSample(bits: 16, count: 10, name: "snare01")
        let buf = SDSSender.headerMessages(for: s, sampleNumber: 2, options: o)
        // 34-byte extended header + (10 + 7)-byte name + 13-byte SPS-1UW name (44 + n + 13).
        #expect(buf.count == 44 + 7 + 13)
        #expect(Array(buf[0..<7]) == [0xF0, 0x7E, 0x01, 0x05, 0x05, 0x00, 0x02])
        #expect(Array(buf[34..<43]) == [0xF0, 0x7E, 0x01, 0x05, 0x03, 0x00, 0x02, 0x00, 0x07])
        #expect(Array(buf.suffix(13)) == [0xF0, 0x00, 0x20, 0x3C, 0x02, 0x00, 0x73, 0x02, 0x53, 0x4E, 0x41, 0x31, 0xF7])
        o.extendedSDS = false; o.sendSPS1UWName = false
        #expect(SDSSender.headerMessages(for: s, sampleNumber: 2, options: o).count == 21)
    }

    /// Open loop at a fast line rate: packets go out back to back at the line rate, plus the delay.
    @Test(arguments: [0.0, 2.0])
    func openLoopPacing(delayMs: Double) throws {
        let device = SimulatedDevice { _ in .silent }
        var o = SDSSender.Options()
        o.handshake = false
        o.lineRate = 100_000
        o.interPacketDelayMs = delayMs
        o.openLoopMinInterval = 0   // pure line-rate pacing for this test
        let s = makeSample(bits: 16, count: 4000) // 100 packets
        let (report, elapsed, _) = run(device, [s], options: o)
        #expect(report.outcome == .completed && report.packetsSent == 100)
        let perPacket = 127 / o.lineRate + delayMs / 1000
        let starts = device.messageStarts
        try #require(starts.count == 101)
        let gaps = zip(starts.dropFirst(), starts).map { HostTime.seconds(fromTicks: $0 - $1) }
        // The first gap follows the 21-byte header.
        #expect(abs(gaps[0] - (21 / o.lineRate + delayMs / 1000)) < 0.0005)
        let packetGaps = gaps.dropFirst()
        #expect(packetGaps.allSatisfy { $0 >= perPacket - 0.00005 }, "never faster than the line rate")
        let mean = packetGaps.reduce(0, +) / Double(packetGaps.count)
        #expect(mean < perPacket * 1.25, "mean gap \(mean) vs \(perPacket)")
        let nominal = (21 + 100 * 127) / o.lineRate + 100 * delayMs / 1000
        #expect(elapsed >= nominal && elapsed < nominal * 1.5 + 0.1)
    }

    /// Without replies, packets never start closer than `openLoopMinInterval` (default 9 ms, a
    /// Machinedrum's digest rate), even when the line is faster.
    @Test func openLoopRespectsTheDevicesPace() throws {
        let device = SimulatedDevice { _ in .silent }
        var o = SDSSender.Options()
        o.handshake = false
        o.lineRate = 100_000
        let s = makeSample(bits: 16, count: 2000) // 50 packets
        let (report, elapsed, _) = run(device, [s], options: o)
        #expect(report.outcome == .completed && report.packetsSent == 50)
        let starts = device.messageStarts
        let gaps = zip(starts.dropFirst(2), starts.dropFirst()).map { HostTime.seconds(fromTicks: $0 - $1) }
        #expect(gaps.allSatisfy { $0 >= 0.0089 }, "min gap \(gaps.min() ?? 0)")
        #expect(elapsed >= 49 * 0.009 && elapsed < 49 * 0.009 * 1.5 + 0.1)
    }
}

private func isCancel(_ m: [UInt8]) -> Bool {
    if case .cancel? = SDSMessage.decode(m) { return true }
    return false
}

/// Thread-safe counter for scripts.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    /// Returns the value before incrementing.
    func increment() -> Int { lock.lock(); defer { n += 1; lock.unlock() }; return n }
}

// MARK: - Receiver

@Suite struct SDSReceiverTests {
    private final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var events: [SDSReceiver.Event] = []
        func add(_ e: SDSReceiver.Event) { lock.lock(); events.append(e); lock.unlock() }
        var dumps: [SDSReceiver.ReceivedDump] {
            lock.lock(); defer { lock.unlock() }
            return events.compactMap { if case let .dump(d) = $0 { return d } else { return nil } }
        }
    }

    /// Sender → receiver over two wires; returns the receiver's dumps and the sender's report.
    private func loop(_ samples: [SDSSample], sender so: SDSSender.Options, receiver ro: SDSReceiver.Options = .init(),
                      corrupt: ((Int, [UInt8]) -> [UInt8])? = nil)
        -> (SDSSender.Report, [SDSReceiver.ReceivedDump], Wire, Wire) {
        let toReceiver = Wire(), toSender = Wire()
        let sender = SDSSender(transport: toReceiver, options: so)
        let receiver = SDSReceiver(transport: toSender, options: ro)
        let events = Collector()
        receiver.onEvent = events.add
        toReceiver.deliver = { receiver.handle($0) }
        toReceiver.transform = corrupt.map { c in { m, i in c(i, m) } }
        toSender.deliver = { sender.handle($0) }
        let report = sender.send(samples)
        return (report, events.dumps, toReceiver, toSender)
    }

    @Test(arguments: [8, 12, 16, 20, 24])
    func roundTripStandardWithSPSName(bits: Int) throws {
        var o = fastOptions(); o.sendSPS1UWName = true; o.deviceNumber = 6; o.startSampleNumber = 10
        let samples = [makeSample(bits: bits, count: 1001, seed: 7, name: "kick"),
                       makeSample(bits: bits, count: 59, seed: 8, name: "åska")]
        let (report, dumps, _, toSender) = loop(samples, sender: o)
        #expect(report.outcome == .completed && report.timeouts == 0 && report.openLoopSamples == 0)
        try #require(dumps.count == 2)
        for (got, want) in zip(dumps, samples) {
            #expect(got.isComplete && !got.isExtended && got.badPackets == 0)
            expectSameAudio(got.sample, want)
            #expect(got.sample.sampleRate == 44100)
        }
        #expect(dumps.map(\.sample.sampleNumber) == [10, 11])
        #expect(dumps.map(\.sample.name) == ["KICK", "ÅSKA"])
        #expect(toSender.sent.allSatisfy { $0[2] == 6 && $0[3] == 0x7F }) // ACKs only, device 6
        // The dump keeps the messages for the SDS (.syx) form: header, SPS name, packets.
        #expect(dumps[1].messages.count == 2 + SDSWordFormat(bits: bits)!.packetCount(forLength: 59))
    }

    @Test func roundTripExtendedWithNames() throws {
        var o = fastOptions(); o.extendedSDS = true; o.sendSPS1UWName = true; o.startSampleNumber = 300
        var a = makeSample(bits: 24, count: 2000, seed: 3, name: "snare01", rate: 96000)
        a.loopType = SDSSample.loopAlternating
        let b = makeSample(bits: 12, count: 100, seed: 4, name: nil, rate: 22050)
        let (report, dumps, _, _) = loop([a, b], sender: o)
        #expect(report.outcome == .completed)
        try #require(dumps.count == 2)
        expectSameAudio(dumps[0].sample, a)
        expectSameAudio(dumps[1].sample, b)
        #expect(dumps.allSatisfy { $0.isExtended })
        #expect(dumps[0].sample.sampleRateHz == 96000 && dumps[1].sample.sampleRateHz == 22050)
        #expect(dumps[0].sample.name == "snare01") // 05 03 name wins over the 4-letter one
        #expect(dumps[1].sample.name == nil)
        #expect(dumps.map(\.sample.sampleNumber) == [300, 301])
    }

    @Test func roundTripHandshakeOff() throws {
        var ro = SDSReceiver.Options(); ro.handshake = false
        let s = makeSample(bits: 16, count: 5000, seed: 9)
        let (report, dumps, _, toSender) = loop([s], sender: fastOptions(handshake: false), receiver: ro)
        #expect(report.outcome == .completed)
        try #require(dumps.count == 1)
        expectSameAudio(dumps[0].sample, s)
        #expect(toSender.sent.isEmpty)
    }

    @Test func roundTripRecoversFromCorruptPackets() throws {
        // Corrupt the first transmission of packets 1 and 2.
        var hits = Set<UInt8>()
        let s = makeSample(bits: 20, count: 400, seed: 5)
        let (report, dumps, toReceiver, toSender) = loop([s], sender: fastOptions()) { _, m in
            guard SDSMessage.isDataPacket(m), (1...2).contains(m[4]), !hits.contains(m[4]) else { return m }
            hits.insert(m[4])
            var x = m; x[40] ^= 0x01; return x
        }
        #expect(report.outcome == .completed && report.resends == 2)
        try #require(dumps.count == 1)
        expectSameAudio(dumps[0].sample, s)
        #expect(dumps[0].badPackets == 2)
        #expect(toSender.sent.filter { $0[3] == 0x7E }.map { $0[4] } == [1, 2])
        #expect(toReceiver.sent.count == 1 + 10 + 2)
    }

    // Hand-fed receiver tests.

    private func header(device: UInt8, sn: Int, bits: Int, length: Int) -> [UInt8] {
        SDSMessage.dumpHeader(SDSDumpHeader(device: device, sampleNumber: sn, bits: bits, samplePeriodNs: 20833,
                                            length: length, loopStart: 0, loopEnd: length - 1, loopType: 0x7F)).bytes()
    }

    private func packets(_ s: SDSSample, device: UInt8) -> [[UInt8]] {
        let f = SDSWordFormat(bits: s.bits)!
        return (0..<f.packetCount(forLength: s.length)).map {
            SDSMessage.dataPacket(SDSDataPacket(sample: s, index: $0, device: device, format: f)).bytes()
        }
    }

    @Test func nakThenRecover() throws {
        let replies = Wire()
        let r = SDSReceiver(transport: replies)
        let c = Collector(); r.onEvent = c.add
        let s = makeSample(bits: 16, count: 120)
        let p = packets(s, device: 9)
        #expect(r.handle(header(device: 9, sn: 1, bits: 16, length: 120)))
        #expect(r.handle(p[0]))
        var bad = p[1]; bad[10] ^= 0x10
        #expect(r.handle(bad))
        #expect(r.handle(p[1]))
        #expect(r.handle(p[1])) // repeat of an accepted packet: ACKed again, not stored
        #expect(r.handle(p[2]))
        #expect(replies.sent == [[0xF0, 0x7E, 0x09, 0x7F, 0x00, 0xF7], [0xF0, 0x7E, 0x09, 0x7F, 0x00, 0xF7],
                                 [0xF0, 0x7E, 0x09, 0x7E, 0x01, 0xF7], [0xF0, 0x7E, 0x09, 0x7F, 0x01, 0xF7],
                                 [0xF0, 0x7E, 0x09, 0x7F, 0x01, 0xF7], [0xF0, 0x7E, 0x09, 0x7F, 0x02, 0xF7]])
        let d = try #require(c.dumps.first)
        #expect(d.isComplete && d.sample.samples == s.samples && d.badPackets == 1 && d.messages.count == 4)
        #expect(!r.isDumpInProgress)
        #expect(c.events.contains(.started(sampleNumber: 1, length: 120, bits: 16)))
        #expect(c.events.contains(.progress(received: 120, total: 120)))
    }

    @Test func threeBadPacketsCancel() throws {
        let replies = Wire()
        let r = SDSReceiver(transport: replies)
        let c = Collector(); r.onEvent = c.add
        let p = packets(makeSample(bits: 16, count: 200), device: 9)
        r.handle(header(device: 9, sn: 1, bits: 16, length: 200))
        r.handle(p[0])
        for _ in 0..<3 { r.handle(p[2]) } // out of sequence
        #expect(Array(replies.sent.suffix(3)) == [[0xF0, 0x7E, 0x09, 0x7E, 0x01, 0xF7], [0xF0, 0x7E, 0x09, 0x7E, 0x01, 0xF7],
                                                  [0xF0, 0x7E, 0x09, 0x7D, 0x01, 0xF7]])
        let d = try #require(c.dumps.first)
        #expect(!d.isComplete && d.sample.samples.count == 40 && d.badPackets == 3)
        #expect(c.events.contains { if case .cancelled = $0 { return true }; return false })
        #expect(!r.isDumpInProgress)
    }

    @Test func badPacketWithoutHandshakeCancels() {
        let replies = Wire()
        var o = SDSReceiver.Options(); o.handshake = false
        let r = SDSReceiver(transport: replies, options: o)
        let p = packets(makeSample(bits: 16, count: 200), device: 2)
        r.handle(header(device: 2, sn: 1, bits: 16, length: 200))
        r.handle(p[1])
        #expect(replies.sent == [[0xF0, 0x7E, 0x02, 0x7D, 0x00, 0xF7]])
    }

    @Test func remoteCancel() throws {
        let replies = Wire()
        let r = SDSReceiver(transport: replies)
        let c = Collector(); r.onEvent = c.add
        r.handle(header(device: 0, sn: 1, bits: 8, length: 500))
        r.handle(packets(makeSample(bits: 8, count: 500), device: 0)[0])
        #expect(r.handle(SDSMessage.cancel(device: 0, packet: 1).bytes()))
        #expect(c.events.last == .remotelyCancelled)
        #expect(SDSReceiver.remotelyCancelledText == "Remotely cancelled.")
        let d = try #require(c.dumps.first)
        #expect(!d.isComplete && d.sample.samples.count == 60)
        #expect(replies.sent.count == 2) // ACK header, ACK packet — the CANCEL is not ACKed
    }

    @Test func stopSendsCancelAndReturnsPartial() throws {
        let replies = Wire()
        let r = SDSReceiver(transport: replies)
        r.handle(header(device: 5, sn: 1, bits: 16, length: 500))
        r.handle(packets(makeSample(bits: 16, count: 500), device: 5)[0])
        let partial = try #require(r.stop())
        #expect(!partial.isComplete && partial.sample.samples.count == 40)
        #expect(replies.sent.last == [0xF0, 0x7E, 0x05, 0x7D, 0x01, 0xF7])
        #expect(r.stop() == nil)
    }

    @Test func newHeaderInterruptsDump() {
        let r = SDSReceiver(transport: nil)
        let c = Collector(); r.onEvent = c.add
        r.handle(header(device: 0, sn: 1, bits: 16, length: 500))
        r.handle(header(device: 0, sn: 2, bits: 16, length: 10))
        r.handle(packets(makeSample(bits: 16, count: 10), device: 0)[0])
        #expect(c.dumps.map(\.isComplete) == [false, true])
        #expect(c.dumps.map(\.sample.sampleNumber) == [1, 2])
    }

    @Test func spsNameCaptureRules() {
        let r = SDSReceiver(transport: nil)
        let c = Collector(); r.onEvent = c.add
        let name = SDSMessage.spsNameMessage(slot: 47, name: "SNA1")
        #expect(!r.handle(name)) // no dump in progress: not consumed (C6)
        r.handle(header(device: 0, sn: 3, bits: 16, length: 10))
        #expect(r.handle(name))
        r.handle(packets(makeSample(bits: 16, count: 10), device: 0)[0])
        #expect(c.dumps.first?.sample.name == "SNA1")
        #expect(c.dumps.first?.sample.sampleNumber == 3) // the slot byte is ignored
    }

    @Test func sampleNameBeforeHeader() {
        let r = SDSReceiver(transport: nil)
        let c = Collector(); r.onEvent = c.add
        r.handle(SDSMessage.sampleName(SDSSampleName(device: 0, sampleNumber: 3, name: "early")).bytes())
        r.handle(header(device: 0, sn: 3, bits: 16, length: 10))
        r.handle(packets(makeSample(bits: 16, count: 10), device: 0)[0])
        r.handle(SDSMessage.sampleName(SDSSampleName(device: 0, sampleNumber: 9, name: "other")).bytes())
        r.handle(header(device: 0, sn: 4, bits: 16, length: 10))
        r.handle(packets(makeSample(bits: 16, count: 10), device: 0)[0])
        #expect(c.dumps.map(\.sample.name) == ["early", nil])
    }

    /// Rec Format "None": handshake only — no split, no decoding, names stay in the raw stream.
    @Test func noneModeDoesNotSplit() {
        let replies = Wire()
        var o = SDSReceiver.Options(); o.splitDumps = false
        let r = SDSReceiver(transport: replies, options: o)
        let c = Collector(); r.onEvent = c.add
        for sn in 1...2 {
            #expect(!r.handle(header(device: 0, sn: sn, bits: 16, length: 10)))
            #expect(!r.handle(SDSMessage.spsNameMessage(slot: sn, name: "KICK")))
            #expect(!r.handle(packets(makeSample(bits: 16, count: 10), device: 0)[0]))
        }
        #expect(c.dumps.isEmpty)
        #expect(c.events.filter { if case .dumpEnded = $0 { return true }; return false }
            == [.dumpEnded(sampleNumber: 1, complete: true), .dumpEnded(sampleNumber: 2, complete: true)])
        #expect(replies.sent.count == 4) // ACKs still go out
    }

    @Test func unsupportedBitDepthIsCancelled() {
        let replies = Wire()
        let r = SDSReceiver(transport: replies)
        r.handle(header(device: 1, sn: 0, bits: 32, length: 10))
        #expect(replies.sent == [[0xF0, 0x7E, 0x01, 0x7D, 0x00, 0xF7]])
        #expect(!r.isDumpInProgress)
    }

    @Test func itemNames() {
        var n = 1
        let named = SDSReceiver.ReceivedDump(sample: SDSSample(samples: [], bits: 16, samplePeriodNs: 1, name: "HH  "),
                                             messages: [], isComplete: true, isExtended: false, badPackets: 0)
        var unnamed = named; unnamed.sample.name = nil
        #expect(SDSReceiver.itemName(for: named, recFormat: .wav, counter: &n) == "HH.wav")  // C2026 trims the space padding
        // C2026: unnamed dumps are named by sample number; only non-sample data uses the counter.
        #expect(SDSReceiver.itemName(for: unnamed, recFormat: .aiff, counter: &n) == "Sample 0.aiff")
        #expect(SDSReceiver.itemName(for: unnamed, recFormat: .none, counter: &n) == "Sample 0.syx")
        #expect(SDSReceiver.itemName(for: nil, recFormat: .wav, counter: &n) == "Received data 1.syx")
        var md = named; md.mdName = "MOUF"; md.sample.sampleNumber = 25
        #expect(SDSReceiver.itemName(for: md, recFormat: .wav, counter: &n) == "MD26 MOUF.wav")
        md.mdName = "    "
        #expect(SDSReceiver.itemName(for: md, recFormat: .wav, counter: &n) == "MD26.wav")
        #expect(n == 2)   // only the non-sample receive used the counter
    }
}
