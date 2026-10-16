import Foundation

/// The boundary between C6's protocol logic and the MIDI system.
///
/// Protocol engines (TurboMIDI, SDS, SysEx transfers) only talk to this protocol,
/// so they can run against CoreMIDI, a virtual loopback, or a scripted test device.
public protocol MIDITransport: AnyObject {
    /// Sends a fragment of a MIDI 1.0 byte stream, optionally scheduled for a host time
    /// (`HostTime`); `nil` means now. A SysEx message may be split across calls,
    /// which is how paced transfers stream large dumps.
    func sendStream(_ bytes: ArraySlice<UInt8>, at hostTime: UInt64?)

    /// Drops anything scheduled but not yet sent and closes an interrupted SysEx (used by Stop).
    func flushScheduled()

    /// Called on an arbitrary thread for each complete incoming MIDI 1.0 message.
    /// Realtime messages (clock, active sensing) are not delivered.
    var onReceive: (([UInt8]) -> Void)? { get set }
}

public extension MIDITransport {
    /// Sends one complete MIDI 1.0 message (SysEx `F0 … F7` or a short message).
    func send(_ message: [UInt8], at hostTime: UInt64? = nil) { sendStream(message[...], at: hostTime) }
}

/// Fans one incoming stream out to several listeners (UI log, TM-1 controller, receiver…).
public final class MessageBus {
    private let lock = NSLock()
    private var listeners: [UUID: ([UInt8]) -> Void] = [:]

    public init() {}

    @discardableResult
    public func subscribe(_ handler: @escaping ([UInt8]) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); listeners[id] = handler; lock.unlock()
        return id
    }

    public func unsubscribe(_ id: UUID) {
        lock.lock(); listeners[id] = nil; lock.unlock()
    }

    public func publish(_ message: [UInt8]) {
        lock.lock(); let handlers = Array(listeners.values); lock.unlock()
        for h in handlers { h(message) }
    }
}
