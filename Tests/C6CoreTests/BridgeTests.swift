@testable import C6Core
import Foundation
import Testing

/// End-to-end paths through several modules: WAV file → SDS → received dump → WAV/AIFF file,
/// and the list item model.
@Suite struct BridgeTests {
    /// Loops whatever a sender transmits into a receiver (and the receiver's replies back).
    final class Loop: MIDITransport {
        var onReceive: (([UInt8]) -> Void)?
        var deliver: (([UInt8]) -> Void)?
        private var parser = MIDI1StreamParser()
        private let lock = NSLock()
        func sendStream(_ bytes: ArraySlice<UInt8>, at hostTime: UInt64?) {
            var out: [[UInt8]] = []
            lock.lock(); parser.feed(bytes) { out.append($0) }; lock.unlock()
            out.forEach { deliver?($0) }
        }
        func flushScheduled() {}
    }

    func tone(_ n: Int, bits: Int) -> [Int32] {
        let peak = Double((1 << (bits - 1)) - 1)
        return (0..<n).map { Int32((sin(Double($0) * 0.05) * peak * 0.8).rounded()) }
    }

    @Test(arguments: [(16, C6Settings.RecFormat.wav), (16, .aiff), (24, .wav), (8, .aiff)])
    func wavToSDSToFileRoundTrip(bits: Int, format: C6Settings.RecFormat) throws {
        let original = tone(3000, bits: bits)
        let wav = AudioWriter.wav(samples: original, bits: bits, sampleRate: 44100, loop: (100, 2999, 0))
        let audio = try AudioFile(bytes: wav)
        let sample = SDSSample(audio: audio, stereo: .mix, loop: .file, name: "tone")
        #expect(sample.samples == original)
        #expect(sample.loopStart == 100 && sample.loopEnd == 2999 && sample.loopType == 0)

        // Sender → wire → receiver, with the receiver's ACKs travelling back.
        let toDevice = Loop(), toHost = Loop()
        var opts = SDSSender.Options(); opts.lineRate = 1_000_000; opts.startSampleNumber = 44
        let sender = SDSSender(transport: toDevice, options: opts)
        let receiver = SDSReceiver(transport: toHost)
        toDevice.deliver = { _ = receiver.handle($0) }
        toHost.deliver = { _ = sender.handle($0) }
        var dumps: [SDSReceiver.ReceivedDump] = []
        receiver.onEvent = { if case let .dump(d) = $0 { dumps.append(d) } }
        let report = sender.send([sample])
        #expect(report.outcome == .completed)
        #expect(report.openLoopSamples == 0) // every packet was ACKed
        let dump = try #require(dumps.first)
        #expect(dump.sample.sampleNumber == 44)
        #expect(dump.sample.samples == original)

        let file = dump.fileBytes(format: format)
        let back = try AudioFile(bytes: file)
        #expect(back.info.sampleRate == 44100 && back.info.bits == bits)
        #expect(back.sdsSamples(stereo: .mix) == original)
        #expect(back.info.loopOn && back.info.loopStart == 100 && back.info.loopEnd == 2999)
    }

