import SwiftUI
import AppKit

// BoardKit: native SwiftUI components that follow BoardUI's visual language (boardui.com):
// neutral surfaces, a blue accent with gradient fills, grouped rows on a soft gray, white
// controls with hairline borders and tiny shadows, pastel status chips, and an iridescent
// "agent working" light. BoardUI itself is a React/Tailwind library and isn't usable from
// SwiftUI, so nothing here is copied from its source — these are native re-creations of its
// tokens and patterns.

enum BK {
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 12
        static let xxl: CGFloat = 16
        static let card: CGFloat = 20
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// BoardUI's neutral scale (100 and 925 are BoardUI-specific steps) and blue accent.
    enum Palette {
        static let white = Color(hex: 0xFFFFFF)
        static let n50 = Color(hex: 0xFAFAFA)
        static let n100 = Color(hex: 0xF7F7F7)
        static let n200 = Color(hex: 0xEBEBEB)
        static let n300 = Color(hex: 0xD4D4D4)
        static let n400 = Color(hex: 0xA1A1A1)
        static let n500 = Color(hex: 0x737373)
        static let n600 = Color(hex: 0x525252)
        static let n700 = Color(hex: 0x404040)
        static let n800 = Color(hex: 0x262626)
        static let n900 = Color(hex: 0x171717)
        static let n925 = Color(hex: 0x121212)
        static let n950 = Color(hex: 0x0A0A0A)
        static let accent400 = Color(hex: 0x3392FF)
        static let accent500 = Color(hex: 0x2673FE)
        static let accent600 = Color(hex: 0x144BE9)
        static let accent700 = Color(hex: 0x1D3FBF)
    }

    /// Typography, scaled for macOS (BoardUI's body-2 / caption steps).
    enum Font {
        static let title1 = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let title2 = SwiftUI.Font.system(size: 18, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyMedium = SwiftUI.Font.system(size: 13, weight: .medium)
        static let small = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11.5)
        static let captionMedium = SwiftUI.Font.system(size: 11.5, weight: .medium)
        static let micro = SwiftUI.Font.system(size: 10.5, weight: .semibold)
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
    }

    /// Notch surfaces are always dark (they merge with the hardware notch).
    enum Notch {
        static let surface = Color.black
        static let raised = Palette.n900
        static let border = Color.white.opacity(0.09)
        static let text = Palette.n50
        static let secondary = Palette.n400
        static let tertiary = Palette.n600
        static let field = Palette.n900
    }

    enum Tone {
        case neutral, accent, success, warning, danger, info

        /// Solid color for icons and dots.
        var color: Color {
            switch self {
            case .neutral: return Palette.n400
            case .accent, .info: return Palette.accent500
            case .success: return Color(hex: 0x22C55E)
            case .warning: return Color(hex: 0xEAB308)
            case .danger: return Color(hex: 0xEF4444)
            }
        }

        /// Pastel chip colors (BoardUI's status-* tokens), light and dark.
        func chip(dark: Bool) -> (background: Color, text: Color) {
            switch (self, dark) {
            case (.neutral, false): return (Palette.n200, Palette.n600)
            case (.neutral, true): return (Palette.n800, Palette.n300)
            case (.accent, false): return (Color(hex: 0xF3E8FF), Color(hex: 0x9333EA))
            case (.accent, true): return (Color(hex: 0x3B0764).opacity(0.7), Color(hex: 0xD8B4FE))
            case (.info, false): return (Color(hex: 0xDBEAFE), Color(hex: 0x1E40AF))
            case (.info, true): return (Color(hex: 0x172554).opacity(0.8), Color(hex: 0x93C5FD))
            case (.success, false): return (Color(hex: 0xD9F99D), Color(hex: 0x3F6212))
            case (.success, true): return (Color(hex: 0x1A2E05).opacity(0.9), Color(hex: 0xBEF264))
            case (.warning, false): return (Color(hex: 0xFEF08A), Color(hex: 0x854D0E))
            case (.warning, true): return (Color(hex: 0x422006).opacity(0.9), Color(hex: 0xFDE047))
            case (.danger, false): return (Color(hex: 0xFECDD3), Color(hex: 0x9F1239))
            case (.danger, true): return (Color(hex: 0x4C0519).opacity(0.9), Color(hex: 0xFDA4AF))
            }
        }
    }

