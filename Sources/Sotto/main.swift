import AppKit

// ── 入口：验收/自检入口走命令行，其余进 GUI ──

let arguments = CommandLine.arguments

let usage = """
Sotto — 按住热键说话，松手把文字放进剪贴板

用法：
  Sotto                                    启动菜单栏 app（默认 ⌃⌥H）
  Sotto --transcribe-file <wav> [--json]   只跑转写（时延验收用）
  Sotto --help

调试入口：
  --demo                 启动后展开菜单（截图）
  --demo-toggle          菜单切到录音态（不录音，截图）
  --record-file <wav>    跳过麦克风，走「录音结束 → 转写 → 剪贴板 → 气泡」
  --set-hotkey <组合>    例 ctrl+shift+J；走设置面板保存的同一段代码后退出
  --set-logging on|off   走设置面板复选框的同一段代码后退出
  --dump-menu            打印菜单文案后退出
"""

if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
}

if arguments.contains("--transcribe-file") {
    // 纯命令行路径：不建 NSApplication、不碰麦克风/剪贴板/界面。
    TranscribeFileCommand.run(arguments: arguments)
}

if arguments.contains("--dump-menu") {
    // 不建 NSApplication：这里只验菜单的文案和状态机，不碰窗口系统。
    var state = RecordingState.idle
    print("\(AppInfo.name) menu (v\(AppInfo.version)):")
    print("  \(MenuCopy.holdToTalk(HotKeyCombo.default.displayString))")
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
// 直接跑 .build/debug/Sotto 没有 plist 可读，所以这里再显式设一次。
app.setActivationPolicy(.accessory)
app.run()