    @Test func stereoModesPickChannels() throws {
        // Interleaved stereo: L = +1000, R = -3000.
        var bytes: [UInt8] = []
        func le16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] }
        func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16) }
        let frames = 10
        let data = (0..<frames).flatMap { _ in le16(1000) + le16(-3000) }
        bytes = Array("RIFF".utf8) + le32(36 + data.count) + Array("WAVEfmt ".utf8) + le32(16)
            + le16(1) + le16(2) + le32(44100) + le32(44100 * 4) + le16(4) + le16(16) + Array("data".utf8) + le32(data.count) + data
        let audio = try AudioFile(bytes: bytes)
        #expect(SDSSample(audio: audio, stereo: .left, loop: .file, name: nil).samples.allSatisfy { $0 == 1000 })
        #expect(SDSSample(audio: audio, stereo: .right, loop: .file, name: nil).samples.allSatisfy { $0 == -3000 })
        #expect(SDSSample(audio: audio, stereo: .mix, loop: .file, name: nil).samples.allSatisfy { $0 == -1000 })
    }

    @Test func itemsRecogniseAudioAndSysEx() {
        C6Item.audioDescriber = { _, b in AudioFile.describe(b) }
        let wav = AudioWriter.wav(samples: tone(500, bits: 16), bits: 16, sampleRate: 48000)
        let item = C6Item(name: "t.wav", bytes: wav)
        #expect(item.isAudio && item.typeLabel == "WAV")
        #expect(item.info == "Sample length: 500 Channels: 1 Sample Rate: 48000\nBits: 16 Loop OFF.")
        let tm1 = C6Item(name: "x.syx", bytes: TM1Message.statusRequest)
        #expect(!tm1.isAudio && tm1.sysex.messages.count == 1)
    }

    @Test func c6FileListRoundTrip() throws {
        let dir = URL(fileURLWithPath: "/Users/someone/Music")
        let list = C6FileList(samplePosition: 12, entries: [
            .init(url: dir.appendingPathComponent("kick.wav"), loop: .file, stereo: .mix),
            .init(url: dir.appendingPathComponent("drums/snare.aif"), loop: .on, stereo: .right),
            .init(url: URL(fileURLWithPath: "/Volumes/Samples/hat.syx"), loop: .off, stereo: .left),
        ])
        let bytes = list.serialize(directory: dir)
        // Byte-identical to the example in the reverse-engineered spec (40-config-ui §3.1),
        // with the path adjusted.
        let expected: [UInt8] = Array("C6 Filelist".utf8) + [0] + Array("0".utf8) + [0] + Array("12".utf8) + [0]
            + Array("00*kick.wav".utf8) + [0] + Array("12*drums/snare.aif".utf8) + [0] + Array("21/Volumes/Samples/hat.syx".utf8) + [0]
        #expect([UInt8](bytes) == expected)
        #expect(try C6FileList.parse(bytes, directory: dir) == list)
        #expect(throws: C6FileList.ParseError.self) { try C6FileList.parse(Data("nope".utf8), directory: dir) }
    }
}

@Suite struct SDSExportTests {
    @Test func exportMatchesWhatTheSenderTransmits() throws {
        let samples = (0..<500).map { Int32(($0 * 97) % 60000 - 30000) }
        let s = SDSSample(samples: samples, bits: 16, sampleRate: 44100, name: "blip")
        let bytes = s.sdsFileBytes(sampleNumber: 44)
        let msgs = SysExData(bytes: bytes).messages
        #expect(msgs.count == 1 + 13)                       // header + ceil(500 / 40) packets
        #expect(SysExRecognizer.typeString(bytes) == "SDS")
        #expect(SysExRecognizer.describe(bytes) == "Dump length: 500 Sample Rate: 44100\nBits: 16 Loop OFF. Loop start: 0 Loop end: 499")
        // Feeding the file to a receiver gives the samples back, numbered 44.
        let r = SDSReceiver(transport: nil)
        var got: SDSSample?
        r.onEvent = { if case let .dump(d) = $0 { got = d.sample } }
        msgs.forEach { _ = r.handle($0) }
        #expect(got?.samples == samples && got?.sampleNumber == 44)
    }
}

/// Replays what a real Machinedrum sent when dumping a sample to the Mac (captured 2026-10-16):
/// an 8-bit dump header for sample 45, then its SPS-1UW name, then 116 data packets.
@Suite struct MachinedrumReceiveTests {
    final class Recorder: MIDITransport {
        var onReceive: (([UInt8]) -> Void)?
        var sent: [[UInt8]] = []
        private var parser = MIDI1StreamParser()
        func sendStream(_ b: ArraySlice<UInt8>, at: UInt64?) { parser.feed(b) { sent.append($0) } }
        func flushScheduled() {}
    }

    static let header: [UInt8] = [0xF0, 0x7E, 0x00, 0x01, 0x2D, 0x00, 0x08, 0x13, 0x31, 0x01, 0x00, 0x36, 0x00,
                                  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF7]
    static let name: [UInt8] = [0xF0, 0x00, 0x20, 0x3C, 0x02, 0x00, 0x73, 0x2D, 0x48, 0x45, 0x41, 0x20, 0xF7]

