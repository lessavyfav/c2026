import Foundation

/// Collects incoming SysEx for the Receive button.
///
/// C6 required pressing Stop when a dump was complete. This receiver can also finish by itself
/// once the line has been quiet for `idleTimeout` after data started arriving.
public final class SysExReceiver {
    public struct Status: Sendable {
        public var messageCount: Int
        public var byteCount: Int
        public var lastActivity: UInt64?
    }

    private let lock = NSLock()
    private var messages: [[UInt8]] = []
    private var bytes = 0
    private var lastActivity: UInt64?
    private var firstActivity: UInt64?
    private var finished = false
    private let done = DispatchSemaphore(value: 0)

    /// Messages for which this returns false are ignored (e.g. TM-1 status replies).
    public var filter: ([UInt8]) -> Bool = { TM1Message.parseStatus($0) == nil }
    /// Called (on the MIDI thread) after each accepted message.
    public var onMessage: (([UInt8], Status) -> Void)?

    public init() {}

    public func handle(_ msg: [UInt8]) {
        guard msg.first == 0xF0, filter(msg) else { return }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        messages.append(msg); bytes += msg.count
        let now = HostTime.now
        lastActivity = now; if firstActivity == nil { firstActivity = now }
        let s = Status(messageCount: messages.count, byteCount: bytes, lastActivity: now)
        lock.unlock()
        onMessage?(msg, s)
    }

    /// Counts traffic handled elsewhere (e.g. sample-dump packets) towards activity and the byte
    /// count, so the idle timeout doesn't fire in the middle of a sample dump.
    public func noteActivity(bytes n: Int) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        bytes += n
        let now = HostTime.now
        lastActivity = now; if firstActivity == nil { firstActivity = now }
        let s = Status(messageCount: messages.count, byteCount: bytes, lastActivity: now)
        lock.unlock()
        onMessage?([], s)
    }

    public var status: Status {
        lock.lock(); defer { lock.unlock() }
        return Status(messageCount: messages.count, byteCount: bytes, lastActivity: lastActivity)
    }

    /// Seconds between the first and the last received message.
    public var activeDuration: Double {
        lock.lock(); defer { lock.unlock() }
        guard let a = firstActivity, let b = lastActivity else { return 0 }
        return HostTime.seconds(fromTicks: b - a)
    }

    /// Stops receiving and returns everything collected.
    @discardableResult
    public func finish() -> SysExData {
        lock.lock(); finished = true; let m = messages; lock.unlock()
        done.signal()
        return SysExData(messages: m)
    }

    /// Blocks until data has arrived and then the line was idle for `idleTimeout` seconds,
    /// `finish()` was called, or `overallTimeout` elapsed. Returns the collected data.
    public func waitUntilIdle(idleTimeout: Double, overallTimeout: Double? = nil, shouldStop: () -> Bool = { false }) -> SysExData {
        let start = HostTime.now
        while true {
            if done.wait(timeout: .now() + 0.05) == .success { break }
            if shouldStop() { break }
            let now = HostTime.now
            if let t = overallTimeout, HostTime.seconds(fromTicks: now - start) > t { break }
            lock.lock(); let last = lastActivity; lock.unlock()
            if let last, HostTime.seconds(fromTicks: now - last) > idleTimeout { break }
        }
        return finish()
    }
}
