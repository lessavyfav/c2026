import C6Core
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var preview: AudioPreview
    @State private var spacebar: SpacebarMonitor?
    @State private var showSettings = false
    @State private var showLog = false
    @State private var importing = false
    @State private var confirmSampleSend = false
    @State private var confirmOverflow = false
    @State private var showDevice = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            itemList
            Divider()
            infoPanel
            Divider()
            statusRow
            if showLog { Divider(); LogView() .frame(height: 140) }
        }
        .frame(minWidth: 620, minHeight: 420)
        .onAppear {
            spacebar = SpacebarMonitor {
                guard let item = model.selectedItems.first(where: \.isPlayable) else { return false }
                preview.toggle(item, asMachinedrum: model.settings.previewAsMachinedrum, interpolation: model.settings.pitchDownEmulation); return true
            }
        }
        .onChange(of: model.items.map(\.id)) { ids in
            if let p = preview.playingID, !ids.contains(p) { preview.stop() }
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
        .sheet(isPresented: $showDevice) { DeviceSamplesView().environmentObject(model) }
        .fileImporter(isPresented: $importing, allowedContentTypes: C6Types.importable, allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { model.load(urls: urls) }
        }
        .confirmationDialog(sampleSendTitle, isPresented: $confirmSampleSend) {
            Button("Send") { model.send() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces whatever is stored in those sample slots on the device.")
        }
        .alert(overflowTitle, isPresented: $confirmOverflow) {
            if let p = model.samplePlan {
                Button("Stop at slot \(p.slotCount)") { model.send(overflow: .stop) }
                Button("Wrap to slot 1") { model.send(overflow: .wrap) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let p = model.samplePlan {
                Text("Stop sends the first \(p.fittingCount) and skips the rest. Wrap continues from slot 1, replacing slots 1–\(min(p.slotCount, p.end - p.slotCount)). The device has \(p.slotCount) slots (Configure → Sample slots).")
            }
        }
        .alert("C2026", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: { Text(model.lastError ?? "") }
    }

    // MARK: Toolbar (C6: Send, Receive, Load, Save, Close, Configure)

    private var toolbar: some View {
        HStack(spacing: 8) {
            if case .sending = model.activity {
                Button("Stop") { model.stop() }.keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Send") {
                    if model.selection.isEmpty { importing = true }
                    else if let plan = model.samplePlan { if plan.fits { confirmSampleSend = true } else { confirmOverflow = true } }
                    else { model.send() }
                }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isBusy)
            }
            if case .receiving = model.activity {
                Button("Stop") { model.stop() }.keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Receive") { model.receive() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isBusy)
            }
            Divider().frame(height: 18)
            Button("Load…") { importing = true }.keyboardShortcut("o", modifiers: .command)
            Button("Save…") { saveSelected() }.keyboardShortcut("s", modifiers: .command).disabled(model.items.isEmpty)
            Button("Remove") { model.removeSelected() }.keyboardShortcut(.delete, modifiers: []).disabled(model.selection.isEmpty || model.isBusy)
            Spacer()
            turboControl
            Button { showDevice = true } label: { MachinedrumIcon().frame(width: 26) }
                .help("Machinedrum samples and memory")
            Button { showSettings = true } label: { Image(systemName: "gearshape") }.help("Configure")
            Button { showLog.toggle() } label: { Image(systemName: "list.bullet.rectangle") }.help("MIDI log")
        }
        .padding(8)
    }

    private var turboControl: some View {
        HStack(spacing: 6) {
            Circle().fill(model.tm1Present ? (model.turbo > .x1 ? Color.orange : Color.green) : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Toggle("Turbo \(model.turbo > .x1 ? model.turbo.label : "")", isOn: Binding(get: { model.turbo > .x1 }, set: { _ in model.toggleTurbo() }))
                .toggleStyle(.button)
                .disabled(!model.tm1Present || model.isBusy)
                .help(model.tm1Present ? "TurboMIDI via the TM-1 (limit \(TurboSpeed(code: model.settings.turboLimit)?.label ?? "20×"))" : "No TM-1 on the selected ports")
        }
    }

    // MARK: Data browser

    private var itemList: some View {
        List(selection: $model.selection) {
            ForEach(model.items) { item in
                ItemRow(item: item, isPlaying: preview.playingID == item.id,
                        onPlay: { preview.toggle(item, asMachinedrum: model.settings.previewAsMachinedrum, interpolation: model.settings.pitchDownEmulation) },
                        onToggleRate: { model.toggleHalfRate(item.id); replay(item.id) },
                        onToggleDouble: { model.toggleDoubleSpeed(item.id); replay(item.id) })
                    .tag(item.id)
                    .contextMenu {
                        if item.isAudio {
                            Button("Export as Sample Dump (.syx)…") { exportSampleDump(item) }
                        }
                    }
            }
            .onMove { model.move(from: $0, to: $1) }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if model.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Drop .syx, WAV or AIFF files here, or press Receive").foregroundStyle(.secondary)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in model.load(urls: urls); return true }
    }

    // MARK: File info (C6: info text, Loop, Stereo, DigiPRO)

    private var infoPanel: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("File Info").font(.caption).foregroundStyle(.secondary)
                Text(model.selectedItems.count == 1 ? model.selectedItems[0].info : model.selectedItems.isEmpty ? "No selection" : "\(model.selectedItems.count) items selected")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                memoryLine
                HStack(spacing: 6) {
                    let audio = model.selectedItems.filter(\.isAudio)
                    // C6's Loop / Stereo buttons cycle through their values for the selected samples.
                    Button(audio.first?.loopMode.rawValue ?? C6Item.LoopMode.file.rawValue) { model.cycleLoop() }
                        .disabled(audio.isEmpty || model.isBusy)
                        .help("How loop points are sent as a sample dump")
                    Button(audio.first?.stereoMode.rawValue ?? C6Item.StereoMode.mix.rawValue) { model.cycleStereo() }
                        .disabled(audio.isEmpty || model.isBusy)
                        .help("Which channel of a stereo file is sent (sample dumps are mono)")
                    Button("DigiPRO") { model.convertSelectionToDigiPRO() }
                        .disabled(!model.canConvertSelectionToDigiPRO || model.isBusy)
                        .help("Convert to a Monomachine DigiPRO waveform (the loop, or the whole sample; max 16384 samples)")
                    if audio.count == 1, let item = audio.first {
                        Divider().frame(height: 14)
                        Text("MD name").foregroundStyle(.secondary)
                        TextField(MDName.suggest(forFileName: item.name), text: Binding(
                            get: { item.mdName ?? "" },
                            set: { model.setMDName($0, for: item.id) }))
                            .frame(width: 56)
                            .font(.system(.body, design: .monospaced))
                        Text(item.mdName != nil ? "sent" : model.settings.sendSPS1UWName ? "auto" : "off")
                            .foregroundStyle(.secondary)
                            .help(item.mdName != nil
                                  ? "This name is sent to the Machinedrum with the sample."
                                  : model.settings.sendSPS1UWName
                                    ? "The suggested name is sent (Configure → Send SPS-1UW Name). Type to change it."
                                    : "No name is sent. Type one here, or turn on Configure → Send SPS-1UW Name.")
                    }
                }
                .controlSize(.small)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text("Connection").font(.caption).foregroundStyle(.secondary)
                Text(model.connectionDescription).lineLimit(1)
                Text("Send to slot").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                HStack(spacing: 4) {
                    TextField("1", value: $model.targetSlot, format: .number).frame(width: 50)
                    Stepper("", value: $model.targetSlot, in: 1...max(1, model.settings.sampleSlots)).labelsHidden()
                    Text("SDS #\(model.samplePosition)").foregroundStyle(.tertiary).font(.caption)
                }
                .help("Slot for the next sample, numbered as on the device (the Machinedrum's slots start at 1). Several samples sent together fill the following slots; this number stays put. The sample dump itself carries the number minus one (SDS #). Note: the Machinedrum stores a dump in that slot even when it isn't armed to receive.")
            }
            .frame(width: 200, alignment: .leading)
        }
        .padding(8)
        .frame(height: 118)
    }

    // MARK: Status row

    private var statusRow: some View {
        HStack {
            switch model.activity {
            case .idle:
                Text(model.log.last?.text ?? "Ready").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            case let .sending(item, index, count, p):
                ProgressView(value: p.fraction).frame(width: 220)
                Text("Sending \(item) (\(index + 1)/\(count))").lineLimit(1)
                Spacer()
                Text("\(Format.bytes(Int(p.bytesPerSecond)))/s" + (p.remaining.map { " · \(Format.duration($0)) left" } ?? ""))
                    .monospacedDigit().foregroundStyle(.secondary)
            case let .receiving(bytes, messages):
                ProgressView().controlSize(.small)
                Text("Receiving: \(Format.bytes(bytes)) in \(messages) messages").monospacedDigit()
                Spacer()
                Text(model.settings.receiveIdleTimeout > 0 ? "stops after \(Int(model.settings.receiveIdleTimeout)) s of silence" : "press Stop when done")
                    .foregroundStyle(.secondary)
            case let .turbo(text):
                ProgressView().controlSize(.small)
                Text(text)
                Spacer()
            case let .scanning(done, total):
                ProgressView(value: Double(done), total: Double(max(1, total))).frame(width: 220)
                Text("Reading the device's sample slots (\(done)/\(total))")
                Spacer()
                Button("Stop") { model.stop() }.controlSize(.small)
            case let .downloading(slot, index, count, received, total):
                ProgressView(value: Double(received), total: Double(max(1, total))).frame(width: 220)
                Text("Downloading slot \(slot) (\(index + 1)/\(count))")
                Spacer()
                Button("Stop") { model.stop() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .font(.callout)
    }

    private func exportSampleDump(_ item: C6Item) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (item.name as NSString).deletingPathExtension + ".syx"
        panel.allowedContentTypes = [C6Types.syx]
        panel.message = "The dump is numbered for slot \(model.targetSlot); devices that honour the number store it there."
        if panel.runModal() == .OK, let url = panel.url { model.saveAsSampleDump(item: item, to: url) }
    }

    /// "MD memory: 3 samples, 412 kB → slots 45–47 · after sending 2.43 MB of 2.50 MB (77 kB free)".
    @ViewBuilder private var memoryLine: some View {
        let audio = model.selectedItems.filter(\.isAudio)
        if !audio.isEmpty {
            let size = model.memory.bytes(frames: audio.reduce(0) { $0 + ($1.sendFrames ?? 0) })
            let plan = model.samplePlan
            let slots = plan.map { $0.count == 1 ? "slot \($0.start)" : "slots \($0.start)–\($0.fits ? $0.end : $0.slotCount)" } ?? ""
            HStack(spacing: 4) {
                if model.deviceScanDate != nil, let p = model.selectionProjection() {
                    Image(systemName: p.fits ? "checkmark.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(p.fits ? Color.green : Color.orange)
                    Text("\(audio.count == 1 ? "1 sample" : "\(audio.count) samples"), \(ByteFormat.memory(size)) → \(slots) · "
                         + (p.fits ? "after sending: \(ByteFormat.memory(p.usedAfter)) of \(ByteFormat.memory(p.total)) used, \(ByteFormat.memory(p.freeAfter)) free"
                                   : "\(ByteFormat.memory(-p.freeAfter)) more than the device's free memory"))
                } else {
                    MachinedrumIcon(lineWidth: 0.9).frame(width: 18).foregroundStyle(.secondary)
                    Text("\(audio.count == 1 ? "1 sample" : "\(audio.count) samples"), \(ByteFormat.memory(size)) of sample memory → \(slots)")
                    Button("Check free space…") { showDevice = true }.buttonStyle(.link)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Sample memory is 2 bytes per frame whatever the bit depth; lower sample rates use less. Replacing a slot frees its old sample's space.")
        }
    }

    /// Restarts the preview after a 22k/2× change so the difference can be heard.
    private func replay(_ id: C6Item.ID) {
        guard preview.playingID == id, let updated = model.items.first(where: { $0.id == id }) else { return }
        preview.play(updated, asMachinedrum: model.settings.previewAsMachinedrum, interpolation: model.settings.pitchDownEmulation)
    }

    private var sampleSendTitle: String {
        guard let p = model.samplePlan else { return "" }
        return p.count == 1 ? "Send sample to slot \(p.start)?" : "Send \(p.count) samples to slots \(p.start)–\(p.end)?"
    }

    private var overflowTitle: String {
        guard let p = model.samplePlan else { return "" }
        return "\(p.count) samples from slot \(p.start) go past the last slot (\(p.slotCount))"
    }

    private func saveSelected() {
        // C6: no selection saves the file list (.c6); otherwise one save dialog per selected item.
        guard !model.selectedItems.isEmpty else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Filelist.c6"
            panel.allowedContentTypes = [C6Types.c6]
            if panel.runModal() == .OK, let url = panel.url { model.saveFileList(to: url) }
            return
        }
        for item in model.selectedItems {
            let panel = NSSavePanel()
            let ext: String
            switch item.type {
            case .wav: ext = "wav"
            case .aiff: ext = "aiff"
            case .aifc: ext = "aifc"
            default: ext = "syx"
            }
            let base = (item.name as NSString).deletingPathExtension
            panel.nameFieldStringValue = base + "." + ext
            // Audio items can also be saved as a MIDI Sample Dump .syx (new in C2026).
            panel.allowedContentTypes = item.isAudio ? [UTType(filenameExtension: ext) ?? .audio, C6Types.syx] : [UTType(filenameExtension: ext) ?? .data]
            panel.allowsOtherFileTypes = item.isAudio
            if item.isAudio { panel.message = "Save as .\(ext), or change the extension to .syx to export a MIDI Sample Dump." }
            guard panel.runModal() == .OK, let url = panel.url else { return } // Cancel stops the rest, like C6
            if item.isAudio && url.pathExtension.lowercased() == "syx" { model.saveAsSampleDump(item: item, to: url) }
            else { model.save(item: item, to: url) }
        }
    }
}

struct ItemRow: View {
    let item: C6Item
    var isPlaying = false
    var onPlay: () -> Void = {}
    var onToggleRate: () -> Void = {}
    var onToggleDouble: () -> Void = {}
    /// Preview renders only: draw controls as plain labels (ImageRenderer can't draw buttons).
    var staticControls = false

    @ViewBuilder private func control(_ action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        if staticControls { label() } else { Button(action: action, label: label).buttonStyle(.borderless) }
    }
    var body: some View {
        HStack {
            if item.isPlayable {
                control(onPlay) {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill").frame(width: 14)
                        .foregroundStyle(staticControls ? Color.accentColor : Color.primary)
                }
                .help(isPlaying ? "Stop" : "Play (Space) — as the Machinedrum will play it")
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            rateToggle.frame(width: 44)
            doubleToggle.frame(width: 26)
            Text(item.name).lineLimit(1).truncationMode(.middle)
            Spacer()
            statusView
            if let frames = item.sendFrames {
                Text("MD " + ByteFormat.memory(frames * 2)).monospacedDigit().foregroundStyle(.tertiary).font(.caption)
                    .help("Space this sample takes in the Machinedrum's sample memory")
            }
            Text(Format.sizeColumn(item.byteCount)).monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
            Text(item.typeLabel).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
        }
    }

    /// "44.1k" ↔ "22k": the rate the sample is sent (and previewed) at.
    @ViewBuilder private var rateToggle: some View {
        if item.canHalveRate, let rate = item.sampleRate {
            control(onToggleRate) {
                Text(item.halfRate ? "22k" : Self.rateLabel(rate))
                    .font(.caption.monospacedDigit().weight(item.halfRate ? .semibold : .regular))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(item.halfRate ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
                    .foregroundStyle(item.halfRate ? Color.accentColor : Color.secondary)
            }
            .help(item.halfRate
                  ? "Sent at 22.05 kHz — half the memory. Click to send at \(Self.rateLabel(rate))Hz."
                  : "Sent at \(Self.rateLabel(rate))Hz. Click to send at 22.05 kHz and use half the memory (the preview follows).")
        } else if let rate = item.sampleRate, item.isPlayable {
            Text(Self.rateLabel(rate)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
    }

    /// 44100 → "44.1k", 48000 → "48k", 22050 → "22k", 11025 → "11k".
    /// "2×": send at double speed (half the memory; PTCH −36 on the MD).
    @ViewBuilder private var doubleToggle: some View {
        if item.canDoubleSpeed {
            control(onToggleDouble) {
                Text("2×")
                    .font(.caption.monospacedDigit().weight(item.doubleSpeed ? .semibold : .regular))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(item.doubleSpeed ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.12)))
                    .foregroundStyle(item.doubleSpeed ? Color.orange : Color.secondary)
            }
            .help(item.doubleSpeed
                  ? "Sent at double speed — half the memory. Set the track's PTCH to −36 on the MD (one octave down). Click to send at normal speed."
                  : "Send at double speed: half the memory; set the track's PTCH to −36 on the MD (one octave down) to compensate. The preview plays it as it will sound there.")
        }
    }

    static func rateLabel(_ rate: Int) -> String {
        let k = Double(rate) / 1000
        return abs(k - k.rounded()) < 0.06 ? "\(Int(k.rounded()))k" : String(format: "%.1fk", k)
    }

    @ViewBuilder private var statusView: some View {
        switch item.status {
        case .idle: EmptyView()
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case let .sending(f): ProgressView(value: f).frame(width: 60)
        case .sent: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        case let .skipped(why): Image(systemName: "minus.circle").foregroundStyle(.secondary).help(why)
        }
    }
}

struct LogView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollViewReader { proxy in
            List(model.log) { line in
                HStack(alignment: .firstTextBaseline) {
                    Text(line.time, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
                    Text(line.text).textSelection(.enabled)
                }
                .font(.system(.caption, design: .monospaced))
                .id(line.id)
            }
            .onChange(of: model.log.count) { _ in if let last = model.log.last { proxy.scrollTo(last.id) } }
        }
    }
}

enum C6Types {
    static let syx = UTType(filenameExtension: "syx") ?? .data
    static let c6 = UTType(filenameExtension: "c6") ?? .data
    static let importable: [UTType] = [syx, .wav, .aiff, UTType(filenameExtension: "aifc") ?? .audio, c6]
}