    /// The iridescent agent gradient (BoardUI's orbiting "agent is working" light).
    static let iridescent = AngularGradient(
        colors: [Color(hex: 0x8B6BFF), Color(hex: 0x3D8BFF), Color(hex: 0x33E0D4), Color(hex: 0xFF73BF), Color(hex: 0x8B6BFF)],
        center: .center)

    /// BoardUI's primary fill: a vertical accent-500 → accent-600 gradient.
    static let accentGradient = LinearGradient(colors: [Palette.accent500, Palette.accent600], startPoint: .top, endPoint: .bottom)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// Semantic colors for the current color scheme (BoardUI's background / border / text tokens).
struct BKTheme {
    let dark: Bool
    init(_ scheme: ColorScheme) { dark = scheme == .dark }
    init(dark: Bool) { self.dark = dark }

    typealias P = BK.Palette
    /// Page / content background ("background-full").
    var canvas: Color { dark ? P.n925 : P.white }
    /// Sidebars and grouped-row containers ("background-secondary").
    var muted: Color { dark ? P.n900 : P.n100 }
    var mutedHover: Color { dark ? P.n800 : P.n200 }
    /// Controls, inputs and selected items ("background-primary").
    var raised: Color { dark ? P.n800 : P.white }
    var raisedHover: Color { dark ? Color(hex: 0x333333) : P.n100 }
    var border: Color { dark ? P.n800 : P.n200 }
    var borderStrong: Color { dark ? P.n700 : P.n300 }
    var text: Color { dark ? P.n50 : P.n950 }
    var secondary: Color { dark ? P.n400 : P.n500 }
    var tertiary: Color { dark ? P.n600 : P.n400 }
    var accent: Color { P.accent500 }
    var accentSoft: Color { dark ? Color(hex: 0x172554).opacity(0.8) : Color(hex: 0xDBEAFE) }
    var accentText: Color { dark ? Color(hex: 0x93C5FD) : P.accent700 }
    var shadow: Color { .black.opacity(dark ? 0.35 : 0.06) }
}

private struct BKForceDarkKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Set inside the notch so components always use dark tokens, even in offscreen renders.
    var bkForceDark: Bool {
        get { self[BKForceDarkKey.self] }
        set { self[BKForceDarkKey.self] = newValue }
    }
}

/// Reads the current BoardKit theme.
struct BKThemeReader<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.bkForceDark) private var forceDark
    @ViewBuilder var content: (BKTheme) -> Content
    var body: some View { content(BKTheme(dark: forceDark || scheme == .dark)) }
}

extension View {
    /// BoardUI's "shadow-card": one soft pixel.
    func bkCardShadow(_ t: BKTheme) -> some View { shadow(color: t.shadow, radius: 0.5, y: 1) }
    /// BoardUI's "shadow-sidebar" / dropdown: hairline outline plus a soft lift.
    func bkFloatShadow(_ t: BKTheme) -> some View {
        shadow(color: .black.opacity(t.dark ? 0.4 : 0.05), radius: 0.5, y: 0)
            .shadow(color: .black.opacity(t.dark ? 0.3 : 0.06), radius: 6, y: 1)
    }
}

// MARK: - Buttons

struct BKButtonStyle: ButtonStyle {
    enum Kind {
        /// Accent gradient.
        case primary
        /// White / raised with a hairline border.
        case secondary
        /// Text-only, gray hover.
        case ghost
        /// BoardUI's ghost: soft accent tint.
        case tinted
        case destructive, success
    }
    var kind: Kind = .secondary
    var compact = false
    var onDark = false

