import C6Core
import Foundation

// `c2026` — command-line companion to the C2026 app (port listing, turbo control, monitoring,
// and scripted transfers). Usage: c2026 <command> [options]

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func hex(_ b: [UInt8], limit: Int = 48) -> String {
    let s = b.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
    return b.count > limit ? s + " … (\(b.count) bytes)" : s
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}

let inName = option("--in")
let outName = option("--out")
let command = args.first ?? "help"

let system: CoreMIDISystem
do { system = try CoreMIDISystem(clientName: "c2026") } catch { fail("\(error)") }

func pick(_ list: [MIDIEndpointInfo], _ name: String?) -> MIDIEndpointInfo {
    let online = list.filter { !$0.isOffline }
    if let name {
        guard let e = online.first(where: { $0.displayName.localizedCaseInsensitiveContains(name) }) else { fail("No port matching “\(name)”") }
        return e
    }
    guard let e = online.first(where: { $0.isTM1 }) else { fail("No TM-1 found; pass --in/--out") }
    return e
}

func openConnection(_ mode: CoreMIDIConnection.InputMode = .bytes) -> (CoreMIDIConnection, TM1Controller) {
    let src = pick(system.sources, inName), dst = pick(system.destinations, outName)
    do {
        let conn = try system.connect(source: src, destination: dst, inputMode: mode)
        let tm1 = TM1Controller(transport: conn)
        conn.onReceive = { tm1.handle($0) }
        return (conn, tm1)
    } catch { fail("\(error)") }
}

