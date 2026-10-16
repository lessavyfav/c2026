import C6Core
import Foundation
import SwiftUI

/// App state: ports, turbo, the item list, and transfers. UI-facing state is main-actor;
/// transfers run on a dedicated worker queue and report back.
@MainActor
final class AppModel: ObservableObject {
    enum Activity: Equatable {
        case idle
        case sending(item: String, index: Int, count: Int, progress: TransferProgress)
        case receiving(bytes: Int, messages: Int)
        case turbo(String)
        case scanning(done: Int, total: Int)
        case downloading(slot: Int, index: Int, count: Int, received: Int, total: Int)
    }

    struct LogLine: Identifiable { let id = UUID(); let time = Date(); let text: String }

    @Published var items: [C6Item] = []
    @Published var selection: Set<C6Item.ID> = []
    @Published var sources: [MIDIEndpointInfo] = []
    @Published var destinations: [MIDIEndpointInfo] = []
    @Published var settings: C6Settings = .load() { didSet { if settings != oldValue { settings.save(); if portsChanged(oldValue) { connect() } } } }
    @Published var turbo: TurboSpeed = .x1
    @Published var tm1Present = false
    @Published var activity: Activity = .idle
    @Published var lastError: String?
    @Published var log: [LogLine] = []
    @Published var connectionDescription = "Not connected"
    /// The device's samples as last scanned (Device Samples window); kept current after sends.
    @Published var deviceSlots: [SlotInfo] = []
    @Published var deviceScanDate: Date?
    /// C6 "Sample position": first SDS sample number for the next send (auto-increments). It is
    /// 0-based on the wire; the UI shows `targetSlot` instead.
    @Published var samplePosition = 0

    /// The 1-based slot the next sample goes to, as Elektron devices number them (MD slot 45 =
    /// SDS sample 44).
    var targetSlot: Int {
        get { samplePosition + 1 }
        set { samplePosition = min(max(1, newValue), settings.sampleSlots) - 1 }
    }

    private var system: CoreMIDISystem?
    var connection: CoreMIDIConnection?
    private var tm1: TM1Controller?
    let bus = MessageBus()
    let worker = DispatchQueue(label: "c6.transfer", qos: .userInitiated)
    var cancelFlag = CancelFlag()
    private var receiver: SysExReceiver?
    var receivedCount = 0

    var isBusy: Bool { activity != .idle }
    var selectedItems: [C6Item] { items.filter { selection.contains($0.id) } }

    init() {
        Self.migrateDefaults()
        C6Item.audioDescriber = { _, bytes in AudioFile.describe(bytes) }
        restoreFilesIfNeeded()
        do {
            let sys = try CoreMIDISystem(clientName: "C2026")
            system = sys
            sys.onChange { [weak self] in Task { @MainActor in self?.endpointsChanged() } }
            endpointsChanged()
        } catch {
            lastError = "\(error)"
        }
    }

    /// Settings moved when the bundle identifier changed from `local.c2026` to
    /// `com.lessavyfav.c2026`: copy them over once.
    private static func migrateDefaults() {
        let d = UserDefaults.standard
        guard d.object(forKey: "settings") == nil, let old = UserDefaults(suiteName: "local.c2026") else { return }
        for key in ["settings", "reloadList", "itemOptions"] {
            if let v = old.object(forKey: key) { d.set(v, forKey: key) }
        }
    }

    // MARK: Ports

    private func portsChanged(_ old: C6Settings) -> Bool {
        old.inputPortID != settings.inputPortID || old.outputPortID != settings.outputPortID
    }

