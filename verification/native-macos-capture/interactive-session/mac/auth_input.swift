// Fixed native Telegram 2FA input. Password arrives only on bounded stdin.
// Never reads AXValue, clipboard, window titles, hints, account text or credentials.
// CLI: auth_input ABSOLUTE_APP_PATH EXPECTED_PID probe|submit
// submit stdin: {"password":"..."}; submitted means native action dispatched,
// never that authentication succeeded. Caller owns a once-before-submit guard.
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

private struct Flags {
    var app = false
    var frontmost = false
    var trusted = false
    var window = false
    var secure = false
    var settable = false
    var next = false
    var focused = false
    var attempted = false
}

private func emit(_ status: String, _ flags: Flags, method: String = "none") -> Never {
    let result: [String: Any] = [
        "schema_version": 1, "status": status,
        "expected_app_running": flags.app, "frontmost_verified": flags.frontmost,
        "accessibility_trusted": flags.trusted, "focused_window_verified": flags.window,
        "single_visible_secure_field": flags.secure, "secure_value_settable": flags.settable,
        "next_button_verified": flags.next, "secure_field_focused": flags.focused,
        "submission_attempted": flags.attempted, "submission_method": method,
        "password_entry_visible": flags.app && flags.frontmost && flags.trusted && flags.window && flags.secure && flags.settable,
        "submitted": status == "submitted"
    ]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
    exit(status == "ready" || status == "submitted" || status == "not_ready" ? 0 : 2)
}

