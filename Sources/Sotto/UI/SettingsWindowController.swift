import AppKit
import SwiftUI

/// 设置面板：通用（热键 / 日志）、模型、版本三块，样式和「海牛」的设置台同源。
///
/// 这一层只做三件事：画窗口、把 SwiftUI 的按钮接回真实动作、把状态刷新进
/// `SettingsModel`。热键必须真去 Carbon 试注册，模型必须走 NSOpenPanel，
/// 这些都不能放进 View 里。
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: AppSettings
    private let model = SettingsModel()
    private lazy var window: NSWindow = makeWindow()

    /// 开始录新组合前临时注销全局热键：否则按到「当前组合」会被 Carbon 先吃掉，
    /// 本地监听根本收不到那次 keyDown。
    var onCaptureStart: (() -> Void)?
    /// 取消 / 关窗时把原组合装回去。
    var onCaptureCancel: (() -> Void)?
    /// 返回是否注册成功。false 时面板留在录制态并提示换一个。
    var onHotKeyChange: ((HotKeyCombo) -> Bool)?
    var onLoggingChange: ((Bool) -> Void)?
    /// 模型键变了（选择 / 恢复默认）才回调；点「取消」不触发。
    var onModelChange: ((String?) -> Void)?

    private var monitor: Any?
    private var isCapturing = false

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        model.onToggleCapture = { [weak self] in self?.toggleCapture() }
        model.onLoggingChange = { [weak self] enabled in self?.loggingChanged(enabled) }
        model.onPickModel = { [weak self] in self?.chooseModel() }
        model.onResetModel = { [weak self] in self?.resetModel() }
        refresh()
    }

    func show() {
        refresh()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 状态

    private func refresh() {
        model.hotKeyText = settings.hotKey.displayString
        model.hint = "保存后立即生效，不用重启。按 Esc 可取消重录。"
        model.loggingEnabled = settings.loggingEnabled
        refreshModel()
    }

    /// 「生效路径」实时反映设置：未设置显示默认 + 来源，已设置显示自定义 + 来源。
    private func refreshModel() {
        model.modelPathText = SottoPaths.modelPathDescription(customPath: settings.modelPath)
        model.modelSource = {
            if settings.modelPath != nil { return "自定义" }
            if SottoPaths.bundledModelPath() != nil { return "包内自带" }
            return "用户缓存"
        }()

        let effective = settings.modelPath ?? SottoPaths.defaultModelPath().path
        model.modelSize = Self.humanSize(of: effective)
        model.canResetModel = settings.modelPath != nil
    }

    private static func humanSize(of path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let attrs = try? FileManager.default.attributesOfItem(atPath: resolved)
        guard let bytes = (attrs?[.size] as? NSNumber)?.int64Value, bytes > 0 else { return "—" }
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }

    // MARK: - 窗口

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 634),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Sotto 设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 12/255, green: 12/255, blue: 13/255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.delegate = self
        // 菜单栏 app 没有 Dock 图标可点，窗口开在别的 app 后面等于「点了没反应」。
        window.level = .floating
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.setContentSize(NSSize(width: 620, height: 634))
        return window
    }

    // MARK: - 热键重录

    private func toggleCapture() {
        if isCapturing {
            cancelCapture()
        } else {
            startCapture()
        }
    }

    private func startCapture() {
        isCapturing = true
        model.isCapturing = true
        model.hint = "至少包含 ⌃⌥⇧⌘ 之一；Esc 取消。"
        onCaptureStart?()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleCaptureKey(event)
        }
    }

    private func handleCaptureKey(_ event: NSEvent) -> NSEvent? {
        guard isCapturing else { return event }
        if event.keyCode == 53 {          // Esc
            cancelCapture()
            return nil
        }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let combo = HotKeyCombo(keyCode: UInt32(event.keyCode),
                                control: flags.contains(.control),
                                option: flags.contains(.option),
                                shift: flags.contains(.shift),
                                command: flags.contains(.command))
        guard combo.isValid else {
            model.hint = "要加至少一个修饰键（⌃⌥⇧⌘），否则会挡住正常打字。"
            return nil                      // 吞掉这次按键，别让它落进输入框
        }
        guard onHotKeyChange?(combo) == true else {
            model.hint = "这个组合被系统占用了，换一个。"
            return nil
        }
        stopMonitor()
        isCapturing = false
        model.isCapturing = false
        model.hotKeyText = combo.displayString
        model.hint = "已生效，不用重启。"
        return nil
    }

    private func cancelCapture() {
        stopMonitor()
        isCapturing = false
        model.isCapturing = false
        onCaptureCancel?()
        refresh()
    }

    private func stopMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    // MARK: - 日志开关

    /// 落盘交给 AppDelegate（它已经负责写 settings.setLoggingEnabled），
    /// 这里只通知，避免两处各写一次。
    private func loggingChanged(_ enabled: Bool) {
        onLoggingChange?(enabled)
    }

    // MARK: - 模型

    /// 不限制文件类型：卡里要求「选了一个 .txt」也能走预检报「无法读取」，
    /// 而不是在面板里就选不中。真正的判定交给 ModelPreflight。
    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 whisper 模型文件（ggml-*.bin）"
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }  // 取消不改键
        settings.setModelPath(url.path)
        refreshModel()
        onModelChange?(settings.modelPath)
    }

    private func resetModel() {
        settings.setModelPath(nil)
        refreshModel()
        onModelChange?(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if isCapturing {
            cancelCapture()
        }
    }
}
