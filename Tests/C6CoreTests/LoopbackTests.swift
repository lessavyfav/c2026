@testable import C6Core
import CoreMIDI
import Foundation
import Testing

/// Exercises the real CoreMIDI receive path with virtual endpoints (no hardware needed).
@Suite(.serialized) struct LoopbackTests {
    /// A virtual source pushes one large event list (one timestamp, hundreds of words, as a fast
    /// USB burst does); every byte must come out the other side. Regression test for packets
    /// with more than 64 words being truncated.
    @Test func largeBurstIsReceivedIntact() throws {
        let system = try CoreMIDISystem(clientName: "C6 test")
        var src = MIDIEndpointRef(), dst = MIDIEndpointRef()
        #expect(MIDISourceCreateWithProtocol(system.client, "C6 test source" as CFString, ._1_0, &src) == noErr)
        #expect(MIDIDestinationCreateWithProtocol(system.client, "C6 test sink" as CFString, ._1_0, &dst) { _, _ in } == noErr)
        defer { MIDIEndpointDispose(src); MIDIEndpointDispose(dst) }

        let conn = try CoreMIDIConnection(client: system.client, source: src, destination: dst)
        defer { conn.close() }
        let lock = NSLock()
        var received: [[UInt8]] = []
        let done = DispatchSemaphore(value: 0)
        let messages: [[UInt8]] = (0..<3).map { n in
            [0xF0, 0x00, 0x20, 0x3C, 0x02, 0x00, 0x52] + (0..<1226).map { UInt8(($0 + n) % 128) } + [0xF7]
        }
        conn.onReceive = { msg in
            lock.lock(); received.append(msg); let c = received.count; lock.unlock()
            if c == messages.count { done.signal() }
        }

        // All three messages in a single event list with one timestamp.
        var words: [UInt32] = []
        for m in messages { words += UMP.sysEx7Words(payload: m[1..<(m.count - 1)]) }
        let capacity = 64 * 1024
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet = MIDIEventListInit(list, ._1_0)
        var i = 0
        words.withUnsafeBufferPointer { wp in
            while i < wp.count { packet = MIDIEventListAdd(list, capacity, packet, 0, 2, wp.baseAddress! + i); i += 2 }
        }
        #expect(MIDIReceivedEventList(src, list) == noErr)

        #expect(done.wait(timeout: .now() + 5) == .success)
        lock.lock(); defer { lock.unlock() }
        #expect(received == messages)
    }

    /// A TurboMIDI link carries Active Sensing (FE) keep-alives, which can land in the middle of a
    /// SysEx dump. That is legal MIDI 1.0; the receiver must drop the FE and keep the dump intact.
    /// Returns what each input mode delivered.
    func receiveWithInterleavedRealtime(mode: CoreMIDIConnection.InputMode) throws -> [[UInt8]] {
        let system = try CoreMIDISystem(clientName: "C6 test")
        var src = MIDIEndpointRef(), dst = MIDIEndpointRef()
        #expect(MIDISourceCreate(system.client, "C6 test bytes source" as CFString, &src) == noErr)
        #expect(MIDIDestinationCreateWithProtocol(system.client, "C6 test sink" as CFString, ._1_0, &dst) { _, _ in } == noErr)
        defer { MIDIEndpointDispose(src); MIDIEndpointDispose(dst) }
        let conn = try CoreMIDIConnection(client: system.client, source: src, destination: dst, inputMode: mode)
        defer { conn.close() }
        let lock = NSLock()
        var received: [[UInt8]] = []
        conn.onReceive = { lock.lock(); received.append($0); lock.unlock() }

        let kit: [UInt8] = [0xF0, 0x00, 0x20, 0x3C, 0x02, 0x00, 0x52] + (0..<1225).map { UInt8($0 % 128) } + [0xF7]
        // Deliver as the USB driver would: 3-byte chunks in separate packets, with an FE
        // keep-alive arriving between two of them.
        var chunks: [[UInt8]] = stride(from: 0, to: kit.count, by: 3).map { Array(kit[$0..<min(kit.count, $0 + 3)]) }
        chunks.insert([0xFE], at: 200)
        let capacity = 64 * 1024
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var packet = MIDIPacketListInit(list)
        for (n, c) in chunks.enumerated() { packet = MIDIPacketListAdd(list, capacity, packet, UInt64(n + 1), c.count, c) }
        #expect(MIDIReceived(src, list) == noErr)
        Thread.sleep(forTimeInterval: 0.5)
        lock.lock(); defer { lock.unlock() }
        return received
    }

    @Test func realtimeInsideSysExKeepsDumpIntact() throws {
        let kit: [UInt8] = [0xF0, 0x00, 0x20, 0x3C, 0x02, 0x00, 0x52] + (0..<1225).map { UInt8($0 % 128) } + [0xF7]
        #expect(try receiveWithInterleavedRealtime(mode: .bytes) == [kit])
    }

    /// Documents how CoreMIDI's own MIDI 1.0 -> UMP conversion treats the same stream.
    @Test func umpConversionWithInterleavedRealtime() throws {
        let got = try receiveWithInterleavedRealtime(mode: .ump)
        print("UMP mode delivered \(got.count) message(s) of sizes \(got.map(\.count))")
    }
}
