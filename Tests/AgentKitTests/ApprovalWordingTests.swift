import Testing
@testable import AgentKit

@Suite("Spoken approval wording")
struct ApprovalWordingTests {
    @Test(arguments: [
        ("Clicking e3045 “Add to cart”", "Click “Add to cart”"),
        ("Click b31 link “Buy MacBook Air” on www.apple.com", "Click “Buy MacBook Air” on apple.com"),
        ("Click b244 radio “15-inch”", "Click “15-inch”"),
        ("Run `rm -rf ~/build`", "Run `rm -rf ~/build`"),
        ("Send the email to Ana.", "Send the email to Ana"),
    ])
    func titlesBecomeSpokenActions(_ c: (String, String)) {
        #expect(TaskController.spokenAction(c.0) == c.1)
    }
}
