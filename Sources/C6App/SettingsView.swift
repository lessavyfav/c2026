import C6Core
import SwiftUI

/// C6's Configure window (MIDI Preferences), plus the new options.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = C6Settings()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Configure").font(.title2.bold())
            HStack(alignment: .top, spacing: 24) {
                Form {
                    Section("MIDI") {
                        Picker("MIDI In", selection: $draft.inputPortID) {
                            Text("None").tag(Int32?.none)
                            ForEach(model.sources) { Text($0.displayName + ($0.isTM1 ? "  (TM-1)" : "")).tag(Int32?.some($0.uniqueID)) }
                        }
                        Picker("MIDI Out", selection: $draft.outputPortID) {
                            Text("None").tag(Int32?.none)
                            ForEach(model.destinations) { Text($0.displayName + ($0.isTM1 ? "  (TM-1)" : "")).tag(Int32?.some($0.uniqueID)) }
                        }
                        Picker("Turbo Limit", selection: $draft.turboLimit) {
                            ForEach(TurboSpeed.allCases.filter { $0 > .x1 }, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                        }
                        Toggle("Engage turbo automatically before transfers", isOn: $draft.autoTurbo)
                        LabeledContent("Delay between messages") {
                            TextField("ms", value: $draft.delayMilliseconds, format: .number).frame(width: 60)
                            Text("ms")
                        }
                    }
                    Section("Receive") {
                        LabeledContent("Stop after silence") {
                            TextField("s", value: $draft.receiveIdleTimeout, format: .number).frame(width: 60)
                            Text("s (0 = manual Stop)")
                        }
                        Picker("SDS Rec Format", selection: $draft.recFormat) {
                            ForEach(C6Settings.RecFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Sample receive pace", selection: $draft.receivePace) {
                            ForEach(C6Settings.ReceivePace.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .help("Auto: fast at turbo speeds (no replies, so a Machinedrum sends about twice as fast; damaged dumps are requested again), handshake at 1×.")
                    }
                }
                .formStyle(.grouped)
                Form {
                    Section("Samples (SDS)") {
                        Toggle("SDS Handshake", isOn: $draft.sdsHandshake)
                        Toggle("Use Extended SDS", isOn: $draft.extendedSDS)
                        Toggle("Send SPS-1UW Name", isOn: $draft.sendSPS1UWName)
                        Stepper("SDS Device Number: \(draft.sdsDeviceNumber)", value: $draft.sdsDeviceNumber, in: 0...127)
                        Toggle("Send samples as 16-bit", isOn: $draft.send16Bit)
                            .help("The Machinedrum stores 16-bit, so 24/32-bit files are sent as 16-bit — a third fewer packets.")
                        Stepper("Sample slots on device: \(draft.sampleSlots)", value: $draft.sampleSlots, in: 1...1024)
                            .help("Machinedrum UW MKII: 48, MKI: 32. Batches of samples stop or wrap around here.")
                        Picker("Sample memory", selection: $draft.sampleMemoryKB) {
                            Text("2.5 MB (MD UW MKII / UW+)").tag(2560)
                            Text("2 MB (MD UW MKI)").tag(2048)
                            if ![2560, 2048].contains(draft.sampleMemoryKB) { Text("\(draft.sampleMemoryKB) kB").tag(draft.sampleMemoryKB) }
                        }
                        .help("Used for the free-space estimate. RAM machine buffers share this memory, so the device's own sample manager has the final word.")
                    }
                    Section("General") {
                        Toggle("Reload files on launch", isOn: $draft.reloadFiles)
                        Toggle("Preview samples as the Machinedrum plays them (12-bit)", isOn: $draft.previewAsMachinedrum)
                            .help("The play button plays samples mono, at the rate they'll be sent (22 kHz / 2× when toggled), at 12-bit resolution.")
                        Picker("22k / 2× playback emulation", selection: $draft.pitchDownEmulation) {
                            ForEach(MachinedrumPreview.Interpolation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .help("How the preview steps through 22 kHz and 2× samples at the MD's 44.1 kHz output. The MD's own method isn't documented: compare with the real thing and keep the closer one.")
                    }
                }
                .formStyle(.grouped)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    var s = draft
                    s.inputPortName = model.sources.first { $0.uniqueID == s.inputPortID }?.displayName
                    s.outputPortName = model.destinations.first { $0.uniqueID == s.outputPortID }?.displayName
                    model.settings = s
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760)
        .onAppear { draft = model.settings }
    }
}