    func makeBody(configuration: Configuration) -> some View {
        BKButtonBody(configuration: configuration, kind: kind, compact: compact, onDark: onDark)
    }
}

private struct BKButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: BKButtonStyle.Kind
    let compact: Bool
    let onDark: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.bkForceDark) private var forceDark
    @State private var hovering = false

    var body: some View {
        let t = BKTheme(dark: onDark || forceDark || scheme == .dark)
        let radius = compact ? BK.Radius.md : BK.Radius.lg
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 7.5)
            .foregroundStyle(foreground(t))
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill(t, pressed: pressed))
                if kind == .primary || kind == .destructive || kind == .success {
                    // Inner top highlight, like BoardUI's raised primary buttons.
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                }
            }
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(hovering ? t.borderStrong : t.border, lineWidth: 1)
                }
            }
            .shadow(color: kind == .secondary || kind == .primary ? t.shadow : .clear, radius: 0.5, y: 1)
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(pressed ? 0.975 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    func foreground(_ t: BKTheme) -> Color {
        switch kind {
        case .primary, .destructive, .success: return .white
        case .secondary, .ghost: return t.text
        case .tinted: return t.accentText
        }
    }

    func fill(_ t: BKTheme, pressed: Bool) -> AnyShapeStyle {
        switch kind {
        case .primary:
            return pressed ? AnyShapeStyle(LinearGradient(colors: [BK.Palette.accent600, BK.Palette.accent700], startPoint: .top, endPoint: .bottom))
                : hovering ? AnyShapeStyle(LinearGradient(colors: [BK.Palette.accent400, BK.Palette.accent500], startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(BK.accentGradient)
        case .destructive:
            return AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xEF4444), Color(hex: 0xDC2626)], startPoint: .top, endPoint: .bottom).opacity(pressed ? 0.85 : 1))
        case .success:
            return AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x22C55E), Color(hex: 0x16A34A)], startPoint: .top, endPoint: .bottom).opacity(pressed ? 0.85 : 1))
        case .secondary:
            return AnyShapeStyle(pressed ? t.mutedHover : (hovering ? t.raisedHover : t.raised))
        case .ghost:
            return AnyShapeStyle(pressed ? t.mutedHover : (hovering ? t.muted : Color.clear.opacity(0.0001)))
        case .tinted:
            return AnyShapeStyle(t.accentSoft.opacity(pressed ? 1 : (hovering ? 0.9 : 0.7)))
        }
    }
}

/// Round icon button used in the notch.
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
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tone?.color ?? BK.Notch.text)
                .frame(width: size, height: size)
                .background(Circle().fill(hovering ? BK.Palette.n700 : BK.Palette.n800))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Switch, segmented control, menus, stepper

/// BoardUI switch: gradient-blue track when on, white chip, spring motion.
struct BKSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        BKThemeReader { t in
            HStack(spacing: 8) {
                configuration.label.fixedSize()
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? AnyShapeStyle(BK.accentGradient) : AnyShapeStyle(t.dark ? BK.Palette.n700 : BK.Palette.n200))
                        .overlay(Capsule().strokeBorder(Color.black.opacity(configuration.isOn ? 0.06 : (t.dark ? 0 : 0.04)), lineWidth: 1))
                    Circle()
                        .fill(LinearGradient(colors: [.white, configuration.isOn ? .white : BK.Palette.n100], startPoint: .top, endPoint: .bottom))
                        .frame(width: 14, height: 14)
                        .overlay {
                            if configuration.isOn { Circle().fill(BK.Palette.accent500).frame(width: 5, height: 5) }
                        }
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                        .padding(2)
                }
                .frame(width: 32, height: 18)
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isOn)
                .contentShape(Capsule())
                .onTapGesture { configuration.isOn.toggle() }
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(configuration.isOn ? "On" : "Off")
                .accessibilityAction { configuration.isOn.toggle() }
            }
        }
    }
}

extension ToggleStyle where Self == BKSwitchStyle {
    static var bk: BKSwitchStyle { BKSwitchStyle() }
}

