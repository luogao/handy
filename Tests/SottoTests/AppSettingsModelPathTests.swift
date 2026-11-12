import Foundation
import Testing
@testable import Sotto

// MARK: - modelPath 键的读写

private func makeDefaults() -> (UserDefaults, String) {
    let name = "SottoTests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

@Test func 未设置模型路径时返回nil() {
    let (defaults, name) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.modelPath == nil)
}

@Test func 设置后持久化并读回绝对路径() {
    let (defaults, name) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    AppSettings(defaults: defaults).setModelPath("/tmp/models/m.bin")

    let reloaded = AppSettings(defaults: defaults)
    #expect(reloaded.modelPath == "/tmp/models/m.bin")
    #expect(defaults.string(forKey: AppSettings.Key.modelPath) == "/tmp/models/m.bin")
}

@Test func 空串与全空白按未设置处理() {
    let (defaults, name) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)

    settings.setModelPath("/tmp/models/m.bin")
    settings.setModelPath("   ")
    #expect(settings.modelPath == nil)
    // 不能留一个空字符串键，否则 defaults read 看起来像「设置过」。
    #expect(defaults.object(forKey: AppSettings.Key.modelPath) == nil)

    settings.setModelPath("/tmp/models/m.bin")
    settings.setModelPath("")
    #expect(settings.modelPath == nil)
    #expect(defaults.object(forKey: AppSettings.Key.modelPath) == nil)
}

@Test func 相对路径归一成绝对路径() throws {
    let (defaults, name) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)

    settings.setModelPath("relative/model.bin")
    let stored = try #require(settings.modelPath)
    #expect(stored.hasPrefix("/"))
    #expect(stored.hasSuffix("/relative/model.bin"))
}

@Test func 波浪号会展开成绝对路径() {
    let (defaults, name) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)

    settings.setModelPath("~/models/m.bin")
    #expect(settings.modelPath == NSHomeDirectory() + "/models/m.bin")
}

@Test func 中文与空格路径原样保留不编码() {
    let (defaults, name) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    let path = "/tmp/测试 目录/模型 文件.bin"

    settings.setModelPath(path)
    #expect(settings.modelPath == path)
    #expect(!(settings.modelPath ?? "").contains("%20"))
    #expect(!(settings.modelPath ?? "").contains("%E6"))
}

@Test func 恢复默认会删掉键() {
    let (defaults, name) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)

    settings.setModelPath("/tmp/models/m.bin")
    settings.setModelPath(nil)
    #expect(settings.modelPath == nil)
    #expect(defaults.object(forKey: AppSettings.Key.modelPath) == nil)
}

// MARK: - 默认路径与展示

@Test func 默认模型路径和CLI保持一致() {
    let path = SottoPaths.defaultModelPath(environment: [:], home: "/Users/someone").path
    #expect(path == "/Users/someone/.cache/whisper.cpp/ggml-medium-q5_0.bin")
}

@Test func 默认模型路径可被SOTTO_MODEL覆盖() {
    let path = SottoPaths.defaultModelPath(
        environment: ["SOTTO_MODEL": "/tmp/测试 模型.bin"], home: "/Users/someone"
    ).path
    #expect(path == "/tmp/测试 模型.bin")
}

@Test func 生效路径文案区分默认与自定义() {
    #expect(SottoPaths.modelPathDescription(customPath: nil, environment: [:],
                                            home: "/Users/someone")
            == "默认：~/.cache/whisper.cpp/ggml-medium-q5_0.bin")
    #expect(SottoPaths.modelPathDescription(customPath: "/tmp/测试 目录/m.bin",
                                            environment: [:], home: "/Users/someone")
            == "自定义：/tmp/测试 目录/m.bin")
}

// MARK: - 模型解析（未设置不传 --model）

@Test func 未设置时用默认路径且不传model参数() {
    let plan = TranscribeService.modelPlan(customPath: nil, environment: [:],
                                           home: "/Users/someone", bundledModel: nil)
    #expect(plan.path == "/Users/someone/.cache/whisper.cpp/ggml-medium-q5_0.bin")
    #expect(!plan.passesModelArgument)
    #expect(plan.logLabel == "default")
}

/// 发行包里带着模型时，未设置也必须显式传 `--model`：CLI 的默认值是
/// `~/.cache/…`，干净机器上不存在，不传就 exit 2（v0.1.0 的实际事故）。
@Test func 内置模型存在时显式传model参数() {
    let bundled = URL(fileURLWithPath: "/Applications/Sotto.app/Contents/Resources/models/ggml-medium-q5_0.bin")
    let plan = TranscribeService.modelPlan(customPath: nil, environment: [:],
                                           home: "/Users/someone", bundledModel: bundled)
    #expect(plan.path == bundled.path)
    #expect(plan.passesModelArgument)
    #expect(plan.logLabel == "bundle")
    #expect(TranscribeService.arguments(wavPath: "/tmp/a.wav", plan: plan)
            == ["/tmp/a.wav", "--model", bundled.path])
}

@Test func 自定义路径优先于内置模型() {
    let bundled = URL(fileURLWithPath: "/Applications/Sotto.app/Contents/Resources/models/ggml-medium-q5_0.bin")
    let plan = TranscribeService.modelPlan(customPath: "~/models/mine.bin", environment: [:],
                                           home: "/Users/someone", bundledModel: bundled)
    // `~` 由 normalizeModelPath 用真实 home 展开，不吃 home 参数
    #expect(plan.path == NSHomeDirectory() + "/models/mine.bin")
    #expect(plan.passesModelArgument)
}

@Test func 设置后解析成自定义路径() {
    let plan = TranscribeService.modelPlan(customPath: "~/models/m.bin", environment: [:],
                                           home: NSHomeDirectory())
    #expect(plan.path == NSHomeDirectory() + "/models/m.bin")
    #expect(plan.passesModelArgument)
    #expect(plan.logLabel == NSHomeDirectory() + "/models/m.bin")
}
