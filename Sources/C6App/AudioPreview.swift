import AppKit
import AVFoundation
import C6Core

/// Plays list items (WAV/AIFF, or sample dumps rendered to WAV) for auditioning before a send or
/// after a receive.
@MainActor
final class AudioPreview: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: C6Item.ID?
    private var player: AVAudioPlayer?

    func toggle(_ item: C6Item, asMachinedrum: Bool, interpolation: MachinedrumPreview.Interpolation = .hold) {
        if playingID == item.id { stop() } else { play(item, asMachinedrum: asMachinedrum, interpolation: interpolation) }
    }

    /// Plays `item` — as the Machinedrum will (mono, send rate, 12-bit) when `asMachinedrum`.
    /// Rendering (resampling) runs off the main thread.
    func play(_ item: C6Item, asMachinedrum: Bool, interpolation: MachinedrumPreview.Interpolation = .hold) {
        stop()
        playingID = item.id
        let id = item.id
        DispatchQueue.global(qos: .userInitiated).async {
            let audio = item.previewAudio(asMachinedrum: asMachinedrum, interpolation: interpolation)
            Task { @MainActor in
                guard self.playingID == id else { return }   // stopped or replaced meanwhile
                guard let audio, let p = try? AVAudioPlayer(data: Data(audio)) else { self.playingID = nil; NSSound.beep(); return }
                p.delegate = self
                p.play()
                self.player = p
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in if self.player === player { self.stop() } }
    }
}

/// Spacebar plays/stops the selected item, unless a text field is being edited.
final class SpacebarMonitor {
    private var monitor: Any?
    init(_ action: @escaping () -> Bool) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49, event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSTextView) else { return event }
            return action() ? nil : event
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
