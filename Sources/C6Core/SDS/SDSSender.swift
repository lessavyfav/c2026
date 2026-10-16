import Foundation

// SDS sender (spec 20-transfer §2, §3, §4, §7): sends SDSSamples as Dump Header (or Extended
// Dump Header + Sample Name), optional Machinedrum SPS-1UW name, then 127-byte data packets,
// with or without the ACK/NAK/WAIT/CANCEL handshake.
//
// Deviations from C6 1.51 (Mac build is the reference; quirk numbers refer to spec §8):
//  1. NAK resends the NAK'd packet. C6 compared the NAK's packet number with byte 5 of the last
//     packet instead of byte 4 (Q2), so almost every NAK aborted the batch. A NAK whose number
//     matches nothing recently sent is ignored as stale (C6: abort). At most `maxResends`
//     consecutive NAKs per message, then the batch fails (C6: unbounded).
//  2. A NAK to the header resends the header (C6: abort).
//  3. A packet-reply timeout in closed loop falls back to open loop for the following packets,
//     as the SDS spec says; C6 aborted the whole batch ("Done."). Any later ACK/NAK from the
//     device puts the transfer back into closed loop (C6's per-file open loop was final).
//  4. WAIT pauses until the next ACK/NAK/CANCEL for up to `waitTimeout` (default 60 s, re-armed
//     by each WAIT) and is honoured after the header and in open loop too. C6 only honoured it
//     inside the closed-loop wait, for ≈5 s, and kept a stale WAIT flag across packets/files.
//  5. Header reply timeout is 2 s (the SDS spec's value) instead of C6's ≈200 ms; per-packet
//     reply timeout stays at C6's 65 ms. All are options.
//  6. Pacing: every message is timestamped at the line rate (`PacedSender`), so open loop runs
//     at the real wire speed instead of relying on CoreMIDI's MaxSysExSpeed property plus
//     1/60 s `Delay()` ticks. `interPacketDelayMs` adds a gap before every message except the
//     first (C6 Mac: before every packet and before headers 2…n); in closed loop the gap counts
//     from the reply, as C6's Delay ran after the handshake wait.
//  7. Local cancel sends `F0 7E dd 7D pp F7` with the configured device number and the number of
//     the last packet sent. C6's Stop sent nothing while sending, and its CANCEL template was
//     never patched (always `F0 7E 00 7D 00 F7`, Q9). A batch that fails after the header
//     also sends CANCEL.
//  8. CANCEL from the device stops the batch with `.remotelyCancelled` ("Remotely cancelled.",
//     the Windows behaviour; the Mac build just said "Done.").
//  9. Header buffers are built per message (no 21-byte HDRBUF overflow, Q1); samples longer than
//     2^21 − 1 words are refused without Extended SDS instead of wrapping the 21-bit fields.
// 10. The last packet is not padded with the frame after the end (Q7): missing words are 0.
// 11. Replies are only read while a send is running and are reset per `send` call. Like C6, any
//     ACK counts for the outstanding message (its packet number is not checked).
// 12. Name messages are skipped when the sample has no name (C6 always had a file name).

/// Sends SDS samples over a `MIDITransport`. Blocking: call `send` on a worker thread, and feed
/// every incoming MIDI message to `handle(_:)` (from any thread) while it runs.
public final class SDSSender: @unchecked Sendable {
    public struct Options: Sendable, Equatable {
        /// SDS handshake (C6 "SDS Handshake" = !`Ignore Handshake`). Off = pure open loop.
        public var handshake = true
        /// Send the CA-019 Extended Dump Header (05 05) and Sample Name (05 03) instead of 01.
        public var extendedSDS = false
        /// Append the Machinedrum SPS-1UW name message (0x73) after the header.
        public var sendSPS1UWName = false
        /// SDS device number (`dd`), 0…127; replies are only accepted from this number.
        public var deviceNumber: UInt8 = 0
        /// Sample number of the first sample; nil uses each sample's own `sampleNumber`.
        public var startSampleNumber: Int?
        /// With `startSampleNumber`: sample i gets start + i (C6's Sample Position auto-increment).
        public var autoIncrementSampleNumber = true
        /// Extra gap before each message after the first, in milliseconds.
        public var interPacketDelayMs: Double = 0
        /// Minimum time between packet starts while no replies arrive (open loop). Line rate at 10×
        /// is ~4 ms per packet, but a Machinedrum digests one per ~6.5–9 ms, so without its ACKs to
        /// pace by, faster sending only works while its input buffer lasts.
        public var openLoopMinInterval: Double = 0.009
        /// Line rate in bytes/s for pacing (3125 = MIDI 1.0; multiply for TurboMIDI).
        public var lineRate: Double = Elektron.baseBytesPerSecond
        /// Sample-number byte order for 05 05 / 05 03 (C6: MSB first).
        public var sampleNumberOrder: SDSSampleNumberOrder = .c6
        /// Seconds to wait for the first reply after a header before assuming open loop.
        public var headerReplyTimeout: Double = 2.0
        /// Seconds to wait for a packet's reply in closed loop before continuing open loop.
        public var packetReplyTimeout: Double = 0.065
        /// Ceiling for a WAIT (re-armed by every WAIT); expiring fails the batch.
        public var waitTimeout: Double = 60
        /// Consecutive NAKs tolerated for one message before giving up.
        public var maxResends = 10

