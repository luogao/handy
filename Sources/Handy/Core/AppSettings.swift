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
}
