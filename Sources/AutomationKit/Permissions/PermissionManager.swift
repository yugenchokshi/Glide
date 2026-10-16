import Foundation
import AppKit
import ApplicationServices
import AVFoundation

/// Status and request flow for the macOS permissions Glide uses. Requests happen only
/// when a feature needs them; the app can't grant itself anything.
public enum PermissionKind: String, CaseIterable, Sendable, Identifiable {
    case accessibility, screenRecording, automation, microphone
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .automation: return "Automation"
        case .microphone: return "Microphone"
        }
    }

    public var purpose: String {
        switch self {
        case .accessibility: return "Read app controls and move the cursor, click and type. Required."
        case .screenRecording: return "See windows whose controls aren't accessible (OCR and vision fallback). Optional."
        case .automation: return "Read the current browser URL and page text. Optional, asked per app."
        case .microphone: return "Dictate tasks by voice. Optional."
        }
    }

    public var settingsURL: URL {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .automation: anchor = "Privacy_Automation"
        case .microphone: anchor = "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public enum PermissionStatus: String, Sendable {
    case granted, denied, notDetermined, unknown
}

public enum PermissionManager {
    public static func status(_ kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .accessibility: return AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording: return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .automation: return .unknown // checked per target app when first used
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        }
    }

    /// Shows the system prompt where one exists, otherwise opens the right Settings pane.
    @MainActor
    public static func request(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { NSWorkspace.shared.open(kind.settingsURL) }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(kind.settingsURL) }
        case .automation:
            NSWorkspace.shared.open(kind.settingsURL)
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        return status(kind)
    }
}
