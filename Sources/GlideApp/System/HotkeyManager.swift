import AppKit
import Carbon.HIToolbox
import AgentKit
import AutomationKit

/// System-wide shortcuts via Carbon RegisterEventHotKey. Works while Glide is in the
/// background and its UI is hidden (needed for the emergency stop), and needs no permission.
@MainActor
final class HotkeyManager {
    enum Action: UInt32, CaseIterable { case open = 1, pauseResume = 2, stop = 3 }

    private var refs: [Action: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    var handler: (Action) -> Void = { _ in }
    /// Actions whose shortcut couldn't be registered (already taken by another app).
    private(set) var conflicts: [Action: String] = [:]

    static let signature: OSType = 0x4E425554 // "NBUT"

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            if let action = Action(rawValue: id.id) {
                MainActor.assumeIsolated { manager.handler(action) }
            }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
    }

    func apply(_ settings: HotkeySettings) {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        conflicts.removeAll()
        let pairs: [(Action, HotkeySetting)] = [(.open, settings.open), (.pauseResume, settings.pauseResume), (.stop, settings.stop)]
        for (action, setting) in pairs where setting.enabled {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let status = RegisterEventHotKey(setting.keyCode, setting.modifierSet.carbonFlags, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
            } else {
                conflicts[action] = "\(setting.display) is already used by another app or the system."
            }
        }
        // macOS system shortcuts (Spotlight, input sources, screenshots…) win over ours.
        for (action, setting) in pairs where setting.enabled && Self.isSystemShortcut(keyCode: setting.keyCode, modifiers: setting.modifierSet) {
            conflicts[action] = "\(setting.display) is a macOS system shortcut (System Settings › Keyboard › Keyboard Shortcuts)."
        }
        // Two Glide actions bound to the same keys is also a conflict.
        let displays = pairs.map { $0.1.display }
        for (action, setting) in pairs where displays.filter({ $0 == setting.display }).count > 1 {
            conflicts[action] = "\(setting.display) is assigned to more than one Glide action."
        }
    }
}

extension HotkeyManager {
    /// Checks the enabled entries in com.apple.symbolichotkeys. Shortcuts registered by other
    /// third-party apps can't be detected (Carbon accepts duplicate registrations silently).
    static func isSystemShortcut(keyCode: UInt32, modifiers: KeyCombination.Modifiers) -> Bool {
        guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") else { return false }
        var mask = 0
        if modifiers.contains(.shift) { mask |= 1 << 17 }
        if modifiers.contains(.control) { mask |= 1 << 18 }
        if modifiers.contains(.option) { mask |= 1 << 19 }
        if modifiers.contains(.command) { mask |= 1 << 20 }
        for case let entry as [String: Any] in all.values {
            guard (entry["enabled"] as? Bool) == true || (entry["enabled"] as? Int) == 1,
                  let value = entry["value"] as? [String: Any], let params = value["parameters"] as? [Int], params.count >= 3 else { continue }
            let relevant = params[2] & ((1 << 17) | (1 << 18) | (1 << 19) | (1 << 20))
            if params[1] == Int(keyCode) && relevant == mask { return true }
        }
        return false
    }
}

extension HotkeySetting {
    /// Builds a hotkey from a key event captured by the shortcut recorder.
    static func from(event: NSEvent) -> HotkeySetting? {
        var mods: KeyCombination.Modifiers = []
        let f = event.modifierFlags
        if f.contains(.command) { mods.insert(.command) }
        if f.contains(.option) { mods.insert(.option) }
        if f.contains(.control) { mods.insert(.control) }
        if f.contains(.shift) { mods.insert(.shift) }
        guard !mods.isEmpty || (event.keyCode >= 0x60 && event.keyCode <= 0x7A) else { return nil } // F-keys allowed bare
        var display = ""
        if mods.contains(.control) { display += "⌃" }
        if mods.contains(.option) { display += "⌥" }
        if mods.contains(.shift) { display += "⇧" }
        if mods.contains(.command) { display += "⌘" }
        let key: String = {
            switch Int(event.keyCode) {
            case kVK_Space: return "Space"
            case kVK_Return: return "↩"
            case kVK_Escape: return "⎋"
            case kVK_Delete: return "⌫"
            case kVK_Tab: return "⇥"
            default: return (event.charactersIgnoringModifiers ?? "?").uppercased()
            }
        }()
        return HotkeySetting(keyCode: UInt32(event.keyCode), modifiers: mods, display: display + key)
    }
}