    /// Fast pace: no replies while packets are good; a bad packet → CANCEL naming that packet, then a
    /// Dump Request for the same sample; the second attempt completes.
    @Test func fastPaceCancelsAndRequestsAgain() throws {
        let rec = Recorder()
        var o = SDSReceiver.Options(); o.pace = .fast(retries: 2)
        let r = SDSReceiver(transport: rec, options: o)
        r.retryDelay = 0.01
        var events: [String] = []
        var dump: SDSReceiver.ReceivedDump?
        r.onEvent = { e in
            switch e {
            case let .dump(d): dump = d
            case let .retrying(n, a): events.append("retry \(n) #\(a)")
            case let .cancelled(s): events.append(s)
            default: break
            }
        }
        let fmt = try #require(SDSWordFormat(bits: 8))
        let words = (0..<600).map { Int32(($0 % 200) - 100) }   // 10 packets
        func packets(damage: Int?) -> [[UInt8]] {
            (0..<fmt.packetCount(forLength: words.count)).map { k in
                let chunk = Array(words[(k * 60)..<min(words.count, k * 60 + 60)])
                var data = fmt.encode(chunk); data += [UInt8](repeating: 0, count: 120 - data.count)
                let body: [UInt8] = [0x7E, 0x00, 0x02, UInt8(k)] + data
                var pkt = [0xF0] + body + [body.reduce(0, ^) & 0x7F, 0xF7]
                if k == damage { pkt[20] ^= 1 }
                return pkt
            }
        }
        var header = Self.header
        header[10] = UInt8(600 & 0x7F); header[11] = UInt8(600 >> 7); header[12] = 0   // length 600
        _ = r.handle(header)
        #expect(rec.sent.isEmpty, "fast pace stays silent on the header")
        for (k, p) in packets(damage: 3).enumerated() where k <= 3 { _ = r.handle(p) }
        #expect(rec.sent == [[0xF0, 0x7E, 0x00, 0x7D, 0x03, 0xF7]], "CANCEL names the packet the device is on")
        #expect(events == ["retry 45 #1"])
        let deadline = Date().addingTimeInterval(2)
        while rec.sent.count < 2 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(rec.sent.last == [0xF0, 0x7E, 0x00, 0x03, 0x2D, 0x00, 0xF7], "then a Dump Request for sample 45")
        _ = r.handle(header)
        packets(damage: nil).forEach { _ = r.handle($0) }
        #expect(dump?.isComplete == true && dump?.sample.samples == words)
        #expect(rec.sent.count == 2, "no ACKs at any point")
    }

    @Test func stopCancelsThePacketTheDeviceIsOn() {
        let rec = Recorder()
        let r = SDSReceiver(transport: rec)
        _ = r.handle(Self.header)
        var body: [UInt8] = [0x7E, 0x00, 0x02, 0x00] + [UInt8](repeating: 0x40, count: 120)
        _ = r.handle([0xF0] + body + [body.reduce(0, ^) & 0x7F, 0xF7])
        body[3] = 0x01
        _ = r.handle([0xF0] + body + [body.reduce(0, ^) & 0x7F, 0xF7])
        _ = r.stop()
        // Device sent packet 1 last; CANCEL 1 first, then the next number for good measure.
        #expect(Array(rec.sent.suffix(2)) == [[0xF0, 0x7E, 0x00, 0x7D, 0x01, 0xF7], [0xF0, 0x7E, 0x00, 0x7D, 0x02, 0xF7]])
    }

