import AppKit

// A deterministic test app for live automation tests. It has accessible controls, a control
// that is invisible to accessibility (only reachable via OCR/vision), a delayed element for
// recovery tests, a confirmation dialog and a high-risk button for approval tests.

@MainActor
final class CanvasControl: NSView {
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        setAccessibilityChildren([])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityRole() -> NSAccessibility.Role? { .unknown }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemIndigo.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let text = "LAUNCH ROCKET" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

@MainActor
final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let status = NSTextField(labelWithString: "Status: idle")
    let countLabel = NSTextField(labelWithString: "Count: 0")
    let nameField = NSTextField(string: "")
    let notesView = NSTextView()
    var secretButton: NSButton!
    var count = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 560, height: 520),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "NB Fixture"
        window.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        status.setAccessibilityIdentifier("status")
        countLabel.setAccessibilityIdentifier("count")
        let increment = NSButton(title: "Increment", target: self, action: #selector(incrementTapped))
        nameField.placeholderString = "Your name"
        nameField.setAccessibilityLabel("Name")
        nameField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let greet = NSButton(title: "Greet", target: self, action: #selector(greetTapped))
        let reveal = NSButton(title: "Reveal Secret", target: self, action: #selector(revealTapped))
        secretButton = NSButton(title: "Secret Action", target: self, action: #selector(secretTapped))
        secretButton.isHidden = true
        let dialog = NSButton(title: "Open Dialog", target: self, action: #selector(dialogTapped))
        let delete = NSButton(title: "Delete Everything", target: self, action: #selector(deleteTapped))
        let canvas = CanvasControl(frame: NSRect(x: 0, y: 0, width: 220, height: 56))
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.widthAnchor.constraint(equalToConstant: 220).isActive = true
        canvas.heightAnchor.constraint(equalToConstant: 56).isActive = true
        canvas.onClick = { [weak self] in self?.status.stringValue = "Status: canvas clicked" }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 90))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 400).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        notesView.isRichText = false
        notesView.setAccessibilityLabel("Notes")
        notesView.autoresizingMask = [.width]
        scroll.documentView = notesView
        scroll.hasVerticalScroller = true

        for v: NSView in [status, countLabel, increment, row(nameField, greet), row(reveal, secretButton), dialog, delete, canvas, scroll] {
            stack.addArrangedSubview(v)
        }
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func row(_ views: NSView...) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = 8
        return r
    }

    @objc func incrementTapped() { count += 1; countLabel.stringValue = "Count: \(count)"; status.stringValue = "Status: incremented" }
    @objc func greetTapped() { status.stringValue = "Status: Hello, \(nameField.stringValue)!" }
    @objc func revealTapped() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.secretButton.isHidden = false }
    }
    @objc func secretTapped() { status.stringValue = "Status: secret unlocked" }
    @objc func deleteTapped() { status.stringValue = "Status: everything deleted" }
    @objc func dialogTapped() {
        let alert = NSAlert()
        alert.messageText = "Apply changes?"
        alert.informativeText = "This is a fixture confirmation dialog."
        alert.addButton(withTitle: "Confirm")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            self.status.stringValue = response == .alertFirstButtonReturn ? "Status: dialog confirmed" : "Status: dialog cancelled"
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = Controller()
    app.delegate = controller
    app.setActivationPolicy(.regular)
    app.run()
}