        public init() {}
    }

    public struct Progress: Sendable, Equatable {
        /// 0-based index of the sample being sent, and the batch size.
        public var sampleIndex: Int
        public var sampleCount: Int
        public var sampleNumber: Int
        /// Words of the current sample sent so far (C6's "%d samples").
        public var samplesDone: Int
        public var samplesTotal: Int
        /// Bytes of the whole batch (headers + packets, resends not counted).
        public var bytesDone: Int
        public var bytesTotal: Int
    }

    public enum Outcome: Sendable, Equatable {
        case completed
        case cancelled
        case remotelyCancelled
        case failed(String)

        public var statusText: String {
            switch self {
            case .completed: return "Done."
            case .cancelled: return "Cancelled."
            case .remotelyCancelled: return SDSSender.remotelyCancelledText
            case let .failed(s): return s
            }
        }
    }

    public struct Report: Sendable, Equatable {
        public var outcome: Outcome
        /// Samples fully sent.
        public var samplesCompleted = 0
        /// Sample numbers used, for every sample that was started.
        public var sampleNumbers: [Int] = []
        /// Data packets put on the wire, including resends.
        public var packetsSent = 0
        /// Messages (headers or packets) resent after a NAK.
        public var resends = 0
        /// Closed-loop reply timeouts (each one continued open loop).
        public var timeouts = 0
        /// WAIT messages honoured.
        public var waits = 0
        /// Samples whose header got no reply (sent open loop with handshake on).
        public var openLoopSamples = 0
    }

    public static let remotelyCancelledText = "Remotely cancelled."

    public let transport: MIDITransport
    /// Read when `send` starts.
    public var options: Options

    // Reply mailbox, written by `handle` (MIDI thread), read by the worker.
    private enum Reply: Equatable { case ack(UInt8), nak(UInt8) }
    private let cond = NSCondition()
    private var active = false
    private var activeDevice: UInt8 = 0
    private var reply: Reply?
    private var waitPending = false
    private var remoteCancel = false
    private var localCancel = false

    public init(transport: MIDITransport, options: Options = Options()) {
        self.transport = transport
        self.options = options
    }

    /// Feed incoming MIDI messages here. Returns true for an SDS reply consumed by a running send
    /// (ACK, NAK, WAIT or CANCEL from the configured device; EOF is ignored as in C6).
    @discardableResult
    public func handle(_ m: [UInt8]) -> Bool {
        guard m.count >= 6, m[0] == 0xF0, m[1] == 0x7E, m[m.count - 1] == 0xF7 else { return false }
        cond.lock(); defer { cond.unlock() }
        guard active, m[2] == activeDevice else { return false }
        switch m[3] {
        case SDSMessage.SubID.ack: reply = .ack(m[4])
        case SDSMessage.SubID.nak: reply = .nak(m[4])
        case SDSMessage.SubID.cancel: remoteCancel = true
        case SDSMessage.SubID.wait: waitPending = true
        default: return false
        }
        cond.broadcast()
        return true
    }

    /// Requests cancellation of a running `send` (thread-safe). Same effect as `isCancelled`.
    public func cancel() {
        cond.lock(); localCancel = true; cond.broadcast(); cond.unlock()
    }

