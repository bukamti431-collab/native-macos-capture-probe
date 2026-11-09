// Fixed native search only. No messages, result selection, clipboard, or free text.
// CLI: native_ui ABSOLUTE_APP_PATH EXPECTED_PID probe-filter|filter-target
// filter-target stdin: {"target":"ConfiguredBotUsername"}; ASCII username only.
// filtered means the native search field contains the query, not that all
// displayed results have been independently checked for presentation privacy.
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

private func emit(_ status: String, available: Bool = false, filtered: Bool = false) -> Never {
    let value: [String: Any] = ["status": status, "search_available": available, "filtered": filtered]
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
    exit(["available", "not_available", "filtered"].contains(status) ? 0 : 2)
}
private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
}
private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? { attribute(element, name) as? String }
private func elementAttribute(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
    guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return value as! AXUIElement
}
private func bounds(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute as CFString),
          let s = attribute(element, kAXSizeAttribute as CFString),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
          point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
          size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: point, size: size)
}
private func isSearch(_ element: AXUIElement) -> Bool {
    stringAttribute(element, kAXRoleAttribute as CFString) == "AXTextField" &&
        stringAttribute(element, kAXSubroleAttribute as CFString) == "AXSearchField"
}
private func searchField(_ window: AXUIElement, frame: CGRect) -> AXUIElement? {
    var stack: [(AXUIElement, Int)] = [(window, 0)], found: [AXUIElement] = [], visited = 0
    while let (element, depth) = stack.popLast() {
        visited += 1
        if visited > 600 || depth > 20 { return nil }
        if (attribute(element, "AXHidden" as CFString) as? Bool) == true { continue }
        let role = stringAttribute(element, kAXRoleAttribute as CFString)
        // Search is a header sibling. Do not enumerate chat/message row contents.
        if ["AXList", "AXTable", "AXOutline"].contains(role ?? "") { continue }
        if isSearch(element), let fieldFrame = bounds(element),
           frame.contains(fieldFrame), fieldFrame.midX < frame.minX + frame.width * 0.55,
           fieldFrame.minY < frame.minY + min(200, frame.height * 0.3),
           !found.contains(where: { CFEqual($0, element) }) { found.append(element) }
        if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for child in children { stack.append((child, depth + 1)) }
        }
    }
    return found.count == 1 ? found.first : nil
}
private func inputQuery() -> String? {
    guard isatty(STDIN_FILENO) == 0 else { return nil }
    var data = Data()
    do {
        while true {
            let chunk = try FileHandle.standardInput.read(upToCount: 513 - data.count) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > 512 { return nil }
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["target"]), let target = object["target"] as? String,
              (5...32).contains(target.utf8.count), target.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
              }) else { return nil } // Exactly /^[A-Za-z0-9_]{5,32}$/; no newline/Unicode/free text.
        let normalized = target.lowercased()
        return normalized.hasSuffix("_bot") ? String(normalized.dropLast(4)) : normalized
    } catch { return nil }
}

let args = CommandLine.arguments
guard args.count == 4, ["probe-filter", "filter-target"].contains(args[3]),
      args[1].hasPrefix("/"), args[1].hasSuffix(".app"), let pid = Int32(args[2]), pid > 1 else { emit("invalid_arguments") }
let expectedPath = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath().path
let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "ru.keepcoder.Telegram").filter {
    $0.processIdentifier == pid && $0.bundleURL?.resolvingSymlinksInPath().path == expectedPath
}
guard applications.count == 1, AXIsProcessTrusted() else { emit("not_available") }
func frontmost() -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication else { return false }
    return app.processIdentifier == pid && app.bundleIdentifier == "ru.keepcoder.Telegram" &&
        app.bundleURL?.resolvingSymlinksInPath().path == expectedPath
}
guard frontmost() else { emit("not_available") }
let appElement = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(appElement, 1)
guard let window = elementAttribute(appElement, kAXFocusedWindowAttribute as CFString),
      let frame = bounds(window), let initialField = searchField(window, frame: frame) else { emit("not_available") }
var windowPID: pid_t = 0
guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == pid else { emit("not_available") }
if args[3] == "probe-filter" { emit("available", available: true) }
guard let fixedQuery = inputQuery(), frontmost() else { emit("rejected") }
func sameWindow() -> Bool {
    guard frontmost(), let current = elementAttribute(appElement, kAXFocusedWindowAttribute as CFString) else { return false }
    return CFEqual(current, window)
}
// Source SearchView's AX focus opens its own real input; no global Cmd-K.
guard sameWindow(), AXUIElementSetAttributeValue(initialField, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { emit("unverified", available: true) }
var field: AXUIElement?
for _ in 0..<8 {
    guard sameWindow() else { emit("unverified", available: true) }
    if let candidate = searchField(window, frame: frame),
       let focused = elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString),
       CFEqual(candidate, focused), isSearch(focused) { field = candidate; break }
    Thread.sleep(forTimeInterval: 0.1)
}
guard let field else { emit("unverified", available: true) }
func focusedSearch() -> Bool {
    guard sameWindow(), isSearch(field), let focused = elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString) else { return false }
    return CFEqual(field, focused)
}
guard let source = CGEventSource(stateID: .privateState),
      let selectDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
      let selectUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false),
      let typeDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
      let typeUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false),
      focusedSearch() else { emit("unverified", available: true) }
selectDown.flags = .maskCommand; selectUp.flags = .maskCommand
selectDown.postToPid(pid); selectUp.postToPid(pid)
guard focusedSearch() else { emit("unverified", available: true) }
typeDown.flags = []; typeUp.flags = []
let units = Array(fixedQuery.utf16)
units.withUnsafeBufferPointer { buffer in
    if let pointer = buffer.baseAddress {
        typeDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: pointer)
        typeUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: pointer)
    }
}
// No Return: this only edits the verified native search input.
typeDown.postToPid(pid); typeUp.postToPid(pid)
for _ in 0..<8 {
    guard focusedSearch() else { emit("unverified", available: true) }
    // Read only this search field after replacing it; never read chat text.
    if stringAttribute(field, kAXValueAttribute as CFString) == fixedQuery {
        emit("filtered", available: true, filtered: true)
    }
    Thread.sleep(forTimeInterval: 0.1)
}
emit("unverified", available: true)
