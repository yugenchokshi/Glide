import Foundation
import AppKit
import ScreenCaptureKit
import CoreImage

/// A captured image plus the mapping from image pixels back to global screen points.
public struct CapturedImage: @unchecked Sendable {
    public let image: CGImage
    /// Global (top-left origin) rectangle the image covers, in points.
    public let screenRect: CGRect

    public init(image: CGImage, screenRect: CGRect) {
        self.image = image
        self.screenRect = screenRect
    }

    public var scaleX: CGFloat { CGFloat(image.width) / max(screenRect.width, 1) }
    public var scaleY: CGFloat { CGFloat(image.height) / max(screenRect.height, 1) }

    public func screenPoint(fromPixel p: CGPoint) -> CGPoint {
        CGPoint(x: screenRect.minX + p.x / scaleX, y: screenRect.minY + p.y / scaleY)
    }

    public func screenRect(fromPixelRect r: CGRect) -> CGRect {
        CGRect(x: screenRect.minX + r.minX / scaleX, y: screenRect.minY + r.minY / scaleY,
               width: r.width / scaleX, height: r.height / scaleY)
    }

    public func pixelRect(fromScreenRect r: CGRect) -> CGRect {
        CGRect(x: (r.minX - screenRect.minX) * scaleX, y: (r.minY - screenRect.minY) * scaleY,
               width: r.width * scaleX, height: r.height * scaleY)
    }

    /// PNG bytes, downscaled so the longest side is at most `maxSide` pixels.
    public func pngData(maxSide: Int = 1440) -> (data: Data, width: Int, height: Int)? {
        var img = image
        let longest = max(img.width, img.height)
        if longest > maxSide {
            let scale = Double(maxSide) / Double(longest)
            let w = Int(Double(img.width) * scale), h = Int(Double(img.height) * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { return nil }
            img = scaled
        }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return (data, img.width, img.height)
    }
}

/// ScreenCaptureKit-based window and region capture.
public final class ScreenCapture: @unchecked Sendable {
    public init() {}

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Captures the on-screen window of `pid` whose frame best matches `frame`.
    public func captureWindow(pid: pid_t, frame: CGRect?) async throws -> CapturedImage {
        guard Self.hasPermission else { throw AutomationError.screenRecordingNotGranted }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 40 }
        let window: SCWindow? = {
            guard let frame else { return candidates.first }
            return candidates.min(by: { distance($0.frame, frame) < distance($1.frame, frame) })
        }()
        guard let window else { throw AutomationError.captureFailed("window not found on screen") }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        // SCWindow.frame is in global top-left point coordinates, like AX.
        return CapturedImage(image: image, screenRect: window.frame)
    }

    /// Captures the whole display containing `point` (excluding Glide's own windows).
    public func captureDisplay(containing point: CGPoint? = nil) async throws -> CapturedImage {
        guard Self.hasPermission else { throw AutomationError.screenRecordingNotGranted }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = content.displays.first(where: { point.map($0.frame.contains) ?? false }) ?? content.displays.first
        guard let display else { throw AutomationError.captureFailed("no display") }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.windows.filter { $0.owningApplication?.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return CapturedImage(image: image, screenRect: display.frame)
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}

/// Blacks out sensitive regions (secure fields, excluded app windows) before an image leaves
/// the machine.
public enum Redactor {
    public static func redact(_ captured: CapturedImage, screenRects: [CGRect]) -> CapturedImage {
        guard !screenRects.isEmpty else { return captured }
        let w = captured.image.width, h = captured.image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return captured }
        ctx.draw(captured.image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for r in screenRects {
            let p = captured.pixelRect(fromScreenRect: r.insetBy(dx: -4, dy: -4))
            // CGContext has a bottom-left origin.
            ctx.fill(CGRect(x: p.minX, y: CGFloat(h) - p.maxY, width: p.width, height: p.height))
        }
        guard let out = ctx.makeImage() else { return captured }
        return CapturedImage(image: out, screenRect: captured.screenRect)
    }
}