    /// Why a sample cannot be sent with `options`, or nil.
    public static func validate(_ s: SDSSample, options: Options) -> String? {
        if SDSWordFormat(bits: s.bits) == nil { return "Unsupported sample format: \(s.bits) bits" }
        if !options.extendedSDS && s.length > (1 << 21) - 1 {
            return "Sample too long for standard SDS (\(s.length) words, max \((1 << 21) - 1)); use Extended SDS"
        }
        return nil
    }

    /// The header buffer C6 sent in one go: Dump Header, or Extended Dump Header + Sample Name,
    /// then the SPS-1UW name message if enabled (§2.1 step 5–6, §3, §4.1).
    public static func headerMessages(for s: SDSSample, sampleNumber: Int, options: Options) -> [UInt8] {
        let dev = options.deviceNumber & 0x7F
        let name = (s.name?.isEmpty == false) ? s.name : nil
        var out: [UInt8]
        if options.extendedSDS {
            out = SDSMessage.extendedDumpHeader(SDSExtendedDumpHeader(sample: s, device: dev, sampleNumber: sampleNumber))
                .bytes(order: options.sampleNumberOrder)
            if let name {
                out += SDSMessage.sampleName(SDSSampleName(device: dev, sampleNumber: sampleNumber, name: name))
                    .bytes(order: options.sampleNumberOrder)
            }
        } else {
            out = SDSMessage.dumpHeader(SDSDumpHeader(sample: s, device: dev, sampleNumber: sampleNumber)).bytes()
        }
        // C2026: an explicit MD name (typed by the user) is always sent; otherwise C6's rule applies
        // when "Send SPS-1UW Name" is on.
        if let md = s.mdName.map(MDName.normalize), !md.isEmpty {
            out += SDSMessage.spsNameMessage(slot: sampleNumber, name: md)
        } else if options.sendSPS1UWName, let name {
            out += SDSMessage.spsNameMessage(slot: sampleNumber, name: SDSMessage.spsName(fromBaseName: name))
        }
        return out
    }

