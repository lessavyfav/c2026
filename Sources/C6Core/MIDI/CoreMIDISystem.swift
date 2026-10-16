import CoreMIDI
import Foundation

public struct MIDIEndpointInfo: Hashable, Identifiable, Sendable {
    public enum Direction: Sendable { case source, destination }
    public let uniqueID: Int32
    public let direction: Direction
    public let name: String
    public let displayName: String
    public let manufacturer: String
    public let deviceName: String
    public let isOffline: Bool
    public var id: String { "\(direction == .source ? "in" : "out"):\(uniqueID)" }

    /// The Elektron TM-1 shows up as "Elektron TM-1" (USB VID 0x1935, PID 0x0001, Apple's class driver).
    public var isTM1: Bool { displayName.localizedCaseInsensitiveContains("TM-1") || deviceName.localizedCaseInsensitiveContains("TM-1") }
}

/// Owns the CoreMIDI client, tracks endpoints (hot-plug), and opens connections.
public final class CoreMIDISystem {
    public private(set) var client = MIDIClientRef()
    private let lock = NSLock()
    private var _sources: [MIDIEndpointInfo] = []
    private var _destinations: [MIDIEndpointInfo] = []
    private var changeHandlers: [UUID: () -> Void] = [:]

    public var sources: [MIDIEndpointInfo] { lock.lock(); defer { lock.unlock() }; return _sources }
    public var destinations: [MIDIEndpointInfo] { lock.lock(); defer { lock.unlock() }; return _destinations }

    public init(clientName: String = "C6") throws {
        let status = MIDIClientCreateWithBlock(clientName as CFString, &client) { [weak self] notification in
            switch notification.pointee.messageID {
            case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged:
                self?.refresh()
            default: break
            }
        }
        guard status == noErr else { throw MIDIError.osStatus(status, "MIDIClientCreate") }
        refresh()
    }

    deinit { MIDIClientDispose(client) }

    @discardableResult
    public func onChange(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock(); changeHandlers[id] = handler; lock.unlock()
        return id
    }

    public func refresh() {
        let src = (0..<MIDIGetNumberOfSources()).map { Self.info(MIDIGetSource($0), .source) }
        let dst = (0..<MIDIGetNumberOfDestinations()).map { Self.info(MIDIGetDestination($0), .destination) }
        lock.lock()
        _sources = src; _destinations = dst
        let handlers = Array(changeHandlers.values)
        lock.unlock()
        handlers.forEach { $0() }
    }

    public func endpointRef(for info: MIDIEndpointInfo) -> MIDIEndpointRef? {
        var obj = MIDIObjectRef(), type = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(info.uniqueID, &obj, &type) == noErr else { return nil }
        return MIDIEndpointRef(obj)
    }

    public func connect(source: MIDIEndpointInfo, destination: MIDIEndpointInfo,
                        inputMode: CoreMIDIConnection.InputMode = .bytes) throws -> CoreMIDIConnection {
        guard let src = endpointRef(for: source) else { throw MIDIError.endpointMissing(source.displayName) }
        guard let dst = endpointRef(for: destination) else { throw MIDIError.endpointMissing(destination.displayName) }
        return try CoreMIDIConnection(client: client, source: src, destination: dst, inputMode: inputMode)
    }

    static func info(_ e: MIDIEndpointRef, _ dir: MIDIEndpointInfo.Direction) -> MIDIEndpointInfo {
        var entity = MIDIEntityRef(), device = MIDIDeviceRef()
        MIDIEndpointGetEntity(e, &entity)
        if entity != 0 { MIDIEntityGetDevice(entity, &device) }
        return MIDIEndpointInfo(
            uniqueID: intProp(e, kMIDIPropertyUniqueID) ?? 0,
            direction: dir,
            name: stringProp(e, kMIDIPropertyName) ?? "",
            displayName: stringProp(e, kMIDIPropertyDisplayName) ?? stringProp(e, kMIDIPropertyName) ?? "Unknown",
            manufacturer: stringProp(e, kMIDIPropertyManufacturer) ?? (device != 0 ? stringProp(device, kMIDIPropertyManufacturer) : nil) ?? "",
            deviceName: device != 0 ? (stringProp(device, kMIDIPropertyName) ?? "") : "",
            isOffline: (intProp(e, kMIDIPropertyOffline) ?? 0) != 0
        )
    }

    static func stringProp(_ o: MIDIObjectRef, _ p: CFString) -> String? {
        var s: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(o, p, &s) == noErr, let v = s else { return nil }
        return v.takeRetainedValue() as String
    }

    static func intProp(_ o: MIDIObjectRef, _ p: CFString) -> Int32? {
        var v: Int32 = 0
        return MIDIObjectGetIntegerProperty(o, p, &v) == noErr ? v : nil
    }
}