    @Test func acksTheMachinedrumDump() throws {
        let rec = Recorder()
        let r = SDSReceiver(transport: rec)
        var dumps: [SDSReceiver.ReceivedDump] = []
        r.onEvent = { if case let .dump(d) = $0 { dumps.append(d) } }
        _ = r.handle(Self.header)
        #expect(rec.sent.last == [0xF0, 0x7E, 0x00, 0x7F, 0x00, 0xF7], "header must be ACKed")
        _ = r.handle(Self.name)
        let fmt = try #require(SDSWordFormat(bits: 8))
        let words = (0..<6912).map { Int32(($0 % 200) - 100) }
        for k in 0..<fmt.packetCount(forLength: words.count) {
            let chunk = Array(words[(k * 60)..<min(words.count, k * 60 + 60)])
            var data = fmt.encode(chunk); data += [UInt8](repeating: 0, count: 120 - data.count)
            let body: [UInt8] = [0x7E, 0x00, 0x02, UInt8(k & 0x7F)] + data
            let pkt = [0xF0] + body + [body.reduce(0, ^) & 0x7F, 0xF7]
            _ = r.handle(pkt)
            #expect(rec.sent.last == [0xF0, 0x7E, 0x00, 0x7F, UInt8(k & 0x7F), 0xF7], "packet \(k) must be ACKed")
        }
        let d = try #require(dumps.first)
        #expect(d.sample.sampleNumber == 45 && d.sample.bits == 8 && d.sample.samples == words)
        #expect(d.sample.name == "HEA ")       // as sent: 4 letters, space padded
        var counter = 1
        #expect(SDSReceiver.itemName(for: d, recFormat: .wav, counter: &counter) == "MD46 HEA.wav")   // sample 45 = slot 46
    }
}

@Suite struct SettingsTests {
    @Test func grittyIsTheDefaultEmulation() {
        #expect(C6Settings().pitchDownEmulation == .hold)
    }

    @Test func oldSettingsStillDecode() throws {
        // Saved by an earlier build (no receivePace key).
        let json = #"{"turboLimit":11,"inputPortName":"Elektron TM-1","recFormat":"WAV","extendedSDS":false,"sdsHandshake":true}"#
        let s = try JSONDecoder().decode(C6Settings.self, from: Data(json.utf8))
        #expect(s.inputPortName == "Elektron TM-1" && s.turboLimit == 11 && s.receivePace == .auto && s.receiveIdleTimeout == 3)
        #expect(s.sdsReceivePace(at: .x10) == .fast(retries: 2))
        #expect(s.sdsReceivePace(at: .x1) == .ackEachPacket)
    }
}

import AVFoundation

@Suite struct PlaybackTests {
    @Test(arguments: [8, 16, 24])
    func sampleDumpItemsPlayAsWAV(bits: Int) throws {
        let peak = Int32((1 << (bits - 1)) - 1)
        let samples = (0..<2000).map { Int32(sin(Double($0) * 0.1) * Double(peak) * 0.7) }
        let syx = SDSSample(samples: samples, bits: bits, sampleRate: 44100, name: "t").sdsFileBytes(sampleNumber: 3)
        let item = C6Item(name: "t.syx", bytes: syx)
        #expect(item.typeLabel == "SDS" && item.isPlayable)
        let wav = try #require(item.playableAudio)
        #expect(try AudioFile(bytes: wav).sdsSamples(stereo: .mix) == samples)
        let player = try AVAudioPlayer(data: Data(wav))          // what the play button uses
        #expect(abs(player.duration - 2000.0 / 44100) < 0.001)
    }

    @Test func nonAudioIsNotPlayable() {
        let kit = C6Item(name: "k.syx", bytes: TM1Message.statusRequest)
        #expect(!kit.isPlayable && kit.playableAudio == nil)
    }
}

@Suite struct MDNameTests {
    @Test func normalizeAndSuggest() {
        #expect(MDName.normalize("mouf") == "MOUF")
        #expect(MDName.normalize("ka§k#ick") == "KAK#")
        #expect(MDName.suggest(forFileName: "MD26 MOUF.wav") == "MOUF")          // received-sample names round-trip
        #expect(MDName.suggest(forFileName: "MD3 BD.wav") == "BD")
        #expect(MDName.suggest(forFileName: "snare01.wav") == "SNA1")             // C6's rule otherwise
        #expect(MDName.suggest(forFileName: "fh2_oneshot_percussion_low_tone_blip.wav") == "FH2P")
        #expect(MDName.suggest(forFileName: "hh.aif") == "HH")
    }

