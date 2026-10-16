import Foundation

/// What a device holds in one sample slot, read from the header of a dump it was asked for.
public struct SlotInfo: Equatable, Sendable, Identifiable {
    public var sampleNumber: Int            // SDS number (0-based)
    public var slot: Int { sampleNumber + 1 } // as the device shows it
    public var id: Int { sampleNumber }
    public var name: String?                 // Machinedrum 4-letter name, if sent
    public var length: Int                   // frames
    public var bits: Int
    public var sampleRate: Int
    public var loopStart: Int
    public var loopEnd: Int
    public var loopType: UInt8

    public init(sampleNumber: Int, name: String?, length: Int, bits: Int, sampleRate: Int,
                loopStart: Int, loopEnd: Int, loopType: UInt8) {
        self.sampleNumber = sampleNumber; self.name = name; self.length = length; self.bits = bits
        self.sampleRate = sampleRate; self.loopStart = loopStart; self.loopEnd = loopEnd; self.loopType = loopType
    }

    public var duration: Double { sampleRate > 0 ? Double(length) / Double(sampleRate) : 0 }
    /// Whether the slot has a usable loop (devices report "0–0" or end ≤ start for none).
    public var hasLoop: Bool { loopType != 0x7F && loopEnd > loopStart && loopEnd < length }
    /// Header values a real sample can have (rejects headers garbled by a busy device).
    public var isPlausible: Bool {
        (8...28).contains(bits) && (1000...192_000).contains(sampleRate) && length > 0
    }
}

/// Lists a device's samples without downloading them: for each slot it sends a Dump Request,
/// reads the Dump Header (and the Machinedrum's name message), then CANCELs.
public final class SampleScanner: @unchecked Sendable {
    public struct Options: Sendable {
        public var deviceNumber: UInt8 = 0
        /// How long to wait for a header before treating the slot as empty.
        public var headerTimeout: Double = 0.5
        /// How long to wait after the header for the name message.
        public var nameWait: Double = 0.12
        /// Pause after CANCEL before the next request. A Machinedrum needs ~300 ms to abort: with
        /// less it misses every other request and answers some with garbled headers.
        public var settle: Double = 0.3
        /// Extra attempts for a slot that didn't answer or answered with an implausible header.
        public var retries = 1
        public init() {}
    }

    private let transport: MIDITransport
    private let cond = NSCondition()
    private var header: SDSDumpHeader?
    private var name: String?
    private var packetsSeen = 0
    public var options: Options

    public init(transport: MIDITransport, options: Options = Options()) {
        self.transport = transport
        self.options = options
    }

    /// Feed every incoming message here while scanning; returns true if it was consumed.
    @discardableResult
    public func handle(_ m: [UInt8]) -> Bool {
        if let sps = SDSMessage.parseSPSName(m) {
            cond.lock(); name = sps.name; cond.signal(); cond.unlock(); return true
        }
        guard m.count > 3, m[1] == 0x7E else { return false }
        switch SDSMessage.decode(m) {
        case let .dumpHeader(h)?:
            cond.lock(); header = h; cond.signal(); cond.unlock(); return true
        case .dataPacket?:
            cond.lock(); packetsSeen += 1; cond.unlock(); return true
        default:
            return false
        }
    }

    /// Scans the given SDS sample numbers in order. Blocking; run on a worker thread.
    /// `progress` gets each slot's result (nil = empty / no answer) as it is read.
    public func scan(_ numbers: [Int], isCancelled: () -> Bool = { false },
                     progress: ((Int, SlotInfo?) -> Void)? = nil) -> [SlotInfo] {
        var results: [Int: SlotInfo] = [:]
        var pending = numbers
        for attempt in 0...max(0, options.retries) {
            let last = attempt == options.retries
            let got = scanOnce(pending, isCancelled: isCancelled) { n, info in
                if let info, info.isPlausible { results[n] = info; progress?(n, info) }
                else if last { progress?(n, info?.isPlausible == false ? nil : nil) }
            }
            _ = got
            pending = pending.filter { results[$0] == nil }
            if pending.isEmpty || isCancelled() { break }
        }
        return numbers.compactMap { results[$0] }
    }

    private func scanOnce(_ numbers: [Int], isCancelled: () -> Bool,
                          progress: ((Int, SlotInfo?) -> Void)?) -> [SlotInfo] {
        var found: [SlotInfo] = []
        let dev = options.deviceNumber & 0x7F
        for n in numbers {
            if isCancelled() { break }
            cond.lock(); header = nil; name = nil; packetsSeen = 0; cond.unlock()
            transport.send(SDSMessage.dumpRequest(device: dev, sampleNumber: n).bytes())
            // Wait for the header.
            let deadline = Date().addingTimeInterval(options.headerTimeout)
            cond.lock()
            while header == nil && Date() < deadline { _ = cond.wait(until: deadline) }
            let h = header
            cond.unlock()
            guard let h else { progress?(n, nil); continue }
            if h.sampleNumber != n {
                // Answered with another sample: stop that dump too, and report what came back.
                transport.send(SDSMessage.cancel(device: dev, packet: 0).bytes())
                mismatches.append((requested: n, got: h.sampleNumber))
                Thread.sleep(forTimeInterval: options.settle)
                progress?(n, nil)
                continue
            }
            // The Machinedrum sends its name message right after the header.
            let nameDeadline = Date().addingTimeInterval(options.nameWait)
            cond.lock()
            while name == nil && Date() < nameDeadline { _ = cond.wait(until: nameDeadline) }
            let nm = name
            cond.unlock()
            // Stop the dump: the device is waiting on the header (packet 0).
            transport.send(SDSMessage.cancel(device: dev, packet: 0).bytes())
            Thread.sleep(forTimeInterval: options.settle)
            let info = SlotInfo(sampleNumber: n, name: nm?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                                length: h.length, bits: h.bits, sampleRate: SDSSample.rate(forPeriod: h.samplePeriodNs),
                                loopStart: h.loopStart, loopEnd: h.loopEnd, loopType: h.loopType)
            found.append(info)
            progress?(n, info)
        }
        return found
    }

    /// Requests answered with a different sample number (diagnostics).
    public private(set) var mismatches: [(requested: Int, got: Int)] = []

    /// Data packets that arrived since the last request (non-zero = the device ignored CANCEL).
    public var packetsSinceRequest: Int { cond.lock(); defer { cond.unlock() }; return packetsSeen }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
