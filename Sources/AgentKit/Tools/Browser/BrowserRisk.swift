import Foundation
import AutomationKit

/// Deterministic risk rules for browser tool calls. No model is involved: the verdict comes from
/// the element the model saw in the last snapshot (its name, role and enclosing form or dialog),
/// the page's address and title, and the call's own arguments. The word lists are the same ones
/// `SafetyPolicy` applies to on-screen clicks, so "Send", "Delete", "Buy now" or "Publish" need
/// approval in a background tab exactly as they do on screen.
enum BrowserRisk {
    /// Sites where Return sends a message straight away.
    static let messagingHosts = [
        "mail.google.com", "chat.google.com", "messages.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com",
        "web.whatsapp.com", "app.slack.com", "slack.com", "discord.com", "teams.microsoft.com", "teams.live.com", "messenger.com",
        "web.telegram.org", "x.com", "twitter.com", "linkedin.com", "facebook.com", "instagram.com", "web.skype.com", "reddit.com",
    ]
    /// Page or form words that make a "Continue" or "Confirm" button a purchase or payment.
    static let checkoutWords = [
        "checkout", "check out", "payment", "payments", "pay", "billing", "purchase", "order", "orders", "cart", "basket",
        "subscribe", "subscription", "donate", "donation", "transfer", "wire", "send money", "place order",
    ]
    /// Buttons that commit whatever form they sit in.
    static let commitWords = [
        "continue", "confirm", "submit", "next", "place", "complete", "finish", "proceed", "done", "ok", "yes", "agree",
        "accept", "save", "apply", "review", "authorize", "approve",
    ]
    /// Fields Glide never fills in: payment card details.
    static let cardFieldWords = ["card number", "credit card", "debit card", "cvv", "cvc", "cvv2", "security code", "card verification", "expiry date", "expiration date"]

    static func host(of url: String) -> String {
        (URL(string: url)?.host ?? "").lowercased()
    }

