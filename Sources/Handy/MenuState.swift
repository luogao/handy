import Foundation

/// 菜单栏在 P0 只有两态：没在录 / 正在录。
///
/// P0 不录音，这个状态唯一的用途是证明「点一下 → 文案变 → 再点变回来」这条
/// 交互链路是通的；P1 把 AVAudioEngine 的启停挂到同一组 API 上，菜单和测试
/// 都不用改。放在没有 AppKit 的文件里，是为了能脱离 UI 单测。
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

/// 菜单文案只有这一份来源：真实菜单和 `--dump-menu` 自检读同一处，
/// 免得验收时看到的字和测试里断言的字不是同一个。
enum MenuCopy {
    static let settings = "设置…"
    static let quit = "退出"
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
