import Foundation

// SDS receiver (spec 20-transfer §4.3, §5): reassembles incoming sample dumps, answers the
// handshake, and emits one `SDSSample` per dump.
//
// Deviations from C6 1.51:
//  1. ACK/NAK/CANCEL carry the device number of the dump header being received. C6 only set it
//     in the WAV/AIFF header parsers (stale 0 for SDS/None), and its CANCEL was always
//     `F0 7E 00 7D 00 F7` (Q9); here CANCEL carries the device and the expected packet number.
//  2. Only headers and data packets are ACKed. C6 ACKed every `F0 7E` message, including an
//     incoming CANCEL, EOF, WAIT, identity replies and 05 xx extension messages.
//  3. An incoming CANCEL ends the current dump (partial result) and reports "Remotely
//     cancelled."; C6 ACKed it and kept receiving.
//  4. Extended Dump Headers (05 05) and Sample Names (05 03) are parsed (C6 ignored them), with
//     the same sample-number byte-order option as the sender. A 05 03 name wins over an SPS-1UW
//     name; one that arrives before its header is kept for the next header with that number.
//  5. A good packet that repeats the last accepted one (the device missed our ACK) is ACKed
//     again and dropped instead of counting as a bad packet.
//  6. After `maxBadPackets` consecutive bad packets (C6: 3) only the current dump is cancelled;
//     C6 ended the whole Receive. Same for a bad packet with handshake off (C6 cancelled at once,
//     this does too, but keeps listening for the next header).
//  7. Data packets are decoded into words here; C6's WAV/AIFF writers lived in the parser. The
//     dump's raw messages are kept so the caller can save the SDS (.syx) form too.
//  8. Headers with an unsupported bit depth are answered with CANCEL (C6 reused the previous
//     sample's packet layout).
//
// Rec Format "None" (`splitDumps = false`): the receiver still answers the handshake, but does
// not split, decode or keep anything, and does not consume SPS-1UW name messages — like C6, the
// caller keeps the whole raw stream as one item. `.dumpEnded` marks where C6's Mac build would
// still finalize (end of each complete dump); Windows never split.

/// Consumes incoming MIDI messages during Receive. Thread-safe; events are delivered on the
/// thread that called `handle`/`stop`, after replies have been sent.
public final class SDSReceiver: @unchecked Sendable {
    /// Reply strategy for incoming dumps (measured on a Machinedrum through a TM-1, 2026-10-16).
    public enum Pace: Sendable, Equatable {
        /// ACK every packet, NAK bad ones (C6). Works with every SDS sender. A Machinedrum then
        /// sends one packet per ≈160 ms at any TurboMIDI speed.
        case ackEachPacket
        /// Stay silent from the header on, so the sender runs open-loop: a Machinedrum at 10× sends
        /// one packet per ≈84 ms — about twice as fast. A bad packet can't be NAKed (open-loop MD
        /// ignores NAKs, and its NAK resend carries the next packet's data anyway), so the dump is
        /// cancelled and requested again with a Dump Request, up to `retries` times. An open-loop
        /// Machinedrum ignores CANCEL as well, so the rest of the failed dump is drained (counted
        /// and discarded) first; the request goes out when it ends or the line goes quiet.
        /// Never start ACKing mid-dump: a Machinedrum that has seen one ACK waits for an ACK on
        /// every packet and re-sends forever without it.
        case fast(retries: Int)
    }

    public struct Options: Sendable, Equatable {
        /// Reply ACK/NAK (C6 "SDS Handshake").
        public var handshake = true
        /// How good packets are answered while `handshake` is on.
        public var pace: Pace = .ackEachPacket
        /// false = C6 Rec Format "None": no per-dump split, no decoding, no name capture.
        public var splitDumps = true
        /// Sample-number byte order of 05 05 / 05 03 (C6: MSB first).
        public var sampleNumberOrder: SDSSampleNumberOrder = .c6
        /// Consecutive bad packets that cancel the dump (C6: NAK twice, CANCEL on the third).
        public var maxBadPackets = 3
        /// When set (after a Dump Request), a dump of any other sample is cancelled at its header
        /// and reported as `.unexpectedSample`. A Machinedrum sometimes answers the first request
        /// after other activity with the sample it last handled.
        public var expectedSampleNumber: Int?

