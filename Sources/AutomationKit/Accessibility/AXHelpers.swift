import Foundation
import ApplicationServices

/// Sendable box for an AXUIElement. AX elements are CF objects that are safe to message
/// from any thread; the box only exists to cross concurrency boundaries.
public struct AXRef: @unchecked Sendable, Hashable {
    public let element: AXUIElement
    public init(_ element: AXUIElement) { self.element = element }
    public static func == (lhs: AXRef, rhs: AXRef) -> Bool { CFEqual(lhs.element, rhs.element) }
    public func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

enum AX {
    static let batchAttributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXValueAttribute, kAXHelpAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXEnabledAttribute, kAXFocusedAttribute, kAXChildrenAttribute, kAXIdentifierAttribute,
        kAXPlaceholderValueAttribute, kAXSelectedAttribute, "AXLabel", kAXRoleDescriptionAttribute,
        "AXVisibleChildren",
    ]

    struct Attributes {
        var role: String = ""
        var subrole: String?
        var title: String?
        var desc: String?
        var value: String?
        var help: String?
        var position: CGPoint?
        var size: CGSize?
        var enabled: Bool = true
        var focused: Bool = false
        var children: [AXUIElement] = []
        var identifier: String?
        var placeholder: String?
        var selected: Bool = false
        var label: String?
        var roleDescription: String?
    }

    /// Fetches the common attributes in one IPC round trip.
    static func attributes(of element: AXUIElement) -> Attributes? {
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            element, batchAttributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard err == .success, let array = values as? [AnyObject], array.count == batchAttributes.count else {
            return nil
        }
        func value(_ i: Int) -> AnyObject? {
            let v = array[i]
            // Missing attributes come back as AXValue of type .axError.
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
            return v
        }
        var a = Attributes()
        a.role = (value(0) as? String) ?? ""
        a.subrole = value(1) as? String
        a.title = value(2) as? String
        a.desc = value(3) as? String
        a.value = stringify(value(4))
        a.help = value(5) as? String
        if let v = value(6), CFGetTypeID(v) == AXValueGetTypeID() { a.position = point(v as! AXValue) }
        if let v = value(7), CFGetTypeID(v) == AXValueGetTypeID() { a.size = size(v as! AXValue) }
        a.enabled = (value(8) as? Bool) ?? true
        a.focused = (value(9) as? Bool) ?? false
        let visible = value(16) as? [AXUIElement]
        a.children = visible ?? (value(10) as? [AXUIElement]) ?? []
        a.identifier = value(11) as? String
        a.placeholder = value(12) as? String
        a.selected = (value(13) as? Bool) ?? false
        a.label = value(14) as? String
        a.roleDescription = value(15) as? String
        return a
    }

    static func stringify(_ v: AnyObject?) -> String? {
        guard let v else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let attributed = v as? NSAttributedString { return attributed.string }
        if CFGetTypeID(v) == AXValueGetTypeID() { return nil }
        return nil
    }

    static func point(_ v: AXValue) -> CGPoint? {
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    static func size(_ v: AXValue) -> CGSize? {
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    static func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        stringify(copy(element, attribute))
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copy(element, attribute) as? Bool
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = copy(element, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        (copy(element, attribute) as? [AXUIElement]) ?? []
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = copy(element, kAXPositionAttribute), let s = copy(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
              let origin = point(p as! AXValue), let size = size(s as! AXValue)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ attribute: String, _ value: AnyObject) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    static func pid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    /// Normalizes AX roles into the small vocabulary the planner and models see.
    static func normalizedRole(role: String, subrole: String?, actions: [String]) -> String {
        switch role {
        case kAXButtonRole:
            if subrole == "AXSwitch" { return "switch" }
            return "button"
        case kAXCheckBoxRole: return subrole == "AXSwitch" ? "switch" : "checkbox"
        case kAXRadioButtonRole: return "radio"
        case kAXTextFieldRole:
            if subrole == kAXSecureTextFieldSubrole { return "textfield" }
            if subrole == kAXSearchFieldSubrole { return "searchfield" }
            return "textfield"
        case kAXTextAreaRole: return "textarea"
        case kAXComboBoxRole: return "combobox"
        case kAXPopUpButtonRole: return "popup"
        case kAXMenuButtonRole: return "menubutton"
        case "AXLink": return "link"
        case kAXTabGroupRole: return "tabgroup"
        case "AXTab": return "tab"
        case kAXSliderRole: return "slider"
        case kAXMenuItemRole: return "menuitem"
        case kAXMenuBarItemRole: return "menubaritem"
        case kAXCellRole: return "cell"
        case kAXRowRole: return subrole == kAXOutlineRowSubrole ? "outline-row" : "row"
        case kAXDisclosureTriangleRole: return "disclosure"
        case kAXIncrementorRole: return "stepper"
        case kAXStaticTextRole: return "text"
        case kAXImageRole: return actions.contains(kAXPressAction) ? "image-button" : "image"
        case kAXGroupRole: return "group"
        case kAXWindowRole: return "window"
        case kAXSheetRole: return "sheet"
        case kAXToolbarRole: return "toolbar"
        case kAXScrollAreaRole: return "scrollarea"
        case kAXTableRole, kAXOutlineRole: return "list"
        case kAXListRole: return "list"
        case "AXWebArea": return "webarea"
        case "AXHeading": return "heading"
        case kAXColorWellRole: return "colorwell"
        case "AXDockItem": return "dockitem"
        case "AXSegmentedControl": return "segmented"
        default:
            if actions.contains(kAXPressAction) { return "button" }
            return role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role.lowercased()
        }
    }
}
