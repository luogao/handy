import AppKit

/// 写系统剪贴板。只用 NSPasteboard（NSPasteboardTypeString），
/// 不请求任何权限、不模拟 ⌘V（自动粘贴要辅助功能，v0.1 明确不做）。
enum Clipboard {
    @discardableResult
    static func write(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        // 写后立刻读回：剪贴板被别的进程抢写时不至于报「已复制」却是空的。
        return pasteboard.string(forType: .string) == text
    }
}
