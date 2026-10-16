import C6Core
import SwiftUI

/// Lists the device's sample slots (read from dump headers — no audio is transferred) with a
/// memory bar; slots can be downloaded into the list or chosen as the send target.
struct DeviceSamplesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<Int> = []

    struct Row: Identifiable {
        let slot: Int
        let info: SlotInfo?
        var id: Int { slot }
    }

    var rows: [Row] {
        let bySlot = Dictionary(model.deviceSlots.map { ($0.slot, $0) }, uniquingKeysWith: { a, _ in a })
        return (1...max(1, model.settings.sampleSlots)).map { Row(slot: $0, info: bySlot[$0]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Device Samples").font(.title2.bold())
                Spacer()
                if case let .scanning(done, total) = model.activity {
                    ProgressView(value: Double(done), total: Double(max(1, total))).frame(width: 120)
                    Button("Stop") { model.stop() }
                } else {
                    Button(model.deviceScanDate == nil ? "Scan Device" : "Rescan") { model.scanDevice() }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                        .disabled(model.isBusy)
                }
            }
            memoryBar
            Table(rows, selection: $selection) {
                TableColumn("Slot") { r in Text("\(r.slot)").monospacedDigit() }.width(40)
                TableColumn("Name") { r in Text(r.info?.name ?? (r.info == nil ? "—" : "")).font(.system(.body, design: .monospaced)) }.width(60)
                TableColumn("Length") { r in Text(r.info.map { String(format: "%.2f s", $0.duration) } ?? "").monospacedDigit() }.width(60)
                TableColumn("Rate") { r in Text(r.info.map { "\(($0.sampleRate + 50) / 100 * 100 == 44100 ? "44.1" : String(format: "%.1f", Double($0.sampleRate) / 1000)) kHz" } ?? "").monospacedDigit() }.width(70)
                TableColumn("Bits") { r in Text(r.info.map { "\($0.bits)" } ?? "") }.width(36)
                TableColumn("Memory") { r in Text(r.info.map { ByteFormat.memory(model.memory.bytes(frames: $0.length)) } ?? "empty").monospacedDigit().foregroundStyle(r.info == nil ? .tertiary : .primary) }.width(70)
            }
            .frame(minHeight: 320)
            HStack {
                Text(model.deviceScanDate.map { "Scanned \($0.formatted(date: .omitted, time: .shortened))" } ?? "Scan reads each slot's name and length; nothing on the device changes.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Send to Slot \(selection.min() ?? model.targetSlot)") {
                    if let s = selection.min() { model.targetSlot = s }
                    dismiss()
                }
                .disabled(selection.isEmpty)
                .help("Make this the slot the next sample is sent to")
                Button("Download \(selectedFilled.count > 1 ? "\(selectedFilled.count) Samples" : "Sample")") {
                    model.downloadSlots(selectedFilled.sorted())
                    dismiss()
                }
                .disabled(selectedFilled.isEmpty || model.isBusy)
                .help("Receive the selected slots into the list (as WAV, per Configure → SDS Rec Format)")
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .onAppear { if model.deviceScanDate == nil && !model.isBusy { model.scanDevice() } }
    }

    private var selectedFilled: [Int] {
        let filled = Set(model.deviceSlots.map(\.slot))
        return selection.filter { filled.contains($0) }
    }

    private var memoryBar: some View {
        let used = model.deviceUsedBytes, total = model.memory.totalBytes
        let pct = Int((Double(used) / Double(max(1, total)) * 100).rounded())
        let after = model.selectionProjection()?.usedAfter
        return VStack(alignment: .leading, spacing: 6) {
            MemoryUsageBar(slots: model.deviceSlots, memory: model.memory, highlighted: selection,
                           usedAfterSend: after == used ? nil : after,
                           onSelect: { slot in selection = [slot] })
                .padding(.top, 30)   // room for the hover bubble
            HStack(spacing: 12) {
                if model.deviceScanDate == nil {
                    Text("Memory: not scanned yet")
                } else {
                    Text("\(pct)% used").bold()
                    Text("\(ByteFormat.memory(used)) of \(ByteFormat.memory(total))")
                    Text("\(ByteFormat.memory(max(0, total - used))) free")
                    Text("\(model.deviceSlots.count)/\(model.settings.sampleSlots) slots")
                }
                Spacer()
                if let after, after != used {
                    Label("after send: \(ByteFormat.memory(after))", systemImage: "arrowtriangle.down.fill")
                        .foregroundStyle(after > total ? .orange : .secondary)
                        .help("Where memory use lands after sending the samples selected in the main window")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Estimate: 2 bytes per frame whatever the bit depth (22 kHz samples use half). RAM machine buffers share this memory.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
