import Foundation

/// Elektron constants shared by every protocol.
public enum Elektron {
    public static let manufacturerID: [UInt8] = [0x00, 0x20, 0x3C]
    /// Device byte that follows the manufacturer ID in Elektron SysEx.
    public static let tm1DeviceID: UInt8 = 0x04
    /// MIDI 1.0 line speed in bytes/second (31250 baud, 10 bits per byte).
    public static let baseBytesPerSecond: Double = 3125
}

/// TurboMIDI speed codes as used by the TM-1 and C6.
///
/// Recovered from C6 1.51 (Mac: multiplier table at 0x119e0, labels at 0x123a0). C6 stored the
/// multipliers in tenths (33, 66, 133); the true TurboMIDI rates are 10/3, 20/3 and 40/3.
public enum TurboSpeed: UInt8, CaseIterable, Comparable, Sendable {
    case x1 = 1, x2, x3_3, x4, x5, x6_7, x8, x10, x13_3, x16, x20

    public init?(code: UInt8) {
        if code == 0 { self = .x1; return } // C6 treated 0 like 1 (both labelled 1x)
        self.init(rawValue: code)
    }

    public var multiplier: Double {
        switch self {
        case .x1: return 1
        case .x2: return 2
        case .x3_3: return 10.0 / 3
        case .x4: return 4
        case .x5: return 5
        case .x6_7: return 20.0 / 3
        case .x8: return 8
        case .x10: return 10
        case .x13_3: return 40.0 / 3
        case .x16: return 16
        case .x20: return 20
        }
    }

    public var label: String {
        switch self {
        case .x1: return "1×"
        case .x2: return "2×"
        case .x3_3: return "3.3×"
        case .x4: return "4×"
        case .x5: return "5×"
        case .x6_7: return "6.7×"
        case .x8: return "8×"
        case .x10: return "10×"
        case .x13_3: return "13.3×"
        case .x16: return "16×"
        case .x20: return "20×"
        }
    }

    public var baud: Int { Int((31250 * multiplier).rounded()) }
    public var bytesPerSecond: Double { Elektron.baseBytesPerSecond * multiplier }

    public static func < (a: TurboSpeed, b: TurboSpeed) -> Bool { a.rawValue < b.rawValue }
}

/// TM-1 control messages (recovered from C6 1.51 and confirmed against a real TM-1).
public enum TM1Message {
    static let header: [UInt8] = [0xF0] + Elektron.manufacturerID + [Elektron.tm1DeviceID, 0x00]

    /// `F0 00 20 3C 04 00 01 F7` — ask the TM-1 for its current TurboMIDI speed.
    public static let statusRequest: [UInt8] = header + [0x01, 0xF7]

    /// `F0 00 20 3C 04 00 03 <code> F7` — ask the TM-1 to negotiate `speed` with the connected device.
    public static func setSpeed(_ speed: TurboSpeed) -> [UInt8] { header + [0x03, speed.rawValue, 0xF7] }

    /// Parses `F0 00 20 3C 04 00 02 <code> … F7` (the TM-1's status reply).
    public static func parseStatus(_ msg: [UInt8]) -> TurboSpeed? {
        guard msg.count >= 9, Array(msg.prefix(7)) == header + [0x02] else { return nil }
        return TurboSpeed(code: msg[7])
    }
}

/// Talks to a TM-1: reads and changes the TurboMIDI speed.
///
/// C6 behaviour being reproduced: query at startup; the Turbo button requests the configured
/// limit (default 20×) when at 1×, or 1× when turbo is on; the TM-1 negotiates with the device
/// behind it and answers with a status message carrying the speed actually in effect.
public final class TM1Controller {
    private let transport: MIDITransport
    private let lock = NSLock()
    private var waiters: [(TurboSpeed) -> Void] = []
    private var _speed: TurboSpeed = .x1
    private var _seen = false

    /// Called (on the MIDI thread) whenever the TM-1 reports a speed.
    public var onStatus: ((TurboSpeed) -> Void)?

    /// Last speed the TM-1 reported (1× until it answers).
    public var speed: TurboSpeed { lock.lock(); defer { lock.unlock() }; return _speed }
    /// Whether a TM-1 has answered on this connection.
    public var isPresent: Bool { lock.lock(); defer { lock.unlock() }; return _seen }

    public init(transport: MIDITransport) { self.transport = transport }

    /// Feed every incoming message here (returns true if it was a TM-1 status message).
    @discardableResult
    public func handle(_ msg: [UInt8]) -> Bool {
        guard let s = TM1Message.parseStatus(msg) else { return false }
        lock.lock()
        _speed = s; _seen = true
        let w = waiters; waiters.removeAll()
        lock.unlock()
        w.forEach { $0(s) }
        onStatus?(s)
        return true
    }

    /// Asks for the current speed and waits for the answer. Returns nil if nothing answered
    /// (no TM-1 on this port).
    public func queryStatus(timeout: Double = 0.5) -> TurboSpeed? {
        exchange(TM1Message.statusRequest, timeout: timeout)
    }

    /// Requests `speed`; returns the speed the TM-1 reports afterwards (which can be lower if the
    /// device behind it supports less), or nil on timeout.
    public func setSpeed(_ speed: TurboSpeed, timeout: Double = 3.0) -> TurboSpeed? {
        exchange(TM1Message.setSpeed(speed), timeout: timeout)
    }

    private func exchange(_ msg: [UInt8], timeout: Double) -> TurboSpeed? {
        let sem = DispatchSemaphore(value: 0)
        var result: TurboSpeed?
        lock.lock(); waiters.append { s in result = s; sem.signal() }; lock.unlock()
        transport.send(msg)
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); waiters.removeAll(); lock.unlock()
            return nil
        }
        return result
    }
}
