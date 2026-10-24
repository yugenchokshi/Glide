import Testing
import Foundation
@testable import AgentKit
@testable import AutomationKit

// browser.press types characters just like browser.type, so the same fields are off limits.
// These only judge snapshots; no browser is started.

@Suite("browser.press risk")
struct BrowserPressRiskTests {
    private func page(focused element: PageSnapshot.Element?, url: String = "https://example.com/login") -> PageSnapshot {
        PageSnapshot(tabID: "t", url: url, title: "Sign in", elements: element.map { [$0] } ?? [])
    }

    private let password = PageSnapshot.Element(ref: "e1", role: "textbox", name: "Password", inputType: "password", focused: true, secure: true)
    private let cardNumber = PageSnapshot.Element(ref: "e2", role: "textbox", name: "Card number", focused: true)
    private let search = PageSnapshot.Element(ref: "e3", role: "searchbox", name: "Search", focused: true)

    @Test func neverTypesIntoAPasswordField() {
        for keys in ["h u n t e r 2", "Shift+h", "Space", "plus", "Meta+V", "Control+v", "Shift+Insert", "a Enter"] {
            let v = BrowserRisk.press(keys: keys, page: page(focused: password))
            #expect(v.blocked?.contains("password") == true, "\(keys) should be refused")
        }
        // A field marked secure without a password type is the same.
        var masked = password
        masked.inputType = nil
        #expect(BrowserRisk.press(keys: "x", page: page(focused: masked)).blocked != nil)
    }

    @Test func navigationKeysStillWorkInAPasswordField() {
        for keys in ["Tab", "Shift+Tab", "Escape", "ArrowDown", "Backspace", "Meta+A", "Enter"] {
            #expect(BrowserRisk.press(keys: keys, page: page(focused: password)).blocked == nil, "\(keys) should be allowed")
        }
    }

    @Test func neverEntersPaymentCards() {
        #expect(BrowserRisk.press(keys: "4 2", page: page(focused: cardNumber)).blocked?.contains("payment card") == true)
        #expect(BrowserRisk.press(keys: "Meta+V", page: page(focused: cardNumber)).blocked != nil)
        // A card number spelled out key by key is refused in any field.
        let digits = "4 2 4 2 4 2 4 2 4 2 4 2 4 2 4 2"
        #expect(BrowserRisk.press(keys: digits, page: page(focused: search)).blocked?.contains("payment card") == true)
        #expect(BrowserRisk.press(keys: "1 2 3", page: page(focused: search)).blocked == nil)
    }

    @Test func typingWithoutAKnownFocusNeedsALook() {
        let v = BrowserRisk.press(keys: "h i", page: page(focused: nil))
        #expect(v.blocked == nil && v.risk == .medium)
        #expect(BrowserRisk.press(keys: "Escape", page: page(focused: nil)).risk == .low)
        #expect(BrowserRisk.press(keys: "h i", page: page(focused: search)).risk == .low)
    }

    @Test func superCountsAsCommand() {
        #expect(BrowserRisk.press(keys: "Super+Enter", page: page(focused: search)).risk == .high)
    }
}
