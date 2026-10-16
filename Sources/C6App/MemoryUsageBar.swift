import C6Core
import SwiftUI

/// A chunky bar showing the device's sample memory: one segment per used slot (width = its share
/// of memory), free space in grey, selected slots highlighted, and an optional marker for where
/// usage would land after sending the samples selected in the main list. Hovering shows the
/// slot, name and size under the pointer; clicking a segment reports its slot.
struct MemoryUsageBar: View {
    let slots: [SlotInfo]
    let memory: SampleMemory
    var highlighted: Set<Int> = []          // 1-based slots
    var usedAfterSend: Int? = nil           // bytes, if the main selection would change usage
    var height: CGFloat = 22
    var onSelect: ((Int) -> Void)? = nil
    /// Preview renders only: pretend the pointer is over this slot (0 = the free area).
    var previewHoverSlot: Int? = nil

    private enum Hover: Equatable { case slot(SlotInfo), free }
    @State private var hover: Hover?
    @State private var hoverX: CGFloat = 0

    private struct Segment { let info: SlotInfo; let x0: CGFloat; let x1: CGFloat }

    private func segments(width: CGFloat) -> [Segment] {
        let total = CGFloat(max(1, memory.totalBytes))
        var x: CGFloat = 0
        return slots.sorted { $0.sampleNumber < $1.sampleNumber }.map { s in
            let w = width * CGFloat(memory.bytes(frames: s.length)) / total
            defer { x += w }
            return Segment(info: s, x0: x, x1: min(width, x + w))
        }
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let segs = segments(width: width)
            let usedEnd = segs.last?.x1 ?? 0
            let hovered: Hover? = previewHover(segs: segs, width: width) ?? hover
            Canvas { ctx, size in
                var hoveredRect: CGRect?
                for (i, seg) in segs.enumerated() {
                    // 1 pt gap between neighbours; very small samples stay at least 1 pt wide.
                    let rect = CGRect(x: seg.x0, y: 0, width: max(1, seg.x1 - seg.x0 - 1), height: size.height)
                    ctx.fill(Path(rect), with: .color(color(for: seg.info, index: i)))
                    if hovered == .slot(seg.info) { hoveredRect = rect }
                }
                if let r = hoveredRect {
                    // Outline the segment under the pointer (reads the same in light and dark mode).
                    let outline = r.width < 4 ? r.insetBy(dx: -1.5, dy: 0) : r.insetBy(dx: 1, dy: 1)
                    ctx.stroke(Path(roundedRect: outline, cornerRadius: 2), with: .color(.primary), lineWidth: 2)
                }
                if hovered == .free, usedEnd < size.width {
                    ctx.fill(Path(CGRect(x: usedEnd, y: 0, width: size.width - usedEnd, height: size.height)),
                             with: .color(Color.secondary.opacity(0.18)))
                }
                if memory.used(by: slots) > memory.totalBytes {
                    // More than the configured memory: the estimate is off (or memory is set too small).
                    ctx.fill(Path(CGRect(x: size.width - 3, y: 0, width: 3, height: size.height)), with: .color(.orange))
                }
            }
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(p):
                    hoverX = p.x
                    if let seg = segs.first(where: { p.x >= $0.x0 && p.x < $0.x1 }) { hover = .slot(seg.info) }
                    else { hover = p.x >= usedEnd ? .free : nil }
                case .ended:
                    hover = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { p in
                if let seg = segs.first(where: { p.x >= $0.x0 && p.x < $0.x1 }) { onSelect?(seg.info.slot) }
            }
            .overlay(alignment: .leading) {
                if let after = usedAfterSend {
                    // Where usage lands after sending the main list's selected samples: a notch
                    // that sticks out above and below the bar.
                    let x = min(width - 2, max(0, width * CGFloat(after) / CGFloat(max(1, memory.totalBytes))))
                    Rectangle()
                        .fill(after > memory.totalBytes ? Color.orange : Color.primary)
                        .frame(width: 2, height: height + 8)
                        .offset(x: x - 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if let hovered {
                    let (text, x) = bubble(hovered, segs: segs, usedEnd: usedEnd, width: width)
                    Text(text)
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.35)))
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                        .position(x: min(max(x, 90), width - 90), y: -16)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Sample memory \(Int((Double(memory.used(by: slots)) / Double(max(1, memory.totalBytes)) * 100).rounded())) percent used")
    }

    private func previewHover(segs: [Segment], width: CGFloat) -> Hover? {
        guard let s = previewHoverSlot else { return nil }
        if s == 0 { return .free }
        return segs.first { $0.info.slot == s }.map { .slot($0.info) }
    }

    /// Text and anchor x for the hover bubble.
    private func bubble(_ h: Hover, segs: [Segment], usedEnd: CGFloat, width: CGFloat) -> (String, CGFloat) {
        switch h {
        case let .slot(info):
            let seg = segs.first { $0.info.slot == info.slot }
            let mid = seg.map { ($0.x0 + $0.x1) / 2 } ?? hoverX
            var parts = ["Slot \(info.slot)"]
            if let n = info.name, !n.isEmpty { parts.append(n) }
            parts.append(ByteFormat.memory(memory.bytes(frames: info.length)))
            parts.append(String(format: "%.2f s", info.duration))
            return (parts.joined(separator: " · "), mid)
        case .free:
            let free = max(0, memory.totalBytes - memory.used(by: slots))
            return ("Free · \(ByteFormat.memory(free))", (usedEnd + width) / 2)
        }
    }

    private func color(for s: SlotInfo, index: Int) -> Color {
        if highlighted.contains(s.slot) { return .orange }
        return Color.accentColor.opacity(index.isMultiple(of: 2) ? 0.9 : 0.65)
    }
}