/// A labels-hidden BoardUI switch.
struct BKSwitch: View {
    @Binding var isOn: Bool
    var label = ""
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Toggle(isOn: $isOn) { EmptyView() }.toggleStyle(.bk).opacity(enabled ? 1 : 0.45).accessibilityLabel(label)
    }
}

/// BoardUI segmented control: muted track, raised sliding pill.
struct BKSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var onDark = false
    @Namespace private var ns

    var body: some View {
        BKThemeReader { base in
            let t = onDark ? BKTheme(dark: true) : base
            HStack(spacing: 2) {
                ForEach(options, id: \.0) { value, title in
                    let selected = value == selection
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? t.text : t.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 4.5)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(t.raised)
                                    .bkFloatShadow(t)
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = value } }
                        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityLabel(title)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.dark ? BK.Palette.n925 : BK.Palette.n100))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(t.border.opacity(t.dark ? 1 : 0.6), lineWidth: 1))
            .fixedSize()
        }
    }
}

/// Dropdown styled like BoardUI's select trigger.
struct BKMenu<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var minWidth: CGFloat = 0

    var body: some View {
        BKThemeReader { t in
            Menu {
                ForEach(options, id: \.0) { value, title in
                    Button { selection = value } label: {
                        if value == selection { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(options.first { $0.0 == selection }?.1 ?? "—").font(.system(size: 12.5, weight: .medium)).foregroundStyle(t.text).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(t.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5.5)
                .frame(minWidth: minWidth)
                .background(RoundedRectangle(cornerRadius: BK.Radius.md, style: .continuous).fill(t.raised))
                .overlay(RoundedRectangle(cornerRadius: BK.Radius.md, style: .continuous).strokeBorder(t.border, lineWidth: 1))
                .shadow(color: t.shadow, radius: 0.5, y: 1)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// Compact − value + stepper.
struct BKStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String = { String(Int($0)) }

    var body: some View {
        BKThemeReader { t in
            HStack(spacing: 0) {
                button("minus", t) { value = max(range.lowerBound, value - step) }.disabled(value <= range.lowerBound)
                Text(format(value)).font(.system(size: 12.5, weight: .medium).monospacedDigit()).foregroundStyle(t.text)
                    .frame(minWidth: 56).padding(.horizontal, 4)
                    .contentTransition(.numericText())
                button("plus", t) { value = min(range.upperBound, value + step) }.disabled(value >= range.upperBound)
            }
            .background(RoundedRectangle(cornerRadius: BK.Radius.md, style: .continuous).fill(t.raised))
            .overlay(RoundedRectangle(cornerRadius: BK.Radius.md, style: .continuous).strokeBorder(t.border, lineWidth: 1))
            .shadow(color: t.shadow, radius: 0.5, y: 1)
            .animation(.snappy(duration: 0.2), value: value)
        }
    }

    func button(_ icon: String, _ t: BKTheme, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(t.secondary)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension BKStepper {
    init(value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, format: @escaping (Int) -> String = { String($0) }) {
        self.init(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }),
                  range: Double(range.lowerBound)...Double(range.upperBound), step: Double(step), format: { format(Int($0)) })
    }
}

// MARK: - Badges, dots, keycaps, tiles

/// BoardUI chip: pastel fill, dark text.
struct BKBadge: View {
    let text: String
    var tone: BK.Tone = .neutral
    var icon: String? = nil
    var body: some View {
        BKThemeReader { t in
            let c = tone.chip(dark: t.dark)
            HStack(spacing: 3) {
                if let icon { Image(systemName: icon).font(.system(size: 8.5, weight: .bold)) }
                Text(text)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .foregroundStyle(c.text)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.background))
            .fixedSize()
        }
    }
}

/// Status dot with BoardUI's soft halo.
struct BKStatusDot: View {
    var tone: BK.Tone
    var pulsing = false
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle().fill(tone.color.opacity(0.22)).frame(width: 12, height: 12)
                .scaleEffect(pulsing && pulse ? 1.45 : 1).opacity(pulsing && pulse ? 0 : 1)
            Circle().fill(tone.color).frame(width: 6, height: 6)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityHidden(true)
    }
}

struct BKKeyCap: View {
    let text: String
    var onDark = false
    var body: some View {
        BKThemeReader { base in
            let t = onDark ? BKTheme(dark: true) : base
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .foregroundStyle(t.secondary)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(t.dark ? BK.Palette.n800 : BK.Palette.n200))
                .fixedSize()
        }
    }
}

/// Rounded square avatar tile: a logo (when one is loaded), a symbol, or initials on a brand
/// color, with an optional status dot in the corner (BoardUI's MCP list rows).
struct BKTile: View {
    var title: String
    var color: Color = BK.Palette.n500
    var symbol: String? = nil
    var logoURL: URL? = nil
    var size: CGFloat = 32
    var status: BK.Tone? = nil

    var body: some View {
        BKThemeReader { t in
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(logoURL == nil ? AnyShapeStyle(color.gradient) : AnyShapeStyle(t.raised))
                if let logoURL {
                    AsyncImage(url: logoURL) { img in img.resizable().scaledToFit() } placeholder: { initials }
                        .padding(size * 0.16)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(.white)
                } else {
                    initials
                }
            }
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Color.black.opacity(t.dark ? 0.2 : 0.06), lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                if let status {
                    Circle().fill(status.color).frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(t.canvas, lineWidth: 1.5))
                        .offset(x: -2, y: 2)
                }
            }
            .accessibilityHidden(true)
        }
    }

    var initials: some View {
        Text(String(title.prefix(1)).uppercased())
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(logoURL == nil ? .white : color)
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
        .shadow(color: mode == .thinking || mode == .acting ? Color(hex: 0x5B7CFF).opacity(0.7) : .clear, radius: 6)
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

/// BoardUI agent-progress ring: a spinning accent arc for the active step.
struct BKProgressRing: View {
    var size: CGFloat = 14
    var lineWidth: CGFloat = 2
    var trackColor: Color = BK.Palette.n700
    @State private var spin = false
    var body: some View {
        ZStack {
            Circle().stroke(trackColor, lineWidth: lineWidth)
            Circle().trim(from: 0, to: 0.32)
                .stroke(AngularGradient(colors: [BK.Palette.accent500.opacity(0), BK.Palette.accent400], center: .center, startAngle: .zero, endAngle: .degrees(115)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true } }
        .accessibilityHidden(true)
    }
}

/// BoardUI "composer loader": an iridescent band of light travelling around a rounded rim.
struct BKIridescentRim: ViewModifier {
    var active: Bool
    var cornerRadius: CGFloat
    @State private var angle = 0.0

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                let band = AngularGradient(colors: [.clear, .clear, Color(hex: 0x8B6BFF), Color(hex: 0x3D8BFF), Color(hex: 0x33E0D4), Color(hex: 0xFF73BF), .clear],
                                           center: .center, angle: .degrees(angle))
                ZStack {
                    shape.strokeBorder(band, lineWidth: 6).blur(radius: 7).opacity(0.55)
                    shape.strokeBorder(band, lineWidth: 1.2)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                .onAppear { withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { angle = 360 } }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: active)
    }
}

extension View {
    func bkIridescentRim(_ active: Bool, cornerRadius: CGFloat) -> some View {
        modifier(BKIridescentRim(active: active, cornerRadius: cornerRadius))
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

// MARK: - Page structure (settings, onboarding — light/dark adaptive)

/// Page title and lead paragraph.
struct BKSectionHeader: View {
    let title: String
    var subtitle: String?
    var body: some View {
        BKThemeReader { t in
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(BK.Font.title2).foregroundStyle(t.text)
                if let subtitle { Text(subtitle).font(BK.Font.body).foregroundStyle(t.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
        }
    }
}

/// Small heading above a group ("Pull Requests", "Home MCP Servers").
struct BKGroupHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    var body: some View {
        BKThemeReader { t in
            HStack(alignment: .bottom, spacing: BK.Space.md) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(BK.Font.captionMedium).foregroundStyle(t.text.opacity(0.85))
                    if let subtitle { Text(subtitle).font(BK.Font.caption).foregroundStyle(t.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
                accessory
            }
            .padding(.horizontal, 4)
            .padding(.top, 6)
        }
    }
}

extension BKGroupHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

/// BoardUI grouped rows: a muted rounded container; each child row is separated by a
/// hairline in the page color.
struct BKGroup<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    @ViewBuilder var content: Content
    var body: some View {
        BKThemeReader { t in
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        if i > 0 { Rectangle().fill(t.dark ? t.border : t.canvas).frame(height: 1) }
                        row.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: BK.Radius.xl, style: .continuous).fill(t.muted))
            .overlay {
                if t.dark { RoundedRectangle(cornerRadius: BK.Radius.xl, style: .continuous).strokeBorder(t.border, lineWidth: 1) }
            }
            .clipShape(RoundedRectangle(cornerRadius: BK.Radius.xl, style: .continuous))
        }
    }
}

/// A settings row: title, optional detail, trailing control.
struct BKFormRow<Accessory: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var accessory: Accessory
    var body: some View {
        BKThemeReader { t in
            HStack(alignment: .center, spacing: BK.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(BK.Font.bodyMedium).foregroundStyle(t.text)
                    if let detail { Text(detail).font(BK.Font.caption).foregroundStyle(t.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: BK.Space.md)
                accessory
            }
        }
    }
}

extension BKFormRow where Accessory == EmptyView {
    init(title: String, detail: String? = nil) { self.init(title: title, detail: detail) { EmptyView() } }
}

/// A raised card (catalog tiles, history entries).
struct BKCard<Content: View>: View {
    var padding: CGFloat = BK.Space.lg
    var selected = false
    @ViewBuilder var content: Content
    var body: some View {
        BKThemeReader { t in
            VStack(alignment: .leading, spacing: BK.Space.md) { content }
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: BK.Radius.xxl, style: .continuous).fill(t.dark ? BK.Palette.n900 : BK.Palette.white))
                .overlay(RoundedRectangle(cornerRadius: BK.Radius.xxl, style: .continuous)
                    .strokeBorder(selected ? t.accent.opacity(0.7) : t.border, lineWidth: selected ? 1.5 : 1))
                .bkCardShadow(t)
        }
    }
}

