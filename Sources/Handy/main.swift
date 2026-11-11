import AppKit

// ── 入口：--dump-menu 走命令行自检，其余进 GUI ──

if CommandLine.arguments.contains("--dump-menu") {
    // 不建 NSApplication：这里只验菜单的文案和状态机，不碰窗口系统。
    var state = RecordingState.idle
    print("\(AppInfo.name) menu (v\(AppInfo.version)):")
    print("  \(state.actionTitle)")
    state = state.toggled
    print("  \(state.actionTitle)")
    state = state.toggled
    print("  \(state.actionTitle)")
    print("  \(MenuCopy.settings)")
    print("  \(MenuCopy.quit)")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 菜单栏 app 不该出现在 Dock / ⌘Tab。打包后靠 Info.plist 的 LSUIElement，
// 直接跑 .build/debug/Handy 没有 plist 可读，所以这里再显式设一次。
app.setActivationPolicy(.accessory)
app.run()