    private func endpointsChanged() {
        guard let system else { return }
        sources = system.sources.filter { !$0.isOffline }
        destinations = system.destinations.filter { !$0.isOffline }
        // Auto-select: remembered port by ID, then by name, then a TM-1.
        var s = settings
        if s.inputPortID == nil || !sources.contains(where: { $0.uniqueID == s.inputPortID }) {
            if let e = sources.first(where: { $0.displayName == s.inputPortName }) ?? sources.first(where: \.isTM1) {
                s.inputPortID = e.uniqueID; s.inputPortName = e.displayName
            }
        }
        if s.outputPortID == nil || !destinations.contains(where: { $0.uniqueID == s.outputPortID }) {
            if let e = destinations.first(where: { $0.displayName == s.outputPortName }) ?? destinations.first(where: \.isTM1) {
                s.outputPortID = e.uniqueID; s.outputPortName = e.displayName
            }
        }
        if s != settings { settings = s } // triggers connect()
        let connectedStillThere = connection != nil
            && sources.contains(where: { $0.uniqueID == settings.inputPortID })
            && destinations.contains(where: { $0.uniqueID == settings.outputPortID })
        if !connectedStillThere { connect() }
    }

    func connect() {
        connection?.close(); connection = nil; tm1 = nil; tm1Present = false; turbo = .x1
        guard let system,
              let src = sources.first(where: { $0.uniqueID == settings.inputPortID }),
              let dst = destinations.first(where: { $0.uniqueID == settings.outputPortID }) else {
            connectionDescription = "Not connected"; return
        }
        do {
            let conn = try system.connect(source: src, destination: dst)
            let controller = TM1Controller(transport: conn)
            controller.onStatus = { [weak self] s in Task { @MainActor in self?.turbo = s; self?.tm1Present = true } }
            let bus = self.bus
            conn.onReceive = { msg in
                if controller.handle(msg) { return }
                bus.publish(msg)
            }
            connection = conn; tm1 = controller
            connectionDescription = src.displayName == dst.displayName ? src.displayName : "\(src.displayName) → \(dst.displayName)"
            append("Connected: \(connectionDescription)")
            worker.async { [weak self] in
                let s = controller.queryStatus()
                Task { @MainActor in
                    guard let self else { return }
                    if let s { self.turbo = s; self.tm1Present = true; self.append("TM-1 found, TurboMIDI \(s.label)") }
                }
            }
        } catch {
            connectionDescription = "Not connected"
            lastError = "\(error)"
        }
    }

    // MARK: Turbo

    func toggleTurbo() {
        guard let tm1, !isBusy else { return }
        let target: TurboSpeed = turbo == .x1 ? (TurboSpeed(code: settings.turboLimit) ?? .x20) : .x1
        activity = .turbo(target == .x1 ? "Turning turbo off…" : "Negotiating turbo…")
        worker.async { [weak self] in
            let result = tm1.setSpeed(target)
            Task { @MainActor in
                guard let self else { return }
                self.activity = .idle
                if let result { self.turbo = result; self.append("TurboMIDI: requested \(target.label), running at \(result.label)") }
                else { self.lastError = "The TM-1 did not answer the turbo request" }
            }
        }
    }

    // MARK: Items

    func load(urls: [URL]) {
        for url in urls {
            if url.pathExtension.lowercased() == "c6" { loadFileList(url); continue }
            do { var item = try C6Item.load(url: url); applySavedOptions(&item); items.append(item) }
            catch { lastError = "Could not open “\(url.lastPathComponent)”: \(error.localizedDescription)" }
        }
        rememberFiles()
    }

    /// Loads a .c6 list (replaces the current list, like C6).
    func loadFileList(_ url: URL) {
        do {
            let list = try C6FileList.parse(Data(contentsOf: url), directory: url.deletingLastPathComponent())
            var loaded: [C6Item] = [], missing: [String] = []
            for e in list.entries {
                guard var item = try? C6Item.load(url: e.url) else { missing.append(e.url.lastPathComponent); continue }
                item.loopMode = e.loop; item.stereoMode = e.stereo
                applySavedOptions(&item)
                loaded.append(item)
            }
            items = loaded; selection.removeAll(); samplePosition = list.samplePosition
            append("Opened \(url.lastPathComponent): \(loaded.count) files" + (missing.isEmpty ? "" : ", \(missing.count) missing"))
            if !missing.isEmpty { lastError = "These files from \(url.lastPathComponent) were not found:\n" + missing.joined(separator: "\n") }
        } catch {
            lastError = "“\(url.lastPathComponent)” is not a C6 file list"
        }
    }

