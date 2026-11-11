import AppKit

/// 菜单栏进程的全部生命周期都在这里。P0 只做三件事：
/// 挂图标、挂菜单、把点击变成可观察的反馈（文案 + 日志），不碰音频。
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private(set) var state: RecordingState = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: AppInfo.name)
            // template = true 让菜单栏按壁纸明暗自动反色；写死颜色的图标在浅色
            // 壁纸下会糊成一块。
            image?.isTemplate = true
            button.image = image
            button.toolTip = AppInfo.name
            button.setAccessibilityLabel(AppInfo.name)
        }
        item.menu = makeMenu()
        statusItem = item

        NSLog("[handy] launched pid=%d v%@ (%@) state=%@",
              getpid(), AppInfo.version, AppInfo.build, state.rawValue)

        // 验收截图用：启动后自动把菜单展开，免得截图的人要靠辅助功能去点。
        // 只是把「人点一下」换成代码点一下，显示的还是同一个 NSMenu。
        if CommandLine.arguments.contains("--demo") {
            if CommandLine.arguments.contains("--demo-toggle") {
                toggleRecording()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let button = self?.statusItem?.button,
                      let menu = self?.statusItem?.menu else { return }
                menu.popUp(positioning: nil,
                           at: NSPoint(x: 0, y: button.bounds.height + 4),
                           in: button)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("[handy] terminating")
    }

    // MARK: - 菜单

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let toggle = NSMenuItem(title: state.actionTitle,
                                action: #selector(toggleRecording),
                                keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        toggleItem = toggle

        menu.addItem(.separator())

        // 设置项先做成可点的占位窗口：灰掉会让人以为是坏的，
        // 点开看到「还没做」比点不动诚实。
        let settings = NSMenuItem(title: MenuCopy.settings,
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: MenuCopy.quit,
                              action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func toggleRecording() {
        state = state.toggled
        toggleItem?.title = state.actionTitle
        statusItem?.button?.toolTip = "\(AppInfo.name) · \(state.actionTitle)"
        NSLog("[handy] state -> %@ (P0 占位：没有录音)", state.rawValue)
    }

    // MARK: - 设置（占位）

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Handy 设置"
        window.isReleasedWhenClosed = false

        let label = NSTextField(labelWithString: "热键、模型和日志开关会在 v0.1 功能移植完成后出现在这里。")
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        window.contentView = container
        window.center()
        return window
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
