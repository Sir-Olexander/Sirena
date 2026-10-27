import SwiftUI

/// The pill. It never takes focus; the panel that hosts it is non-activating.
public struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    public init(model: OverlayModel) { self.model = model }

    private var scale: CGFloat { model.large ? 1.3 : 1.0 }

    private var accent: Color {
        if model.isDictating { return Color(red: 1.0, green: 0.62, blue: 0.18) }
        switch model.state {
        case .off: return Color.gray
        case .waiting: return Color(white: 0.6)
        case .awake: return Color(red: 0.25, green: 0.78, blue: 0.92)
        }
    }

    public var body: some View {
        Group {
            switch model.state {
            case .off: offDot
            case .waiting: waitingPill
            case .awake: awakeBody
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.state)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.mode)
        .animation(.easeInOut(duration: 0.25), value: model.isActive)
        .animation(.easeInOut(duration: 0.2), value: model.isDictating)
        .fixedSize()
        .coordinateSpace(name: "overlay")
        .onPreferenceChange(ConfirmFramesKey.self) { frames in model.confirmFrames = frames }
    }

    // MARK: - States

    private var offDot: some View {
        Circle()
            .fill(Color.gray.opacity(0.55))
            .frame(width: 14 * scale, height: 14 * scale)
            .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
            .padding(8)
            .contentShape(Rectangle())
            .help("Click to turn Sirena on")
    }

    private var waitingPill: some View {
        HStack(spacing: 6 * scale) {
            Image(systemName: model.privateListening ? "lock.fill" : "moon.zzz.fill").font(.system(size: 10 * scale))
            Text(statusLine ?? (model.privateListening ? "Say “Hey Sirena” · on-device" : "Say “Hey Sirena”")).font(.system(size: 11 * scale, weight: .medium))
        }
        .foregroundColor(.white.opacity(0.75))
        .padding(.horizontal, 10 * scale).padding(.vertical, 5 * scale)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
        .padding(6)
        .contentShape(Rectangle())
    }

    private var awakeBody: some View {
        VStack(spacing: 6 * scale) {
            if case .confirm(let message) = model.mode {
                confirmCard(message)
            } else {
                mainPill
            }
        }
        .padding(6)
    }

    private var mainPill: some View {
        HStack(spacing: 8 * scale) {
            dotWithRing
            if model.isActive || !model.partialText.isEmpty || model.mode != .idle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryLine)
                        .font(.system(size: 12.5 * scale, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 420 * scale, alignment: .leading)
                    if let secondary = secondaryLine {
                        Text(secondary)
                            .font(.system(size: 10 * scale, weight: .regular, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                .foregroundColor(.white.opacity(0.95))
                .transition(.opacity.combined(with: .move(edge: .leading)))
            } else {
                Text(model.isDictating ? "Dictating" : "Listening")
                    .font(.system(size: 11 * scale, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            if model.isSpeaking || !model.partialText.isEmpty { waveform }
        }
        .padding(.horizontal, 12 * scale).padding(.vertical, 7 * scale)
        .background(Capsule().fill(pillColor))
        .overlay(Capsule().stroke(accent.opacity(0.55), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .contentShape(Capsule())
    }

    private var pillColor: Color {
        if case .error = model.mode { return Color(red: 0.45, green: 0.12, blue: 0.12).opacity(0.92) }
        if model.isDictating { return Color(red: 0.32, green: 0.18, blue: 0.04).opacity(0.92) }
        return Color.black.opacity(0.78)
    }

    private var dotWithRing: some View {
        ZStack {
            if let p = model.followUpProgress {
                Circle()
                    .trim(from: 0, to: p)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 18 * scale, height: 18 * scale)
            }
            Circle()
                .fill(accent)
                .frame(width: 10 * scale, height: 10 * scale)
                .scaleEffect(model.isSpeaking ? 1.25 : 1.0)
                .shadow(color: accent.opacity(0.9), radius: model.isSpeaking ? 6 : 2)
                .animation(.easeInOut(duration: 0.15), value: model.isSpeaking)
        }
        .frame(width: 20 * scale, height: 20 * scale)
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 1.5 * scale) {
            ForEach(Array(model.levels.suffix(14).enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1)
                    .fill(accent.opacity(0.9))
                    .frame(width: 2 * scale, height: max(2, CGFloat(v) * 16 * scale + 2))
            }
        }
        .frame(height: 18 * scale)
        .animation(.linear(duration: 0.08), value: model.levels)
    }

    private var primaryLine: String {
        switch model.mode {
        case .working(let t), .message(let t), .hint(let t), .error(let t), .confirm(let t):
            if !model.partialText.isEmpty, case .working = model.mode { return model.partialText }
            return t
        case .idle:
            if !model.partialText.isEmpty { return model.partialText }
            if let c = model.connectionNote { return c }
            return model.isDictating ? "Dictating — say “Sirena, stop” to finish" : "Listening"
        }
    }

    private var secondaryLine: String? {
        if let c = model.connectionNote, !model.partialText.isEmpty || model.mode != .idle { return c }
        if model.showLatency, let l = model.latency { return l.summary }
        return nil
    }

    private var statusLine: String? { model.connectionNote }

    private func confirmCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            HStack(spacing: 8 * scale) {
                Image(systemName: "questionmark.circle.fill").foregroundColor(accent).font(.system(size: 16 * scale))
                Text(message)
                    .font(.system(size: 13.5 * scale, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(3)
                    .frame(maxWidth: 380 * scale, alignment: .leading)
            }
            HStack(spacing: 10 * scale) {
                confirmButton("Yes", systemImage: "checkmark", tint: Color(red: 0.2, green: 0.75, blue: 0.4)) { model.confirm(true) }
                confirmButton("Cancel", systemImage: "xmark", tint: Color(white: 0.45)) { model.confirm(false) }
                Spacer()
                Text("say “yes” or “cancel”")
                    .font(.system(size: 10 * scale))
                    .foregroundColor(.white.opacity(0.55))
            }
            if model.showLatency, let l = model.latency {
                Text(l.summary).font(.system(size: 10 * scale, design: .monospaced)).foregroundColor(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 16 * scale).padding(.vertical, 12 * scale)
        .background(RoundedRectangle(cornerRadius: 16 * scale).fill(Color.black.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 16 * scale).stroke(accent.opacity(0.7), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 4)
    }

    private func confirmButton(_ title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12 * scale, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12 * scale).padding(.vertical, 6 * scale)
            .background(Capsule().fill(tint))
            .background(GeometryReader { g in
                Color.clear.preference(key: ConfirmFramesKey.self, value: [title == "Yes" ? "yes" : "cancel": g.frame(in: .named("overlay"))])
            })
    }
}


struct ConfirmFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