switch command {
case "ports":
    for e in system.sources where !e.isOffline { print("in : \(e.displayName)\(e.isTM1 ? "  [TM-1]" : "")") }
    for e in system.destinations where !e.isOffline { print("out: \(e.displayName)\(e.isTM1 ? "  [TM-1]" : "")") }

case "turbo":
    let (_, tm1) = openConnection()
    let sub = args.count > 1 ? args[1] : "status"
    if sub == "status" {
        guard let s = tm1.queryStatus() else { fail("No answer from a TM-1 on this port") }
        print("TM-1 speed: \(s.label) (code \(s.rawValue), \(s.baud) baud, \(Int(s.bytesPerSecond)) bytes/s)")
    } else {
        let wanted = TurboSpeed.allCases.first { $0.label.replacingOccurrences(of: "×", with: "") == sub.replacingOccurrences(of: "x", with: "") }
            ?? UInt8(sub).flatMap(TurboSpeed.init(code:))
        guard let wanted else { fail("Unknown speed “\(sub)”. Use one of: " + TurboSpeed.allCases.map { $0.label }.joined(separator: " ")) }
        guard let s = tm1.setSpeed(wanted) else { fail("No answer from the TM-1") }
        print("Requested \(wanted.label); TM-1 reports \(s.label)")
    }

case "exchange":
    // c2026 exchange "F0 00 20 3C 02 00 53 00 F7" [--listen 3]
    let listen = Double(option("--listen") ?? "3") ?? 3
    let text = args.dropFirst().joined(separator: " ")
    let bytes = text.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { UInt8($0, radix: 16) }
    guard bytes.first == 0xF0, bytes.last == 0xF7 else { fail("Give one SysEx message as hex, F0 … F7") }
    let (conn, tm1) = openConnection()
    let speed = tm1.queryStatus() ?? .x1
    print("TM-1 at \(speed.label); sending \(hex(bytes))")
    var first: Date?, last = Date(), total = 0
    conn.onReceive = { msg in
        if TM1Message.parseStatus(msg) != nil { return }
        let now = Date(); if first == nil { first = now }; last = now; total += msg.count
        let id = msg.count > 6 ? String(format: "id %02X", msg[6]) : ""
        print("  ← \(msg.count) bytes \(id)  checksum \(ElektronChecksum.isValid(msg) ? "OK" : "n/a or bad")  \(hex(msg, limit: 12))")
    }
    let sent = Date()
    conn.send(bytes)
    Thread.sleep(forTimeInterval: listen)
    if let first {
        let span = last.timeIntervalSince(first)
        print(String(format: "received %d bytes; first reply after %.1f ms; %.1f ms from first to last message", total, first.timeIntervalSince(sent) * 1000, span * 1000))
    } else { print("no reply") }

case "receive":
    // c2026 receive [--save dump.syx] [--idle 2] [--timeout 120]
    let out = option("--save")
    let idle = Double(option("--idle") ?? "2") ?? 2
    let timeout = Double(option("--timeout") ?? "120") ?? 120
    let compare = args.contains("--compare")
    let (conn, tm1) = openConnection(.bytes)
    let speed = tm1.queryStatus() ?? .x1
    let receiver = SysExReceiver()
    receiver.onMessage = { msg, s in
        let id = msg.count > 6 && Array(msg[1...3]) == Elektron.manufacturerID ? String(format: "dev %02X id %02X", msg[4], msg[6]) : "non-Elektron"
        print("  ← #\(s.messageCount) \(msg.count) bytes  \(id)  checksum \(ElektronChecksum.isValid(msg) ? "OK" : "-")")
    }
    conn.onReceive = { tm1.handle($0); receiver.handle($0) }
    // --compare: also receive the same stream through CoreMIDI's UMP conversion.
    var umpConn: CoreMIDIConnection?
    let umpReceiver = SysExReceiver()
    var realtimeSeen = 0
    if compare {
        let (c, _) = openConnection(.ump)
        c.onReceive = { umpReceiver.handle($0) }
        umpConn = c
        // Count realtime bytes on the byte path to correlate with damage.
        let (raw, _) = openConnection(.bytes)
        _ = raw
    }
    print("TM-1 at \(speed.label). Waiting for SysEx (stops \(idle)s after the last message)…")
    let data = receiver.waitUntilIdle(idleTimeout: idle, overallTimeout: timeout)
    if compare {
        let u = umpReceiver.finish()
        let okBytes = data.messages.filter { ElektronChecksum.isValid($0) }.count
        let okUMP = u.messages.filter { ElektronChecksum.isValid($0) }.count
        print("byte-stream input: \(data.messages.count) messages, \(okBytes) valid checksums")
        print("UMP input        : \(u.messages.count) messages, \(okUMP) valid checksums")
        _ = umpConn; _ = realtimeSeen
    }
    let secs = receiver.activeDuration
    let valid = data.messages.filter { ElektronChecksum.isValid($0) }.count
    print("Valid Elektron checksums: \(valid)/\(data.messages.count); split messages repaired: \(conn.repairedSplits)")
    print(String(format: "Received %d messages, %d bytes in %.3f s%@", data.messages.count, data.byteCount, secs,
                 secs > 0 ? String(format: " (%.1f kB/s)", Double(data.byteCount) / secs / 1000) : ""))
    if let out {
        do { try data.write(to: URL(fileURLWithPath: out)); print("Saved \(out)") } catch { fail("\(error)") }
    }

case "info":
    // c2026 info <file> — Type and File Info as the app shows them (no MIDI).
    guard args.count > 1 else { fail("Usage: c2026 info <file>") }
    do {
        let item = try C6Item.load(url: URL(fileURLWithPath: args[1]))
        let data = item.sysex
        print("Type: \(item.typeLabel)   Size: \(Format.bytes(item.byteCount))   SysEx messages: \(data.messages.count)")
        print(item.info.isEmpty ? "(no File Info)" : item.info)
        if !item.isAudio { print("Receive name: " + DumpNamer.fileName(for: data) + (DumpNamer.describe(data).map { "  (\($0))" } ?? "")) }
    } catch { fail("\(error)") }
    exit(0)

case "scan":
    // c2026 scan [--slots 1-48] [--check] — list the device's samples from dump headers (no audio).
    let range = (option("--slots") ?? "1-48").split(separator: "-").compactMap { Int($0) }
    guard let lo = range.first, let hi = range.last, lo >= 1, hi >= lo else { fail("--slots like 1-48") }
    let check = args.contains("--check")
    let (conn, tm1) = openConnection()
    let speed = tm1.queryStatus() ?? .x1
    let scanner = SampleScanner(transport: conn)
    if let v = option("--settle").flatMap(Double.init) { scanner.options.settle = v / 1000 }
    conn.onReceive = { if !tm1.handle($0) { scanner.handle($0) } }
    print("TM-1 at \(speed.label); scanning slots \(lo)–\(hi)…")
    let t0 = Date()
    let found = scanner.scan(Array((lo - 1)...(hi - 1))) { n, info in
        if let i = info {
            print(String(format: "  slot %2d  %-4@  %7d frames  %5.2f s  %2d-bit  %5d Hz%@", i.slot, (i.name ?? "") as NSString, i.length,
                         i.duration, i.bits, i.sampleRate, i.hasLoop ? "  loop \(i.loopStart)–\(i.loopEnd)" : ""))
        } else if check { print("  slot \(n + 1)  (empty / no answer)") }
    }
    let frames = found.reduce(0) { $0 + $1.length }
    print(String(format: "%d samples, %d frames (%.1f s at 44.1 kHz) in %.1f s", found.count, frames, Double(frames) / 44100, Date().timeIntervalSince(t0)))
    for m in scanner.mismatches { print("  asked for sample \(m.requested) (slot \(m.requested + 1)), got sample \(m.got)") }
    if check {
        Thread.sleep(forTimeInterval: 3)
        print("Data packets after the last CANCEL: \(scanner.packetsSinceRequest) (0 = the device stopped as asked)")
    }

case "receive-sample":
    // c2026 receive-sample [--request N] [--no-ack] [--save out.wav] [--timeout s]
    // Receives one MIDI Sample Dump (optionally asking for sample number N first) and times its packets.
    let request = option("--request").flatMap { Int($0) }
    let save = option("--save")
    let timeout = Double(option("--timeout") ?? "60") ?? 60
    // --mode ack (default, like C6) | fast (silent; NAK a bad packet, then ACK the rest) | silent (no replies)
    let mode = option("--mode") ?? (args.contains("--no-ack") ? "silent" : "ack")
    guard ["ack", "fast", "silent"].contains(mode) else { fail("--mode must be ack, fast or silent") }
    let ack = mode != "silent"
    let corrupt = option("--corrupt").flatMap { Int($0) }   // test: damage packet N once (receiver should NAK it)
    let (conn, tm1) = openConnection()
    let speed = tm1.queryStatus() ?? .x1
    var o = SDSReceiver.Options(); o.handshake = ack; o.pace = mode == "fast" ? .fast(retries: 2) : .ackEachPacket
    o.expectedSampleNumber = request
    var corrupted = false
    var seenNumbers: [Int] = []
    let rx = SDSReceiver(transport: conn, options: o)
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var stamps: [Double] = []
    var result: SDSReceiver.ReceivedDump?
    let t0 = Date()
    rx.onEvent = { e in
        switch e {
        case let .started(n, len, bits): print("Header: sample \(n), \(len) samples, \(bits)-bit")
        case let .dump(d): result = d; done.signal()
        case let .retrying(n, a): print("Bad packet: cancelled sample \(n), requesting it again (attempt \(a))")
        case let .unexpectedSample(want, got):
            print("Device answered with sample \(got) instead of \(want): cancelled, asking again")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                conn.send([0xF0, 0x7E, 0x00, 0x03, UInt8(want & 0x7F), UInt8((want >> 7) & 0x7F), 0xF7])
            }
        case .remotelyCancelled, .cancelled: print("Cancelled: \(e)"); done.signal()
        default: break
        }
    }
    conn.onReceive = { m in
        if tm1.handle(m) { return }
        var m = m
        if SDSMessage.isDataPacket(m) {
            lock.lock(); stamps.append(Date().timeIntervalSince(t0)); seenNumbers.append(Int(m[4])); lock.unlock()
            if let c = corrupt, !corrupted, Int(m[4]) == c { m[10] ^= 0x01; corrupted = true; print("  (damaged packet \(c) on purpose)") }
        }
        _ = rx.handle(m)
    }
    print("TM-1 at \(speed.label); replies: \(mode)" + (request.map { "; requesting sample \($0)" } ?? "; waiting for a dump"))
    if let n = request { conn.send([0xF0, 0x7E, 0x00, 0x03, UInt8(n & 0x7F), UInt8((n >> 7) & 0x7F), 0xF7]) }
    // --timeout applies until the dump starts; after that, wait for the whole dump and give up
    // only after 6 s without packets (stopping mid-dump would leave a Machinedrum waiting).
    let begin = Date()
    while done.wait(timeout: .now() + 0.25) == .timedOut {
        lock.lock(); let last = stamps.last; lock.unlock()
        if rx.isDumpInProgress || last != nil {
            if let last, Date().timeIntervalSince(t0) - last > 6 { print("Device stopped sending; cancelling"); _ = rx.stop(); break }
        } else if Date().timeIntervalSince(begin) > timeout { print("No dump within \(Int(timeout)) s"); break }
    }
    lock.lock(); let s = stamps; lock.unlock()
    if s.count > 1 {
        let gaps = zip(s.dropFirst(), s).map { ($0 - $1) * 1000 }.sorted()
        print(String(format: "Packets: %d in %.2f s; gap median %.1f ms (min %.1f, max %.1f)", s.count, s.last! - s.first!,
                     gaps[gaps.count / 2], gaps.first!, gaps.last!))
    }
    if let c = corrupt {
        lock.lock(); let n = seenNumbers.filter { $0 == c }.count; lock.unlock()
        print("Packet \(c) arrived \(n) time(s)" + (n > 1 ? " — the device resent it after the NAK" : ""))
    }
    if let d = result {
        var counter = 1
        print("C2026 would name it: " + SDSReceiver.itemName(for: d, recFormat: .wav, counter: &counter))
        print("Got sample \(d.sample.sampleNumber) “\(d.sample.name ?? "")”: \(d.sample.length) samples, \(d.sample.bits)-bit, \(d.sample.sampleRate) Hz, bad packets \(d.badPackets)")
        if let save {
            try? Data(d.fileBytes(format: save.lowercased().hasSuffix(".aiff") ? .aiff : save.lowercased().hasSuffix(".syx") ? .sds : .wav))
                .write(to: URL(fileURLWithPath: save))
            print("Saved \(save)")
        }
    }
    exit(0)

