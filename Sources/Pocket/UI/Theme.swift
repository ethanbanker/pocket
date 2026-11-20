import SwiftUI

/// Ableton-ish dark palette: one place for every shade used by the UI.
enum Theme {
    static let bg = Color(white: 0.086)
    static let panel = Color(white: 0.128)
    static let panelAlt = Color(white: 0.165)
    static let header = Color(white: 0.155)
    static let stroke = Color(white: 0.22)
    static let hairlight = Color(white: 1.0).opacity(0.055)
    static let text = Color(white: 0.82)
    static let dim = Color(white: 0.48)
    static let accent = Color(red: 0.36, green: 0.72, blue: 0.95)
    static let playhead = Color(red: 1.0, green: 0.56, blue: 0.30)
    static let record = Color(red: 0.93, green: 0.35, blue: 0.32)
    static let go = Color(red: 0.30, green: 0.66, blue: 0.45)
    static let mute = Color(red: 0.95, green: 0.74, blue: 0.28)
    static let solo = Color(red: 0.36, green: 0.80, blue: 0.98)
}

/// Small square toggle used for M / S / ARM flags.
struct FlagButton: View {
    let label: String
    let active: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .frame(width: 16, height: 14)
                .background(active ? tint : Color(white: 0.22))
                .foregroundStyle(active ? Color.black : Color(white: 0.62))
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .buttonStyle(.plain)
    }
}

/// Compact flat button used across the transport and panel headers.
struct FlatButton: View {
    let title: String
    var tint: Color = Theme.text
    var background: Color = Theme.panelAlt
    var width: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .frame(width: width)
                .background(background)
                .foregroundStyle(tint)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }
}

/// Rotary control: drag up/down to change. Keeps the fader-less Ableton device look.
struct Knob: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var tint: Color = Theme.accent
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    let set: (Double) -> Void

    private var norm: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(Color(white: 0.19))
                Circle().stroke(Color(white: 0.27), lineWidth: 1)
                Circle()
                    .trim(from: 0, to: 0.75 * norm)
                    .rotation(.degrees(135))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .padding(3.5)
                Rectangle()
                    .fill(Color(white: 0.85))
                    .frame(width: 1.5, height: 8)
                    .offset(y: -8)
                    .rotationEffect(.degrees(-135 + 270 * norm))
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let anchors = KnobAnchors.shared
                        if anchors.anchors[label] == nil { anchors.anchors[label] = norm }
                        let base = anchors.anchors[label] ?? norm
                        let next = min(max(base - Double(drag.translation.height) / 140, 0), 1)
                        set(range.lowerBound + next * (range.upperBound - range.lowerBound))
                    }
                    .onEnded { _ in KnobAnchors.shared.anchors[label] = nil }
            )
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.dim)
            Text(format(value))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Theme.text)
        }
        .frame(width: 46)
    }
}

/// Drag anchors for knobs. A plain reference box keeps this out of SwiftUI property wrappers,
/// whose macro plugin is not available in this Command Line Tools-only toolchain.
private final class KnobAnchors: @unchecked Sendable {
    static let shared = KnobAnchors()
    var anchors: [String: Double] = [:]
}
