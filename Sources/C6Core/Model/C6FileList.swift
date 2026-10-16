import Foundation

/// C6's `.c6` file list (identical on Mac and Windows C6 1.51):
///
///     "C6 Filelist" 00  "0" 00  "<sample position>" 00  { <L><S><path> 00 }*
///
/// L = loop digit (0 file, 1 on, 2 off), S = stereo digit (0 L+R, 1 left, 2 right),
/// path = absolute, or `*` + a `/`-separated path relative to the folder holding the .c6.
/// Written byte-compatibly so old C6 builds can still open lists made here.
public struct C6FileList: Equatable {
    public struct Entry: Equatable {
        public var url: URL
        public var loop: C6Item.LoopMode
        public var stereo: C6Item.StereoMode
        public init(url: URL, loop: C6Item.LoopMode = .file, stereo: C6Item.StereoMode = .mix) {
            self.url = url; self.loop = loop; self.stereo = stereo
        }
    }

    public var samplePosition: Int
    public var entries: [Entry]

    public init(samplePosition: Int = 0, entries: [Entry] = []) {
        self.samplePosition = samplePosition; self.entries = entries
    }

    static let magic = Array("C6 Filelist".utf8) + [0]
    static let loops: [C6Item.LoopMode] = [.file, .on, .off]
    static let stereos: [C6Item.StereoMode] = [.mix, .left, .right]

    public enum ParseError: Error { case notAFileList, unsupportedVersion }

    /// Parses a .c6 file. Relative records resolve against `directory` (the folder holding the .c6).
    public static func parse(_ data: Data, directory: URL) throws -> C6FileList {
        let bytes = [UInt8](data)
        guard bytes.starts(with: magic) else { throw ParseError.notAFileList }
        var strings: [[UInt8]] = []
        var current: [UInt8] = []
        for b in bytes[magic.count...] {
            if b == 0 { strings.append(current); current = [] } else { current.append(b) }
        }
        if !current.isEmpty { strings.append(current) } // tolerate a missing final NUL
        guard let version = strings.first, version.first == UInt8(ascii: "0") else { throw ParseError.unsupportedVersion }
        let position = strings.count > 1 ? Int(String(decoding: strings[1].prefix { (0x30...0x39).contains($0) }, as: UTF8.self)) ?? 0 : 0
        var list = C6FileList(samplePosition: position)
        for rec in strings.dropFirst(2) where rec.count > 2 {
            let l = Int(rec[0]) - 0x30, s = Int(rec[1]) - 0x30
            var pathBytes = Array(rec[2...])
            let relative = pathBytes.first == UInt8(ascii: "*")
            if relative { pathBytes.removeFirst() }
            var path = decodePath(pathBytes)
            if relative { path = path.replacingOccurrences(of: "\\", with: "/") }
            let url = relative ? directory.appendingPathComponent(path) : URL(fileURLWithPath: path)
            list.entries.append(Entry(url: url.standardizedFileURL,
                                      loop: loops.indices.contains(l) ? loops[l] : .file,
                                      stereo: stereos.indices.contains(s) ? stereos[s] : .mix))
        }
        return list
    }

    /// Serializes; entries under `directory` are stored relative (`*…`), others absolute.
    public func serialize(directory: URL) -> Data {
        var out = Self.magic + Array("0".utf8) + [0] + Array(String(max(0, samplePosition)).utf8) + [0]
        let dir = directory.standardizedFileURL.path.hasSuffix("/") ? directory.standardizedFileURL.path : directory.standardizedFileURL.path + "/"
        for e in entries {
            let path = e.url.standardizedFileURL.path
            let stored = path.hasPrefix(dir) ? "*" + path.dropFirst(dir.count) : path
            out += [UInt8(0x30 + (Self.loops.firstIndex(of: e.loop) ?? 0)), UInt8(0x30 + (Self.stereos.firstIndex(of: e.stereo) ?? 0))]
            out += Array(stored.utf8) + [0]
        }
        return Data(out)
    }

    /// Paths are UTF-8 on the Mac; Windows lists use the ANSI code page.
    static func decodePath(_ bytes: [UInt8]) -> String {
        if let s = String(bytes: bytes, encoding: .utf8) { return s }
        return String(bytes: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }
}
