import SwiftUI
import AppKit

// BoardKit: native SwiftUI components that follow BoardUI's visual language (neutral zinc
// surfaces, hairline borders, rounded-xl cards, pill badges, iridescent "agent" accents).
// BoardUI itself is a React/Tailwind library and isn't usable from SwiftUI, so nothing here
// is copied from its source — these are native re-creations of the patterns.

enum BK {
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Notch surfaces are always dark (they merge with the hardware notch).
    enum Notch {
        static let surface = Color.black
        static let raised = Color(white: 0.11)
        static let border = Color.white.opacity(0.08)
        static let text = Color.white.opacity(0.94)
        static let secondary = Color.white.opacity(0.58)
        static let tertiary = Color.white.opacity(0.36)
        static let field = Color.white.opacity(0.07)
    }

    enum Tone {
        case neutral, accent, success, warning, danger, info

        var color: Color {
            switch self {
            case .neutral: return Color(nsColor: .secondaryLabelColor)
            case .accent: return Color(red: 0.55, green: 0.45, blue: 1.0)
            case .success: return Color(red: 0.20, green: 0.83, blue: 0.60)
            case .warning: return Color(red: 0.98, green: 0.75, blue: 0.14)
            case .danger: return Color(red: 0.97, green: 0.44, blue: 0.44)
            case .info: return Color(red: 0.38, green: 0.65, blue: 0.98)
            }
        }
    }

    /// The iridescent agent gradient (BoardUI's "iridescent light" accent).
    static let iridescent = AngularGradient(
        colors: [Color(red: 0.55, green: 0.42, blue: 1.0), Color(red: 0.25, green: 0.62, blue: 1.0),
                 Color(red: 0.20, green: 0.90, blue: 0.85), Color(red: 1.0, green: 0.45, blue: 0.75),
                 Color(red: 0.55, green: 0.42, blue: 1.0)],
        center: .center)

    static let accentGradient = LinearGradient(colors: [Color(red: 0.56, green: 0.44, blue: 1.0), Color(red: 0.30, green: 0.58, blue: 1.0)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - Buttons

struct BKButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive, success }
    var kind: Kind = .secondary
    var compact = false
    var onDark = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 13, weight: .semibold))
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 7)
            .foregroundStyle(foreground)
            .background { background(pressed: configuration.isPressed).clipShape(RoundedRectangle(cornerRadius: compact ? 8 : BK.Radius.md, style: .continuous)) }
            .overlay(RoundedRectangle(cornerRadius: compact ? 8 : BK.Radius.md, style: .continuous).strokeBorder(border, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Rectangle())
    }

    var foreground: Color {
        switch kind {
        case .primary, .destructive, .success: return .white
        case .secondary, .ghost: return onDark ? BK.Notch.text : Color(nsColor: .labelColor)
        }
    }

    var border: Color {
        switch kind {
        case .secondary: return onDark ? BK.Notch.border : Color(nsColor: .separatorColor)
        default: return .clear
        }
    }

    @ViewBuilder func background(pressed: Bool) -> some View {
        switch kind {
        case .primary: BK.accentGradient.opacity(pressed ? 0.85 : 1)
        case .destructive: BK.Tone.danger.color.opacity(pressed ? 0.8 : 0.92)
        case .success: BK.Tone.success.color.opacity(pressed ? 0.8 : 0.92)
        case .secondary: (onDark ? Color.white.opacity(pressed ? 0.14 : 0.08) : Color(nsColor: .controlBackgroundColor).opacity(pressed ? 0.7 : 1))
        case .ghost: Color.primary.opacity(pressed ? 0.08 : 0.0001)
        }
    }
}

struct BKIconButton: View {
    let systemName: String
    var help: String
    var tone: BK.Tone? = nil
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(tone?.color ?? BK.Notch.text)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Badges, dots, keycaps

struct BKBadge: View {
    let text: String
    var tone: BK.Tone = .neutral
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
            .background(Capsule().fill(tone.color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tone.color.opacity(0.25), lineWidth: 0.5))
    }
}

