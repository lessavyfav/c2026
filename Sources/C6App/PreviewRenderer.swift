#if DEBUG
import AppKit
import C6Core
import SwiftUI

/// Debug builds only: `C2026App --render-previews <dir> [slots.json]` renders UI pieces to PNG
/// (light and dark) and exits — used to check visuals without a screen.
enum PreviewRenderer {
    @MainActor static func run(_ args: [String]) {
        guard let i = args.firstIndex(of: "--render-previews"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        var slots: [SlotInfo] = []
        if i + 2 < args.count, let data = try? Data(contentsOf: URL(fileURLWithPath: args[i + 2])),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            slots = rows.compactMap { r in
                guard let n = r["slot"] as? Int, let len = r["frames"] as? Int else { return nil }
                return SlotInfo(sampleNumber: n - 1, name: r["name"] as? String, length: len, bits: 16,
                                sampleRate: r["rate"] as? Int ?? 44100, loopStart: 0, loopEnd: 0, loopType: 0x7F)
            }
        }
        let memory = SampleMemory.machinedrumUWMK2
        let used = memory.used(by: slots)
        func card(_ dark: Bool, hover: Int?) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                MemoryUsageBar(slots: slots, memory: memory, highlighted: [30], usedAfterSend: used - 300_000,
                               previewHoverSlot: hover)
                    .padding(.top, 30)
                HStack(spacing: 12) {
                    Text("\(Int((Double(used) / Double(memory.totalBytes) * 100).rounded()))% used").bold()
                    Text("\(ByteFormat.memory(used)) of \(ByteFormat.memory(memory.totalBytes))")
                    Text("\(ByteFormat.memory(memory.totalBytes - used)) free")
                    Text("\(slots.count)/48 slots")
                    Spacer()
                    Label("after send: \(ByteFormat.memory(used - 300_000))", systemImage: "arrowtriangle.down.fill")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 24).frame(width: 520)
            .background(dark ? Color(white: 0.15) : Color(white: 0.97))
            .environment(\.colorScheme, dark ? .dark : .light)
        }
        let view = VStack(spacing: 0) { card(false, hover: 26); card(true, hover: 11); card(false, hover: 0) }
        save(view, dir.appendingPathComponent("memory-bar-preview.png"))

        // List rows: the 22k toggle off and on, a file already at 22 kHz, and a kit dump.
        func wav(_ name: String, rate: Int, seconds: Double) -> C6Item {
            let n = Int(Double(rate) * seconds)
            var i = C6Item(name: name, bytes: AudioWriter.wav(samples: [Int32](repeating: 0, count: n), bits: 16, sampleRate: rate))
            i.mdName = MDName.suggest(forFileName: name)
            return i
        }
        var on = wav("808_main_house_C.wav", rate: 44100, seconds: 0.8); on.halfRate = true
        var dbl = wav("TORI_LETZLER_vocal_vowel_short_high_ee_C.wav", rate: 44100, seconds: 0.6); dbl.doubleSpeed = true
        var both = wav("Bpm180_BrokenBreak_Paranoia_PL.wav", rate: 44100, seconds: 2); both.halfRate = true; both.doubleSpeed = true
        let rows = [wav("fh2_oneshot_percussion_low_tone_blip.wav", rate: 44100, seconds: 0.16), on, dbl, both,
                    wav("MD26 MOUF.wav", rate: 22050, seconds: 1.8),
                    C6Item(name: "MDK 2026-10-16 12.31.syx", bytes: [0xF0, 0x00, 0x20, 0x3C, 0x02, 0x00, 0x52, 0xF7])]
        func list(_ dark: Bool) -> some View {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, item in
                    ItemRow(item: item, isPlaying: i == 1, staticControls: true).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(i % 2 == 1 ? Color.secondary.opacity(0.06) : Color.clear)
                }
            }
            .frame(width: 560).padding(.vertical, 8)
            .background(dark ? Color(white: 0.15) : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
        }
        save(VStack(spacing: 0) { list(false); list(true) }, dir.appendingPathComponent("rows-preview.png"))
        exit(0)
    }

    @MainActor static func save(_ view: some View, _ url: URL) {
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}
#endif
