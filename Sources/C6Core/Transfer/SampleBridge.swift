import Foundation

/// Glue between audio files, SDS samples and list items.
public extension SDSSample {
    /// Builds the SDS sample C6 sent for an audio file, honouring the item's Stereo and Loop buttons.
    init(audio: AudioFile, stereo: C6Item.StereoMode, loop: C6Item.LoopMode, name: String?, sampleNumber: Int = 0) {
        let i = audio.info
        self.init(samples: audio.sdsSamples(stereo: stereo), bits: i.bits, samplePeriodNs: i.samplePeriodNs,
                  sampleRateHz: i.sampleRate, loopStart: i.loopOn ? i.loopStart : 0,
                  loopEnd: i.loopOn ? i.loopEnd : nil,
                  loopType: i.loopOn ? UInt8(i.loopType & 0x7F) : SDSSample.loopOff,
                  name: name, sampleNumber: sampleNumber, channels: 1)
        self = applyingLoopMode(loop)
    }
}

public extension SDSReceiver.ReceivedDump {
    /// File bytes for a received sample in the chosen Rec Format.
    func fileBytes(format: C6Settings.RecFormat) -> [UInt8] {
        let s = sample
        let loop: AudioWriter.Loop? = s.loopType == SDSSample.loopOff ? nil : (s.loopStart, s.loopEnd, Int(s.loopType))
        switch format {
        case .wav: return AudioWriter.wav(samples: s.samples, bits: s.bits, sampleRate: s.sampleRate, loop: loop)
        case .aiff: return AudioWriter.aiff(samples: s.samples, bits: s.bits, sampleRate: s.sampleRate, loop: loop)
        case .sds, .none: return messages.flatMap { $0 }
        }
    }
}

public extension C6Item {
    /// Audio for the play button: the file itself for WAV/AIFF/AIFC items, or the first sample of
    /// a sample-dump (.syx) item rendered as WAV. Nil when there is nothing to play.
    var playableAudio: [UInt8]? {
        if isAudio { return bytes }
        guard type == .sds else { return nil }
        let r = SDSReceiver(transport: nil)
        var dump: SDSReceiver.ReceivedDump?
        r.onEvent = { if case let .dump(d) = $0, dump == nil { dump = d } }
        for m in sysex.messages where dump == nil { _ = r.handle(m) }
        if dump == nil { dump = r.stop() }   // play what arrived of an incomplete dump
        guard let d = dump, !d.sample.samples.isEmpty else { return nil }
        return d.fileBytes(format: .wav)
    }

    var isPlayable: Bool { isAudio || type == .sds }
}
