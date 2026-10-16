import Testing
import Foundation
import CoreGraphics
@testable import AutomationKit

@Suite("KeyCombination")
struct KeyCombinationTests {
    @Test func parsesModifiersAndKeys() throws {
        let k = try KeyCombination(parsing: "cmd+shift+n")
        #expect(k.modifiers == [.command, .shift])
        #expect(k.key == "n")
        #expect(k.displayString == "⇧⌘N")
    }

    @Test func parsesSymbolsAndNamedKeys() throws {
        let save = try KeyCombination(parsing: "⌘S")
        #expect(save.modifiers == .command && save.key == "s")
        let ret = try KeyCombination(parsing: "Return")
        #expect(ret.modifiers.isEmpty && ret.keyCode == 36)
        let opt = try KeyCombination(parsing: "option-space")
        #expect(opt.modifiers == .option && opt.key == "space")
    }

    @Test func parsesSeparatorKeys() throws {
        let zoomOut = try KeyCombination(parsing: "cmd+-")
        #expect(zoomOut.key == "-" && zoomOut.modifiers == .command)
        let zoomIn = try KeyCombination(parsing: "cmd++")
        #expect(zoomIn.key == "+")
    }

    @Test func rejectsUnknown() {
        #expect(throws: AutomationError.self) { try KeyCombination(parsing: "hyper+q") }
        #expect(throws: AutomationError.self) { try KeyCombination(parsing: "cmd+banana") }
    }
}

func node(_ role: String, _ name: String, value: String? = nil, enabled: Bool = true, secure: Bool = false, frame: CGRect = CGRect(x: 10, y: 10, width: 80, height: 24)) -> UIElementNode {
    UIElementNode(role: role, axRole: "AX" + role, name: name, value: value, frame: frame, enabled: enabled, isSecure: secure)
}

@Suite("ElementMatcher")
struct ElementMatcherTests {
    let nodes = [
        node("button", "New Note"), node("button", "Delete Note"), node("searchfield", "Search"),
        node("button", "Share"), node("textfield", "Name", value: "Ada"), node("button", "Save…"),
    ]

    @Test func exactMatchWins() {
        let r = ElementMatcher.rank("New Note", in: nodes)
        #expect(r.first?.node.name == "New Note")
        #expect(ElementMatcher.unambiguousBest(r)?.name == "New Note")
    }

    @Test func roleWordsAndEllipsisAreIgnored() {
        #expect(ElementMatcher.rank("the save button", in: nodes).first?.node.name == "Save…")
        #expect(ElementMatcher.rank("search field", in: nodes).first?.node.role == "searchfield")
    }

    @Test func labelsWithStopWordsMatchExactly() {
        let links = [node("link", "Go to page two"), node("link", "Page one")]
        let r = ElementMatcher.rank("Go to page two", in: links)
        #expect(r.first?.node.name == "Go to page two")
        #expect((r.first?.score ?? 0) >= 0.95)
    }

    @Test func toleratesTypos() {
        #expect(ElementMatcher.rank("Shaer", in: nodes).first?.node.name == "Share")
    }

    @Test func ambiguityIsReported() {
        let dupes = [node("button", "Note A"), node("button", "Note B")]
        #expect(ElementMatcher.unambiguousBest(ElementMatcher.rank("Note", in: dupes)) == nil)
    }

    @Test func disabledElementsRankLower() {
        let r = ElementMatcher.rank("Send", in: [node("button", "Send", enabled: false), node("button", "Send now")])
        #expect(r.first?.node.name == "Send now")
    }
}

@Suite("ElementGraph")
struct ElementGraphTests {
    @Test func idsAreStableAcrossObservations() {
        let g = ElementGraph()
        let raws = [RawElement(node: node("button", "A"), ref: nil, pathKey: "w/button:A"), RawElement(node: node("button", "B"), ref: nil, pathKey: "w/button:B")]
        let first = g.assignIDs(raws).nodes
        let second = g.assignIDs(raws.reversed()).nodes
        #expect(first.first { $0.name == "A" }?.id == second.first { $0.name == "A" }?.id)
        #expect(first.first { $0.name == "B" }?.id == second.first { $0.name == "B" }?.id)
    }

