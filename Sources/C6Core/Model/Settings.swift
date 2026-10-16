import Foundation

/// User settings, mirroring C6's Configure window (plus a few additions).
/// Defaults follow C6 1.51 where known; the spec agents' findings refine these.
public struct C6Settings: Codable, Equatable, Sendable {
    public enum RecFormat: String, Codable, CaseIterable, Sendable { case aiff = "AIFF", wav = "WAV", sds = "SDS", none = "None" }
    /// How received sample dumps are answered (see `SDSReceiver.Pace`).
    public enum ReceivePace: String, Codable, CaseIterable, Sendable {
        /// Fast at TurboMIDI speeds, handshake at 1×.
        case auto = "Auto"
        /// No replies; bad dumps are requested again (≈2× faster from a Machinedrum at 10×).
        case fast = "Fast"
        /// ACK every packet, like C6.
        case handshake = "Handshake"
    }

    // MIDI ports are remembered by CoreMIDI unique ID, with the name as a fallback after re-plugging.
    public var inputPortID: Int32?
    public var inputPortName: String?
    public var outputPortID: Int32?
    public var outputPortName: String?

    public var reloadFiles = true
    /// Extra gap between messages/packets in milliseconds (C6: Windows "Delay (ms)", Mac "Delay (ticks)").
    public var delayMilliseconds: Double = 0
    /// Highest TurboMIDI speed the Turbo button asks for (C6 "Turbo Limit"; default 20× = no limit).
    public var turboLimit: UInt8 = TurboSpeed.x20.rawValue
    public var sdsHandshake = true
    public var extendedSDS = false
    public var sendSPS1UWName = false
    public var sdsDeviceNumber: UInt8 = 0
    public var recFormat: RecFormat = .wav

    // Additions
    /// Engage turbo automatically before a transfer when a TM-1 is present.
    public var autoTurbo = true
    /// Receive stops by itself after this many seconds without data (0 = manual Stop, like C6).
    public var receiveIdleTimeout: Double = 3
    /// Safety margin below the nominal line rate when pacing output.
    public var pacingHeadroom: Double = 0.02
    public var receivePace: ReceivePace = .auto
    /// Sample slots on the target device (Machinedrum UW MKII: 48, MKI: 32); batches stop or wrap here.
    public var sampleSlots = 48
    /// Device sample memory in kB (MD UW MKII: 2560 = 2.5 MB; MKI: 2048).
    public var sampleMemoryKB = 2560
    /// The play button plays samples as the Machinedrum will (mono, send rate, 12-bit).
    public var previewAsMachinedrum = true
    /// Send samples deeper than 16 bits as 16-bit (the Machinedrum stores 16-bit; 24-bit takes
    /// a third more packets).
    public var send16Bit = true
    /// How the preview steps through 22 kHz and 2× samples. Gritty (sample & hold) is the default:
    /// it matches the Machinedrum's old-school playback by ear; Smooth stays as an option.
    public var pitchDownEmulation: MachinedrumPreview.Interpolation = .hold
    public var maxSendBits: Int? { send16Bit ? 16 : nil }
    public var sampleMemory: SampleMemory { SampleMemory(totalBytes: sampleMemoryKB * 1024) }

    public init() {}

    /// The receiver strategy for the current TurboMIDI speed.
    public func sdsReceivePace(at speed: TurboSpeed) -> SDSReceiver.Pace {
        switch receivePace {
        case .fast: return .fast(retries: 2)
        case .handshake: return .ackEachPacket
        case .auto: return speed > .x1 ? .fast(retries: 2) : .ackEachPacket
        }
    }

    // Decoding tolerates missing keys, so settings saved by older builds keep working.
    private enum CodingKeys: String, CodingKey {
        case inputPortID, inputPortName, outputPortID, outputPortName, reloadFiles, delayMilliseconds, turboLimit,
             sdsHandshake, extendedSDS, sendSPS1UWName, sdsDeviceNumber, recFormat, autoTurbo, receiveIdleTimeout,
             pacingHeadroom, receivePace, sampleSlots, sampleMemoryKB, previewAsMachinedrum, send16Bit, pitchDownEmulation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = C6Settings()
        inputPortID = try c.decodeIfPresent(Int32.self, forKey: .inputPortID)
        inputPortName = try c.decodeIfPresent(String.self, forKey: .inputPortName)
        outputPortID = try c.decodeIfPresent(Int32.self, forKey: .outputPortID)
        outputPortName = try c.decodeIfPresent(String.self, forKey: .outputPortName)
        reloadFiles = try c.decodeIfPresent(Bool.self, forKey: .reloadFiles) ?? d.reloadFiles
        delayMilliseconds = try c.decodeIfPresent(Double.self, forKey: .delayMilliseconds) ?? d.delayMilliseconds
        turboLimit = try c.decodeIfPresent(UInt8.self, forKey: .turboLimit) ?? d.turboLimit
        sdsHandshake = try c.decodeIfPresent(Bool.self, forKey: .sdsHandshake) ?? d.sdsHandshake
        extendedSDS = try c.decodeIfPresent(Bool.self, forKey: .extendedSDS) ?? d.extendedSDS
        sendSPS1UWName = try c.decodeIfPresent(Bool.self, forKey: .sendSPS1UWName) ?? d.sendSPS1UWName
        sdsDeviceNumber = try c.decodeIfPresent(UInt8.self, forKey: .sdsDeviceNumber) ?? d.sdsDeviceNumber
        recFormat = (try? c.decodeIfPresent(RecFormat.self, forKey: .recFormat)) ?? d.recFormat
        autoTurbo = try c.decodeIfPresent(Bool.self, forKey: .autoTurbo) ?? d.autoTurbo
        receiveIdleTimeout = try c.decodeIfPresent(Double.self, forKey: .receiveIdleTimeout) ?? d.receiveIdleTimeout
        pacingHeadroom = try c.decodeIfPresent(Double.self, forKey: .pacingHeadroom) ?? d.pacingHeadroom
        receivePace = (try? c.decodeIfPresent(ReceivePace.self, forKey: .receivePace)) ?? d.receivePace
        sampleSlots = max(1, try c.decodeIfPresent(Int.self, forKey: .sampleSlots) ?? d.sampleSlots)
        sampleMemoryKB = max(1, try c.decodeIfPresent(Int.self, forKey: .sampleMemoryKB) ?? d.sampleMemoryKB)
        previewAsMachinedrum = try c.decodeIfPresent(Bool.self, forKey: .previewAsMachinedrum) ?? d.previewAsMachinedrum
        send16Bit = try c.decodeIfPresent(Bool.self, forKey: .send16Bit) ?? d.send16Bit
        pitchDownEmulation = (try? c.decodeIfPresent(MachinedrumPreview.Interpolation.self, forKey: .pitchDownEmulation)) ?? d.pitchDownEmulation
    }

    public static func load(from defaults: UserDefaults = .standard) -> C6Settings {
        guard let d = defaults.data(forKey: "settings"), let s = try? JSONDecoder().decode(C6Settings.self, from: d) else { return C6Settings() }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: "settings") }
    }
}
