import Foundation
import CoreGraphics

/// Builds observations from the best available sources: accessibility first, then local OCR
/// when the tree is too sparse to act on.
public final class PerceptionEngine: @unchecked Sendable {
    public let accessibility: AccessibilityEngine
    public let capture: ScreenCapture
    public let browser: BrowserAdapter

    /// Below this many interactive AX elements, OCR augmentation is attempted automatically.
    public var sparseThreshold = 4

    public init(accessibility: AccessibilityEngine, capture: ScreenCapture = ScreenCapture(), browser: BrowserAdapter = BrowserAdapter()) {
        self.accessibility = accessibility
        self.capture = capture
        self.browser = browser
    }

    public func observe(_ app: AppInfo, forceOCR: Bool = false, useCache: Bool = true) async throws -> ScreenObservation {
        var obs = try accessibility.observe(app, useCache: useCache && !forceOCR)
        if (forceOCR || obs.interactiveCount < sparseThreshold), ScreenCapture.hasPermission {
            if let augmented = try? await augmentWithOCR(obs) { obs = augmented }
        }
        return obs
    }

    /// Adds OCR text nodes that don't duplicate existing accessibility text.
    public func augmentWithOCR(_ obs: ScreenObservation) async throws -> ScreenObservation {
        let shot = try await capture.captureWindow(pid: obs.app.pid, frame: obs.windowFrame)
        let boxes = try OCREngine.recognize(shot)
        let existing = obs.elements
        let fresh = boxes.filter { box in
            let t = ElementMatcher.normalize(box.text)
            guard !t.isEmpty else { return false }
            return !existing.contains { node in
                node.frame.intersects(box.screenRect) &&
                    ElementMatcher.similarity(t, ElementMatcher.normalize(node.label + " " + (node.value ?? ""))) > 0.7
            }
        }
        let (nodes, _) = accessibility.graph.assignIDs(OCREngine.nodes(from: fresh))
        var out = obs
        out.elements.append(contentsOf: nodes)
        return out
    }

    /// Screen rectangles that must be blacked out before a capture leaves the machine.
    public func sensitiveRects(in obs: ScreenObservation) -> [CGRect] {
        obs.elements.filter { $0.isSecure }.map(\.frame)
    }
}