private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name, &result) == .success ? result : nil
}
private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
    attribute(element, name) as? String
}
private func elementAttribute(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
    guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
private func enabled(_ element: AXUIElement) -> Bool {
    (attribute(element, kAXEnabledAttribute as CFString) as? Bool) == true
}
private func bounds(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute as CFString),
          let size = attribute(element, kAXSizeAttribute as CFString),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
          point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
          dimensions.width > 0, dimensions.height > 0 else { return nil }
    return CGRect(origin: point, size: dimensions)
}
private func visible(_ element: AXUIElement, in window: CGRect) -> Bool {
    if (attribute(element, "AXHidden" as CFString) as? Bool) == true { return false }
    guard let frame = bounds(element) else { return false }
    let intersection = frame.intersection(window)
    return !intersection.isNull && intersection.width >= frame.width * 0.9 && intersection.height >= frame.height * 0.9
}
private func same(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool { CFEqual(lhs, rhs) }
private func isSecure(_ element: AXUIElement) -> Bool {
    stringAttribute(element, kAXRoleAttribute as CFString) == "AXTextField" &&
        stringAttribute(element, kAXSubroleAttribute as CFString) == "AXSecureTextField"
}
private func inputPassword() -> String? {
    guard isatty(STDIN_FILENO) == 0 else { return nil } // Pipe only; never echo terminal input.
    var data = Data()
    do {
        while true {
            let chunk = try FileHandle.standardInput.read(upToCount: 4097 - data.count) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > 4096 { return nil }
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["password"]), let password = object["password"] as? String,
              !password.isEmpty, password.utf8.count <= 2048,
              !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return password
    } catch { return nil } // Never print an exception or input.
}

private var flags = Flags()
let args = CommandLine.arguments
guard args.count == 4, ["probe", "submit"].contains(args[3]), args[1].hasPrefix("/"),
      args[1].hasSuffix(".app"), let expectedPID = Int32(args[2]), expectedPID > 1 else {
    emit("invalid_arguments", flags)
}
let expectedPath = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath().path
let matches = NSRunningApplication.runningApplications(withBundleIdentifier: "ru.keepcoder.Telegram").filter {
    $0.processIdentifier == expectedPID && $0.bundleURL?.resolvingSymlinksInPath().path == expectedPath
}
flags.app = matches.count == 1
guard flags.app else { emit("not_ready", flags) }
func contextIsFrontmost() -> Bool {
    guard let front = NSWorkspace.shared.frontmostApplication else { return false }
    return front.processIdentifier == expectedPID && front.bundleIdentifier == "ru.keepcoder.Telegram" &&
        front.bundleURL?.resolvingSymlinksInPath().path == expectedPath
}
flags.frontmost = contextIsFrontmost()
flags.trusted = AXIsProcessTrusted() // Does not prompt or modify permissions.
guard flags.frontmost && flags.trusted else { emit("not_ready", flags) }
let appElement = AXUIElementCreateApplication(expectedPID)
AXUIElementSetMessagingTimeout(appElement, 2)
guard let window = elementAttribute(appElement, kAXFocusedWindowAttribute as CFString),
      let windowFrame = bounds(window) else { emit("not_ready", flags) }
var windowPID: pid_t = 0
flags.window = AXUIElementGetPid(window, &windowPID) == .success && windowPID == expectedPID
guard flags.window else { emit("not_ready", flags) }

var secureFields: [AXUIElement] = [], nextButtons: [AXUIElement] = []
var stack: [(AXUIElement, Int)] = [(window, 0)], visited = 0
while let (element, depth) = stack.popLast() {
    visited += 1
    guard visited <= 800, depth <= 24 else { emit("not_ready", flags) }
    if (attribute(element, "AXHidden" as CFString) as? Bool) == true { continue }
    let role = stringAttribute(element, kAXRoleAttribute as CFString)
    if isSecure(element) && enabled(element) && visible(element, in: windowFrame) { secureFields.append(element) }
    if role == "AXButton" && enabled(element) && visible(element, in: windowFrame) {
        // Source's Login.Next = "Next"; do not guess localized titles or press arbitrary buttons.
        let label = stringAttribute(element, kAXDescriptionAttribute as CFString) ??
                    stringAttribute(element, kAXTitleAttribute as CFString)
        if label == "Next" { nextButtons.append(element) }
    }
    if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
        for child in children { stack.append((child, depth + 1)) }
    }
}
flags.secure = secureFields.count == 1
guard flags.secure, let field = secureFields.first else { emit("not_ready", flags) }
var valueSettable = DarwinBoolean(false)
flags.settable = AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &valueSettable) == .success && valueSettable.boolValue
flags.next = nextButtons.count == 1
guard flags.settable else { emit("not_ready", flags) }
if args[3] == "probe" { emit("ready", flags) }
guard let password = inputPassword(), contextIsFrontmost(),
      let focusedWindow = elementAttribute(appElement, kAXFocusedWindowAttribute as CFString), same(window, focusedWindow),
      visible(field, in: windowFrame), isSecure(field) else { emit("rejected", flags) }
guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
      let focusedField = elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString), same(field, focusedField),
      contextIsFrontmost() else { emit("rejected", flags) }
flags.focused = true
// Deliberately never call AXUIElementCopyAttributeValue(..., AXValue).
guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, password as CFString) == .success,
      contextIsFrontmost(), let stillWindow = elementAttribute(appElement, kAXFocusedWindowAttribute as CFString), same(window, stillWindow),
      let stillField = elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString), same(field, stillField) else { emit("rejected", flags) }
if flags.next, let button = nextButtons.first,
   enabled(button), visible(button, in: windowFrame),
   (stringAttribute(button, kAXDescriptionAttribute as CFString) ?? stringAttribute(button, kAXTitleAttribute as CFString)) == "Next" {
    flags.attempted = true
    let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
    emit(result == .success ? "submitted" : "submit_unverified", flags, method: "verified_next_axpress")
}
// Narrow fallback: one Return to the same PID while that exact secure field is focused.
guard let source = CGEventSource(stateID: .privateState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false),
      contextIsFrontmost(), let finalField = elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString), same(field, finalField) else { emit("rejected", flags) }
flags.attempted = true
down.postToPid(expectedPID); up.postToPid(expectedPID)
emit("submitted", flags, method: "focused_secure_return")