public enum MIDIError: Error, CustomStringConvertible {
    case osStatus(OSStatus, String)
    case endpointMissing(String)
    public var description: String {
        switch self {
        case let .osStatus(s, call): return "\(call) failed (OSStatus \(s))"
        case let .endpointMissing(n): return "MIDI port “\(n)” is not available"
        }
    }
}

/// A bidirectional connection to one source + one destination, speaking MIDI 1.0 bytes.
/// Output goes through CoreMIDI's UMP (MIDI 1.0 protocol) API. Input can use either the UMP
/// API or the legacy byte-stream API (see `InputMode`).
public final class CoreMIDIConnection: MIDITransport {
    public enum InputMode: String, CaseIterable, Sendable {
        /// MIDIPacketList byte stream, parsed by C6 itself (realtime bytes inside SysEx are skipped,
        /// as the original C6 did).
        case bytes
        /// MIDIEventList (UMP) as converted by CoreMIDI.
        case ump
    }

    public var onReceive: (([UInt8]) -> Void)?
    /// Diagnostics: raw packets as delivered by CoreMIDI (UMP words or MIDI 1.0 bytes), before parsing.
    public var onRawUMP: ((UInt64, UnsafeBufferPointer<UInt32>) -> Void)?
    public var onRawBytes: ((UInt64, UnsafeBufferPointer<UInt8>) -> Void)?
    public let destination: MIDIEndpointRef
    public let inputMode: InputMode
    private let source: MIDIEndpointRef
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var decoder = UMPToMIDI1Decoder()
    private var byteParser = MIDI1StreamParser(repairSplitSysEx: true)
    private let parseLock = NSLock()
    private let flushQueue = DispatchQueue(label: "c6.midi.flush")
    private var flushItem: DispatchWorkItem?
    /// How long a completed SysEx is held back to see whether a spurious F7 split it (see
    /// `MIDI1StreamParser.repairSplitSysEx`). The continuation arrives in the next USB packet.
    public var splitRepairWindow: Double = 0.03
    /// Number of SysEx messages that were re-joined after a spurious F7.
    public var repairedSplits: Int { parseLock.lock(); defer { parseLock.unlock() }; return byteParser.repairedCount }
    private let sendLock = NSLock()
    private var encoder = MIDI1ToUMPEncoder()

    init(client: MIDIClientRef, source: MIDIEndpointRef, destination: MIDIEndpointRef, inputMode: InputMode = .bytes) throws {
        self.source = source
        self.destination = destination
        self.inputMode = inputMode
        var st: OSStatus
        switch inputMode {
        case .ump:
            st = MIDIInputPortCreateWithProtocol(client, "C6 In" as CFString, ._1_0, &inPort) { [weak self] list, _ in
                self?.handle(list)
            }
        case .bytes:
            st = MIDIInputPortCreateWithBlock(client, "C6 In" as CFString, &inPort) { [weak self] list, _ in
                self?.handle(list)
            }
        }
        guard st == noErr else { throw MIDIError.osStatus(st, "MIDIInputPortCreate") }
        st = MIDIOutputPortCreate(client, "C6 Out" as CFString, &outPort)
        guard st == noErr else { throw MIDIError.osStatus(st, "MIDIOutputPortCreate") }
        st = MIDIPortConnectSource(inPort, source, nil)
        guard st == noErr else { throw MIDIError.osStatus(st, "MIDIPortConnectSource") }
    }

    deinit { close() }

    public func close() {
        if inPort != 0 { MIDIPortDisconnectSource(inPort, source); MIDIPortDispose(inPort); inPort = 0 }
        if outPort != 0 { MIDIPortDispose(outPort); outPort = 0 }
    }

    private static let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!

    private func handle(_ list: UnsafePointer<MIDIEventList>) {
        for packet in list.unsafeSequence() {
            // MIDIEventPacket is variable-length: `words` is declared as 64 words, but a burst of
            // SysEx sharing one timestamp can carry more. Read wordCount words in place — copying
            // the struct (or clamping to 64) silently drops the rest of fast dumps.
            let count = Int(packet.pointee.wordCount)
            let base = (UnsafeRawPointer(packet) + Self.wordsOffset).assumingMemoryBound(to: UInt32.self)
            onRawUMP?(packet.pointee.timeStamp, UnsafeBufferPointer(start: base, count: count))
            decoder.decode(UnsafeBufferPointer(start: base, count: count)) { msg in
                if msg.count == 1, msg[0] >= 0xF8 { return } // drop realtime (clock, active sensing…)
                onReceive?(msg)
            }
        }
    }

    private static let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!

    private func handle(_ list: UnsafePointer<MIDIPacketList>) {
        var out: [[UInt8]] = []
        parseLock.lock()
        for packet in list.unsafeSequence() {
            // Like MIDIEventPacket, MIDIPacket is variable-length (SysEx packets exceed 256 bytes).
            let base = (UnsafeRawPointer(packet) + Self.dataOffset).assumingMemoryBound(to: UInt8.self)
            let bytes = UnsafeBufferPointer(start: base, count: Int(packet.pointee.length))
            onRawBytes?(packet.pointee.timeStamp, bytes)
            byteParser.feed(bytes) { out.append($0) }
        }
        let holding = byteParser.hasPending
        parseLock.unlock()
        out.forEach { onReceive?($0) }
        scheduleFlush(holding)
    }