case "preview":
    // c2026 preview <file.wav> [--22k] [--2x] [--smooth] [--raw] --save out.wav (gritty by default) — what ▶ plays (no MIDI)
    guard args.count > 1, let out = option("--save") else { fail("Usage: c2026 preview <file> [--22k] [--2x] [--smooth] --save out.wav") }
    do {
        var item = try C6Item.load(url: URL(fileURLWithPath: args[1]))
        item.halfRate = args.contains("--22k"); item.doubleSpeed = args.contains("--2x")
        guard let wav = item.previewAudio(asMachinedrum: !args.contains("--raw"),
                                          interpolation: args.contains("--smooth") ? .linear : .hold) else { fail("Not a sample") }
        try Data(wav).write(to: URL(fileURLWithPath: out))
        print("\(out): MD memory \(ByteFormat.memory((item.sendFrames ?? 0) * 2))")
    } catch { fail("\(error)") }
    exit(0)

case "wav2syx":
    // c2026 wav2syx <file.wav|aiff> [--slot N] [--save out.syx] [--stereo mix|left|right] — no MIDI
    guard args.count > 1 else { fail("Usage: c2026 wav2syx <file> [--slot N] [--save out.syx]") }
    let slot = Int(option("--slot") ?? "1") ?? 1
    let stereo: C6Item.StereoMode = ["left": .left, "right": .right][option("--stereo") ?? ""] ?? .mix
    let url = URL(fileURLWithPath: args[1])
    let out = option("--save") ?? url.deletingPathExtension().appendingPathExtension("syx").path
    do {
        var item = try C6Item.load(url: url)
        item.stereoMode = stereo; item.halfRate = args.contains("--22k"); item.doubleSpeed = args.contains("--2x")
        guard let sample = item.sdsSampleToSend(name: url.deletingPathExtension().lastPathComponent,
                                                maxBits: args.contains("--keep-bits") ? nil : 16) else { fail("Not a sample") }
        let bytes = sample.sdsFileBytes(sampleNumber: max(0, slot - 1))
        try Data(bytes).write(to: URL(fileURLWithPath: out), options: .atomic)
        print("\(url.lastPathComponent) → \(out) (\(Format.bytes(bytes.count)), sample #\(max(0, slot - 1)) = MD slot \(slot))")
    } catch { fail("\(error)") }
    exit(0)