    func saveFileList(to url: URL) {
        let entries = items.compactMap { item in item.url.map { C6FileList.Entry(url: $0, loop: item.loopMode, stereo: item.stereoMode) } }
        let list = C6FileList(samplePosition: samplePosition, entries: entries)
        do {
            try list.serialize(directory: url.deletingLastPathComponent()).write(to: url, options: .atomic)
            let unsaved = items.count - entries.count
            append("Saved \(url.lastPathComponent)" + (unsaved > 0 ? " (\(unsaved) unsaved received items not included)" : ""))
        } catch { lastError = "\(error)" }
    }

    /// "Reload files" on next launch: remember the list in the preferences.
    func rememberFiles() {
        let list = C6FileList(samplePosition: samplePosition,
                              entries: items.compactMap { i in i.url.map { C6FileList.Entry(url: $0, loop: i.loopMode, stereo: i.stereoMode) } })
        UserDefaults.standard.set(list.serialize(directory: URL(fileURLWithPath: "/")), forKey: "reloadList")
    }

    func restoreFilesIfNeeded() {
        guard settings.reloadFiles, let d = UserDefaults.standard.data(forKey: "reloadList"),
              let list = try? C6FileList.parse(d, directory: URL(fileURLWithPath: "/")) else { return }
        items = list.entries.compactMap { e in
            guard var i = try? C6Item.load(url: e.url) else { return nil }
            i.loopMode = e.loop; i.stereoMode = e.stereo
            applySavedOptions(&i); return i
        }
        samplePosition = list.samplePosition
    }

    func removeSelected() {
        items.removeAll { selection.contains($0.id) }
        selection.removeAll()
        rememberFiles()
    }

    func move(from: IndexSet, to: Int) { items.move(fromOffsets: from, toOffset: to); rememberFiles() }

