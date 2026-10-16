import SwiftUI
import AgentKit

/// BoardUI-style "agent progress": the plan's steps with done / current / pending states.
struct BKPlanProgress: View {
    let plan: Plan
    let currentIndex: Int
    var finished = false
    var onDark = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(plan.steps.enumerated()), id: \.offset) { i, step in
                HStack(spacing: 8) {
                    marker(for: i)
                    Text(step.title)
                        .font(.system(size: 12, weight: i == currentIndex && !finished ? .semibold : .regular))
                        .foregroundStyle(color(for: i))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if step.risk == .high { BKBadge(text: "Approval", tone: .warning) }
                    if step.route != .gui { BKBadge(text: step.route.rawValue.capitalized, tone: .info) }
                }
            }
        }
    }

    @ViewBuilder func marker(for i: Int) -> some View {
        if i < currentIndex || finished {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(BK.Tone.success.color)
                .frame(width: 14, height: 14)
        } else if i == currentIndex {
            BKProgressRing(size: 13, trackColor: onDark ? BK.Palette.n800 : BK.Palette.n200)
        } else {
            Circle().strokeBorder(onDark ? BK.Palette.n700 : BK.Palette.n300, style: StrokeStyle(lineWidth: 1.2, dash: [2.2, 2.2]))
                .frame(width: 13, height: 13)
        }
    }

    func color(for i: Int) -> Color {
        if i == currentIndex && !finished { return onDark ? BK.Notch.text : .primary }
        return onDark ? BK.Notch.secondary : .secondary
    }
}

/// Human-readable activity timeline.
struct BKTimeline: View {
    let entries: [ActivityEntry]
    var onDark = true
    var showDetails = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { e in
                HStack(alignment: .top, spacing: 9) {
                    VStack(spacing: 0) {
                        icon(e).frame(width: 18, height: 18)
                        Rectangle().fill(onDark ? BK.Notch.border : Color(nsColor: .separatorColor)).frame(width: 1).frame(maxHeight: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(e.title).font(.system(size: 12, weight: e.kind == .step ? .semibold : .regular))
                                .foregroundStyle(onDark ? BK.Notch.text : .primary).lineLimit(2)
                            if let ms = e.durationMs, e.kind == .action || e.kind == .tool || e.kind == .verify {
                                Text(ms < 1000 ? "\(Int(ms))ms" : String(format: "%.1fs", ms / 1000))
                                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(onDark ? BK.Notch.tertiary : .secondary)
                            }
                        }
                        if showDetails, let d = e.detail, !d.isEmpty {
                            Text(d).font(.system(size: 11)).foregroundStyle(onDark ? BK.Notch.secondary : .secondary).lineLimit(4)
                        }
                    }
                    .padding(.bottom, 9)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder func icon(_ e: ActivityEntry) -> some View {
        let (name, tone): (String, BK.Tone) = {
            switch e.kind {
            case .plan: return ("list.bullet", .accent)
            case .step: return ("arrow.right.circle.fill", .accent)
            case .action: return (e.success == false ? "xmark.circle.fill" : "cursorarrow.click.2", e.success == false ? .danger : .info)
            case .verify: return ("checkmark.seal.fill", .success)
            case .model: return ("sparkles", .accent)
            case .tool: return ("puzzlepiece.extension.fill", e.success == false ? .danger : .info)
            case .recovery: return ("arrow.triangle.2.circlepath", .warning)
            case .approval: return ("hand.raised.fill", e.success == false ? .danger : .warning)
            case .error: return ("exclamationmark.triangle.fill", .danger)
            case .info: return ("info.circle.fill", .neutral)
            case .result: return ("flag.checkered", .success)
            case .vision: return ("eye.fill", e.success == false ? .danger : .info)
            }
        }()
        Image(systemName: name).font(.system(size: 11)).foregroundStyle(tone.color)
    }
}