/// Inline notification (BoardUI Notification): icon tile, title, message, optional action.
struct BKCallout<Accessory: View>: View {
    var tone: BK.Tone = .info
    var icon: String
    var title: String
    var message: String?
    @ViewBuilder var accessory: Accessory
    var body: some View {
        BKThemeReader { t in
            let c = tone.chip(dark: t.dark)
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(c.text)
                    .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.background))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(BK.Font.bodyMedium).foregroundStyle(t.text)
                    if let message { Text(message).font(BK.Font.caption).foregroundStyle(t.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                accessory
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: BK.Radius.xl, style: .continuous).fill(t.dark ? BK.Palette.n900 : BK.Palette.white))
            .overlay(RoundedRectangle(cornerRadius: BK.Radius.xl, style: .continuous).strokeBorder(t.border, lineWidth: 1))
            .bkCardShadow(t)
        }
    }
}

extension BKCallout where Accessory == EmptyView {
    init(tone: BK.Tone = .info, icon: String, title: String, message: String? = nil) {
        self.init(tone: tone, icon: icon, title: title, message: message) { EmptyView() }
    }
}

/// Centered empty state inside a muted container.
struct BKEmptyState: View {
    var icon: String? = nil
    let title: String
    var message: String?
    var body: some View {
        BKThemeReader { t in
            VStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 18, weight: .medium)).foregroundStyle(t.tertiary).padding(.bottom, 2) }
                Text(title).font(BK.Font.bodyMedium).foregroundStyle(t.text)
                if let message { Text(message).font(BK.Font.caption).foregroundStyle(t.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26).padding(.horizontal, 20)
            .background(RoundedRectangle(cornerRadius: BK.Radius.xl, style: .continuous).fill(t.muted))
        }
    }
}

