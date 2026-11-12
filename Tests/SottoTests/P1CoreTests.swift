import Foundation
import Testing
@testable import Sotto

// MARK: - 热键组合

@Test func 默认热键是控制加选项加H() {
    let combo = HotKeyCombo.default
    #expect(combo.keyCode == KeyCode.h)
    #expect(combo.control)
    #expect(combo.option)
    #expect(!combo.shift)
    #expect(!combo.command)
    #expect(combo.displayString == "⌃⌥H")
    #expect(combo.carbonModifiers == 0x1800)
    #expect(combo.isValid)
}

@Test func 热键文案顺序固定为控制选项上档命令() {
    let combo = HotKeyCombo(keyCode: KeyCode.h, control: true, option: true,
                            shift: true, command: true)
    #expect(combo.displayString == "⌃⌥⇧⌘H")
    #expect(combo.carbonModifiers == 0x1B00)
}

@Test func 热键可以解析常见写法() {
    #expect(HotKeyCombo.parse("ctrl+opt+H") == .default)
    #expect(HotKeyCombo.parse("⌃⌥H") == .default)
    #expect(HotKeyCombo.parse("cmd+shift+j")
            == HotKeyCombo(keyCode: KeyCode.j, control: false, option: false,
                           shift: true, command: true))
    #expect(HotKeyCombo.parse("option+control+space")
            == HotKeyCombo(keyCode: 49, control: true, option: true,
                           shift: false, command: false))
}

@Test func 没有修饰键或没有主键的热键不合法() {
    #expect(HotKeyCombo.parse("H") == nil)          // 裸字母会挡住正常打字
    #expect(HotKeyCombo.parse("ctrl+") == nil)      // 没有主键
    #expect(HotKeyCombo.parse("") == nil)
    #expect(HotKeyCombo.parse("ctrl+A+B") == nil)   // 两个主键
    #expect(HotKeyCombo.parse("ctrl+不存在的键") == nil)
}

@Test func 特殊键有可读文案() {
    #expect(KeyCode.name(for: 49) == "Space")
    #expect(KeyCode.name(for: 53) == "Esc")
    #expect(KeyCode.name(for: 123) == "←")
    #expect(KeyCode.name(for: 999) == "Key999")
}

// MARK: - 设置

@Test func 设置默认值() {
    let name = "SottoTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.hotKey == .default)
    #expect(settings.loggingEnabled)   // 默认开
}

@Test func 热键与日志开关会持久化() {
    let name = "SottoTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let combo = HotKeyCombo(keyCode: KeyCode.j, control: true, option: false,
                            shift: true, command: false)
    AppSettings(defaults: defaults).setHotKey(combo)
    AppSettings(defaults: defaults).setLoggingEnabled(false)

    let reloaded = AppSettings(defaults: defaults)
    #expect(reloaded.hotKey == combo)
    #expect(!reloaded.loggingEnabled)
}

// MARK: - 事件日志

@Test func 日志行是毫秒时间戳加元数据() {
    let date = Date(timeIntervalSince1970: 1_700_000_000.123)
    let line = EventLogger.line(event: "transcribe",
                                fields: [("ms", "1234"), ("chars", "45")], at: date)
    let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z event=transcribe ms=1234 chars=45$"#
    #expect(line.range(of: pattern, options: .regularExpression) != nil)
}

@Test func 日志字段里的空白不会把一行拆成两行() {
    let line = EventLogger.line(event: "error",
                                fields: [("stage", "mic"), ("detail", "a b\nc")],
                                at: Date(timeIntervalSince1970: 0))
    #expect(line.contains("detail=a_b_c"))
    #expect(!line.contains("\n"))
}

@Test func 日志关闭时不写文件() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sotto-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = EventLogger(directory: directory, isEnabled: { false })
    logger.write(event: "record_start", fields: [("max_s", "60")])
    #expect(!FileManager.default.fileExists(atPath: logger.fileURL.path))
}

@Test func 日志打开时追加一行() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sotto-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = EventLogger(directory: directory, isEnabled: { true })
    logger.write(event: "record_stop", fields: [("audio_ms", "1200")])
    let text = try String(contentsOf: logger.fileURL, encoding: .utf8)
    #expect(text.contains("event=record_stop audio_ms=1200"))
    #expect(text.hasSuffix("\n"))
}

// MARK: - 转写器定位

@Test func 环境变量覆盖转写器路径() {
    let target = "/opt/fake/sotto-transcribe"
    let location = TranscriberResolver.resolve(
        environment: ["SOTTO_TRANSCRIBE": target],
        bundleResourceURL: nil,
        executableURL: URL(fileURLWithPath: "/repo/sotto/.build/debug/Sotto"),
        isExecutable: { $0 == target }
    )
    #expect(location.url?.path == target)
    #expect(location.source == "SOTTO_TRANSCRIBE")
}

