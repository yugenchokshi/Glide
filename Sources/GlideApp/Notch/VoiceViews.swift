import SwiftUI
import AgentKit
import AutomationKit

// MARK: - Pieces

/// Live input level as a row of soft bars; flat and dim while the microphone isn't open yet.
struct VoiceWaveform: View {
    var levels: [Float]
    var active: Bool
    var bars = 14
    var height: CGFloat = 26

    var body: some View {
        let recent = Array(levels.suffix(bars))
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(recent.indices, id: \.self) { i in
                Capsule()
                    .fill(active ? AnyShapeStyle(LinearGradient(colors: [BK.Palette.accent400, Color(hex: 0x33E0D4)], startPoint: .bottom, endPoint: .top))
                                 : AnyShapeStyle(BK.Palette.n700))
                    .frame(width: 3, height: max(3, CGFloat(recent[i]) * height))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.12), value: recent)
        .accessibilityHidden(true)
    }
}

/// The microphone is on. Shown whenever it is, so listening is never silent.
struct MicIndicator: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(BK.Tone.danger.color).frame(width: 6, height: 6)
            Image(systemName: "mic.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(BK.Notch.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(BK.Palette.n900))
        .help("The microphone is on")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone on")
    }
}

// MARK: - Listening

/// The user is talking: waveform, live transcript, and how to switch to typing. Ends on its own
/// when they stop; any key switches to the text field with what was heard so far.
struct NotchListeningView: View {
    @Bindable var model: NotchModel
    @FocusState private var focused: Bool

    var body: some View {
        let v = model.voice
        VStack(alignment: .leading, spacing: 7) {
            if let q = model.shownQuestion {
                Text(q.text).font(.system(size: 12)).foregroundStyle(BK.Notch.secondary).lineLimit(1)
            }
            HStack(spacing: 12) {
                VoiceWaveform(levels: v.levels, active: v.micLive)
                    .frame(width: 58)
                Group {
                    if v.transcript.isEmpty {
                        Text(v.preparing ? "Getting ready…" : (v.micLive ? "Listening…" : "Starting the microphone…"))
                            .foregroundStyle(BK.Notch.tertiary)
                    } else {
                        Text(v.transcript).foregroundStyle(BK.Notch.text)
                            .contentTransition(.opacity)
                    }
                }
                .font(.system(size: 15))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                BKIconButton(systemName: "mic.fill", help: "Stop listening and type", tone: .danger, size: 30) { model.switchToTyping() }
            }
            .padding(.leading, 14).padding(.trailing, 7).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BK.Notch.field))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(BK.Notch.border))
            .bkIridescentRim(v.micLive && v.heardSpeech, cornerRadius: 16)
            if v.preparing {
                HStack(spacing: 8) {
                    ProgressView(value: v.preparingFraction ?? 0).progressViewStyle(.linear).tint(BK.Palette.accent400).frame(width: 90)
                    Text("Setting up on-device speech recognition (first time only)…").font(.system(size: 11)).foregroundStyle(BK.Notch.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                if v.micLive { MicIndicator() }
                Text(v.userInitiated ? "Just talk — I'll send it when you pause. Type to switch, esc to cancel." : "Go ahead, I'm listening.")
                    .font(.system(size: 11)).foregroundStyle(BK.Notch.tertiary).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 8)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handle(press) }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape {
            model.close()
            return .handled
        }
        if press.key == .return {
            model.voice.finishNow()
            return .handled
        }
        guard press.modifiers.isDisjoint(with: [.command, .control]) else { return .ignored }
        let typed = press.characters.filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
        guard !typed.isEmpty else { return .ignored }
        model.switchToTyping(typed: typed)
        return .handled
    }
}

// MARK: - Thinking

struct NotchThinkingView: View {
    var body: some View {
        HStack(spacing: 10) {
            BKAgentOrb(mode: .thinking, size: 16)
            BKShimmerText(text: "Thinking…")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BK.Notch.field))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(BK.Notch.border))
        .padding(.top, 6)
    }
}

// MARK: - Speaking

/// The short line Glide is saying (or just said). Shown whether or not it is spoken.
struct NotchSpeakingView: View {
    @Bindable var model: NotchModel

    var body: some View {
        let v = model.voice
        HStack(spacing: 10) {
            BKAgentOrb(mode: orbMode(v), size: 18)
            Text(v.caption ?? "").font(.system(size: 13.5, weight: .medium)).foregroundStyle(BK.Notch.text).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
            if v.micLive { MicIndicator() }
            if v.isSpeaking {
                BKIconButton(systemName: "speaker.slash.fill", help: "Stop talking") { v.stopSpeaking() }
            } else {
                BKIconButton(systemName: "xmark", help: "Dismiss") { model.close() }
            }
        }
        .padding(.leading, 12).padding(.trailing, 7).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BK.Notch.field))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(BK.Notch.border))
        .bkIridescentRim(v.isSpeaking, cornerRadius: 14)
        .padding(.top, 6)
    }

    private func orbMode(_ v: VoiceSession) -> BKAgentOrb.Mode {
        switch v.captionKind {
        case .error: return .error
        case .needsYou: return .paused
        case .result: return v.isSpeaking ? .acting : .success
        default: return v.isSpeaking ? .acting : .idle
        }
    }
}

// MARK: - Question

/// A question Glide asks while it keeps working: the text, up to four option chips, and, right
/// after it was asked, a live "listening for your answer" line. The task carries on underneath.
struct NotchQuestionView: View {
    @Bindable var model: NotchModel

    var body: some View {
        if let q = model.shownQuestion {
            let v = model.voice
            let c = model.controller
            VStack(alignment: .leading, spacing: 9) {
                if c.isRunning {
                    HStack(spacing: 6) {
                        BKStatusDot(tone: .info, pulsing: true)
                        Text(c.status).font(.system(size: 11)).foregroundStyle(BK.Notch.tertiary).lineLimit(1)
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    let chip = BK.Tone.accent.chip(dark: true)
                    Image(systemName: q.isApproval ? "hand.raised.fill" : "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(chip.text)
                        .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(chip.background))
                    Text(q.text).font(.system(size: 14, weight: .medium)).foregroundStyle(BK.Notch.text).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    BKIconButton(systemName: "keyboard", help: "Type an answer") { model.typeAnswer() }
                }
                if !q.options.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(q.options.prefix(4).enumerated()), id: \.offset) { _, option in
                            OptionChip(title: option, suggested: option == q.defaultOption) { model.answerQuestion(q, with: option) }
                        }
                        Spacer(minLength: 0)
                    }
                }
                if v.purpose == .answer {
                    HStack(spacing: 8) {
                        MicIndicator()
                        VoiceWaveform(levels: v.levels, active: v.micLive, bars: 10, height: 14)
                        Text(v.partial.isEmpty ? "Listening for your answer…" : v.partial)
                            .font(.system(size: 12)).foregroundStyle(v.partial.isEmpty ? BK.Notch.tertiary : BK.Notch.text).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.top, 8)
            // A new question gets new chips: a press that began on the previous card is dropped.
            .id(q.id)
        }
    }
}

private struct OptionChip: View {
    let title: String
    var suggested = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(NotchApprovalView.short(title, max: 28))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(BK.Notch.text).lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 13, style: .continuous).fill(hovering ? BK.Palette.n700 : BK.Palette.n800)
                        RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(suggested ? BK.Palette.accent400.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}