// MARK: - Inputs

private struct BKFieldChrome: ViewModifier {
    var focused: Bool
    func body(content: Content) -> some View {
        BKThemeReader { t in
            content
                .padding(.horizontal, 10).padding(.vertical, 6.5)
                .background(RoundedRectangle(cornerRadius: BK.Radius.md, style: .continuous).fill(t.raised))
                .overlay(RoundedRectangle(cornerRadius: BK.Radius.md, style: .continuous).strokeBorder(focused ? t.accent : t.border, lineWidth: 1))
                .overlay(RoundedRectangle(cornerRadius: BK.Radius.md + 2, style: .continuous).strokeBorder(t.accent.opacity(focused ? 0.22 : 0), lineWidth: 3).padding(-2))
                .shadow(color: t.shadow, radius: 0.5, y: 1)
                .animation(.easeOut(duration: 0.12), value: focused)
        }
    }
}

/// Masked secret input with paste and show/hide (keys are masked by default).
struct BKSecretField: View {
    let placeholder: String
    @Binding var text: String
    @State private var revealed = false
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 7) {
            Group {
                if revealed { TextField(placeholder, text: $text) } else { SecureField(placeholder, text: $text) }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: .monospaced))
            .focused($focused)
            Button {
                if let clip = NSPasteboard.general.string(forType: .string) {
                    text = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } label: {
                Image(systemName: "doc.on.clipboard").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Paste from clipboard")
            .accessibilityLabel("Paste from clipboard")
            Button { revealed.toggle() } label: {
                Image(systemName: revealed ? "eye.slash" : "eye").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(revealed ? "Hide key" : "Show key")
            .accessibilityLabel(revealed ? "Hide key" : "Show key")
        }
        .modifier(BKFieldChrome(focused: focused))
    }
}

