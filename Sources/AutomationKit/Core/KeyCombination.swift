import Foundation
import CoreGraphics
import Carbon.HIToolbox

/// A key plus modifiers, parsed from strings like "cmd+shift+n", "return", "⌘S", "ctrl-a".
public struct KeyCombination: Codable, Sendable, Hashable {
    public struct Modifiers: OptionSet, Codable, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
        public static let function = Modifiers(rawValue: 1 << 4)

        public var cgFlags: CGEventFlags {
            var flags: CGEventFlags = []
            if contains(.command) { flags.insert(.maskCommand) }
            if contains(.shift) { flags.insert(.maskShift) }
            if contains(.option) { flags.insert(.maskAlternate) }
            if contains(.control) { flags.insert(.maskControl) }
            if contains(.function) { flags.insert(.maskSecondaryFn) }
            return flags
        }

        /// Carbon modifier mask for RegisterEventHotKey.
        public var carbonFlags: UInt32 {
            var flags: UInt32 = 0
            if contains(.command) { flags |= UInt32(cmdKey) }
            if contains(.shift) { flags |= UInt32(shiftKey) }
            if contains(.option) { flags |= UInt32(optionKey) }
            if contains(.control) { flags |= UInt32(controlKey) }
            return flags
        }
    }

    public var key: String
    public var keyCode: CGKeyCode
    public var modifiers: Modifiers

    public init(keyCode: CGKeyCode, key: String, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.key = key
        self.modifiers = modifiers
    }

    public init(parsing raw: String) throws {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var mods: Modifiers = []
        // Symbol prefixes: ⌘⇧⌥⌃
        let symbols: [(Character, Modifiers)] = [("⌘", .command), ("⇧", .shift), ("⌥", .option), ("⌃", .control)]
        while let first = text.first, let match = symbols.first(where: { $0.0 == first }) {
            mods.insert(match.1)
            text.removeFirst()
        }
        text = text.lowercased().replacingOccurrences(of: " ", with: "")
        // "cmd+-" / "cmd++" / "-": the key itself is a separator character.
        var literalKey: String?
        if let last = text.last, last == "+" || last == "-" {
            let before = text.dropLast()
            if before.isEmpty || before.last == "+" || before.last == "-" {
                literalKey = String(last)
                text = String(before.dropLast(before.isEmpty ? 0 : 1))
            }
        }
        var parts = text.split(whereSeparator: { $0 == "+" || $0 == "-" }).map(String.init)
        let keyName: String
        if let literalKey {
            keyName = literalKey
        } else {
            keyName = parts.popLast() ?? ""
        }
        for part in parts {
            switch part {
            case "cmd", "command", "meta", "super": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            case "fn", "function": mods.insert(.function)
            default: throw AutomationError.invalidKeyCombination(raw)
            }
        }
        guard let code = KeyCodes.code(for: keyName) else { throw AutomationError.invalidKeyCombination(raw) }
        self.init(keyCode: code, key: keyName, modifiers: mods)
    }

    public var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + KeyCodes.displayName(for: key)
    }
}

public enum KeyCodes {
    static let named: [String: Int] = [
        "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space,
        "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
        "escape": kVK_Escape, "esc": kVK_Escape, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "up": kVK_UpArrow, "down": kVK_DownArrow, "home": kVK_Home, "end": kVK_End,
        "pageup": kVK_PageUp, "pagedown": kVK_PageDown, "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3,
        "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9,
        "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12, "keypadenter": kVK_ANSI_KeypadEnter,
    ]
    static let characters: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8,
        "9": kVK_ANSI_9, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "+": kVK_ANSI_Equal,
        "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
        "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
    ]

    public static func code(for key: String) -> CGKeyCode? {
        let k = key.lowercased()
        if let c = named[k] { return CGKeyCode(c) }
        if k.count == 1, let ch = k.first, let c = characters[ch] { return CGKeyCode(c) }
        return nil
    }

    public static func displayName(for key: String) -> String {
        switch key.lowercased() {
        case "return", "enter": return "↩"
        case "tab": return "⇥"
        case "space": return "Space"
        case "delete", "backspace": return "⌫"
        case "escape", "esc": return "⎋"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        default: return key.uppercased()
        }
    }
}
