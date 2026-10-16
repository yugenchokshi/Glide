// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Glide",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Glide", targets: ["GlideApp"]),
        .executable(name: "glidectl", targets: ["glidectl"]),
        .executable(name: "NBFixtureApp", targets: ["NBFixtureApp"]),
        .executable(name: "nb-mock-servers", targets: ["NBMockServers"]),
        .library(name: "AutomationKit", targets: ["AutomationKit"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
    ],
    targets: [
        // Accessibility, perception, input injection, verification. No UI, no AI.
        .target(
            name: "AutomationKit",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("Carbon"),
            ]
        ),
        // Providers, planner, orchestrator, safety, history, credentials, integrations.
        .target(
            name: "AgentKit",
            dependencies: ["AutomationKit"],
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Security")]
        ),
        // The notch app: SwiftUI + AppKit only, talks to AgentKit through TaskController.
        .executableTarget(
            name: "GlideApp",
            dependencies: ["AgentKit", "AutomationKit"],
            linkerSettings: [.linkedFramework("Speech"), .linkedFramework("AVFoundation")]
        ),
        // Headless CLI: inspect accessibility trees, run tasks, run benchmarks.
        .executableTarget(name: "glidectl", dependencies: ["AgentKit", "AutomationKit"]),
        // Deterministic fixture app used by live tests (labeled + inaccessible controls).
        .executableTarget(name: "NBFixtureApp"),
        // Local mock MCP (stdio) and scripted OpenAI-compatible endpoint for tests.
        .executableTarget(name: "NBMockServers"),
        .testTarget(name: "AutomationKitTests", dependencies: ["AutomationKit"]),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit", "AutomationKit"]),
    ],
    swiftLanguageModes: [.v6]
)