struct BKTextField: View {
    let placeholder: String
    @Binding var text: String
    var monospaced = false
    @FocusState private var focused: Bool
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: monospaced ? .monospaced : .default))
            .focused($focused)
            .modifier(BKFieldChrome(focused: focused))
    }
}

/// Multi-line field with the same chrome.
struct BKTextEditor: View {
    @Binding var text: String
    var monospaced = false
    var height: CGFloat = 70
    @FocusState private var focused: Bool
    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .scrollContentBackground(.hidden)
            .focused($focused)
            .frame(height: height)
            .padding(.horizontal, -4).padding(.vertical, -2)
            .modifier(BKFieldChrome(focused: focused))
    }
}

/// BoardUI "Quick Search": muted field with a magnifier.
struct BKSearchField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool
    var body: some View {
        BKThemeReader { t in
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(t.secondary)
                TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12.5)).focused($focused).onSubmit(onSubmit)
                if !text.isEmpty {
                    Button { text = ""; onSubmit() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(t.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: BK.Radius.lg, style: .continuous).fill(t.muted))
            .overlay(RoundedRectangle(cornerRadius: BK.Radius.lg, style: .continuous).strokeBorder(focused ? t.accent : t.border.opacity(t.dark ? 1 : 0.0), lineWidth: 1))
        }
    }
}

/// Selectable filter pill (BoardUI pill tabs).
struct BKPill: View {
    let title: String
    var count: Int? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        BKThemeReader { t in
            Button(action: action) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    if let count {
                        Text("\(count)").font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(selected ? t.accentSoft : (t.dark ? BK.Palette.n800 : BK.Palette.n200)))
                    }
                }
                .foregroundStyle(selected ? t.accentText : t.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(selected ? t.accentSoft.opacity(0.55) : (hovering ? t.muted : .clear)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}
