import SwiftUI

/// A small line drawing of a Machinedrum (body, main knob, display, two rows of knobs, the step
/// buttons), used for the Device Samples toolbar button. Simplified from a full-size drawing so it
/// reads at toolbar size; draws in the current foreground colour, so it follows light/dark mode.
struct MachinedrumIcon: View {
    /// Line weight in points (the toolbar version uses ~1.1).
    var lineWidth: CGFloat = 1.1

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let lw = lineWidth
            let small = w < 60          // toolbar size: solid knobs/steps read better than outlines
            let shading = GraphicsContext.Shading.foreground
            // Body.
            let body = CGRect(x: lw / 2, y: lw / 2, width: w - lw, height: h - lw)
            ctx.stroke(Path(roundedRect: body, cornerRadius: lw * 1.2), with: shading, lineWidth: lw)
            // Proportions taken from the reference drawing (body = 768 × 397).
            func x(_ f: CGFloat) -> CGFloat { body.minX + f * body.width }
            func y(_ f: CGFloat) -> CGFloat { body.minY + f * body.height }
            // Main knob (data entry), with its position marker.
            let r = max(lw * 1.6, body.height * (small ? 0.17 : 0.15))
            let knob = CGRect(x: x(0.18) - r, y: y(0.38) - r, width: r * 2, height: r * 2)
            ctx.stroke(Path(ellipseIn: knob), with: shading, lineWidth: lw)
            let dot = max(lw * 0.55, r * 0.28)
            ctx.fill(Path(ellipseIn: CGRect(x: x(0.18) + r * 0.32 - dot / 2, y: y(0.38) - r * 0.42 - dot / 2, width: dot, height: dot)), with: shading)
            // Display.
            ctx.stroke(Path(CGRect(x: x(0.34), y: y(small ? 0.2 : 0.22), width: body.width * (small ? 0.22 : 0.205),
                                   height: body.height * (small ? 0.25 : 0.22))),
                       with: shading, lineWidth: lw)
            // Two rows of four parameter knobs.
            let kr = max(lw * 0.65, body.height * 0.05)
            for fy in [CGFloat(0.245), 0.40] {
                for i in 0..<4 {
                    let c = CGRect(x: x(0.66 + CGFloat(i) * 0.088) - kr, y: y(fy) - kr, width: kr * 2, height: kr * 2)
                    if small { ctx.fill(Path(ellipseIn: c), with: shading) }
                    else { ctx.stroke(Path(ellipseIn: c), with: shading, lineWidth: lw) }
                }
            }
            // Step buttons along the bottom (16 on the real thing; 8 read better this small).
            let steps = w >= 60 ? 16 : 8
            let left = x(0.04), right = x(0.90), top = y(0.74), stepH = body.height * 0.13
            let pitch = (right - left) / CGFloat(steps)
            for i in 0..<steps {
                let rect = CGRect(x: left + CGFloat(i) * pitch + pitch * 0.12, y: top, width: pitch * 0.76, height: stepH)
                let p = Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.2)
                if small { ctx.fill(p, with: shading) } else { ctx.stroke(p, with: shading, lineWidth: lw) }
            }
        }
        .aspectRatio(768.0 / 397.0, contentMode: .fit)
        .accessibilityLabel("Machinedrum samples")
    }
}
