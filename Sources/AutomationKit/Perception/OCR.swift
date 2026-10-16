import Foundation
import Vision

/// Local text recognition with Apple Vision. Produces graph nodes (source `.ocr`) for text the
/// accessibility tree doesn't expose.
public enum OCREngine {
    public struct TextBox: Sendable {
        public let text: String
        public let screenRect: CGRect
        public let confidence: Float
    }

    public static func recognize(_ captured: CapturedImage, accurate: Bool = true) throws -> [TextBox] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: captured.image, options: [:])
        try handler.perform([request])
        let w = CGFloat(captured.image.width), h = CGFloat(captured.image.height)
        return (request.results ?? []).compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            // Vision boxes are normalized with a bottom-left origin.
            let b = obs.boundingBox
            let pixel = CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
            return TextBox(text: candidate.string, screenRect: captured.screenRect(fromPixelRect: pixel), confidence: candidate.confidence)
        }
    }

    public static func nodes(from boxes: [TextBox]) -> [RawElement] {
        boxes.enumerated().map { i, box in
            RawElement(
                node: UIElementNode(role: "text", axRole: "OCRText", name: box.text, frame: box.screenRect,
                                    source: .ocr, confidence: Double(box.confidence)),
                ref: nil, pathKey: "ocr/\(i):\(box.text.prefix(20))")
        }
    }
}