case "send-sample":
    // c2026 send-sample <file.wav|aiff> --slot N [--no-handshake] [--sps-name] [--stereo mix|left|right]
    guard args.count > 1 else { fail("Usage: c2026 send-sample <file> --slot N") }
    guard let slotText = option("--slot"), let slot = Int(slotText), slot >= 1 else { fail("Give the MD slot (1-based) with --slot") }
    let handshake = !args.contains("--no-handshake")
    let spsName = args.contains("--sps-name")
    let mdName = option("--md-name")
    let stereo: C6Item.StereoMode = ["left": .left, "right": .right][option("--stereo") ?? ""] ?? .mix
    let url = URL(fileURLWithPath: args[1])
    let audio: AudioFile
    do { audio = try AudioFile(contentsOf: url) } catch { fail("\(error)") }
    print(audio.infoText)
    let base = url.deletingPathExtension().lastPathComponent
    // Same conversion as the app: --22k, --2x, and 16-bit unless --keep-bits.
    guard var item = try? C6Item.load(url: url) else { fail("Can't read \(url.path)") }
    item.stereoMode = stereo; item.halfRate = args.contains("--22k"); item.doubleSpeed = args.contains("--2x")
    guard var sample = item.sdsSampleToSend(name: base, maxBits: args.contains("--keep-bits") ? nil : 16) else { fail("Not a sample") }
    if item.doubleSpeed { print("2× speed: set the track's PTCH to −36 on the MD (one octave down)") }
    sample.mdName = mdName ?? (spsName ? MDName.suggest(forFileName: url.lastPathComponent) : nil)
    if let n = sample.mdName { print("MD name: \(MDName.normalize(n))") }
    let (conn, tm1) = openConnection()
    let speed = tm1.queryStatus() ?? .x1
    var opts = SDSSender.Options()
    opts.handshake = handshake
    opts.sendSPS1UWName = false   // decided above (--md-name / --sps-name)
    opts.startSampleNumber = slot - 1          // SDS numbers are 0-based; MD slots are shown 1-based
    opts.lineRate = speed.bytesPerSecond * 0.98
    let sender = SDSSender(transport: conn, options: opts)
    conn.onReceive = { msg in if !tm1.handle(msg) { _ = sender.handle(msg) } }
    print("Sending \(url.lastPathComponent) as sample #\(slot - 1) (slot \(slot)) at \(speed.label), handshake \(handshake ? "on" : "off")")
    let start = HostTime.now
    var lastPrint = 0
    let report = sender.send([sample], progress: { p in
        let pct = p.samplesTotal > 0 ? p.samplesDone * 100 / p.samplesTotal : 0
        if pct >= lastPrint + 25 || p.samplesDone == p.samplesTotal { print("  \(pct)%  (\(p.samplesDone)/\(p.samplesTotal) samples)"); lastPrint = pct }
    })
    let secs = HostTime.seconds(fromTicks: HostTime.now - start)
    print(String(format: "%@  %.3f s; packets %d, resends %d, timeouts %d, waits %d%@", report.outcome.statusText, secs,
                 report.packetsSent, report.resends, report.timeouts, report.waits,
                 report.openLoopSamples > 0 ? " (fell back to open loop)" : ""))

