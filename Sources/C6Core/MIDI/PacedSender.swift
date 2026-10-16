import Foundation

/// Streams bytes to a transport at a precise byte rate using timestamped scheduling.
///
/// The original C6 relied on CoreMIDI's `kMIDIPropertyMaxSysExSpeed` pacing (a driver-owned,
/// system-wide property it overwrote) and on 1/60 s `Delay()` ticks between SDS packets.
/// Here the app paces itself: each fragment is scheduled at
/// `start + bytesSoFar / bytesPerSecond`, a short lookahead ahead of real time,
/// so the line runs at its real speed without touching driver settings.
public struct PacedSender {
    public struct Options {
        /// Line speed in bytes per second (3125 = MIDI 1.0; TurboMIDI multiplies this).
        public var bytesPerSecond: Double
        /// How far ahead of real time fragments are handed to CoreMIDI.
        public var lookahead: Double = 0.020
        /// Fragment duration; fragments are rounded to whole 6-byte SysEx7 packets.
        public var fragmentDuration: Double = 0.002

        public init(bytesPerSecond: Double) { self.bytesPerSecond = bytesPerSecond }
    }

    public enum Result: Equatable { case completed, cancelled }

    public let transport: MIDITransport
    public var options: Options

    public init(transport: MIDITransport, options: Options) {
        self.transport = transport
        self.options = options
    }

    /// Time the bytes occupy on the wire at the configured speed.
    public func duration(ofBytes n: Int) -> Double { Double(n) / options.bytesPerSecond }

    /// Sends `bytes` (any MIDI 1.0 stream: one SysEx, many, or a fragment) and blocks
    /// until the last byte's scheduled time has passed. Call from a worker thread.
    ///
    /// - Parameters:
    ///   - startAt: host time for the first byte; defaults to "now + lookahead".
    ///   - progress: called with the number of bytes whose send time has been reached.
    ///   - isCancelled: polled between fragments; on cancel, scheduled output is flushed.
    /// - Returns: `.completed`, or `.cancelled`; plus the host time at which the last byte ends.
    @discardableResult
    public func send(_ bytes: ArraySlice<UInt8>,
                     startAt: UInt64? = nil,
                     progress: ((Int) -> Void)? = nil,
                     isCancelled: () -> Bool = { false }) -> (Result, UInt64) {
        let rate = max(1, options.bytesPerSecond)
        let fragment = max(6, Int((rate * options.fragmentDuration / 6).rounded(.up)) * 6)
        let lookaheadTicks = HostTime.ticks(fromSeconds: options.lookahead)
        let t0 = startAt ?? (HostTime.now + lookaheadTicks)
        var offset = 0
        var lastReported = 0
        let total = bytes.count
        while offset < total {
            if isCancelled() { transport.flushScheduled(); return (.cancelled, HostTime.now) }
            let deadline = t0 + HostTime.ticks(fromSeconds: Double(offset) / rate)
            if deadline > lookaheadTicks { HostTime.wait(until: deadline - lookaheadTicks) }
            let end = min(total, offset + fragment)
            let lo = bytes.startIndex + offset
            transport.sendStream(bytes[lo..<(bytes.startIndex + end)], at: deadline)
            // Bytes up to `offset` have now reached their scheduled time (minus the lookahead).
            if let progress, offset - lastReported >= fragment * 8 || end == total { progress(offset); lastReported = offset }
            offset = end
        }
        let finish = t0 + HostTime.ticks(fromSeconds: Double(total) / rate)
        // Wait until the tail is really out, polling cancel so Stop stays responsive.
        while HostTime.now < finish {
            if isCancelled() { transport.flushScheduled(); return (.cancelled, HostTime.now) }
            HostTime.wait(until: min(finish, HostTime.now + HostTime.ticks(fromSeconds: 0.01)))
        }
        progress?(total)
        return (.completed, finish)
    }
}
