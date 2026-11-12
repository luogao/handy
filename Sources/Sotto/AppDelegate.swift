import AppKit
import AVFoundation

/// 菜单栏进程的全部生命周期：图标、菜单、全局热键、录音、转写、剪贴板、气泡。
///
/// 分工刻意保持单向：AppDelegate 只做编排；录音在 MicrophoneRecorder、
/// 转写在 TranscribeService、日志在 EventLogger，任何一个都不碰别的层。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var logger = EventLogger(isEnabled: { [weak self] in
        self?.settings.loggingEnabled ?? true
    })
    private lazy var transcriber = TranscribeService(modelPath: settings.modelPath)
    private lazy var recorder = MicrophoneRecorder()
    private lazy var hotKeyManager = HotKeyManager()
    private lazy var hud = HUD()

    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var hotkeyHintItem: NSMenuItem?
    private var settingsController: SettingsWindowController?
    private var state: RecordingState = .idle
    private var isHotKeyDown = false

    /// 转写串行：连按两次时不要让两个 whisper 抢 Metal / 抢 server。
    private let transcribeQueue = DispatchQueue(label: "top.rungundam.sotto.transcribe",
                                                qos: .userInitiated)

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: AppInfo.name)
            // template = true 让菜单栏按壁纸明暗自动反色；写死颜色的图标在浅色
            // 壁纸下会糊成一块。
            image?.isTemplate = true
            button.image = image
            button.toolTip = MenuCopy.holdToTalk(settings.hotKey.displayString)
            button.setAccessibilityLabel(AppInfo.name)
        }
        item.menu = makeMenu()
        statusItem = item
        updateMenu()

        logger.write(event: "launch", fields: [
            ("version", AppInfo.version),
            ("pid", "\(getpid())"),
            ("transcriber", transcriber.location.source),
            ("hotkey", settings.hotKey.displayString),
        ])

        setupHotKey()

        recorder.onMaxDuration = { [weak self] in
            self?.finishRecording(reason: "max_duration")
        }

        handleDebugArguments()
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder.cancel()
        logger.write(event: "terminate", fields: [])
    }

    // MARK: - 菜单

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let hint = NSMenuItem(title: MenuCopy.holdToTalk(settings.hotKey.displayString),
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        hotkeyHintItem = hint

        let toggle = NSMenuItem(title: state.actionTitle,
                                action: #selector(toggleRecording),
                                keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        toggleItem = toggle

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: MenuCopy.settings,
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: MenuCopy.quit,
                              action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func updateMenu() {
        toggleItem?.title = state.actionTitle
        hotkeyHintItem?.title = MenuCopy.holdToTalk(settings.hotKey.displayString)
        let recording = state == .listening
        statusItem?.button?.toolTip = recording
            ? "\(AppInfo.name) · 正在录音"
            : MenuCopy.holdToTalk(settings.hotKey.displayString)
        let symbol = recording ? "waveform" : "mic.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: AppInfo.name)
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    // MARK: - 全局热键

    private func setupHotKey() {
        hotKeyManager.onPress = { [weak self] in self?.hotKeyPressed() }
        hotKeyManager.onRelease = { [weak self] in self?.hotKeyReleased() }
        let install = hotKeyManager.installHandler()
        let registered = hotKeyManager.register(settings.hotKey)
        logger.write(event: "hotkey", fields: [
            ("hotkey", settings.hotKey.displayString),
            ("registered", registered == 0 ? "1" : "0"),
            ("osstatus", "\(registered)"),
        ])
        if install != 0 || registered != 0 {
            logger.write(event: "error", fields: [("stage", "hotkey"),
                                                  ("code", "osstatus\(registered)")])
            hud.show("全局热键 \(settings.hotKey.displayString) 注册失败，先用菜单里的「开始」",
                     isError: true)
        }
    }

    private func hotKeyPressed() {
        isHotKeyDown = true
        // 按键到达的第一现场：这一步没有日志时，「没反应」到底是热键没送达
        // 还是录音链路静默失败，从日志上分不出来。
        logger.write(event: "hotkey_press", fields: [("state", "\(state)")])
        beginRecording(fromHotKey: true)
    }

    private func hotKeyReleased() {
        isHotKeyDown = false
        logger.write(event: "hotkey_release", fields: [])
        finishRecording(reason: "released")
    }

    /// 换热键：先注册新的，成功才落盘；失败把旧的装回去。
    /// 设置面板保存后立即生效（不重启）就是走这条。
    @discardableResult
    private func applyHotKey(_ combo: HotKeyCombo, restoreOnFailure: Bool = true) -> Bool {
        let previous = settings.hotKey
        let status = hotKeyManager.register(combo)
        guard status == 0 else {
            // 设置面板还在录新组合时不能把旧热键装回去：用户下一秒按到旧组合
            // 会被 Carbon 先吃掉，面板就再也收不到那次按键。
            if restoreOnFailure {
                _ = hotKeyManager.register(previous)
            }
            logger.write(event: "error", fields: [("stage", "hotkey"),
                                                  ("code", "osstatus\(status)")])
            return false
        }
        settings.setHotKey(combo)
        logger.write(event: "hotkey", fields: [
            ("hotkey", combo.displayString),
            ("previous", previous.displayString),
            ("registered", "1"),
        ])
        updateMenu()
        return true
    }

    // MARK: - 录音

    @objc private func toggleRecording() {
        if state == .listening {
            finishRecording(reason: "menu")
        } else {
            beginRecording(fromHotKey: false)
        }
    }

    private func beginRecording(fromHotKey: Bool) {
        guard state == .idle else { return }   // 连按/热键重复只算一次

        switch MicrophoneRecorder.authorizationStatus() {
        case .authorized:
            startRecorder()
        case .notDetermined:
            // 先数设备再申请权限：没有输入设备时系统会卡 20 秒才回 denied
            // （sotto-mic.swift 踩过这个坑），而且这里本来就不该弹权限框。
            guard MicrophoneRecorder.inputDeviceCount() > 0 else {
                logger.write(event: "error", fields: [("stage", "mic"), ("code", "no_device")])
                hud.show("没有检测到麦克风，插一个再试", isError: true)
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // 热键模式下如果权限框还没点完用户就松手了，就别再起录音。
                    let stillWanted = fromHotKey ? self.isHotKeyDown : true
                    if granted, stillWanted {
                        self.startRecorder()
                    } else if !granted {
                        self.showMicDenied()
                    }
                }
            }
        default:
            showMicDenied()
        }
    }

    private func startRecorder() {
        guard state == .idle, recorder.start() else {
            logger.write(event: "error", fields: [("stage", "record"), ("code", "start_failed")])
            hud.show("录音启动失败，检查麦克风后重试", isError: true)
            return
        }
        state = .listening
        updateMenu()
        logger.write(event: "record_start", fields: [
            ("max_s", "\(Int(MicrophoneRecorder.maxSeconds))"),
            ("hotkey", settings.hotKey.displayString),
        ])
    }

    private func finishRecording(reason: String) {
        guard state == .listening else { return }
        state = .idle
        updateMenu()

        guard let capture = recorder.stop() else {
            // <200ms：按设计丢弃。用户按太快不是错误，但要让他知道没录上。
            logger.write(event: "error", fields: [("stage", "record"),
                                                  ("code", "too_short")])
            hud.show("说话太短，按住多说一会儿", isError: true)
            return
        }
        logger.write(event: "record_stop", fields: [
            ("audio_ms", "\(capture.audioMS)"),
            ("write_ms", "\(capture.writeMS)"),
            ("reason", reason),
        ])
        process(wav: capture.url)
    }

    private func showMicDenied() {
        logger.write(event: "error", fields: [("stage", "mic"), ("code", "denied")])
        let alert = NSAlert()
        alert.messageText = "Sotto 没有麦克风权限"
        alert.informativeText = "打开「系统设置 → 隐私与安全性 → 麦克风」，勾选 Sotto 后再按一次热键。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 转写 → 剪贴板 → 气泡

    /// 录音文件和 `--record-file` 共用这一条链，不许有第二份实现。
    private func process(wav: URL) {
        transcribeQueue.async { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: wav) }   // 音频不留在盘上
            do {
                // 设置面板改完模型立即生效：每次转写前从 AppSettings 重新读，
                // 不用重启 app，也不会拿着构造时的旧路径跑。
                self.transcriber.modelPath = self.settings.modelPath
                let result = try self.transcriber.transcribe(wavURL: wav)
                self.logger.write(event: "request", fields: [("model", result.modelLabel)])
                self.logger.write(event: "transcribe", fields: [
                    ("ms", "\(result.wallMS)"),
                    ("decode_ms", result.decodeMS.map(String.init) ?? "-"),
                    ("chars", "\(result.text.count)"),
                    ("path", result.requestPath ?? "-"),
                ])
                print("transcribed chars=\(result.text.count) "
                      + "decode_ms=\(result.decodeMS.map(String.init) ?? "-") "
                      + "wall_ms=\(result.wallMS)")
                DispatchQueue.main.async {
                    if Clipboard.write(result.text) {
                        self.hud.show(MenuCopy.copiedHint)
                    } else {
                        self.logger.write(event: "error",
                                          fields: [("stage", "clipboard"),
                                                   ("code", "write_failed")])
                        self.hud.show("剪贴板写入失败，再按一次试试", isError: true)
                    }
                }
            } catch let failure as TranscribeFailure {
                if let problem = failure.modelProblem {
                    // 预检失败没 spawn 进程：日志里直接写具体原因和路径，
                    // 不要落成 exit2 那种需要再猜的码。
                    self.logger.write(event: "error", fields: [
                        ("code", problem.rawValue),
                        ("path", failure.modelPath ?? "-"),
                    ])
                } else {
                    self.logger.write(event: "error", fields: [
                        ("stage", "transcribe"),
                        ("code", "exit\(failure.status)"),
                    ])
                }
                FileHandle.standardError.write(Data(("sotto: " + failure.bubbleMessage + "\n").utf8))
                DispatchQueue.main.async {
                    self.hud.show(failure.bubbleMessage, isError: true)
                }
            } catch {
                self.logger.write(event: "error", fields: [("stage", "transcribe"),
                                                           ("code", "unknown")])
                DispatchQueue.main.async {
                    self.hud.show("转写失败，详见日志", isError: true)
                }
            }
        }
    }

    // MARK: - 设置

    @objc private func openSettings() {
        if settingsController == nil {
            let controller = SettingsWindowController(settings: settings)
            controller.onCaptureStart = { [weak self] in
                self?.hotKeyManager.unregisterHotKey()
            }
            controller.onCaptureCancel = { [weak self] in
                guard let self else { return }
                _ = self.hotKeyManager.register(self.settings.hotKey)
            }
            controller.onHotKeyChange = { [weak self] combo in
                self?.applyHotKey(combo, restoreOnFailure: false) ?? false
            }
            controller.onLoggingChange = { [weak self] enabled in
                self?.settings.setLoggingEnabled(enabled)
            }
            controller.onModelChange = { [weak self] path in
                // 只记一笔；真正生效在 process() 里从 AppSettings 重读，
                // 避免在这里跨线程改 transcriber 的状态。
                self?.logger.write(event: "settings", fields: [("model", path ?? "default")])
            }
            settingsController = controller
        }
        settingsController?.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 调试入口（GUI 侧）

    /// 这些参数不改变正常启动行为，只在验收/截图时用：
    ///   --demo                     启动后展开菜单（截图）
    ///   --demo-toggle              只切换菜单文案/图标，不录音（截图录音态）
    ///   --record-file <wav>        跳过麦克风，走「录音已结束」之后的同一条链
    ///   --set-hotkey <组合>        走设置面板保存时的同一段代码，然后退出
    ///   --set-logging on|off       走设置面板复选框的同一段代码，然后退出
    private func handleDebugArguments() {
        let arguments = CommandLine.arguments

        if let index = arguments.firstIndex(of: "--set-hotkey"), index + 1 < arguments.count {
            let raw = arguments[index + 1]
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let combo = HotKeyCombo.parse(raw) else {
                    print("hotkey_parse_failed=\(raw)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
                    return
                }
                let previous = self.settings.hotKey.displayString
                let ok = self.applyHotKey(combo)
                print("previous=\(previous) hotkey=\(combo.displayString) registered=\(ok ? 1 : 0)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            }
        }

        if let index = arguments.firstIndex(of: "--set-logging"), index + 1 < arguments.count {
            let enabled = arguments[index + 1].lowercased() == "on"
            settings.setLoggingEnabled(enabled)
            logger.write(event: "settings", fields: [("logging", enabled ? "on" : "off")])
            print("logging=\(enabled ? "on" : "off") path=\(logger.fileURL.path)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
        }

        if let index = arguments.firstIndex(of: "--record-file"), index + 1 < arguments.count {
            let path = (arguments[index + 1] as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.process(wav: url)
            }
        }

        if arguments.contains("--demo-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.openSettings()
            }
        }

        if arguments.contains("--demo") {
            if arguments.contains("--demo-toggle") {
                state = state.toggled
                updateMenu()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let button = self?.statusItem?.button,
                      let menu = self?.statusItem?.menu else { return }
                // 只是把「人点一下」换成代码点一下，显示的还是同一个 NSMenu。
                menu.popUp(positioning: nil,
                           at: NSPoint(x: 0, y: button.bounds.height + 4),
                           in: button)
            }
        }
    }
}