    static func isMessagingHost(_ url: String) -> Bool {
        let h = host(of: url)
        guard !h.isEmpty else { return false }
        return messagingHosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    static func matches(_ text: String, _ words: [String]) -> Bool {
        SafetyPolicy.matches(ElementMatcher.normalize(text), words)
    }

    /// Words describing the page: its title and the path of its address.
    static func pageWords(_ page: PageSnapshot?) -> String {
        guard let page else { return "" }
        let address = URL(string: page.url).map { ($0.host ?? "") + " " + $0.path } ?? ""
        return page.title + " " + address
    }

    /// Every name the element goes by: the snapshot's and the step runner's `_label`. Risk is
    /// judged on all of them, so a disagreement can only make a call riskier, never safer.
    static func names(_ element: PageSnapshot.Element?, _ label: String?) -> String {
        [element?.name, label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ")
    }

    static func describe(_ ref: String, _ element: PageSnapshot.Element?, label: String?) -> String {
        let name = element?.name ?? label ?? ""
        let role = element?.role ?? "element"
        return name.isEmpty ? "\(ref) (\(role))" : "\(ref) \(role) “\(PageSnapshot.clip(name, 60))”"
    }

    static func on(_ page: PageSnapshot?) -> String {
        guard let page else { return "" }
        let h = host(of: page.url)
        return h.isEmpty ? "" : " on \(h)"
    }

    // MARK: Verdicts

    static func open(_ raw: String) -> ToolVerdict {
        let summary = "Open \(PageSnapshot.clip(raw, 120)) in Chrome"
        guard let url = BrowserDriver.normalizeURL(raw) else { return ToolVerdict(risk: .low, summary: summary) }
        if BrowserDriver.isRestricted(url: url) {
            return ToolVerdict(risk: .high, reasons: ["browser settings page"], blocked: "Chrome doesn't allow automating \(PageSnapshot.clip(url, 80)).", summary: summary)
        }
        let scheme = BrowserDriver.scheme(of: url) ?? ""
        switch scheme {
        case "javascript":
            return ToolVerdict(risk: .high, reasons: ["runs a javascript: URL in the page"], summary: summary)
        case "file":
            return ToolVerdict(risk: .high, reasons: ["opens a local file in the browser"], summary: summary)
        case _ where !BrowserDriver.navigableSchemes.contains(scheme):
            return ToolVerdict(risk: .medium, reasons: ["\(scheme): links open another app"],
                               blocked: "Glide's browser only opens web pages; use system.open for \(scheme): links.", summary: summary)
        default:
            return ToolVerdict(risk: .low, summary: summary)
        }
    }

    static func click(ref: String, element: PageSnapshot.Element?, label: String?, page: PageSnapshot?) -> ToolVerdict {
        let summary = "Click \(describe(ref, element, label: label))\(on(page))"
        guard element != nil || !(label ?? "").isEmpty else {
            return ToolVerdict(risk: .medium, reasons: ["element not in the latest snapshot"], summary: summary)
        }
        let name = names(element, label)
        var risk = RiskLevel.low
        var reasons: [String] = []
        if matches(name, SafetyPolicy.highRiskWords) {
            risk = .high
            reasons.append("clicking “\(PageSnapshot.clip(name, 60))”")
        } else if matches(name, SafetyPolicy.mediumRiskWords) {
            risk = .medium
        }
        let context = element?.context ?? ""
        let commits = element?.inputType == "submit" || matches(name, commitWords) || (element?.role == "button" && context.hasPrefix("form"))
        if risk < .high, commits {
            if matches(context, SafetyPolicy.highRiskWords) || matches(context, checkoutWords) {
                risk = .high
                reasons.append("submits “\(PageSnapshot.clip(context, 60))”")
            } else if matches(pageWords(page), checkoutWords) {
                risk = .high
                reasons.append("confirms on a checkout or payment page")
            }
        }
        return ToolVerdict(risk: risk, reasons: reasons, summary: summary)
    }

    static func type(ref: String, element: PageSnapshot.Element?, label: String?, text: String, submit: Bool, page: PageSnapshot?) -> ToolVerdict {
        let preview = PageSnapshot.clip(text, 60)
        let summary = "Type “\(preview)” into \(describe(ref, element, label: label))\(submit ? " and press Return" : "")\(on(page))"
        if element?.secure == true || element?.inputType == "password" {
            return ToolVerdict(risk: .high, reasons: ["password field"], blocked: "Glide never types into password fields. Please enter it yourself.", summary: summary)
        }
        let name = names(element, label)
        if SafetyPolicy.looksLikePaymentCard(text) || matches(name, cardFieldWords) {
            return ToolVerdict(risk: .high, reasons: ["payment card details"], blocked: "Glide won't enter payment card details. Please enter them yourself.", summary: summary)
        }
        guard submit else {
            return ToolVerdict(risk: element == nil && (label ?? "").isEmpty ? .medium : .low, summary: summary)
        }
        var risk = RiskLevel.medium
        var reasons = ["presses Return to submit"]
        let context = element?.context ?? ""
        if let page, isMessagingHost(page.url) {
            risk = .high
            reasons.append("Return sends a message on \(host(of: page.url))")
        } else if matches(name, SafetyPolicy.highRiskWords) || matches(context, SafetyPolicy.highRiskWords) {
            risk = .high
            reasons.append("submits “\(PageSnapshot.clip(context.isEmpty ? name : context, 60))”")
        } else if matches(context, checkoutWords) || matches(pageWords(page), checkoutWords) {
            risk = .high
            reasons.append("submits on a checkout or payment page")
        }
        return ToolVerdict(risk: risk, reasons: reasons, summary: summary)
    }

    static func select(ref: String, element: PageSnapshot.Element?, label: String?, value: String, page: PageSnapshot?) -> ToolVerdict {
        let summary = "Choose “\(PageSnapshot.clip(value, 60))” in \(describe(ref, element, label: label))\(on(page))"
        if matches(value, SafetyPolicy.highRiskWords) {
            return ToolVerdict(risk: .medium, reasons: ["option “\(PageSnapshot.clip(value, 60))”"], summary: summary)
        }
        return ToolVerdict(risk: element == nil && (label ?? "").isEmpty ? .medium : .low, summary: summary)
    }

    static func press(keys: String, page: PageSnapshot?) -> ToolVerdict {
        let summary = "Press \(PageSnapshot.clip(keys, 60))\(on(page))"
        let focused = page?.focusedElement
        let inTextField = focused.map { ["textbox", "searchbox", "combobox", "spinbutton"].contains($0.role) } ?? false
        var risk = RiskLevel.low
        var reasons: [String] = []
        for combo in keys.split(whereSeparator: \.isWhitespace) {
            let parts = combo.lowercased().split(separator: "+").map(String.init)
            guard let key = parts.last else { continue }
            let mods = Set(parts.dropLast())
            let command = !mods.isDisjoint(with: ["meta", "cmd", "command", "control", "ctrl"])
            let isEnter = key == "enter" || key == "return"
            let isDelete = key == "backspace" || key == "delete" || key == "del"
            if isEnter, command {
                risk = .high
                reasons.append("⌘/Ctrl+Return sends in many web apps")
            } else if isEnter {
                if let page, isMessagingHost(page.url) {
                    risk = .high
                    reasons.append("Return sends a message on \(host(of: page.url))")
                } else if let f = focused, matches(f.context ?? "", checkoutWords) || matches(f.context ?? "", SafetyPolicy.highRiskWords) {
                    risk = .high
                    reasons.append("submits “\(PageSnapshot.clip(f.context ?? "", 60))”")
                } else {
                    risk = max(risk, .medium)
                    reasons.append("Return may submit a form")
                }
            } else if isDelete, command {
                risk = .high
                reasons.append("⌘⌫ deletes")
            } else if (isDelete || key == "#") && !inTextField {
                risk = max(risk, .medium)
                reasons.append("may delete the selected item")
            }
        }
        return ToolVerdict(risk: risk, reasons: reasons, summary: summary)
    }

    static func closeTab(tabID: String, isGlideTab: Bool) -> ToolVerdict {
        let summary = "Close browser tab \(PageSnapshot.clip(tabID, 40))"
        if isGlideTab { return ToolVerdict(risk: .low, summary: summary) }
        return ToolVerdict(risk: .high, reasons: ["closes a tab Glide didn't open (unsaved work there would be lost)"], summary: summary)
    }
}
