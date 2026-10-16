import C6Core
import Foundation

/// Device Samples: listing the device's slots, downloading them, and memory projections.
extension AppModel {
    var memory: SampleMemory { settings.sampleMemory }
    var deviceUsedBytes: Int { memory.used(by: deviceSlots) }

    /// Memory effect of sending the selected samples to their planned slots (nil: none selected).
    func selectionProjection(overflow: SlotPlan.Overflow = .stop) -> SampleMemory.Projection? {
        let audio = selectedItems.filter(\.isAudio)
        guard let plan = samplePlan, !audio.isEmpty else { return nil }
        return memory.project(newFrames: audio.map { $0.sendFrames ?? 0 }, into: plan.slots(overflow), current: deviceSlots)
    }

    /// Reads every slot's header and name (no audio is transferred).
    func scanDevice() {
        guard !isBusy else { return }
        guard let conn = connection else { lastError = "\(C6Error.notConnected)"; return }
        let total = settings.sampleSlots
        let flag = CancelFlag(); cancelFlag = flag
        activity = .scanning(done: 0, total: total)
        let scanner = SampleScanner(transport: conn)
        let sub = bus.subscribe { scanner.handle($0) }
        worker.async { [weak self] in
            var done = 0
            let found = scanner.scan(Array(0..<total), isCancelled: { flag.isCancelled }) { _, _ in
                done += 1
                let d = done
                Task { @MainActor in self?.activity = .scanning(done: min(d, total), total: total) }
            }
            Task { @MainActor in
                guard let self else { return }
                self.bus.unsubscribe(sub)
                self.activity = .idle
                if flag.isCancelled && found.isEmpty { self.append("Device scan stopped"); return }
                self.deviceSlots = found
                self.deviceScanDate = Date()
                self.append("Device scan: \(found.count) of \(total) slots used, \(ByteFormat.memory(self.deviceUsedBytes)) of \(ByteFormat.memory(self.memory.totalBytes))")
            }
        }
    }

    /// Downloads the given slots (1-based) into the list, one after another, using Dump Requests.
    func downloadSlots(_ slots: [Int]) {
        guard !isBusy, !slots.isEmpty else { return }
        guard let conn = connection else { lastError = "\(C6Error.notConnected)"; return }
        let settings = self.settings
        let flag = CancelFlag(); cancelFlag = flag
        var o = SDSReceiver.Options()
        o.pace = settings.sdsReceivePace(at: turbo)
        let rx = SDSReceiver(transport: conn, options: o)
        let lock = NSLock()
        var lastActivity = Date()
        let sub = bus.subscribe { m in
            if rx.handle(m) { lock.lock(); lastActivity = Date(); lock.unlock() }
        }
        activity = .downloading(slot: slots[0], index: 0, count: slots.count, received: 0, total: 0)
        worker.async { [weak self] in
            for (index, slot) in slots.enumerated() where !flag.isCancelled {
                let done = DispatchSemaphore(value: 0)
                var result: SDSReceiver.ReceivedDump?
                var wrong = false
                rx.options.expectedSampleNumber = slot - 1
                rx.onEvent = { e in
                    switch e {
                    case let .progress(received, total):
                        Task { @MainActor in self?.activity = .downloading(slot: slot, index: index, count: slots.count, received: received, total: total) }
                    case let .dump(d): result = d; done.signal()
                    case .cancelled, .remotelyCancelled: done.signal()
                    case .unexpectedSample: wrong = true; done.signal()
                    case let .retrying(_, attempt):
                        Task { @MainActor in self?.append("Slot \(slot): bad packet — requesting it again (attempt \(attempt))") }
                    default: break
                    }
                }
                for attempt in 0..<3 {
                    wrong = false
                    lock.lock(); lastActivity = Date(); lock.unlock()
                    conn.send(SDSMessage.dumpRequest(device: settings.sdsDeviceNumber, sampleNumber: slot - 1).bytes())
                    // Wait for the dump; give up if the device stays silent (empty slot) or stops sending.
                    while done.wait(timeout: .now() + 0.25) == .timedOut {
                        if flag.isCancelled { _ = rx.stop(); break }
                        lock.lock(); let quiet = Date().timeIntervalSince(lastActivity); lock.unlock()
                        if quiet > 4 { _ = rx.stop(); break }
                    }
                    // The device answered with another sample: it has been cancelled; ask again.
                    guard wrong, attempt < 2, !flag.isCancelled else { break }
                    Thread.sleep(forTimeInterval: 0.3)
                }
                let d = result
                Task { @MainActor in
                    guard let self else { return }
                    guard let d, d.isComplete else { self.append("Slot \(slot): nothing received"); return }
                    var counter = self.receivedCount + 1
                    var name = SDSReceiver.itemName(for: d, recFormat: settings.recFormat == .none ? .wav : settings.recFormat, counter: &counter)
                    let taken = Set(self.items.map(\.name)), ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
                    var k = 2
                    while taken.contains(name) { name = "\(stem) \(k).\(ext)"; k += 1 }
                    var item = C6Item(name: name, bytes: d.fileBytes(format: settings.recFormat == .none ? .wav : settings.recFormat))
                    item.mdName = d.mdName.map(MDName.normalize).flatMap { $0.isEmpty ? nil : $0 }
                    self.items.append(item)
                    self.append("Downloaded slot \(slot) → \(name) (\(d.sample.length) frames)")
                }
                Thread.sleep(forTimeInterval: 0.3)   // let the device settle before the next request
            }
            Task { @MainActor in
                self?.bus.unsubscribe(sub)
                self?.activity = .idle
            }
        }
    }

    /// Keeps the scanned slot list current after a successful sample send.
    func noteSent(_ item: C6Item, toSampleNumber n: Int) {
        guard deviceScanDate != nil, let frames = item.sendFrames else { return }
        let info = SlotInfo(sampleNumber: n, name: AppModel.mdNameToSend(item, settings), length: frames,
                            bits: 16, sampleRate: item.sendRate ?? 44100, loopStart: 0, loopEnd: 0, loopType: 0x7F)
        deviceSlots.removeAll { $0.sampleNumber == n }
        deviceSlots.append(info)
        deviceSlots.sort { $0.sampleNumber < $1.sampleNumber }
    }
}
