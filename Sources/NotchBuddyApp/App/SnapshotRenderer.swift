import AppKit
import SwiftUI
import AgentKit

/// `NotchBuddy --snapshot <dir>` renders every notch state to PNG (for docs and visual
/// regression checks) without running any automation.
@MainActor
enum SnapshotRenderer {
    static func run(into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let controller = TaskController(runtime: AutomationRuntime(), settingsStore: SettingsStore.shared)
        let model = NotchModel(controller: controller, settings: SettingsStore.shared)
        model.geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), hasNotch: true,
                                       notchRect: CGRect(x: 666, y: 950, width: 180, height: 32))
        let plan = Plan(goal: "Summarize Apple earnings into Notes", steps: [
            PlanStep(id: 1, title: "Opening Safari", instruction: "", route: .native, app: "Safari", risk: .low, doneWhen: "", hint: nil),
            PlanStep(id: 2, title: "Reading the results", instruction: "", route: .gui, app: "Safari", risk: .low, doneWhen: "", hint: nil),
            PlanStep(id: 3, title: "Creating a note", instruction: "", route: .gui, app: "Notes", risk: .low, doneWhen: "", hint: nil),
            PlanStep(id: 4, title: "Writing the summary", instruction: "", route: .gui, app: "Notes", risk: .medium, doneWhen: "", hint: nil),
        ], clarification: nil)
        let instruction = "Open Safari, search for the latest Apple earnings, summarize the results, and save the summary in Notes."
        let activity: [ActivityEntry] = [
            ActivityEntry(kind: .plan, title: "Planned 4 steps"),
            ActivityEntry(kind: .step, title: "Opening Safari", route: .native),
            ActivityEntry(kind: .action, title: "Opening https://www.google.com/search?q=apple+earnings", detail: "open-url · window updated", route: .native, success: true, durationMs: 412),
            ActivityEntry(kind: .step, title: "Reading the results", route: .gui),
            ActivityEntry(kind: .info, title: "Noted information", detail: "Q4 revenue $102.5B (+8% YoY); iPhone $49.0B; Services record $28.8B."),
            ActivityEntry(kind: .step, title: "Creating a note", route: .gui),
            ActivityEntry(kind: .action, title: "Pressing ⇧⌘N… Clicking “New Note”", detail: "mouse · window updated", route: .gui, success: true, durationMs: 96),
        ]
        func shot(_ name: String, _ setup: () -> Void) {
            setup()
            model.recompute()
            let size = model.size
            let view = NotchRootView(model: model)
                .frame(width: size.width + 40, height: size.height + 20)
                .background(Color(white: 0.16))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let img = renderer.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/notch-\(name).png"))
                print("wrote notch-\(name).png")
            }
        }
        shot("idle") { controller.previewState(phase: .idle, status: ""); model.inputOpen = false }
        shot("input") { model.inputOpen = true; model.inputText = instruction }
        shot("planning") { model.inputOpen = false; controller.previewState(phase: .planning, status: "Understanding your task…", instruction: instruction) }
        shot("executing") { controller.previewState(phase: .executing, status: "Clicking “New Note”", instruction: instruction, plan: plan, stepIndex: 2, activity: activity) }
        shot("detail") { model.detailOpen = true }
        shot("approval") {
            model.detailOpen = false
            controller.previewState(phase: .awaitingApproval, status: "Needs your approval", instruction: "Email the summary to my team", plan: plan, stepIndex: 3,
                                    approval: ApprovalRequest(kind: .action, title: "Clicking “Send”", detail: "Send the drafted summary email to the team list.",
                                                              appName: "Mail", risk: .high, reasons: ["clicking “Send”"]))
        }
        shot("completed") {
            controller.previewState(phase: .completed, status: "Saved a note “Apple Q4 earnings” with a 5-point summary.", instruction: instruction, plan: plan, stepIndex: 4)
            model.resultVisible = true
        }
        shot("error") {
            controller.previewState(phase: .failed, status: "Couldn't find the “New Note” button after 2 replans. Notes may be showing a sign-in sheet.", instruction: instruction, plan: plan, stepIndex: 2)
            model.resultVisible = true
        }
    }
}