case "send":
    // c2026 send file.syx [--gap ms] [--headroom 0.02] — paced at the TM-1's current TurboMIDI speed.
    let gap = Double(option("--gap") ?? "0") ?? 0
    let firstGap = Double(option("--first-gap") ?? "0") ?? 0   // pause after the first message (e.g. an SDS header)
    let headroom = Double(option("--headroom") ?? "0.02") ?? 0.02
    guard args.count > 1 else { fail("Usage: c2026 send <file.syx>") }
    let url = URL(fileURLWithPath: args[1])
    let data: SysExData
    do { data = try SysExData(contentsOf: url) } catch { fail("\(error)") }
    let (conn, tm1) = openConnection()
    let speed = tm1.queryStatus() ?? .x1
    conn.onReceive = { msg in
        if tm1.handle(msg) { return }
        print("  ← \(msg.count) bytes: \(hex(msg, limit: 16))")
    }
    var sender = PacedSender(transport: conn, options: .init(bytesPerSecond: speed.bytesPerSecond * (1 - headroom)))
    print("Sending \(url.lastPathComponent): \(data.messages.count) messages, \(data.byteCount) bytes at \(speed.label)" + (gap > 0 ? ", \(gap) ms gap" : ""))
    let start = HostTime.now
    var at: UInt64? = nil
    var done = 0
    for (i, msg) in data.messages.enumerated() {
        let (_, end) = sender.send(msg[...], startAt: at)
        done += msg.count
        let pause = i == 0 && firstGap > 0 ? firstGap : gap
        at = pause > 0 ? end + HostTime.ticks(fromSeconds: pause / 1000) : end
        if (i + 1) % 16 == 0 || i == data.messages.count - 1 { print("  sent \(i + 1)/\(data.messages.count)") }
    }
    let secs = HostTime.seconds(fromTicks: HostTime.now - start)
    print(String(format: "Done: %d bytes in %.3f s (%.1f kB/s; line rate %.1f kB/s)", done, secs, Double(done) / secs / 1000, speed.bytesPerSecond / 1000))
    Thread.sleep(forTimeInterval: 1.0) // catch any reply from the device
    _ = sender.duration(ofBytes: 0)

