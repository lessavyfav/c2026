import Foundation

/// Names received SysEx after what it contains, e.g. "MD Kit 01 BELLKIT 2026-10-16 11.58.07.syx",
/// "MD Kits 01–64 …", "MD Pattern A01 …" or "MD 8 Globals, 64 Kits, 128 Patterns, 32 Songs …".
/// (C6 named every receive "Received data N.syx".)
public enum DumpNamer {
    /// What a recognised Elektron message is.
    public struct Entry: Equatable, Sendable {
        public var device: String          // "MD", "MM", "A4", …
        public var kind: String            // "Kit", "Pattern", …
        public var position: Int?          // slot as stored on the device (0-based)
        public var name: String?           // kit / song name when the dump carries one
    }

    static let deviceNames: [UInt8: String] = [0x01: "Sidstation", 0x02: "MD", 0x03: "MM", 0x05: "OT", 0x06: "A4", 0x07: "AR"]

    /// Message-ID → kind, per device family (from C6's recognizer, specs/10-recognition.md).
    static func kind(device: UInt8, id: UInt8) -> String? {
        switch device {
        case 0x02, 0x03:
            switch id {
            case 0x50: return "Global"
            case 0x52: return "Kit"
            case 0x67: return "Pattern"
            case 0x69: return "Song"
            case 0x5D where device == 0x03: return "DigiPRO Wave"
            case 0x7E, 0x7F: return "OS Upgrade"
            default: return nil
            }
        case 0x06, 0x07:
            switch id {
            case 0x52: return "Kit"
            case 0x53: return "Sound"
            case 0x54: return "Pattern"
            case 0x55: return "Song"
            case 0x56: return "Settings"
            case 0x57: return "Global"
            case 0x7E, 0x7F: return "OS Upgrade"
            default: return nil
            }
        case 0x05: return id == 0x7E || id == 0x7F ? "OS Upgrade" : nil
        default: return nil
        }
    }

    /// Recognises one message (nil for non-Elektron or unknown types).
    public static func entry(for m: [UInt8]) -> Entry? {
        guard m.count > 9, m[0] == 0xF0, Array(m[1...3]) == Elektron.manufacturerID,
              let dev = deviceNames[m[4]], let kind = kind(device: m[4], id: m[6]) else { return nil }
        // Machinedrum / Monomachine dumps: ID, version, revision, original position, then the name
        // (kits and songs), plain 7-bit ASCII up to 16 characters — e.g. a real MD kit: 52 40 01 00 "BELLKIT".
        var position: Int?
        var name: String?
        if m[4] == 0x02 || m[4] == 0x03, kind != "OS Upgrade" {
            position = Int(m[9])
            if kind == "Kit" || kind == "Song", m.count > 26 { name = ascii(m[10..<26]) }
        }
        return Entry(device: dev, kind: kind, position: position, name: name)
    }

    static func ascii(_ bytes: ArraySlice<UInt8>) -> String? {
        let chars = bytes.prefix { $0 != 0 }
        guard !chars.isEmpty, chars.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        let s = String(decoding: chars, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    /// "A01"…"H16" for Machinedrum/Monomachine patterns, "01"… for everything else.
    static func slotLabel(kind: String, position: Int) -> String {
        if kind == "Pattern" { return "\(Character(UnicodeScalar(UInt8(65 + (position / 16) % 26))))\(String(format: "%02d", position % 16 + 1))" }
        return String(format: "%02d", position + 1)
    }

    static func plural(_ kind: String, _ n: Int) -> String {
        if n == 1 { return kind }
        switch kind {
        case "Settings", "OS Upgrade": return kind
        default: return kind + "s"
        }
    }

    /// A descriptive base name (no date, no extension), or nil if nothing was recognised.
    public static func describe(_ data: SysExData) -> String? {
        let entries = data.messages.compactMap(entry)
        guard !entries.isEmpty else { return nil }
        // Group by device then kind, keeping the order they first appeared in.
        var order: [String] = []
        var groups: [String: [Entry]] = [:]
        for e in entries {
            let key = e.device + "\u{1}" + e.kind
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(e)
        }
        let devices = Array(NSOrderedSet(array: entries.map(\.device))) as! [String]
        var parts: [String] = []
        for dev in devices {
            var items: [String] = []
            for key in order where key.hasPrefix(dev + "\u{1}") {
                let g = groups[key]!
                let kind = g[0].kind
                if kind == "OS Upgrade" { items.append(kind); continue }
                let positions = g.compactMap(\.position)
                if g.count == 1, let p = positions.first {
                    items.append([kind, slotLabel(kind: kind, position: p), g[0].name].compactMap { $0 }.joined(separator: " "))
                } else if positions.count == g.count, let lo = positions.min(), let hi = positions.max(),
                          hi - lo + 1 == g.count, Set(positions).count == g.count {
                    items.append("\(plural(kind, g.count)) \(slotLabel(kind: kind, position: lo))–\(slotLabel(kind: kind, position: hi))")
                } else {
                    items.append(g.count == 1 ? kind : "\(g.count) \(plural(kind, g.count))")
                }
            }
            parts.append(dev + " " + items.joined(separator: ", "))
        }
        return parts.joined(separator: " + ")
    }

    /// One letter per kind, in this order: G K P S, then A4/AR sounds (N), settings (T), DigiPRO waves (W).
    static let kindLetters: [(kind: String, letter: String)] = [
        ("Global", "G"), ("Kit", "K"), ("Pattern", "P"), ("Song", "S"),
        ("Sound", "N"), ("Settings", "T"), ("DigiPRO Wave", "W"),
    ]
    static let devicePrefix: [String: String] = ["Sidstation": "SID"]

    /// Short code for a dump: device + kinds present, e.g. "MDK", "MDGKPS", "MDKP"; a single item
    /// also carries its slot ("MDK01", "MDPA01"); OS upgrades are "MDOS"; several devices are
    /// joined with "+" ("MDK+MMP"). Nil if nothing was recognised.
    public static func code(_ data: SysExData) -> String? {
        let entries = data.messages.compactMap(entry)
        guard !entries.isEmpty else { return nil }
        let devices = Array(NSOrderedSet(array: entries.map(\.device))) as! [String]
        return devices.map { dev -> String in
            let es = entries.filter { $0.device == dev }
            let prefix = devicePrefix[dev] ?? dev
            if es.allSatisfy({ $0.kind == "OS Upgrade" }) { return prefix + "OS" }
            let kinds = Set(es.map(\.kind))
            var code = prefix + kindLetters.filter { kinds.contains($0.kind) }.map(\.letter).joined()
            if es.count == 1, let p = es[0].position { code += slotLabel(kind: es[0].kind, position: p) }
            return code
        }.joined(separator: "+")
    }

    /// File name for a receive: code (or "Received") + local date and time + ".syx", e.g.
    /// "MDK 2026-10-16 12.19.syx". Names already in `taken` get " 2", " 3", … appended.
    public static func fileName(for data: SysExData, date: Date = Date(), taken: Set<String> = []) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"     // ":" isn't allowed in Finder names
        let base = "\(code(data) ?? "Received") \(f.string(from: date))"
        var name = base + ".syx", n = 2
        while taken.contains(name) { name = "\(base) \(n).syx"; n += 1 }
        return name
    }
}
