// Inspect the actual WindowServer and the official application; creates no UI.
import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("Usage: window_probe <expected-app-path> <inspect|activate>\n", stderr)
    exit(64)
}
let expectedPath = URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath().path
let bundleIdentifier = "ru.keepcoder.Telegram"
let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
let target = applications.first { $0.bundleURL?.resolvingSymlinksInPath().path == expectedPath }
if arguments[2] == "activate" {
    guard let target else { exit(2) }
    target.activate(options: [.activateIgnoringOtherApps])
}
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
let candidates = windows.filter {
    guard let target,
          let pid = $0[kCGWindowOwnerPID as String] as? NSNumber,
          pid.int32Value == target.processIdentifier,
          let layer = $0[kCGWindowLayer as String] as? NSNumber,
          layer.intValue == 0,
          let bounds = $0[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? NSNumber,
          let height = bounds["Height"] as? NSNumber else { return false }
    return width.doubleValue >= 200 && height.doubleValue >= 160
}.sorted {
    func area(_ item: [String: Any]) -> Double {
        let bounds = item[kCGWindowBounds as String] as? [String: Any] ?? [:]
        return ((bounds["Width"] as? NSNumber)?.doubleValue ?? 0) * ((bounds["Height"] as? NSNumber)?.doubleValue ?? 0)
    }
    return area($0) > area($1)
}
let window = candidates.first
let screens = NSScreen.screens.map { screen -> [String: Any] in
    let frame = screen.frame
    return ["frame_points": [frame.origin.x, frame.origin.y, frame.width, frame.height],
            "backing_scale_factor": screen.backingScaleFactor]
}
var result: [String: Any] = [
    "bundle_identifier": bundleIdentifier,
    "expected_application_running": target != nil,
    "frontmost_bundle_identifier": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
    "screen_capture_preflight": CGPreflightScreenCaptureAccess(),
    "screens": screens,
    "target_window_count": candidates.count
]
if let target { result["target_pid"] = Int(target.processIdentifier) }
if let window {
    result["window_id"] = window[kCGWindowNumber as String]
    result["window_bounds"] = window[kCGWindowBounds as String]
}
let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(json)
FileHandle.standardOutput.write(Data("\n".utf8))
exit(target != nil && window != nil && !screens.isEmpty ? 0 : 2)