    func save(item: C6Item, to url: URL) {
        do {
            try Data(item.bytes).write(to: url, options: .atomic)
            if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].url = url; items[i].name = url.lastPathComponent }
            rememberFiles()
        } catch { lastError = "\(error)" }
    }

    /// Saves an audio item as a MIDI Sample Dump .syx (to the current Sample position).
    func saveAsSampleDump(item: C6Item, to url: URL) {
        do {
            let base = (item.name as NSString).deletingPathExtension
            guard var sample = item.sdsSampleToSend(name: base, maxBits: settings.maxSendBits) else { throw C6Error.unsupportedFile(item.name) }
            sample.mdName = AppModel.mdNameToSend(item, settings)
            var o = SDSSender.Options()
            o.extendedSDS = settings.extendedSDS; o.deviceNumber = settings.sdsDeviceNumber
            let bytes = sample.sdsFileBytes(sampleNumber: samplePosition, options: o)
            try Data(bytes).write(to: url, options: .atomic)
            append("Exported \(item.name) as a sample dump for slot \(targetSlot) (\(Format.bytes(bytes.count))) → \(url.lastPathComponent)")
        } catch { lastError = "\(error)" }
    }

    /// The Machinedrum name sent with a sample: the one typed for it, else (when "Send SPS-1UW
    /// Name" is on) the suggestion from its file name; nil sends none.
    nonisolated static func mdNameToSend(_ item: C6Item, _ settings: C6Settings) -> String? {
        if let typed = item.mdName.map(MDName.normalize), !typed.isEmpty { return typed }
        return settings.sendSPS1UWName ? MDName.suggest(forFileName: item.name) : nil
    }

    func setMDName(_ name: String, for id: C6Item.ID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let n = MDName.normalize(name)
        items[i].mdName = n.isEmpty ? nil : n
        saveOptions(items[i])
    }

    /// The 2× toggle in a sample's row.
    func toggleDoubleSpeed(_ id: C6Item.ID) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].canDoubleSpeed else { return }
        items[i].doubleSpeed.toggle()
        saveOptions(items[i])
    }

    /// The 22 kHz toggle in a sample's row.
    func toggleHalfRate(_ id: C6Item.ID) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].canHalveRate else { return }
        items[i].halfRate.toggle()
        saveOptions(items[i])
    }

    // Per-file options (22 kHz, MD name) survive relaunches; .c6 lists can't hold them.
    private static let optionsKey = "itemOptions"

    func saveOptions(_ item: C6Item) {
        guard let path = item.url?.path else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.optionsKey) ?? [:]
        var o: [String: Any] = ["half": item.halfRate, "double": item.doubleSpeed]
        if let n = item.mdName { o["mdName"] = n }
        all[path] = o
        UserDefaults.standard.set(all, forKey: Self.optionsKey)
    }

    func applySavedOptions(_ item: inout C6Item) {
        guard let path = item.url?.path,
              let o = UserDefaults.standard.dictionary(forKey: Self.optionsKey)?[path] as? [String: Any] else { return }
        if let h = o["half"] as? Bool { item.halfRate = h }
        if let d = o["double"] as? Bool { item.doubleSpeed = d }
        if let n = o["mdName"] as? String { item.mdName = n }
    }

    func cycleLoop() {
        for i in items.indices where selection.contains(items[i].id) {
            let all = C6Item.LoopMode.allCases
            items[i].loopMode = all[(all.firstIndex(of: items[i].loopMode)! + 1) % all.count]
        }
        rememberFiles()
    }

    func cycleStereo() {
        for i in items.indices where selection.contains(items[i].id) {
            let all = C6Item.StereoMode.allCases
            items[i].stereoMode = all[(all.firstIndex(of: items[i].stereoMode)! + 1) % all.count]
        }
        rememberFiles()
    }

    // MARK: Transfers

    func stop() {
        cancelFlag.cancel()
        receiver?.finish()
    }

    /// Slots the selected samples would go to (nil when no samples are selected).
    var samplePlan: SlotPlan? {
        let n = selectedItems.filter(\.isAudio).count
        return n > 0 ? SlotPlan(start: targetSlot, count: n, slotCount: settings.sampleSlots) : nil
    }

    /// Sends the selection. Samples go to consecutive slots from the chosen one (which stays put);
    /// `overflow` says what happens past the device's last slot.
    func send(overflow: SlotPlan.Overflow = .stop) {
        guard !isBusy else { return }
        guard let conn = connection else { lastError = "\(C6Error.notConnected)"; return }
        let queue = selectedItems
        guard !queue.isEmpty else { return }
        let flag = CancelFlag(); cancelFlag = flag
        let settings = self.settings
        let tm1 = self.tm1
        var speed = turbo
        let tm1Present = self.tm1Present
        let bus = self.bus
        // SDS sample number (slot − 1) for each sample; missing = past the last slot, skipped.
        var numbers: [C6Item.ID: Int] = [:]
        let audioItems = queue.filter(\.isAudio)
        if let plan = samplePlan {
            for (item, slot) in zip(audioItems, plan.slots(overflow)) { if let slot { numbers[item.id] = slot - 1 } }
        }
        for item in queue { setStatus(item.id, .queued) }
        activity = .sending(item: queue[0].name, index: 0, count: queue.count, progress: .init(bytesDone: 0, bytesTotal: queue[0].byteCount, elapsed: 0))

        worker.async { [weak self] in
            if settings.autoTurbo, tm1Present, speed == .x1, let tm1, let limit = TurboSpeed(code: settings.turboLimit), limit > .x1 {
                if let s = tm1.setSpeed(limit) { speed = s; Task { @MainActor in self?.turbo = s; self?.append("TurboMIDI engaged at \(s.label)") } }
            }
            let lineRate = speed.bytesPerSecond * (1 - settings.pacingHeadroom)
            var paced = PacedSender(transport: conn, options: .init(bytesPerSecond: lineRate))
            paced.options.lookahead = 0.02
            for (index, item) in queue.enumerated() {
                if flag.isCancelled { Task { @MainActor in self?.setStatus(item.id, .cancelled) }; continue }
                let start = HostTime.now
                func report(_ done: Int, _ total: Int) {
                    let p = TransferProgress(bytesDone: done, bytesTotal: total, elapsed: HostTime.seconds(fromTicks: HostTime.now - start))
                    Task { @MainActor in
                        self?.activity = .sending(item: item.name, index: index, count: queue.count, progress: p)
                        self?.setStatus(item.id, .sending(p.fraction))
                    }
                }
                if item.isAudio {
                    guard let sampleNumber = numbers[item.id] else {
                        Task { @MainActor in self?.setStatus(item.id, .skipped("No slot left (stopped at slot \(settings.sampleSlots))")) }
                        continue
                    }
                    // WAV/AIFF → MIDI Sample Dump, with the SDS handshake when enabled.
                    let base = (item.name as NSString).deletingPathExtension
                    // At the file's rate, or resampled to 22.05 kHz when the item's 22k toggle is on.
                    guard var sample = item.sdsSampleToSend(name: base, maxBits: settings.maxSendBits) else {
                        Task { @MainActor in self?.setStatus(item.id, .failed(AudioFile.describe(item.bytes))) }; continue
                    }
                    sample.mdName = AppModel.mdNameToSend(item, settings)
                    var o = SDSSender.Options()
                    o.handshake = settings.sdsHandshake
                    o.extendedSDS = settings.extendedSDS
                    o.sendSPS1UWName = false   // the MD name is decided above
                    o.deviceNumber = settings.sdsDeviceNumber
                    o.startSampleNumber = sampleNumber
                    o.interPacketDelayMs = settings.delayMilliseconds
                    o.lineRate = lineRate
                    let sds = SDSSender(transport: conn, options: o)
                    let sub = bus.subscribe { _ = sds.handle($0) }
                    let r = sds.send([sample], progress: { p in report(p.bytesDone, p.bytesTotal) }, isCancelled: { flag.isCancelled })
                    bus.unsubscribe(sub)
                    let secs = HostTime.seconds(fromTicks: HostTime.now - start)
                    let number = sampleNumber
                    Task { @MainActor in
                        guard let self else { return }
                        switch r.outcome {
                        case .completed:
                            self.setStatus(item.id, .sent)
                            self.noteSent(item, toSampleNumber: number)
                            if item.canDoubleSpeed && item.doubleSpeed {
                                self.append("Slot \(number + 1) holds \(item.name) at 2× speed: set that track's PTCH to −36 on the MD to play it at its original speed")
                            }
                            self.append("Sent \(item.name) to slot \(number + 1) in \(Format.duration(secs)) at \(speed.label)"
                                        + " (\(r.packetsSent) packets, \(r.resends) resent\(r.openLoopSamples > 0 ? ", no handshake replies" : ""))")
                        case .cancelled: self.setStatus(item.id, .cancelled); self.append("Stopped sending \(item.name)")
                        case .remotelyCancelled: self.setStatus(item.id, .failed("Remotely cancelled")); self.append("\(item.name): remotely cancelled")
                        case let .failed(why): self.setStatus(item.id, .failed(why)); self.append("\(item.name): \(why)")
                        }
                    }
                    if r.outcome == .remotelyCancelled { flag.cancel() }
                    continue
                }
                // Raw SysEx: one paced stream per message, optional gap between messages.
                let data = item.sysex
                let total = data.byteCount
                var done = 0
                var result = PacedSender.Result.completed
                var at: UInt64? = nil
                for msg in data.messages {
                    let (r, end) = paced.send(msg[...], startAt: at, progress: { n in report(done + n, total) }, isCancelled: { flag.isCancelled })
                    done += msg.count
                    result = r
                    if r == .cancelled { break }
                    at = settings.delayMilliseconds > 0 ? end + HostTime.ticks(fromSeconds: settings.delayMilliseconds / 1000) : nil
                }
                let secs = HostTime.seconds(fromTicks: HostTime.now - start)
                Task { @MainActor in
                    guard let self else { return }
                    if result == .completed {
                        self.setStatus(item.id, .sent)
                        self.append("Sent \(item.name): \(Format.bytes(total)) in \(Format.duration(secs)) at \(speed.label)")
                    } else { self.setStatus(item.id, .cancelled); self.append("Stopped sending \(item.name)") }
                }
            }
            Task { @MainActor in self?.activity = .idle }
        }
    }

    func receive() {
        guard !isBusy else { return }
        guard let conn = connection else { lastError = "\(C6Error.notConnected)"; return }
        let settings = self.settings
        let r = SysExReceiver()
        // Sample dumps are split into one item per sample (C6 Rec Format) and acknowledged.
        var sdsOptions = SDSReceiver.Options()
        sdsOptions.handshake = settings.sdsHandshake
        sdsOptions.pace = settings.sdsReceivePace(at: turbo)
        sdsOptions.splitDumps = settings.recFormat != .none
        let replies = LoggingTransport(conn)
        let sds = SDSReceiver(transport: replies, options: sdsOptions)
        FileLog.shared.write("Receive: start (SDS handshake \(sdsOptions.handshake ? "on" : "off"), pace \(sdsOptions.pace), split \(sdsOptions.splitDumps), rec format \(settings.recFormat.rawValue))")
        let seen = CancelFlag()  // reused as a simple counter guard for the first-message log
        var seenCount = 0
        let seenLock = NSLock()
        let split = settings.recFormat != .none
        r.filter = { msg in
            if TM1Message.parseStatus(msg) != nil { return false }
            return !(split && msg.count > 1 && msg[1] == 0x7E)   // SDS goes to its own items
        }
        receiver = r
        let sub = bus.subscribe { msg in
            seenLock.lock(); seenCount += 1; let n = seenCount; seenLock.unlock()
            if n <= 4 || n % 50 == 0 {
                FileLog.shared.write("  ← msg #\(n) (\(msg.count) bytes): " + msg.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "))
            }
            let consumed = sds.handle(msg)
            if consumed, split { r.noteActivity(bytes: msg.count) }
            r.handle(msg)
        }
        _ = seen
        sds.onEvent = { [weak self] event in
            FileLog.shared.write("  SDS event: \(event)".prefix(200).description)
            if case let .retrying(n, attempt) = event {
                Task { @MainActor in self?.append("Sample \(n): bad packet — requesting it again (attempt \(attempt))") }
                return
            }
            if case let .cancelled(why) = event { Task { @MainActor in self?.append(why) }; return }
            guard case let .dump(d) = event else { return }
            Task { @MainActor in
                guard let self else { return }
                var counter = self.receivedCount + 1
                var name = SDSReceiver.itemName(for: d, recFormat: settings.recFormat, counter: &counter)
                self.receivedCount = counter - 1
                let taken = Set(self.items.map(\.name)), ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
                var k = 2
                while taken.contains(name) { name = "\(stem) \(k).\(ext)"; k += 1 }
                var item = C6Item(name: name, bytes: d.fileBytes(format: settings.recFormat))
                item.mdName = d.mdName.map(MDName.normalize).flatMap { $0.isEmpty ? nil : $0 }   // keeps it on a re-send
                self.items.append(item)
                self.append("Received slot \(d.sample.sampleNumber + 1) (\(d.sample.length) samples\(d.badPackets > 0 ? ", \(d.badPackets) bad packets" : "")) → \(name)")
            }
        }
        r.onMessage = { [weak self] _, s in Task { @MainActor in self?.activity = .receiving(bytes: s.byteCount, messages: s.messageCount) } }
        activity = .receiving(bytes: 0, messages: 0)
        let idle = settings.receiveIdleTimeout
        let flag = CancelFlag(); cancelFlag = flag
        worker.async { [weak self] in
            // Keep going while a sample dump is in progress (its packets bypass the SysEx receiver).
            let data = r.waitUntilIdle(idleTimeout: idle > 0 ? idle : .infinity, shouldStop: { flag.isCancelled })
            while sds.isDumpInProgress && !flag.isCancelled { Thread.sleep(forTimeInterval: 0.1) }
            let partial = sds.stop()
            let secs = r.activeDuration
            FileLog.shared.write("Receive: end; \(seenCount) messages seen, \(replies.sentCount) replies sent")
            Task { @MainActor in
                guard let self else { return }
                self.bus.unsubscribe(sub)
                self.receiver = nil
                self.activity = .idle
                if let partial, !partial.isComplete { self.append("Sample \(partial.sample.sampleNumber) was incomplete and was not kept") }
                guard !data.messages.isEmpty else { self.append("Receive finished"); return }
                self.receivedCount += 1
                // Named after the contents ("MD Kits 01–64 2026-10-16 11.58.07.syx"); C6 used "Received data N.syx".
                let item = C6Item(name: DumpNamer.fileName(for: data, taken: Set(self.items.map(\.name))), bytes: data.bytes)
                self.items.append(item)
                self.selection = [item.id]
                self.append("Received \(DumpNamer.describe(data) ?? "\(data.messages.count) messages"): \(Format.bytes(data.byteCount)) in \(Format.duration(secs)) → \(item.name)")
            }
        }
    }

    // MARK: DigiPRO

    var canConvertSelectionToDigiPRO: Bool {
        selectedItems.contains { $0.isAudio && ((try? AudioFile(bytes: $0.bytes))?.canConvertToDigiPRO ?? false) }
    }

    /// C6's [DigiPRO] button: converts each selected sample (its loop, or the whole file) to a
    /// Monomachine DigiPRO waveform, replacing the item in place.
    func convertSelectionToDigiPRO() {
        var slot = 0
        for i in items.indices where selection.contains(items[i].id) && items[i].isAudio {
            guard let audio = try? AudioFile(bytes: items[i].bytes), audio.canConvertToDigiPRO else { continue }
            let name = items[i].name
            let syx = DigiPRO.encode(samples: audio.digiPROSamples(stereo: items[i].stereoMode), slot: slot & 0x3F,
                                     name: DigiPRO.waveName(fromFileName: name))
            items[i].replaceBytes(syx, name: DigiPRO.syxFileName(fromFileName: name))
            append("Converted \(name) to DigiPRO waveform “\(DigiPRO.waveName(fromFileName: name))” (position \(slot & 0x3F))")
            slot += 1
        }
    }

    // MARK: Helpers

    func setStatus(_ id: C6Item.ID, _ s: C6Item.Status) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].status = s }
    }

    func append(_ text: String) {
        log.append(LogLine(text: text))
        if log.count > 500 { log.removeFirst(log.count - 500) }
        FileLog.shared.write(text)
    }
}