        public init() {}
    }

    public struct ReceivedDump: Sendable, Equatable {
        public var sample: SDSSample
        /// The dump's messages as received: header, name messages, accepted packets (once each).
        public var messages: [[UInt8]]
        /// False when the dump was interrupted (new header, CANCEL, too many errors, `stop()`).
        public var isComplete: Bool
        /// Received with an Extended Dump Header (05 05).
        public var isExtended: Bool
        /// Packets rejected (bad checksum or out of sequence) during the dump.
        public var badPackets: Int
        /// The Machinedrum name (message 0x73) if the sender sent one — which also marks it as an MD.
        public var mdName: String? = nil
    }

    public enum Event: Sendable, Equatable {
        /// A dump header was accepted (`length` in words).
        case started(sampleNumber: Int, length: Int, bits: Int)
        /// Words received so far for the current dump.
        case progress(received: Int, total: Int)
        /// A dump finished or was interrupted (split mode).
        case dump(ReceivedDump)
        /// "None" mode: a dump ended; its bytes are in the caller's raw stream.
        case dumpEnded(sampleNumber: Int, complete: Bool)
        /// The device sent CANCEL ("Remotely cancelled.").
        case remotelyCancelled
        /// This receiver gave up on the dump and sent CANCEL.
        case cancelled(String)
        /// Fast pace: a bad packet cancelled the dump and it is being requested again.
        case retrying(sampleNumber: Int, attempt: Int)
        /// A dump of another sample than `expectedSampleNumber` began; it was cancelled at its header.
        case unexpectedSample(requested: Int, got: Int)
    }

    public static let remotelyCancelledText = "Remotely cancelled."

    /// Where ACK/NAK/CANCEL go; nil = listen only.
    public let transport: MIDITransport?
    public var onEvent: ((Event) -> Void)?

    private let lock = NSLock()
    private var _options: Options
    public var options: Options {
        get { lock.lock(); defer { lock.unlock() }; return _options }
        set { lock.lock(); _options = newValue; lock.unlock() }
    }

    private struct Dump {
        /// Number of the last packet the device sent (the one it now awaits a reply for).
        var lastNumber: UInt8?
        var device: UInt8
        var sampleNumber: Int
        var format: SDSWordFormat
        var periodNs: Int
        var rateHz: Int?
        var totalWords: Int
        var loopStart: Int
        var loopEnd: Int
        var loopType: UInt8
        var channels: Int
        var extended: Bool
        var expected: UInt8 = 0
        var received = 0
        var accepted = 0
        var words: [Int32] = []
        var messages: [[UInt8]] = []
        var extName: String?
        var spsName: String?
        var consecutiveBad = 0
        var badPackets = 0
    }

    private var dump: Dump?
    private var pendingName: (sampleNumber: Int, name: String)?

    public init(transport: MIDITransport?, options: Options = Options()) {
        self.transport = transport
        _options = options
    }

    public var isDumpInProgress: Bool { lock.lock(); defer { lock.unlock() }; return dump != nil }

    /// Feed every incoming MIDI message. Returns true if the message was consumed into a dump
    /// (the caller should not also store it as raw SysEx). Always false in "None" mode.
    @discardableResult
    public func handle(_ m: [UInt8]) -> Bool {
        var out = Output()
        lock.lock()
        let consumed = process(m, &out)
        let split = _options.splitDumps
        lock.unlock()
        deliver(out)
        return consumed && split
    }

