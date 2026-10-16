import Foundation

/// One row of C6's data browser: a loaded file or something received.
///
/// Like the original, an item holds the file's raw bytes; its Type column and File Info text
/// come from content recognition (`SysExRecognizer`), never from the file extension.
public struct C6Item: Identifiable, Equatable, Sendable {
    public enum LoopMode: String, CaseIterable, Codable, Sendable { case file = "Loop: File", on = "Loop: On", off = "Loop: Off" }
    public enum StereoMode: String, CaseIterable, Codable, Sendable { case mix = "L + R", left = "Left", right = "Right" }
    public enum Status: Equatable, Sendable { case idle, queued, sending(Double), sent, failed(String), cancelled, skipped(String) }

    public let id: UUID
    public var name: String
    /// Where the item lives on disk; nil for received data that hasn't been saved yet.
    public var url: URL?
    public private(set) var bytes: [UInt8]
    public private(set) var type: RecognizedType
    public private(set) var info: String
    /// Frames this item takes on a device as a sample at its own rate (nil if it isn't one).
    public private(set) var sampleFrames: Int?
    /// The item's own sample rate, for samples.
    public private(set) var sampleRate: Int?
    /// Send at 22.05 kHz instead of the file's rate (half the memory on a 44.1 kHz file).
    public var halfRate = false
    /// Send at double speed: half the frames, original rate in the header — the device plays it an
    /// octave up until its pitch is set an octave down — PTCH −36 on a Machinedrum (half the memory; combines with `halfRate`).
    public var doubleSpeed = false
    public var loopMode: LoopMode = .file
    public var stereoMode: StereoMode = .mix
    public var status: Status = .idle
    /// Machinedrum name typed by the user for this sample (sent with it); nil = automatic.
    public var mdName: String?

    /// Supplies File Info text for audio files (set by the app once the audio module is linked).
    nonisolated(unsafe) public static var audioDescriber: (AudioFormat, [UInt8]) -> String = { _, _ in "" }

    public init(id: UUID = UUID(), name: String, url: URL? = nil, bytes: [UInt8]) {
        self.id = id; self.name = name; self.url = url; self.bytes = bytes
        type = SysExRecognizer.classify(bytes)
        info = SysExRecognizer.describe(bytes, audioDescriber: Self.audioDescriber)
        (sampleFrames, sampleRate) = Self.computeSampleFrames(type: type, bytes: bytes)
    }

    public static func load(url: URL) throws -> C6Item {
        var item = C6Item(name: url.lastPathComponent, url: url, bytes: [UInt8](try Data(contentsOf: url)))
        // C2026: samples get a Machinedrum name by default (editable; cleared = none unless
        // "Send SPS-1UW Name" is on).
        if item.isAudio { item.mdName = MDName.suggest(forFileName: url.lastPathComponent) }
        return item
    }

    /// Replaces the contents (e.g. after DigiPRO conversion) and re-runs recognition.
    public mutating func replaceBytes(_ new: [UInt8], name: String? = nil) {
        bytes = new
        if let name { self.name = name; url = nil }
        type = SysExRecognizer.classify(bytes)
        info = SysExRecognizer.describe(bytes, audioDescriber: Self.audioDescriber)
        (sampleFrames, sampleRate) = Self.computeSampleFrames(type: type, bytes: bytes)
    }

    public var byteCount: Int { bytes.count }
    public var isAudio: Bool { type == .wav || type == .aiff || type == .aifc }
    /// The SysEx messages in this item (for sending raw SysEx).
    public var sysex: SysExData { SysExData(bytes: bytes) }
    /// C6 showed the type as "-" for unrecognised data and "SYX"-less names for SysEx families.
    public var typeLabel: String { type.rawValue }
}

public enum C6Error: Error, CustomStringConvertible {
    case unsupportedFile(String)
    case notConnected
    case cancelled
    case timeout(String)
    case device(String)

    public var description: String {
        switch self {
        case let .unsupportedFile(n): return "“\(n)” is not a SysEx, WAV or AIFF file"
        case .notConnected: return "No MIDI ports selected"
        case .cancelled: return "Cancelled"
        case let .timeout(s): return "Timed out: \(s)"
        case let .device(s): return s
        }
    }
}

/// C6's File Info text for SysEx data (see `SysExRecognizer`).
public enum SysExDescriber {
    /// Runs the recognizer on the concatenated messages. `SysExData` has already dropped bytes
    /// outside `F0 … F7` and realtime bytes, which C6 kept in its buffer; that only matters for
    /// files with junk between or inside messages.
    public static func describe(_ data: SysExData) -> String {
        SysExRecognizer.describe(data.bytes)
    }
}
