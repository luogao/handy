import Foundation

/// 菜单栏只有两态：没在录 / 正在录。转写发生在后台队列，不占这个状态——
/// 用户在等转写时再按一次热键应该能立刻开始下一段录音。
///
/// 放在没有 AppKit 的文件里，是为了能脱离 UI 单测。
enum RecordingState: String, Equatable, Sendable {
    case idle
    case listening

    var actionTitle: String {
        switch self {
        case .idle:
            return "开始"
        case .listening:
            return "停止"
        }
    }

    var toggled: RecordingState {
        self == .idle ? .listening : .idle
    }
}

/// 菜单/气泡文案只有这一份来源：真实菜单、`--dump-menu` 自检和测试读同一处，
/// 免得验收时看到的字和测试里断言的字不是同一个。
enum MenuCopy {
    static let settings = "设置…"
    static let quit = "退出"
    /// 气泡文案是卡里写死的，别在调用处另写一份。
    static let copiedHint = "已复制，⌘V 粘贴"

    static func holdToTalk(_ hotkey: String) -> String {
        "按住 \(hotkey) 说话"
    }
}

/// 版本号以 Info.plist 为准（打包后读 bundle），直接跑 `.build/debug/Handy`
/// 时没有 bundle，退回开发版标记，避免日志里出现一个假的正式版本号。
enum AppInfo {
    static let name = "Handy"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0-dev"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }
}