    /// Releases a held-back SysEx once no continuation arrived within `splitRepairWindow`.
    private func scheduleFlush(_ holding: Bool) {
        flushQueue.async { [weak self] in
            guard let self else { return }
            self.flushItem?.cancel(); self.flushItem = nil
            guard holding else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                var out: [[UInt8]] = []
                self.parseLock.lock(); self.byteParser.flush { out.append($0) }; self.parseLock.unlock()
                out.forEach { self.onReceive?($0) }
            }
            self.flushItem = item
            self.flushQueue.asyncAfter(deadline: .now() + self.splitRepairWindow, execute: item)
        }
    }

    public func sendStream(_ bytes: ArraySlice<UInt8>, at hostTime: UInt64?) {
        sendLock.lock(); defer { sendLock.unlock() }
        let words = encoder.encode(bytes)
        guard !words.isEmpty else { return }
        transmit(words, at: hostTime ?? 0)
    }

    public func flushScheduled() {
        MIDIFlushOutput(destination)
        sendLock.lock()
        if encoder.inSysEx { transmit(encoder.encode([0xF7][...]), at: 0) } // close an interrupted SysEx cleanly
        sendLock.unlock()
    }

    private func transmit(_ words: [UInt32], at time: MIDITimeStamp) {
        // MIDIEventListAdd is imported as non-optional, so never let it run out of room: budget the
        // worst case (every event in its own packet: 8-byte timestamp + 4-byte count + words) and
        // send the list whenever the next event might not fit.
        let capacity = 16 * 1024
        let listHeader = 8, packetHeader = 12
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        words.withUnsafeBufferPointer { wp in
            var i = 0
            while i < wp.count {
                var packet = MIDIEventListInit(list, ._1_0)
                var budget = listHeader
                while i < wp.count {
                    let n = min(UMP.wordCount(wp[i]), wp.count - i)
                    let cost = packetHeader + 4 * n
                    if budget + cost > capacity { break }
                    packet = MIDIEventListAdd(list, capacity, packet, time, n, wp.baseAddress! + i)
                    budget += cost; i += n
                }
                MIDISendEventList(outPort, destination, list)
            }
        }
    }
}

/// Incremental MIDI 1.0 -> UMP encoder that tolerates SysEx split across fragments.
struct MIDI1ToUMPEncoder {
    private(set) var inSysEx = false
    private var pending: [UInt8] = []   // up to 6 SysEx data bytes not yet packetized
    private var startedPacket = false   // whether a "start" packet was already emitted for this SysEx

    mutating func encode(_ bytes: ArraySlice<UInt8>) -> [UInt32] {
        var out: [UInt32] = []
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let b = bytes[i]
            if b == 0xF0 {
                if inSysEx { out += finishSysEx() }
                inSysEx = true; startedPacket = false; pending.removeAll(keepingCapacity: true)
            } else if b == 0xF7 {
                if inSysEx { out += finishSysEx() }
            } else if inSysEx && b < 0x80 {
                if pending.count == 6 {
                    out += UMP.sysEx7Packet(status: startedPacket ? .continue : .start, bytes: pending[...])
                    startedPacket = true; pending.removeAll(keepingCapacity: true)
                }
                pending.append(b)
            } else if b >= 0x80 {
                if inSysEx { out += finishSysEx() }
                // Short message: gather status + data bytes.
                let len = Self.shortLength(b)
                let end = min(bytes.endIndex, i + len)
                let msg = Array(bytes[i..<end])
                if msg.count == len { out += Self.shortUMP(msg) }
                i = end
                continue
            }
            i += 1
        }
        return out
    }

    private mutating func finishSysEx() -> [UInt32] {
        let words = UMP.sysEx7Packet(status: startedPacket ? .end : .complete, bytes: pending[...])
        inSysEx = false; startedPacket = false; pending.removeAll(keepingCapacity: true)
        return words
    }

    static func shortLength(_ status: UInt8) -> Int {
        switch status {
        case 0x80...0xBF, 0xE0...0xEF, 0xF2: return 3
        case 0xC0...0xDF, 0xF1, 0xF3: return 2
        default: return 1
        }
    }

    static func shortUMP(_ msg: [UInt8]) -> [UInt32] {
        let type: UInt32 = msg[0] >= 0xF0 ? 0x1 : 0x2
        let d1 = msg.count > 1 ? UInt32(msg[1]) : 0, d2 = msg.count > 2 ? UInt32(msg[2]) : 0
        return [(type << 28) | (UInt32(msg[0]) << 16) | (d1 << 8) | d2]
    }
}