struct BKStatusDot: View {
    var tone: BK.Tone
    var pulsing = false
    @State private var pulse = false
    var body: some View {
        ZStack {
            if pulsing {
                Circle().fill(tone.color.opacity(0.35)).frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1.3 : 0.6).opacity(pulse ? 0 : 1)
            }
            Circle().fill(tone.color).frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

struct BKKeyCap: View {
    let text: String
    var onDark = false
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(onDark ? BK.Notch.secondary : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 5).fill(onDark ? Color.white.opacity(0.07) : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(onDark ? BK.Notch.border : Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

// MARK: - Agent indicators

/// Iridescent orb: idle = still, thinking = rotating glow, acting = pulsing.
struct BKAgentOrb: View {
    enum Mode { case idle, thinking, acting, paused, success, error }
    var mode: Mode
    var size: CGFloat = 18
    @State private var rotation = 0.0
    @State private var breathe = false

    var body: some View {
        ZStack {
            switch mode {
            case .success:
                Circle().fill(BK.Tone.success.color).overlay(Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.black))
            case .error:
                Circle().fill(BK.Tone.danger.color).overlay(Image(systemName: "exclamationmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.black))
            case .paused:
                Circle().fill(BK.Tone.warning.color).overlay(Image(systemName: "pause.fill").font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.black))
            default:
                Circle().fill(BK.iridescent).rotationEffect(.degrees(rotation))
                    .blur(radius: mode == .idle ? 0 : 0.6)
                Circle().fill(RadialGradient(colors: [.white.opacity(0.7), .clear], center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.6))
                    .blendMode(.plusLighter)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(mode == .acting && breathe ? 1.12 : 1)
        .shadow(color: mode == .thinking || mode == .acting ? Color(red: 0.5, green: 0.45, blue: 1).opacity(0.7) : .clear, radius: 6)
        .onAppear(perform: animate)
        .onChange(of: mode) { _, _ in animate() }
        .accessibilityHidden(true)
    }

    private func animate() {
        rotation = 0
        breathe = false
        guard mode == .thinking || mode == .acting else { return }
        withAnimation(.linear(duration: mode == .thinking ? 1.6 : 3).repeatForever(autoreverses: false)) { rotation = 360 }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { breathe = true }
    }
}

/// Text with a moving highlight, for "Understanding your task…".
struct BKShimmerText: View {
    let text: String
    var font: Font = .system(size: 13, weight: .medium)
    @State private var phase: CGFloat = -1

    var body: some View {
        Text(text).font(font).foregroundStyle(BK.Notch.secondary)
            .overlay(
                LinearGradient(colors: [.clear, .white.opacity(0.95), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 80).offset(x: phase * 260)
                    .mask(Text(text).font(font))
                    .allowsHitTesting(false)
            )
            .onAppear { withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 } }
    }
}

// MARK: - Cards and form rows (settings, light/dark adaptive)

struct BKCard<Content: View>: View {
    var padding: CGFloat = BK.Space.lg
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: BK.Space.md) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BK.Radius.lg, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: BK.Radius.lg, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1))
    }
}

struct BKSectionHeader: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 20, weight: .semibold))
            if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.bottom, 4)
    }
}

struct BKFormRow<Accessory: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var accessory: Accessory
    var body: some View {
        HStack(alignment: .center, spacing: BK.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: BK.Space.md)
            accessory
        }
    }
}

/// Masked secret input with show/hide (keys are masked by default).
struct BKSecretField: View {
    let placeholder: String
    @Binding var text: String
    @State private var revealed = false
    var body: some View {
        HStack(spacing: 6) {
            Group {
                if revealed { TextField(placeholder, text: $text) } else { SecureField(placeholder, text: $text) }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            Button {
                if let clip = NSPasteboard.general.string(forType: .string) {
                    text = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } label: {
                Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Paste from clipboard")
            .accessibilityLabel("Paste from clipboard")
            Button { revealed.toggle() } label: {
                Image(systemName: revealed ? "eye.slash" : "eye").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(revealed ? "Hide key" : "Show key")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

struct BKTextField: View {
    let placeholder: String
    @Binding var text: String
    var monospaced = false
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: monospaced ? .monospaced : .default))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}