@Test func 环境变量指错时不静默回退() {
    let location = TranscriberResolver.resolve(
        environment: ["SOTTO_TRANSCRIBE": "/opt/missing"],
        bundleResourceURL: nil,
        executableURL: URL(fileURLWithPath: "/repo/sotto/.build/debug/Sotto"),
        isExecutable: { $0 == "/repo/sotto/sotto-transcribe" }   // 开发目录其实存在
    )
    #expect(location.url == nil)
    #expect(location.source == "SOTTO_TRANSCRIBE")
}

@Test func 打包后优先用bundle内的二进制() {
    let bundled = "/Applications/Sotto.app/Contents/Resources/bin/sotto-transcribe"
    let location = TranscriberResolver.resolve(
        environment: [:],
        bundleResourceURL: URL(fileURLWithPath: "/Applications/Sotto.app/Contents/Resources"),
        executableURL: URL(fileURLWithPath: "/Applications/Sotto.app/Contents/MacOS/Sotto"),
        isExecutable: { $0 == bundled }
    )
    #expect(location.url?.path == bundled)
    #expect(location.source == "bundle")
}

@Test func 开发态从可执行文件向上找到仓库里的转写器() {
    let expected = "/repo/sotto/sotto-transcribe"
    let location = TranscriberResolver.resolve(
        environment: [:],
        bundleResourceURL: nil,
        executableURL: URL(fileURLWithPath: "/repo/sotto/.build/debug/Sotto"),
        isExecutable: { $0 == expected }
    )
    #expect(location.url?.path == expected)
    #expect(location.source == "dev")
}

@Test func 找不到转写器时返回missing() {
    let location = TranscriberResolver.resolve(
        environment: [:],
        bundleResourceURL: nil,
        executableURL: URL(fileURLWithPath: "/nowhere/Sotto"),
        isExecutable: { _ in false }
    )
    #expect(location.url == nil)
    #expect(location.source == "missing")
}

@Test func 转写子进程的PATH会补上Homebrew目录() {
    // 从 Finder 起的 app 只有 launchd 的 PATH；whisper 装在 Homebrew 里。
    let environment = TranscribeService.childEnvironment(from: ["PATH": "/usr/bin:/bin"])
    let entries = environment["PATH"]!.split(separator: ":").map(String.init)
    #expect(entries.contains("/opt/homebrew/bin"))
    #expect(entries.contains("/usr/local/bin"))
    #expect(entries.first == "/usr/bin")
}

@Test func PATH里已有的目录不会重复添加() {
    let environment = TranscribeService.childEnvironment(
        from: ["PATH": "/opt/homebrew/bin:/usr/bin"]
    )
    let entries = environment["PATH"]!.split(separator: ":").map(String.init)
    #expect(entries.filter { $0 == "/opt/homebrew/bin" }.count == 1)
}

// MARK: - 失败文案

@Test func 失败文案按退出码区分且可操作() {
    #expect(TranscribeFailure(status: 2, stderr: "", detail: nil)
        .userMessage.contains("模型"))
    #expect(TranscribeFailure(status: 3, stderr: "", detail: nil)
        .userMessage.contains("whisper-cpp"))
    #expect(TranscribeFailure(status: -1, stderr: "", detail: nil)
        .userMessage.contains("SOTTO_TRANSCRIBE"))
    let empty = TranscribeFailure(status: 1, stderr: "sotto-transcribe: 转写结果为空\n",
                                  detail: nil)
    #expect(empty.userMessage == "转写失败：转写结果为空")
}

// MARK: - 目录与文案

@Test func 日志与录音目录可被环境变量覆盖() {
    let environment = ["SOTTO_LOG_DIR": "/tmp/sotto-log-test",
                       "SOTTO_RECORD_DIR": "/tmp/sotto-rec-test"]
    #expect(SottoPaths.logDirectory(environment: environment).path == "/tmp/sotto-log-test")
    #expect(SottoPaths.recordingsDirectory(environment: environment).path == "/tmp/sotto-rec-test")
}

@Test func 默认日志目录在Caches下() {
    let path = SottoPaths.logDirectory(environment: [:], home: "/Users/someone").path
    #expect(path == "/Users/someone/Library/Caches/sotto")
}

@Test func 气泡文案是卡里写死的那一句() {
    #expect(MenuCopy.copiedHint == "已复制，⌘V 粘贴")
    #expect(MenuCopy.holdToTalk("⌃⌥H") == "按住 ⌃⌥H 说话")
}