    /// Sends `samples` in order and blocks until done, cancelled or failed.
    /// - Parameters:
    ///   - progress: called on this thread after the header and after every packet.
    ///   - isCancelled: polled between fragments and while waiting for replies.
    @discardableResult
    public func send(_ samples: [SDSSample], progress: ((Progress) -> Void)? = nil,
                     isCancelled: () -> Bool = { false }) -> Report {
        let opts = options
        let dev = opts.deviceNumber & 0x7F
        var report = Report(outcome: .completed)
        for s in samples {
            if let err = SDSSender.validate(s, options: opts) {
                report.outcome = .failed(s.name.map { "\($0): \(err)" } ?? err)
                return report
            }
        }

        struct Plan { var sample: SDSSample; var number: Int; var header: [UInt8]; var format: SDSWordFormat; var packets: Int }
        let plans: [Plan] = samples.enumerated().map { i, s in
            let n = opts.startSampleNumber.map { opts.autoIncrementSampleNumber ? $0 + i : $0 } ?? s.sampleNumber
            let f = SDSWordFormat(bits: s.bits)!
            return Plan(sample: s, number: n, header: SDSSender.headerMessages(for: s, sampleNumber: n, options: opts),
                        format: f, packets: f.packetCount(forLength: s.length))
        }
        let bytesTotal = plans.reduce(0) { $0 + $1.header.count + $1.packets * SDSDataPacket.byteCount }
        var bytesBefore = 0

        cond.lock()
        active = true; activeDevice = dev
        reply = nil; waitPending = false; remoteCancel = false; localCancel = false
        cond.unlock()
        defer { cond.lock(); active = false; cond.unlock() }

        let paced = PacedSender(transport: transport, options: .init(bytesPerSecond: opts.lineRate))
        let delay = HostTime.ticks(fromSeconds: opts.interPacketDelayMs / 1000)
        func stopRequested() -> Bool {
            if isCancelled() { return true }
            cond.lock(); defer { cond.unlock() }
            return localCancel || remoteCancel
        }
        // Time after which the next message may start (end of the last message, or the reply).
        var reference: UInt64?

        func startTime() -> UInt64? {
            guard let ref = reference else { return nil }
            let ideal = ref + delay, now = HostTime.now
            // Stay on the line-rate grid when slightly late (thread wake-up latency): the interface
            // is still sending the previous bytes, so a timestamp a few ms in the past keeps the
            // wire busy without bursting more than ~10 ms of data. Further behind, start now.
            return ideal >= now || now - ideal < HostTime.ticks(fromSeconds: 0.010) ? ideal : now
        }

        var lastStart: UInt64?
        let minGap = HostTime.ticks(fromSeconds: opts.openLoopMinInterval)

        /// Sends one message; false if it was interrupted. `openLoop` enforces the minimum spacing.
        func transmit(_ bytes: [UInt8], openLoop: Bool = false) -> Bool {
            clearReply()
            var start = startTime()
            if openLoop, let last = lastStart {
                let earliest = last + minGap
                if (start ?? HostTime.now) < earliest {
                    HostTime.wait(until: earliest > HostTime.ticks(fromSeconds: 0.002) ? earliest - HostTime.ticks(fromSeconds: 0.002) : earliest)
                    start = earliest
                }
            }
            lastStart = start ?? HostTime.now
            let (r, finish) = paced.send(bytes[...], startAt: start, isCancelled: stopRequested)
            reference = finish
            return r == .completed
        }

        /// Ends the batch: flushes output; sends CANCEL unless the device cancelled.
        func stop(_ outcome: Outcome, cancelPacket: UInt8?) -> Report {
            transport.flushScheduled()
            if outcome != .remotelyCancelled, let p = cancelPacket {
                transport.send(SDSMessage.cancel(device: dev, packet: p).bytes())
            }
            report.outcome = outcome
            return report
        }

        func interruption() -> Outcome {
            cond.lock(); defer { cond.unlock() }
            return remoteCancel ? .remotelyCancelled : .cancelled
        }

        for (index, plan) in plans.enumerated() {
            report.sampleNumbers.append(plan.number)
            let length = plan.sample.length, spp = plan.format.samplesPerPacket
            func emit(_ next: Int) {
                progress?(Progress(sampleIndex: index, sampleCount: plans.count, sampleNumber: plan.number,
                                   samplesDone: min(length, next * spp), samplesTotal: length,
                                   bytesDone: bytesBefore + plan.header.count + min(next, plan.packets) * SDSDataPacket.byteCount,
                                   bytesTotal: bytesTotal))
            }

            // ---- Header ----
            var closedLoop = false
            var resends = 0
            header: while true {
                if stopRequested() { return stop(interruption(), cancelPacket: 0) }
                if !transmit(plan.header) { return stop(interruption(), cancelPacket: 0) }
                guard opts.handshake else { break }
                var deadline = HostTime.now + HostTime.ticks(fromSeconds: opts.headerReplyTimeout)
                switch awaitReply(deadline: &deadline, opts: opts, report: &report, isCancelled: isCancelled) {
                case .ack:
                    closedLoop = true
                    break header
                case .nak:
                    resends += 1; report.resends += 1
                    if resends > opts.maxResends {
                        return stop(.failed("The device rejected the dump header."), cancelPacket: 0)
                    }
                case .timeout:
                    report.openLoopSamples += 1
                    break header
                case .waitExpired:
                    return stop(.failed("The device sent WAIT and did not resume."), cancelPacket: 0)
                case .remoteCancel:
                    return stop(.remotelyCancelled, cancelPacket: nil)
                case .localCancel:
                    return stop(.cancelled, cancelPacket: 0)
                }
                reference = HostTime.now
            }
            if closedLoop { reference = HostTime.now }
            emit(0)

            // ---- Data packets ----
            var next = 0          // index of the next packet to send
            var lastSent = -1     // index of the last packet sent
            resends = 0

            /// Index of a recently sent packet carrying number `n` (only the last one in closed loop).
            func nakTarget(_ n: UInt8, window: Int) -> Int? {
                guard lastSent >= 0 else { return nil }
                for j in stride(from: lastSent, through: max(0, lastSent - window + 1), by: -1) where UInt8(j & 0x7F) == n {
                    return j
                }
                return nil
            }

            /// Rewinds to the NAK'd packet if it was sent recently (stale NAKs change nothing).
            /// Returns a report only when the resend limit is exceeded.
            func applyNAK(_ n: UInt8, window: Int) -> Report? {
                guard let j = nakTarget(n, window: window) else { return nil }
                next = j
                resends += 1; report.resends += 1
                if resends > opts.maxResends {
                    return stop(.failed("The device rejected packet \(n) \(resends) times."), cancelPacket: n)
                }
                return nil
            }

            while next < plan.packets {
                let cancelPacket = UInt8(max(0, lastSent) & 0x7F)
                if stopRequested() { return stop(interruption(), cancelPacket: cancelPacket) }

                // Open loop with handshake on: act on replies that arrived meanwhile.
                if opts.handshake && !closedLoop {
                    var now = HostTime.now
                    switch awaitReply(deadline: &now, opts: opts, report: &report, isCancelled: isCancelled) {
                    case .ack:
                        closedLoop = true; resends = 0
                    case let .nak(n):
                        if let failed = applyNAK(n, window: 8) { return failed }
                        if next <= lastSent { closedLoop = true }
                    case .timeout:
                        break
                    case .waitExpired:
                        return stop(.failed("The device sent WAIT and did not resume."), cancelPacket: cancelPacket)
                    case .remoteCancel:
                        return stop(.remotelyCancelled, cancelPacket: nil)
                    case .localCancel:
                        return stop(.cancelled, cancelPacket: cancelPacket)
                    }
                }

                let k = next
                let bytes = SDSMessage.dataPacket(SDSDataPacket(sample: plan.sample, index: k, device: dev, format: plan.format)).bytes()
                if !transmit(bytes, openLoop: !(opts.handshake && closedLoop)) { return stop(interruption(), cancelPacket: UInt8(k & 0x7F)) }
                report.packetsSent += 1
                lastSent = k
                next = k + 1

                if opts.handshake && closedLoop {
                    var deadline = HostTime.now + HostTime.ticks(fromSeconds: opts.packetReplyTimeout)
                    waitLoop: while true {
                        switch awaitReply(deadline: &deadline, opts: opts, report: &report, isCancelled: isCancelled) {
                        case .ack:
                            resends = 0
                        case let .nak(n):
                            guard nakTarget(n, window: 1) != nil else { continue waitLoop } // stale: keep waiting
                            if let failed = applyNAK(n, window: 1) { return failed }
                        case .timeout:
                            report.timeouts += 1
                            closedLoop = false
                        case .waitExpired:
                            return stop(.failed("The device sent WAIT and did not resume."), cancelPacket: UInt8(k & 0x7F))
                        case .remoteCancel:
                            return stop(.remotelyCancelled, cancelPacket: nil)
                        case .localCancel:
                            return stop(.cancelled, cancelPacket: UInt8(k & 0x7F))
                        }
                        break waitLoop
                    }
                    if closedLoop { reference = HostTime.now }
                }
                emit(next)
            }
            report.samplesCompleted += 1
            bytesBefore += plan.header.count + plan.packets * SDSDataPacket.byteCount
        }
        report.outcome = .completed
        return report
    }

