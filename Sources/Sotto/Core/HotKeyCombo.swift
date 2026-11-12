import Foundation

/// 一个全局热键组合：macOS 虚拟键码 + 四个修饰键。
///
/// 这一层刻意不 import AppKit / Carbon：设置持久化、菜单文案、`--set-hotkey`
/// 的参数解析和单测都只依赖它，真正跟系统打交道的 RegisterEventHotKey 在
/// HotKeyManager 里。热键的「值」和「注册动作」分开，改热键时才能先存后注册、
/// 注册失败再回滚。
struct HotKeyCombo: Equatable, Sendable {
    var keyCode: UInt32
    var control: Bool
    var option: Bool
    var shift: Bool
    var command: Bool

    /// 默认 ⌃⌥H。和 sotto-mic.swift 的 hotkeyCombo 一致：P1 是「把已验证的
    /// 链路搬进 app」，默认值不自己另挑一个。
    static let `default` = HotKeyCombo(keyCode: KeyCode.h,
                                       control: true, option: true,
                                       shift: false, command: false)

    /// Carbon 的修饰键位（controlKey/optionKey/shiftKey/cmdKey）。
    /// 写死数值是为了让 Core 不 import Carbon——Carbon 会顺着 IOKit 把测试进程
    /// 拖进一堆系统框架，纯逻辑测试没必要付这个代价。
    var carbonModifiers: UInt32 {
        (control ? 0x1000 : 0)
            | (option ? 0x0800 : 0)
            | (shift ? 0x0200 : 0)
            | (command ? 0x0100 : 0)
    }

    /// 至少要有一个修饰键。裸字母当全局热键会把正常打字吃掉，这种组合不接受。
    var isValid: Bool { control || option || shift || command }

    /// 给人看的写法，按 Apple 的固定顺序 ⌃⌥⇧⌘。菜单、设置面板、日志共用这一份，
    /// 免得三处显示不一样。
    var displayString: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        return text + KeyCode.name(for: keyCode)
    }

    /// 解析 `ctrl+opt+H`、`⌃⌥H`、`cmd+shift+j` 这类写法。
    /// `--set-hotkey` 调试入口和设置面板的测试用例都走它，只有一份解析规则。
    static func parse(_ raw: String) -> HotKeyCombo? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        // 允许直接抄界面上的符号写法。
        text = text.replacingOccurrences(of: "⌃", with: "ctrl+")
            .replacingOccurrences(of: "⌥", with: "opt+")
            .replacingOccurrences(of: "⇧", with: "shift+")
            .replacingOccurrences(of: "⌘", with: "cmd+")

        var control = false, option = false, shift = false, command = false
        var keyName: String?
        for part in text.split(separator: "+", omittingEmptySubsequences: true) {
            switch part.lowercased() {
            case "ctrl", "control": control = true
            case "opt", "option", "alt": option = true
            case "shift": shift = true
            case "cmd", "command", "super": command = true
            default:
                guard keyName == nil else { return nil }   // 两个普通键，不合法
                keyName = String(part)
            }
        }
        guard let keyName, let keyCode = KeyCode.code(for: keyName) else { return nil }
        let combo = HotKeyCombo(keyCode: keyCode, control: control, option: option,
                                shift: shift, command: command)
        return combo.isValid ? combo : nil
    }
}

/// macOS 虚拟键码 → 文案。只列 ANSI 键盘上会拿来当热键的键；表里没有的
/// （功能键以外的厂商键）退成 `Key<码>`，不影响注册，只是名字不好看。
enum KeyCode {
    static let h: UInt32 = 4
    static let j: UInt32 = 38

    static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space",
        50: "`", 51: "Delete", 36: "Return", 53: "Esc",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 107: "F14", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func name(for code: UInt32) -> String {
        names[code] ?? "Key\(code)"
    }

    static func code(for name: String) -> UInt32? {
        let lowered = name.lowercased()
        for (code, value) in names where value.lowercased() == lowered {
            return code
        }
        // `key12` / 直接给数字：留给表外键和调试入口用。
        if lowered.hasPrefix("key"), let value = UInt32(lowered.dropFirst(3)) { return value }
        return nil
    }
}