    @Test func typedNameIsSentEvenWithAutoNamesOff() {
        var s = SDSSample(samples: [0, 1, 2], bits: 16, sampleRate: 44100, name: "fh2_blip")
        s.mdName = "blip"
        var o = SDSSender.Options(); o.sendSPS1UWName = false
        let header = SDSSender.headerMessages(for: s, sampleNumber: 44, options: o)
        let msgs = SysExData(bytes: header).messages
        #expect(msgs.count == 2)
        #expect(SDSMessage.parseSPSName(msgs[1])?.name == "BLIP" && SDSMessage.parseSPSName(msgs[1])?.slot == 44)
        s.mdName = nil
        #expect(SysExData(bytes: SDSSender.headerMessages(for: s, sampleNumber: 44, options: o)).messages.count == 1)
    }

    @Test func receivedMachinedrumSampleKeepsSlotAndName() throws {
        let words = (0..<120).map { Int32($0 - 60) }
        var s = SDSSample(samples: words, bits: 16, sampleRate: 44100, name: "x")
        s.mdName = "MOUF"
        var o = SDSSender.Options(); o.handshake = false; o.lineRate = 1e9
        let bytes = s.sdsFileBytes(sampleNumber: 25, options: o)
        let r = SDSReceiver(transport: nil)
        var got: SDSReceiver.ReceivedDump?
        r.onEvent = { if case let .dump(d) = $0 { got = d } }
        SysExData(bytes: bytes).messages.forEach { _ = r.handle($0) }
        var n = 1
        #expect(SDSReceiver.itemName(for: try #require(got), recFormat: .wav, counter: &n) == "MD26 MOUF.wav")
    }
}

@Suite struct SlotPlanTests {
    @Test func singleAndBatchesThatFit() {
        #expect(SlotPlan(start: 45, count: 1, slotCount: 48).slots() == [45])
        let p = SlotPlan(start: 45, count: 4, slotCount: 48)
        #expect(p.fits && p.slots() == [45, 46, 47, 48])
    }

    @Test func overflowStopOrWrap() {
        let p = SlotPlan(start: 46, count: 5, slotCount: 48)
        #expect(!p.fits && p.fittingCount == 3)
        #expect(p.slots(.stop) == [46, 47, 48, nil, nil])
        #expect(p.slots(.wrap) == [46, 47, 48, 1, 2])
        // A batch bigger than the device wraps more than once.
        #expect(SlotPlan(start: 2, count: 5, slotCount: 3).slots(.wrap) == [2, 3, 1, 2, 3])
    }

    @Test func startIsClampedToTheDevice() {
        #expect(SlotPlan(start: 60, count: 1, slotCount: 48).start == 48)
        #expect(SlotPlan(start: 0, count: 1, slotCount: 48).start == 1)
    }

    @Test func loadedAudioGetsASuggestedMDName() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snare01.wav")
        try Data(AudioWriter.wav(samples: [0, 1, 2], bits: 16, sampleRate: 44100)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try C6Item.load(url: url).mdName == "SNA1")
    }
}

@Suite struct SampleMemoryTests {
    func slot(_ n: Int, frames: Int) -> SlotInfo {
        SlotInfo(sampleNumber: n - 1, name: nil, length: frames, bits: 16, sampleRate: 44100, loopStart: 0, loopEnd: 0, loopType: 0x7F)
    }

    @Test func projectionCountsFreedSlots() {
        let mem = SampleMemory(totalBytes: 1000)
        let current = [slot(1, frames: 100), slot(2, frames: 200)]          // 600 bytes used
        // Replace slot 2 (frees 400) with a 300-frame sample (600), add 50 frames to empty slot 3.
        let p = mem.project(newFrames: [300, 50], into: [2, 3], current: current)
        #expect(p.usedNow == 600 && p.freed == 400 && p.incoming == 700)
        #expect(p.usedAfter == 900 && p.freeAfter == 100 && p.fits)
        // Skipped samples (nil slot) don't count.
        #expect(mem.project(newFrames: [300, 50], into: [2, nil], current: current).incoming == 600)
        #expect(!mem.project(newFrames: [400], into: [3], current: current).fits)
    }

