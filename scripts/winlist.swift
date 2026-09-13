// winlist.swift —— 列出当前屏幕上的窗口（调试用）。
// 用来客观验证启动器是否真的把窗口开出来了、尺寸对不对。
import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    print("无法获取窗口列表")
    exit(1)
}

let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
    guard let filter, owner.localizedCaseInsensitiveContains(filter) else { continue }
    let name = window[kCGWindowName as String] as? String ?? ""
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
    let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
    let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
    let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
    print(String(format: "owner=%@ layer=%d size=%.0fx%.0f alpha=%.2f title=%@",
                 owner, layer, width, height, alpha, name))
}