    // MARK: - Reply waiting

    private enum WaitResult: Equatable { case ack, nak(UInt8), timeout, waitExpired, remoteCancel, localCancel }

    private func clearReply() {
        cond.lock(); reply = nil; cond.unlock()
    }

    /// Waits until `deadline` for ACK/NAK. A WAIT moves the deadline to now + `waitTimeout`
    /// (written back), after which expiry is `.waitExpired`. CANCEL and local cancel end the wait.
    private func awaitReply(deadline: inout UInt64, opts: Options, report: inout Report,
                            isCancelled: () -> Bool) -> WaitResult {
        var waited = false
        cond.lock()
        defer { cond.unlock() }
        while true {
            if remoteCancel { return .remoteCancel }
            if localCancel { return .localCancel }
            if waitPending {
                waitPending = false; waited = true; report.waits += 1
                deadline = HostTime.now + HostTime.ticks(fromSeconds: opts.waitTimeout)
            }
            if let r = reply {
                reply = nil
                switch r {
                case .ack: return .ack
                case let .nak(n): return .nak(n)
                }
            }
            let now = HostTime.now
            if now >= deadline { return waited ? .waitExpired : .timeout }
            cond.unlock()
            let cancelled = isCancelled()
            cond.lock()
            if cancelled { return .localCancel }
            let slice = min(HostTime.seconds(fromTicks: deadline - now), 0.005)
            _ = cond.wait(until: Date(timeIntervalSinceNow: slice))
        }
    }
}