    /// Stops receiving (C6 `stopReceive`): if a dump is in progress, sends CANCEL and emits the
    /// partial dump, which is also returned.
    @discardableResult
    public func stop() -> ReceivedDump? {
        var out = Output()
        lock.lock()
        pendingName = nil
        drain = nil
        var partial: ReceivedDump?
        if let d = dump {
            // A Machinedrum only honours CANCEL for the packet it is waiting on (the last one it
            // sent); send that, and the next number too in case the last one was already handled.
            let waiting = d.lastNumber ?? 0
            out.replies.append(SDSMessage.cancel(device: d.device, packet: waiting).bytes())
            if d.expected != waiting { out.replies.append(SDSMessage.cancel(device: d.device, packet: d.expected).bytes()) }
            partial = end(d, complete: false, &out)
        }
        lock.unlock()
        deliver(out)
        return partial
    }

    // MARK: - Processing (under lock)

    private struct Output { var replies: [[UInt8]] = []; var events: [Event] = []; var delayedRequest: [UInt8]?; var startDrainWatch = false }

    /// Ends a drain: the failed dump is over, so ask for it again.
    private func finishDrain(_ out: inout Output) {
        guard let dr = drain else { return }
        drain = nil
        out.delayedRequest = SDSMessage.dumpRequest(device: dr.device, sampleNumber: dr.sampleNumber).bytes()
    }