case "rawlog":
    // c2026 rawlog --save prefix [--idle 4] — logs raw CoreMIDI packets from both input paths.
    let prefix = option("--save") ?? "rawlog"
    let idle = Double(option("--idle") ?? "4") ?? 4
    let (umpConn, _) = openConnection(.ump)
    let (byteConn, tm1) = openConnection(.bytes)
    let lock = NSLock()
    var umpLines: [String] = [], byteLines: [String] = []
    var last = Date.distantFuture, first: Date?
    umpConn.onRawUMP = { t, w in
        let s = "\(t) " + w.map { String(format: "%08X", $0) }.joined(separator: " ")
        let isSysEx = w.contains { $0 >> 28 == 0x3 }
        lock.lock(); umpLines.append(s); if isSysEx { last = Date(); if first == nil { first = last } }; lock.unlock()
    }
    byteConn.onRawBytes = { t, b in
        let s = "\(t) " + b.map { String(format: "%02X", $0) }.joined(separator: " ")
        lock.lock(); byteLines.append(s); lock.unlock()
    }
    byteConn.onReceive = { tm1.handle($0) }
    print("Logging raw packets… (stops \(idle)s after data stops)")
    while true {
        Thread.sleep(forTimeInterval: 0.2)
        lock.lock(); let l = last; lock.unlock()
        if Date().timeIntervalSince(l) > idle { break }
    }
    try? umpLines.joined(separator: "\n").write(toFile: prefix + "-ump.txt", atomically: true, encoding: .utf8)
    try? byteLines.joined(separator: "\n").write(toFile: prefix + "-bytes.txt", atomically: true, encoding: .utf8)
    print("UMP packets: \(umpLines.count), byte packets: \(byteLines.count) → \(prefix)-ump.txt / -bytes.txt")

case "monitor":
    let (conn, tm1) = openConnection()
    let t0 = Date()
    conn.onReceive = { msg in
        if let s = TM1Message.parseStatus(msg) { print(String(format: "+%8.3f  TM-1 status: %@", Date().timeIntervalSince(t0), s.label)) }
        else { print(String(format: "+%8.3f  %@", Date().timeIntervalSince(t0), hex(msg))) }
        _ = tm1.handle(msg)
    }
    print("Listening… (Ctrl-C to stop)")
    dispatchMain()

default:
    print("""
    c2026 — command-line companion to C2026 (Elektron C6 rebuild)

      c2026 ports                     list MIDI ports
      c2026 turbo [status]            show the TM-1 TurboMIDI speed
      c2026 turbo <1x|2x|…|20x>       request a speed (the TM-1 negotiates with the device)
      c2026 monitor                   print incoming MIDI
      c2026 exchange <hex F0…F7>      send one SysEx and show what comes back [--listen secs]
      c2026 receive [--save f.syx]    receive a dump; stops after --idle secs of silence (default 2)
      c2026 send <f.syx> [--gap ms]   send a SysEx file, paced at the TM-1's TurboMIDI speed
      c2026 send-sample <f.wav> --slot N [--md-name ABCD | --sps-name] [--22k] [--2x] [--keep-bits]   send a WAV/AIFF as a sample dump
      c2026 wav2syx <f.wav> [--slot N]     convert a WAV/AIFF to a sample-dump .syx (no MIDI)
      c2026 info <file>               show Type and File Info as the app does

      --in <name> / --out <name>   choose ports (default: the TM-1)
    """)
}
