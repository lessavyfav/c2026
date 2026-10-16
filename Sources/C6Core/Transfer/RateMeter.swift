import Foundation

/// Throughput / ETA helper for the progress row.
public struct TransferProgress: Sendable, Equatable {
    public var bytesDone: Int
    public var bytesTotal: Int
    public var elapsed: Double

    public init(bytesDone: Int, bytesTotal: Int, elapsed: Double) {
        self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.elapsed = elapsed
    }

    public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
    public var bytesPerSecond: Double { elapsed > 0 ? Double(bytesDone) / elapsed : 0 }
    public var remaining: Double? {
        let r = bytesPerSecond
        return r > 0 ? Double(bytesTotal - bytesDone) / r : nil
    }
}

public enum Format {
    public static func bytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f kB", Double(n) / 1024) }
        return String(format: "%.2f MB", Double(n) / 1024 / 1024)
    }

    /// C6 showed sizes like "44k" in the list.
    public static func sizeColumn(_ n: Int) -> String {
        n < 1024 ? "\(n)" : "\((n + 512) / 1024)k"
    }

    public static func duration(_ s: Double) -> String {
        if s < 1 { return String(format: "%.0f ms", s * 1000) }
        if s < 60 { return String(format: "%.1f s", s) }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
