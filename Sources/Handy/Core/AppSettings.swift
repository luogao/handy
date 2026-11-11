import Foundation

/// 用户设置，只落在 UserDefaults（走 bundle id），不新建配置文件格式。
/// 设置项少，直接给强类型读写，不做通用 KV 包装。
struct AppSettings {
    enum Key {
        static let hotKeyCode = "hotkey.keyCode"
        static let hotKeyControl = "hotkey.control"
        static let hotKeyOption = "hotkey.option"
        static let hotKeyShift = "hotkey.shift"
        static let hotKeyCommand = "hotkey.command"
        static let loggingEnabled = "log.enabled"
        static let modelPath = "modelPath"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 没存过就返回默认 ⌃⌥H。个别字段缺失时按默认值补齐，避免升级过程中
    /// 出现「有键码没修饰键」的半残组合。
    var hotKey: HotKeyCombo {
        let fallback = HotKeyCombo.default
        guard defaults.object(forKey: Key.hotKeyCode) != nil else { return fallback }
        return HotKeyCombo(
            keyCode: UInt32(defaults.integer(forKey: Key.hotKeyCode)),
            control: defaults.bool(forKey: Key.hotKeyControl),
            option: defaults.bool(forKey: Key.hotKeyOption),
            shift: defaults.bool(forKey: Key.hotKeyShift),
            command: defaults.bool(forKey: Key.hotKeyCommand)
        )
    }

    func setHotKey(_ combo: HotKeyCombo) {
        defaults.set(Int(combo.keyCode), forKey: Key.hotKeyCode)
        defaults.set(combo.control, forKey: Key.hotKeyControl)
        defaults.set(combo.option, forKey: Key.hotKeyOption)
        defaults.set(combo.shift, forKey: Key.hotKeyShift)
        defaults.set(combo.command, forKey: Key.hotKeyCommand)
    }

    /// 默认开。事件日志是排障用的，用户明确关掉才不写。
    var loggingEnabled: Bool {
        guard defaults.object(forKey: Key.loggingEnabled) != nil else { return true }
        return defaults.bool(forKey: Key.loggingEnabled)
    }

    func setLoggingEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.loggingEnabled)
    }

    /// 自定义模型路径；未设置返回 nil。
    ///
    /// **绝不在这里补默认路径**：补了之后调用方永远会传 `--model`，CLI 自己的
    /// 默认值就成了摆设，两边各有一份「默认模型」也就再也对不上。未设置就是
    /// 未设置，传不传 `--model` 由调用方按 nil 判断。
    var modelPath: String? {
        HandyPaths.normalizeModelPath(defaults.string(forKey: Key.modelPath))
    }

    /// 传 nil / 空串 / 全空白都表示「恢复默认」：直接删键，不留一个空字符串，
    /// 这样 `defaults read` 看到的就是真正的未设置状态。
    func setModelPath(_ path: String?) {
        guard let normalized = HandyPaths.normalizeModelPath(path) else {
            defaults.removeObject(forKey: Key.modelPath)
            return
        }
        defaults.set(normalized, forKey: Key.modelPath)
    }
}
