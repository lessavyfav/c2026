import Foundation

/// Which device slots a batch of samples goes to. Slots are 1-based, as Elektron devices show them.
///
/// C2026 behaviour: a single sample goes to the chosen slot; a batch fills consecutive slots from
/// it; the chosen slot itself doesn't move. When a batch would run past the device's last slot,
/// the user picks `.stop` (send only what fits) or `.wrap` (continue from slot 1).
public struct SlotPlan: Equatable, Sendable {
    public enum Overflow: Sendable { case stop, wrap }

    public let start: Int
    public let count: Int
    public let slotCount: Int

    public init(start: Int, count: Int, slotCount: Int) {
        self.slotCount = max(1, slotCount)
        self.start = min(max(1, start), self.slotCount)
        self.count = max(0, count)
    }

    /// Last slot used if nothing overflows.
    public var end: Int { start + count - 1 }
    public var fits: Bool { end <= slotCount }
    /// How many samples fit before the last slot.
    public var fittingCount: Int { min(count, slotCount - start + 1) }

    /// The slot for each sample in order; nil = not sent (`.stop` past the last slot).
    public func slots(_ overflow: Overflow = .stop) -> [Int?] {
        (0..<count).map { i in
            let s = start + i
            if s <= slotCount { return s }
            return overflow == .wrap ? ((s - 1) % slotCount) + 1 : nil
        }
    }
}
