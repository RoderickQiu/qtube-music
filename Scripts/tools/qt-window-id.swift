// qt-window-id — find a window's CGWindowID by owner pid and title (for `screencapture -l`).
// Compiled on demand by Scripts/lib.sh into .build/qt-tools/.
//
//   qt-window-id --pid <pid> [--title <substring>] [--wait <seconds>]   → prints the window id
//   qt-window-id --pid <pid> --list                                       → id, layer, bounds, title per window
//
// Without --title it picks the largest normal-layer window. Titles need Screen Recording permission for the
// calling terminal; without it, matching falls back to the largest window when exactly one candidate exists.
import AppKit
import CoreGraphics
import Foundation

struct Win { let id: Int; let layer: Int; let title: String; let area: Double; let bounds: String; let onScreen: Bool }

func windows(pid: Int32) -> [Win] {
    guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { w in
        guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, let id = w[kCGWindowNumber as String] as? Int else { return nil }
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        let width = b["Width"] ?? 0, height = b["Height"] ?? 0
        return Win(id: id, layer: w[kCGWindowLayer as String] as? Int ?? 0, title: w[kCGWindowName as String] as? String ?? "",
                   area: width * height, bounds: "\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(width))x\(Int(height))",
                   onScreen: w[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }
}

var args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
// `--display-bounds <name substring>` → "x y w h" of that display in global CG coordinates (region captures
// clamp to it so they never include another display, e.g. the user's main screen).
if let name = value("--display-bounds") {
    for screen in NSScreen.screens where screen.localizedName.range(of: name, options: .caseInsensitive) != nil {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
        let b = CGDisplayBounds(CGDirectDisplayID(n.uint32Value))
        print("\(Int(b.minX)) \(Int(b.minY)) \(Int(b.width)) \(Int(b.height))")
        exit(0)
    }
    exit(1)
}
guard let pidString = value("--pid"), let pid = Int32(pidString) else {
    FileHandle.standardError.write(Data("usage: qt-window-id --pid <pid> [--title <substring>] [--wait <s>] [--list]\n".utf8))
    exit(2)
}
if args.contains("--list") {
    for w in windows(pid: pid) { print("\(w.id)\tlayer=\(w.layer)\tonScreen=\(w.onScreen)\t\(w.bounds)\t\(w.title)") }
    exit(0)
}
let title = value("--title")
let deadline = Date().addingTimeInterval(Double(value("--wait") ?? "0") ?? 0)
repeat {
    let candidates = windows(pid: pid).filter { $0.onScreen && $0.area > 400 }
    let match: Win?
    if let title {
        match = candidates.filter { $0.title.localizedCaseInsensitiveContains(title) }.max { $0.area < $1.area }
            ?? (candidates.allSatisfy { $0.title.isEmpty } && candidates.count == 1 ? candidates.first : nil)
    } else {
        match = candidates.filter { $0.layer == 0 }.max { $0.area < $1.area }
    }
    if let match { print(match.id); exit(0) }
    Thread.sleep(forTimeInterval: 0.2)
} while Date() < deadline
FileHandle.standardError.write(Data("qt-window-id: no window for pid \(pid)\(title.map { " titled ~\"\($0)\"" } ?? "")\n".utf8))
exit(1)
