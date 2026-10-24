import AppKit

/// Glide never acts on input its own agent posted. The agent can't see Glide's windows (they're
/// left out of its screenshots), so a click or keystroke it aims at the app underneath could
/// land on the notch, on Settings (safety switches included), or on one of Glide's sheets and
/// dialogs. The notch also turns click-through while the agent uses the pointer, so its clicks
/// reach their target; anything that still lands on Glide is dropped here.
final class GlideApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if NotchClickGuard.dropsAgentInput(event) { return }
        super.sendEvent(event)
    }
}