    @Test func realScanMatchesTheMachinedrumsMemory() {
        // Totals from scanning a real, nearly full MD UW MKII: 1,275,662 frames in 46 slots.
        #expect(SampleMemory.machinedrumUWMK2.bytes(frames: 1_275_662) < SampleMemory.machinedrumUWMK2.totalBytes)
        #expect(ByteFormat.memory(2_551_324) == "2.43 MB")
        #expect(ByteFormat.memory(70_116) == "68 kB")
    }

    @Test func itemsKnowTheirFrameCount() {
        let wav = AudioWriter.wav(samples: [Int32](repeating: 0, count: 1234), bits: 16, sampleRate: 22050)
        #expect(C6Item(name: "a.wav", bytes: wav).sampleFrames == 1234)
        let syx = SDSSample(samples: [Int32](repeating: 0, count: 500), bits: 8, sampleRate: 44100).sdsFileBytes(sampleNumber: 0)
        #expect(C6Item(name: "a.syx", bytes: syx).sampleFrames == 500)
        #expect(C6Item(name: "k.syx", bytes: TM1Message.statusRequest).sampleFrames == nil)
    }
}

/// A device that answers Dump Requests with a header + Machinedrum name, and stops on CANCEL.
final class FakeSampleDevice: MIDITransport, @unchecked Sendable {
    var onReceive: (([UInt8]) -> Void)?
    var slots: [Int: (frames: Int, name: String)]
    private var parser = MIDI1StreamParser()
    private(set) var cancels = 0
    init(slots: [Int: (frames: Int, name: String)]) { self.slots = slots }
    func sendStream(_ b: ArraySlice<UInt8>, at: UInt64?) {
        var msgs: [[UInt8]] = []
        parser.feed(b) { msgs.append($0) }
        for m in msgs {
            switch SDSMessage.decode(m) {
            case let .dumpRequest(_, n)?:
                guard let s = slots[n] else { continue }   // empty slot: no answer
                let sample = SDSSample(samples: [Int32](repeating: 0, count: s.frames), bits: 16, sampleRate: 44100, sampleNumber: n)
                let header = SDSMessage.dumpHeader(SDSDumpHeader(sample: sample, device: 0, sampleNumber: n)).bytes()
                DispatchQueue.global().async { [weak self] in
                    self?.onReceive?(header)
                    self?.onReceive?(SDSMessage.spsNameMessage(slot: n, name: s.name))
                }
            case .cancel?: cancels += 1
            default: break
            }
        }
    }
    func flushScheduled() {}
}

@Suite struct SampleScannerTests {
    @Test func scansNamesAndLengthsAndCancelsEachDump() {
        let dev = FakeSampleDevice(slots: [0: (22525, "FREE"), 2: (79325, "MOUF")])
        var o = SampleScanner.Options(); o.headerTimeout = 1.0; o.settle = 0.01; o.retries = 1
        let scanner = SampleScanner(transport: dev, options: o)
        dev.onReceive = { scanner.handle($0) }
        let found = scanner.scan([0, 1, 2])
        #expect(found.map(\.slot) == [1, 3])
        #expect(found.map(\.name) == ["FREE", "MOUF"])
        #expect(found.map(\.length) == [22525, 79325])
        #expect(dev.cancels >= 2, "every answered request is cancelled after the header")
    }
}

@Suite struct ResamplerTests {
    func tone(_ hz: Double, rate: Int, seconds: Double, amp: Double = 0.5) -> [Double] {
        (0..<Int(Double(rate) * seconds)).map { amp * sin(2 * .pi * hz * Double($0) / Double(rate)) }
    }
    func rms(_ x: ArraySlice<Double>) -> Double { (x.reduce(0) { $0 + $1 * $1 } / Double(max(1, x.count))).squareRoot() }