    /// Polls a drain for silence (a device that honoured the CANCEL stops early).
    private func watchDrain() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            var out = Output()
            self.lock.lock()
            guard let dr = self.drain else { self.lock.unlock(); return }
            let quiet = Date().timeIntervalSince(dr.last) > self.drainQuietTime
            if quiet { self.finishDrain(&out) }
            self.lock.unlock()
            if quiet { self.deliver(out) } else { self.watchDrain() }
        }
    }

    /// Pause between cancelling a dump and requesting it again (lets the device settle).
    public var retryDelay: Double = 0.3
    private var retryCounts: [Int: Int] = [:]
    /// Fast pace after a bad packet: discarding the rest of a dump before requesting it again.
    private struct Drain { var device: UInt8; var sampleNumber: Int; var packetsLeft: Int; var last: Date }
    private var drain: Drain?
    /// Silence after which a drained dump is considered over (devices that honoured the CANCEL).
    public var drainQuietTime: Double = 0.6

    private func deliver(_ out: Output) {
        if let t = transport { out.replies.forEach { t.send($0) } }
        if let h = onEvent { out.events.forEach(h) }
        if let req = out.delayedRequest, let t = transport {
            DispatchQueue.global().asyncAfter(deadline: .now() + retryDelay) { t.send(req) }
        }
        if out.startDrainWatch { watchDrain() }
    }

    private func process(_ m: [UInt8], _ out: inout Output) -> Bool {
        guard m.count >= 5, m[0] == 0xF0, m[m.count - 1] == 0xF7 else { return false }
        let opts = _options

        if let sps = SDSMessage.parseSPSName(m) {
            // C6: only while a dump is in progress and Rec Format ≠ None; the slot is ignored.
            guard opts.splitDumps, dump != nil else { return false }
            dump!.spsName = sps.name
            dump!.messages.append(m)
            return true
        }
        guard m[1] == 0x7E else { return false }
        if SDSMessage.isDataPacket(m) { return packet(m, opts, &out) }

        switch SDSMessage.decode(m, order: opts.sampleNumberOrder) {
        case let .dumpHeader(h):
            begin(device: h.device, sampleNumber: h.sampleNumber, bits: h.bits, periodNs: h.samplePeriodNs,
                  rateHz: nil, length: h.length, loopStart: h.loopStart, loopEnd: h.loopEnd,
                  loopType: h.loopType, channels: 1, extended: false, raw: m, opts, &out)
            return true
        case let .extendedDumpHeader(h):
            let rate = h.exactSampleRate
            begin(device: h.device, sampleNumber: h.sampleNumber, bits: h.bits,
                  periodNs: rate > 0 ? Int((1e9 / rate).rounded()) : 0, rateHz: Int(rate.rounded()),
                  length: h.length, loopStart: h.loopStart, loopEnd: h.loopEnd, loopType: h.loopType,
                  channels: max(1, h.channels), extended: true, raw: m, opts, &out)
            return true
        case let .sampleName(n):
            guard opts.splitDumps else { return false }
            if dump != nil {
                dump!.extName = n.name
                dump!.messages.append(m)
            } else {
                pendingName = (n.sampleNumber, n.name)
            }
            return true
        case .cancel:
            if let d = dump { _ = end(d, complete: false, &out) }
            out.events.append(.remotelyCancelled)
            return true
        default:
            return false // ACK/NAK/WAIT/EOF/requests are for a sender
        }
    }

    private func begin(device: UInt8, sampleNumber: Int, bits: Int, periodNs: Int, rateHz: Int?, length: Int,
                       loopStart: Int, loopEnd: Int, loopType: UInt8, channels: Int, extended: Bool,
                       raw: [UInt8], _ opts: Options, _ out: inout Output) {
        if let d = dump { _ = end(d, complete: false, &out) } // C6 finalizes pending data at a header
        if let want = opts.expectedSampleNumber, want != sampleNumber {
            out.replies.append(SDSMessage.cancel(device: device, packet: 0).bytes())
            out.events.append(.unexpectedSample(requested: want, got: sampleNumber))
            return
        }
        guard let format = SDSWordFormat(bits: bits) else {
            out.replies.append(SDSMessage.cancel(device: device, packet: 0).bytes())
            out.events.append(.cancelled("Unsupported sample format: \(bits) bits"))
            return
        }
        var d = Dump(device: device, sampleNumber: sampleNumber, format: format, periodNs: periodNs, rateHz: rateHz,
                     totalWords: length * channels, loopStart: loopStart, loopEnd: loopEnd, loopType: loopType,
                     channels: channels, extended: extended)
        if opts.splitDumps {
            d.messages = [raw]
            d.words.reserveCapacity(min(d.totalWords, 1 << 24))
            if let p = pendingName, p.sampleNumber == sampleNumber { d.extName = p.name }
        }
        pendingName = nil
        drain = nil
        dump = d
        out.events.append(.started(sampleNumber: sampleNumber, length: length, bits: bits))
        if opts.handshake && opts.pace == .ackEachPacket { out.replies.append(SDSMessage.ack(device: device, packet: 0).bytes()) }
        if d.totalWords == 0 { _ = end(d, complete: true, &out) }
    }

    private func packet(_ m: [UInt8], _ opts: Options, _ out: inout Output) -> Bool {
        if var dr = drain, dump == nil {
            dr.packetsLeft -= 1; dr.last = Date(); drain = dr
            if dr.packetsLeft <= 0 { finishDrain(&out) }
            return true
        }
        if m.count > 4 { dump?.lastNumber = m[4] & 0x7F }
        guard var d = dump else { return false } // no header seen: not ours to judge
        let ackGood = opts.handshake && opts.pace == .ackEachPacket
        var p: SDSDataPacket?
        if case let .dataPacket(x)? = SDSMessage.decode(m) { p = x }

        if let p, p.number == d.expected, p.isChecksumValid {
            let take = min(d.format.samplesPerPacket, d.totalWords - d.received)
            if opts.splitDumps {
                d.words += d.format.decode(p.data).prefix(take)
                d.messages.append(m)
            }
            d.received += take
            d.accepted += 1
            d.expected = (d.expected + 1) & 0x7F
            d.consecutiveBad = 0
            if ackGood { out.replies.append(SDSMessage.ack(device: d.device, packet: p.number).bytes()) }
            out.events.append(.progress(received: d.received, total: d.totalWords))
            dump = d
            if d.received >= d.totalWords { _ = end(d, complete: true, &out) }
            return true
        }
        if let p, p.isChecksumValid, d.accepted > 0, p.number == (d.expected &- 1) & 0x7F {
            if ackGood { out.replies.append(SDSMessage.ack(device: d.device, packet: p.number).bytes()) }
            return true // repeat of the last packet
        }
        d.badPackets += 1
        d.consecutiveBad += 1
        dump = d
        if opts.handshake, case let .fast(retries) = opts.pace {
            // Open loop: cancel at once (naming the packet the device is on) and ask again.
            let waiting = d.lastNumber ?? d.expected
            out.replies.append(SDSMessage.cancel(device: d.device, packet: waiting).bytes())
            dump = nil
            let attempt = (retryCounts[d.sampleNumber] ?? 0) + 1
            if attempt <= retries {
                retryCounts[d.sampleNumber] = attempt
                out.events.append(.retrying(sampleNumber: d.sampleNumber, attempt: attempt))
                let total = d.format.packetCount(forLength: d.totalWords)
                drain = Drain(device: d.device, sampleNumber: d.sampleNumber,
                              packetsLeft: max(0, total - d.accepted - 1), last: Date())
                if drain!.packetsLeft == 0 { finishDrain(&out) } else { out.startDrainWatch = true }
            } else {
                retryCounts[d.sampleNumber] = nil
                dump = d
                _ = end(d, complete: false, &out)
                out.events.append(.cancelled("Sample \(d.sampleNumber): bad packets on \(attempt) attempts; receive cancelled."))
            }
            return true
        }
        if opts.handshake && d.consecutiveBad < opts.maxBadPackets {
            out.replies.append(SDSMessage.nak(device: d.device, packet: d.expected).bytes())
        } else {
            out.replies.append(SDSMessage.cancel(device: d.device, packet: d.expected).bytes())
            _ = end(d, complete: false, &out)
            out.events.append(.cancelled(opts.handshake
                ? "Receive cancelled after \(d.consecutiveBad) bad packets."
                : "Receive cancelled: bad packet \(m.count > 4 ? Int(m[4]) : -1)."))
        }
        return true
    }

    /// Finishes the current dump and emits it; returns the dump (split mode).
    private func end(_ d: Dump, complete: Bool, _ out: inout Output) -> ReceivedDump? {
        dump = nil
        guard _options.splitDumps else {
            out.events.append(.dumpEnded(sampleNumber: d.sampleNumber, complete: complete))
            return nil
        }
        let sample = SDSSample(samples: d.words, bits: d.format.bits, samplePeriodNs: d.periodNs, sampleRateHz: d.rateHz,
                               loopStart: d.loopStart, loopEnd: d.loopEnd, loopType: d.loopType,
                               name: d.extName ?? d.spsName, sampleNumber: d.sampleNumber, channels: d.channels)
        let r = ReceivedDump(sample: sample, messages: d.messages, isComplete: complete,
                             isExtended: d.extended, badPackets: d.badPackets, mdName: d.spsName)
        out.events.append(.dump(r))
        if complete { retryCounts[d.sampleNumber] = nil }
        return r
    }

    // MARK: - Naming (40-config-ui §4.1)

    /// C6's list-entry name for received data: `<name>.<ext>` when the dump carried a name
    /// (SPS-1UW or 05 03), else `Received data N.<ext>` with `counter` post-incremented.
    /// The extension follows the Rec Format for SDS dumps (SDS/None → syx, WAV → wav,
    /// AIFF → aiff); non-SDS data (`dump == nil`) is always `.syx`.
    public static func itemName(for dump: ReceivedDump?, recFormat: C6Settings.RecFormat, counter: inout Int) -> String {
        let ext: String
        switch dump == nil ? .sds : recFormat {
        case .wav: ext = "wav"
        case .aiff: ext = "aiff"
        case .sds, .none: ext = "syx"
        }
        if let d = dump {
            // C2026: samples from a Machinedrum carry their slot and name, "MD26 MOUF.wav"
            // (slot = sample number + 1); others use their dump name, or the sample number.
            let n = d.sample.sampleNumber
            if let md = d.mdName {
                let name = md.trimmingCharacters(in: .whitespaces)
                return "MD\(n + 1)" + (name.isEmpty ? "" : " " + name) + ".\(ext)"
            }
            if let name = d.sample.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return "\(name).\(ext)" }
            return "Sample \(n).\(ext)"
        }
        defer { counter += 1 }
        return "Received data \(counter).\(ext)"
    }
}
