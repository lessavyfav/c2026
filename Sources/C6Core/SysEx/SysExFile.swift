import Foundation

/// A SysEx file (`.syx`): raw MIDI bytes, usually a concatenation of `F0 … F7` messages.
public struct SysExData: Equatable, Sendable {
    public var messages: [[UInt8]]

    public init(messages: [[UInt8]]) { self.messages = messages }

    /// Parses any MIDI 1.0 byte stream; bytes outside SysEx and realtime bytes are dropped.
    public init(bytes: some Sequence<UInt8>) {
        var parser = MIDI1StreamParser()
        var msgs: [[UInt8]] = []
        parser.feed(bytes) { msgs.append($0) }
        messages = msgs
    }

    public init(contentsOf url: URL) throws {
        self.init(bytes: try Data(contentsOf: url))
    }

    public var bytes: [UInt8] { messages.flatMap { $0 } }
    public var byteCount: Int { messages.reduce(0) { $0 + $1.count } }

    public func write(to url: URL) throws {
        try Data(bytes).write(to: url, options: .atomic)
    }
}
