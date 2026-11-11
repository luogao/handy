import AppKit

/// 设置面板：热键 + 日志开关 + 模型路径。
///
/// 模型这一组只负责「选文件 / 恢复默认」，不做模型清单和下载——那是 P2。
/// 生效路径必须一直显示出来（含来源），否则用户选完不知道到底在用哪个。
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: AppSettings
    private let hotKeyValueLabel = NSTextField(labelWithString: "")
    private let recordButton = NSButton(title: "重新录制", target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "")
    private let loggingBox = NSButton(checkboxWithTitle: "记录事件日志（只记时间、耗时、字数，不记识别文本）",
                                      target: nil, action: nil)
    private let modelPathLabel = NSTextField(labelWithString: "")
    private let chooseModelButton = NSButton(title: "选择…", target: nil, action: nil)
    private let resetModelButton = NSButton(title: "恢复默认", target: nil, action: nil)
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
        recordButton.target = self
        recordButton.action = #selector(toggleCapture)
        loggingBox.target = self
        loggingBox.action = #selector(loggingToggled)
        loggingBox.state = settings.loggingEnabled ? .on : .off
        chooseModelButton.target = self
        chooseModelButton.action = #selector(chooseModel)
        resetModelButton.target = self
        resetModelButton.action = #selector(resetModel)
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

    // MARK: - 界面

    private func refresh() {
        hotKeyValueLabel.stringValue = settings.hotKey.displayString
        hintLabel.stringValue = "保存后立即生效，不用重启。按 Esc 可取消重录。"
        loggingBox.state = settings.loggingEnabled ? .on : .off
        refreshModelRow()
    }

    /// 「生效路径」实时反映设置：未设置显示默认 + 来源，已设置显示自定义 + 来源。
    private func refreshModelRow() {
        let description = HandyPaths.modelPathDescription(customPath: settings.modelPath)
        modelPathLabel.stringValue = description
        modelPathLabel.toolTip = description
        // 已经是默认态时「恢复默认」没有意义，灰掉避免误点。
        resetModelButton.isEnabled = settings.modelPath != nil
    }

    private func makeWindow() -> NSWindow {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let hotKeyTitle = NSTextField(labelWithString: "全局热键")
        hotKeyTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(hotKeyTitle)

        hotKeyValueLabel.font = .monospacedSystemFont(ofSize: 18, weight: .semibold)
        hotKeyValueLabel.stringValue = settings.hotKey.displayString
        recordButton.bezelStyle = .rounded
        let hotKeyRow = NSStackView(views: [hotKeyValueLabel, recordButton])
        hotKeyRow.orientation = .horizontal
        hotKeyRow.spacing = 12
        hotKeyRow.alignment = .centerY
        stack.addArrangedSubview(hotKeyRow)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hintLabel)

        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalToConstant: 416).isActive = true

        let logTitle = NSTextField(labelWithString: "日志")
        logTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(logTitle)
        stack.addArrangedSubview(loggingBox)

        let logPath = NSTextField(labelWithString: "位置：~/Library/Caches/handy/handy.log")
        logPath.font = .systemFont(ofSize: 11)
        logPath.textColor = .secondaryLabelColor
        stack.addArrangedSubview(logPath)

        let modelSeparator = NSBox()
        modelSeparator.boxType = .separator
        stack.addArrangedSubview(modelSeparator)
        modelSeparator.widthAnchor.constraint(equalToConstant: 416).isActive = true

        let modelTitle = NSTextField(labelWithString: "模型")
        modelTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(modelTitle)

        modelPathLabel.font = .systemFont(ofSize: 11)
        modelPathLabel.textColor = .secondaryLabelColor
        modelPathLabel.lineBreakMode = .byTruncatingMiddle
        modelPathLabel.maximumNumberOfLines = 1
        modelPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modelPathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 416).isActive = true
        refreshModelRow()
        stack.addArrangedSubview(modelPathLabel)

        chooseModelButton.bezelStyle = .rounded
        resetModelButton.bezelStyle = .rounded
        let modelRow = NSStackView(views: [chooseModelButton, resetModelButton])
        modelRow.orientation = .horizontal
        modelRow.spacing = 8
        modelRow.alignment = .centerY
        stack.addArrangedSubview(modelRow)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Handy 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        // 菜单栏 app 没有 Dock 图标可点，窗口开在别的 app 后面等于「点了没反应」。
        window.level = .floating

        // 内容视图必须是个普通 NSView：直接把 NSStackView 当 contentView 时，
        // 它的 translatesAutoresizingMask 会被窗口改回去，栈里的约束就打架。
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container

        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        window.setContentSize(stack.fittingSize)
        return window
    }

    // MARK: - 热键重录

    @objc private func toggleCapture() {
        if isCapturing {
            cancelCapture()
        } else {
            startCapture()
        }
    }

    private func startCapture() {
        isCapturing = true
        recordButton.title = "取消"
        hotKeyValueLabel.stringValue = "按下新的组合键…"
        hintLabel.stringValue = "至少包含 ⌃⌥⇧⌘ 之一；Esc 取消。"
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
            hintLabel.stringValue = "要加至少一个修饰键（⌃⌥⇧⌘），否则会挡住正常打字。"
            return nil                      // 吞掉这次按键，别让它落进输入框
        }
        guard onHotKeyChange?(combo) == true else {
            hintLabel.stringValue = "这个组合被系统占用了，换一个。"
            return nil
        }
        stopMonitor()
        isCapturing = false
        recordButton.title = "重新录制"
        hotKeyValueLabel.stringValue = combo.displayString
        hintLabel.stringValue = "已生效，不用重启。"
        return nil
    }

    private func cancelCapture() {
        stopMonitor()
        isCapturing = false
        recordButton.title = "重新录制"
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

    @objc private func loggingToggled() {
        let enabled = loggingBox.state == .on
        onLoggingChange?(enabled)
        hintLabel.stringValue = enabled ? "日志已打开。" : "日志已关闭，不再新增事件行。"
    }

    // MARK: - 模型

    /// 不限制文件类型：卡里要求「选了一个 .txt」也能走预检报「无法读取」，
    /// 而不是在面板里就选不中。真正的判定交给 ModelPreflight。
    @objc private func chooseModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 whisper 模型文件（ggml-*.bin）"
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }  // 取消不改键
        settings.setModelPath(url.path)
        refreshModelRow()
        onModelChange?(settings.modelPath)
    }

    @objc private func resetModel() {
        settings.setModelPath(nil)
        refreshModelRow()
        onModelChange?(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if isCapturing {
            cancelCapture()
        }
    }
}