    @Test func duplicatesGetDistinctIDsAndParents() {
        let g = ElementGraph()
        let raws = [
            RawElement(node: node("group", "Toolbar"), ref: nil, pathKey: "w/group:Toolbar"),
            RawElement(node: node("button", "OK"), ref: nil, pathKey: "w/group:Toolbar/button:OK"),
            RawElement(node: node("button", "OK"), ref: nil, pathKey: "w/group:Toolbar/button:OK"),
        ]
        let nodes = g.assignIDs(raws).nodes
        #expect(Set(nodes.map(\.id)).count == 3)
        #expect(nodes[1].parentID == nodes[0].id)
    }

    @Test func compactHidesSecureValuesAndMarksFlags() {
        let app = AppInfo(name: "Test", bundleID: nil, pid: 1)
        var secure = node("textfield", "Password", secure: true)
        secure.id = "e1"
        var disabled = node("button", "Send", enabled: false)
        disabled.id = "e2"
        let obs = ScreenObservation(app: app, windowTitle: "Win", windowFrame: nil, elements: [secure, disabled], focusedElementID: nil)
        let text = obs.compact()
        #expect(text.contains("e1 textfield \"Password\" [secure]"))
        #expect(text.contains("e2 button \"Send\" [disabled]"))
    }
}

@Suite("ExecutionGate")
struct ExecutionGateTests {
    @Test func stopThrowsImmediately() async {
        let gate = ExecutionGate()
        gate.stop()
        #expect(throws: AutomationError.stopped) { try gate.checkStopped() }
        await #expect(throws: AutomationError.self) { try await gate.checkpoint() }
    }

    @Test func pauseBlocksUntilResume() async throws {
        let gate = ExecutionGate()
        gate.pause()
        let start = Date()
        _ = Task { try await Task.sleep(for: .milliseconds(200)); gate.resume() }
        try await gate.checkpoint()
        #expect(Date().timeIntervalSince(start) >= 0.15)
    }

    @Test func stopWhilePausedEndsWait() async {
        let gate = ExecutionGate()
        gate.pause()
        _ = Task { try await Task.sleep(for: .milliseconds(100)); gate.stop() }
        await #expect(throws: AutomationError.self) { try await gate.checkpoint() }
    }
}

@Suite("Geometry")
struct GeometryTests {
    @Test func capturedImageMapsPixelsToPoints() {
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        let cap = CapturedImage(image: img, screenRect: CGRect(x: 100, y: 50, width: 100, height: 50)) // 2x scale
        #expect(cap.screenPoint(fromPixel: CGPoint(x: 100, y: 50)) == CGPoint(x: 150, y: 75))
        #expect(cap.pixelRect(fromScreenRect: CGRect(x: 110, y: 60, width: 10, height: 10)) == CGRect(x: 20, y: 20, width: 20, height: 20))
    }

    @Test func redactionKeepsSize() {
        let ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let cap = CapturedImage(image: ctx.makeImage()!, screenRect: CGRect(x: 0, y: 0, width: 40, height: 40))
        let red = Redactor.redact(cap, screenRects: [CGRect(x: 10, y: 10, width: 10, height: 10)])
        #expect(red.image.width == 40 && red.image.height == 40)
    }
}

@Suite("Roles")
struct RoleTests {
    @Test func normalizesCommonRoles() {
        #expect(AX.normalizedRole(role: "AXButton", subrole: nil, actions: []) == "button")
        #expect(AX.normalizedRole(role: "AXTextField", subrole: "AXSearchField", actions: []) == "searchfield")
        #expect(AX.normalizedRole(role: "AXGroup", subrole: nil, actions: ["AXPress"]) == "group")
        #expect(AX.normalizedRole(role: "AXCustomThing", subrole: nil, actions: ["AXPress"]) == "button")
    }
}