/// Mirrors the log panel to ~/Library/Logs/C2026/C2026.log (also used for MIDI diagnostics).
final class FileLog: @unchecked Sendable {
    static let shared = FileLog()
    private let queue = DispatchQueue(label: "c2026.log")
    private let handle: FileHandle?
    private let formatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/C2026")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("C2026.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func write(_ text: String) {
        let line = formatter.string(from: Date()) + "  " + text + "\n"
        queue.async { [handle] in try? handle?.write(contentsOf: Data(line.utf8)) }
    }
}

/// Passes sends through to a transport, logging SysEx replies (e.g. SDS ACKs) for diagnostics.
final class LoggingTransport: MIDITransport, @unchecked Sendable {
    let base: MIDITransport
    var onReceive: (([UInt8]) -> Void)? { get { base.onReceive } set { base.onReceive = newValue } }
    private let lock = NSLock()
    private(set) var sentCount = 0
    init(_ base: MIDITransport) { self.base = base }
    func sendStream(_ bytes: ArraySlice<UInt8>, at hostTime: UInt64?) {
        lock.lock(); sentCount += 1; let n = sentCount; lock.unlock()
        if n <= 3 || n % 50 == 0 { FileLog.shared.write("  → reply #\(n): " + bytes.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")) }
        base.sendStream(bytes, at: hostTime)
    }
    func flushScheduled() { base.flushScheduled() }
}

/// Thread-safe cancel flag shared with a worker.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}
