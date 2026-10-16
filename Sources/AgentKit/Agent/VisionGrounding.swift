import Foundation
import AutomationKit

/// Finds a control visually when accessibility can't: local OCR first (free, private), then
/// a vision-capable model on a redacted window capture. Every coordinate is validated
/// against the window geometry before it becomes a click target.
public struct VisionGrounding: Sendable {
    public struct Hit: Sendable {
        public var point: CGPoint
        public var confidence: Double
        public var source: ElementSource
        public var description: String
    }

    let perception: PerceptionEngine

    public init(perception: PerceptionEngine) {
        self.perception = perception
    }

    /// OCR-only grounding: matches the description against recognized text in the window.
    public func groundWithOCR(_ description: String, obs: ScreenObservation) async throws -> Hit? {
        let shot = try await perception.capture.captureWindow(pid: obs.app.pid, frame: obs.windowFrame)
        let boxes = try OCREngine.recognize(shot)
        let nodes = OCREngine.nodes(from: boxes).map(\.node)
        guard let best = ElementMatcher.rank(description, in: nodes, limit: 3).first, best.score >= 0.8 else { return nil }
        return Hit(point: best.node.center, confidence: best.score, source: .ocr, description: "text “\(best.node.name)”")
    }

    static let schema: JSONValue = Schema.object([
        ("found", Schema.boolean("Whether the target is visible.")),
        ("x", Schema.number("Center x in image pixels.", nullable: true)),
        ("y", Schema.number("Center y in image pixels.", nullable: true)),
        ("confidence", Schema.number("0 to 1.")),
        ("description", Schema.string("What you found at that location.")),
    ])

    /// Model-based grounding on a redacted capture of the target window.
    public func groundWithModel(_ description: String, context: String, obs: ScreenObservation, route: ModelRouter.Route, metrics: TaskMetrics) async throws -> Hit? {
        let raw = try await perception.capture.captureWindow(pid: obs.app.pid, frame: obs.windowFrame)
        let shot = Redactor.redact(raw, screenRects: perception.sensitiveRects(in: obs))
        guard let png = shot.pngData(maxSide: 1440) else { throw AutomationError.captureFailed("encode") }
        let prompt = """
        Target: \(description)
        Context: \(context)
        Image size: \(png.width)x\(png.height) pixels.
        """
        let req = LLMRequest(model: route.model, system: Prompts.vision,
                             messages: [.user(prompt, images: [LLMImage(pngData: png.data, width: png.width, height: png.height)])],
                             schema: Self.schema, schemaName: "vision_target", maxTokens: 1500, effort: route.effort, timeout: 90)
        let response = try await route.provider.complete(req)
        await metrics.recordModel(response, vision: true)
        guard let j = response.json, j["found"]?.boolValue == true, let x = j["x"]?.doubleValue, let y = j["y"]?.doubleValue else { return nil }
        // Validate: inside the image, then map back into the window's screen rect.
        guard x >= 0, y >= 0, x <= Double(png.width), y <= Double(png.height) else { return nil }
        let scale = Double(shot.image.width) / Double(png.width)
        let point = shot.screenPoint(fromPixel: CGPoint(x: x * scale, y: y * scale))
        guard shot.screenRect.insetBy(dx: 2, dy: 2).contains(point) else { return nil }
        // Never click into a redacted (sensitive) region.
        if perception.sensitiveRects(in: obs).contains(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) { return nil }
        let confidence = j["confidence"]?.doubleValue ?? 0.5
        guard confidence >= 0.35 else { return nil }
        return Hit(point: point, confidence: confidence, source: .vision, description: j["description"]?.stringValue ?? description)
    }
}