    @Test func halvingKeepsAudibleTonesAndLength() {
        let x = tone(1000, rate: 44100, seconds: 0.5)
        let y = Resampler.resample(x, from: 44100, to: 22050)
        #expect(y.count == 11025)
        // Same level (away from the edges) and same pitch: 1 kHz = 1000 rising zero crossings/s.
        #expect(abs(rms(y[500..<10500]) - rms(x[1000..<21000])) < 0.01)
        let crossings = zip(y.dropFirst(), y).filter { $1 < 0 && $0 >= 0 }.count
        #expect(abs(crossings - 500) <= 2)
    }

    @Test func contentAboveTheNewNyquistIsRemoved() {
        // 15 kHz can't exist at 22.05 kHz (Nyquist 11.025 kHz): it must be filtered, not aliased to 7 kHz.
        let x = tone(15000, rate: 44100, seconds: 0.5)
        let y = Resampler.resample(x, from: 44100, to: 22050)
        #expect(rms(y[500..<10500]) < rms(x[1000..<21000]) * 0.01)   // > 40 dB down
    }

    @Test func otherRatesAndIntegers() {
        let y = Resampler.resample(tone(500, rate: 48000, seconds: 0.2), from: 48000, to: 22050)
        #expect(y.count == Int((0.2 * 22050).rounded(.up)))
        let ints = Resampler.resample([Int32](repeating: 32767, count: 1000), bits: 16, from: 44100, to: 22050)
        #expect(ints.count == 500 && ints.allSatisfy { $0 <= 32767 && $0 > 32000 })
        #expect(Resampler.resample([1, 2, 3], from: 44100, to: 44100) == [1, 2, 3])
    }

    @Test func twelveBitPreview() {
        #expect(MachinedrumPreview.quantize12([0x7FFF, 1, -1, 0x1234], bits: 16) == [0x7FF0, 0, -16, 0x1230])
        #expect(MachinedrumPreview.quantize12([100, -100], bits: 8) == [100, -100])          // already coarser
        // A 22.05 kHz sample plays at the device's 44.1 kHz, each frame stepped through twice.
        let s = SDSSample(samples: [0x7FFF, 0x0005], bits: 16, sampleRate: 22050)
        let back = try? AudioFile(bytes: MachinedrumPreview.wav(for: s, interpolation: .hold))
        #expect(back?.sdsSamples(stereo: .mix) == [0x7FF0, 0x7FF0, 0, 0] && back?.info.sampleRate == 44100)
    }

    @Test func resampledSampleScalesLoops() {
        let s = SDSSample(samples: [Int32](repeating: 0, count: 44100), bits: 16, sampleRate: 44100, loopStart: 1000, loopEnd: 43000, loopType: 0)
        let h = s.resampled(to: 22050)
        #expect(h.length == 22050 && h.sampleRate == 22050 && h.loopStart == 500 && h.loopEnd == 21500)
        #expect(s.resampled(to: 48000) == s)   // never upsample
    }
}

@Suite struct HalfRateItemTests {
    func wavItem(rate: Int, frames: Int = 4410, stereo: Bool = false) -> C6Item {
        let tone = (0..<frames).map { Int32(sin(Double($0) * 0.05) * 20000) }
        if !stereo { return C6Item(name: "t.wav", bytes: AudioWriter.wav(samples: tone, bits: 16, sampleRate: rate)) }
        // Interleaved stereo: same tone both sides.
        var data: [UInt8] = []
        for v in tone { for _ in 0..<2 { data += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] } }
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        let fmt: [UInt8] = [1, 0, 2, 0] + le32(rate) + le32(rate * 4) + [4, 0, 16, 0]
        let bytes = Array("RIFF".utf8) + le32(36 + data.count) + Array("WAVEfmt ".utf8) + le32(16) + fmt + Array("data".utf8) + le32(data.count) + data
        return C6Item(name: "s.wav", bytes: bytes)
    }

    @Test func toggleHalvesFramesAndMemory() {
        var item = wavItem(rate: 44100)
        #expect(item.canHalveRate && item.sendRate == 44100 && item.sendFrames == 4410)
        item.halfRate = true
        #expect(item.sendRate == 22050 && item.sendFrames == 2205)
        let s = item.sdsSampleToSend(name: "t")!
        #expect(s.sampleRate == 22050 && s.length == 2205)
        #expect(!wavItem(rate: 22050).canHalveRate)   // already 22 kHz: nothing to halve
    }

    @Test func previewIsMonoTwelveBitAtTheSendRate() throws {
        var item = wavItem(rate: 44100, stereo: true)
        let p1 = try AudioFile(bytes: item.previewAudio(asMachinedrum: true)!)
        #expect(p1.info.channels == 1 && p1.info.sampleRate == 44100)
        #expect(p1.sdsSamples(stereo: .mix).allSatisfy { $0 & 0xF == 0 })        // 12-bit: low 4 bits clear
        item.halfRate = true
        // The 22 kHz content plays at the MD's 44.1 kHz output (stepped through twice).
        let p2 = try AudioFile(bytes: item.previewAudio(asMachinedrum: true)!)
        #expect(p2.info.sampleRate == 44100 && p2.info.numFrames == 4410)
        // Preview off: the untouched file (unless the 22k toggle is on, which is still applied).
        item.halfRate = false
        #expect(item.previewAudio(asMachinedrum: false) == item.bytes)
    }
}


@Suite struct DoubleSpeedTests {
    func item(rate: Int = 44100, frames: Int = 4410, bits: Int = 16) -> C6Item {
        let peak = Double((1 << (bits - 1)) - 1)
        let tone = (0..<frames).map { Int32(sin(Double($0) * 0.05) * peak * 0.6) }
        return C6Item(name: "t.wav", bytes: AudioWriter.wav(samples: tone, bits: bits, sampleRate: rate))
    }

    @Test func doubleSpeedHalvesFramesButKeepsTheHeaderRate() throws {
        var i = item()
        i.doubleSpeed = true
        #expect(i.sendFrames == 2205)
        let s = try #require(i.sdsSampleToSend(name: nil))
        #expect(s.length == 2205 && s.sampleRate == 44100)            // plays 2× fast until PTCH −12
        // With 22k as well: a quarter of the frames, header 22.05 kHz.
        i.halfRate = true
        #expect(i.sendFrames == 1103)
        let q = try #require(i.sdsSampleToSend(name: nil))
        #expect(q.sampleRate == 22050 && abs(q.length - 1103) <= 1)
    }

    @Test func previewCompensatesTheOctave() throws {
        var i = item(); i.doubleSpeed = true
        // Original speed and length: 2205 stored frames stepped through twice at 44.1 kHz.
        let p = try AudioFile(bytes: i.previewAudio(asMachinedrum: true)!)
        #expect(p.info.sampleRate == 44100 && p.info.numFrames == 4410)
        // Without device emulation it still plays at the compensated speed (content rate 22.05 kHz).
        let q = try AudioFile(bytes: i.previewAudio(asMachinedrum: false)!)
        #expect(q.info.sampleRate == 22050 && q.info.numFrames == 2205)
    }

    @Test func interpolationModes() {
        #expect(MachinedrumPreview.stretch([0, 100], by: 2, interpolation: .hold) == [0, 0, 100, 100])
        #expect(MachinedrumPreview.stretch([0, 100], by: 2, interpolation: .linear) == [0, 50, 100, 100])
        #expect(MachinedrumPreview.stretch([0, 100], by: 4, interpolation: .linear) == [0, 25, 50, 75, 100, 100, 100, 100])
    }

    @Test func deepSamplesAreSentAs16Bit() throws {
        let i = item(bits: 24)
        let s16 = try #require(i.sdsSampleToSend(name: nil))
        #expect(s16.bits == 16 && SDSWordFormat(bits: 16)!.packetCount(forLength: s16.length) == 111)   // 40 per packet
        let s24 = try #require(i.sdsSampleToSend(name: nil, maxBits: nil))
        #expect(s24.bits == 24 && SDSWordFormat(bits: 24)!.packetCount(forLength: s24.length) == 147)   // 30 per packet
    }
}
