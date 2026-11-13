import SwiftUI
import AppKit

/// 设置面板的主题与项目常量。配色和「海牛」的设置台同一套：
/// 近黑底 + 暖琥珀点缀，一行一条参数，不堆控件。
enum SottoTheme {
    static let bg     = Color(red: 12/255,  green: 12/255,  blue: 13/255)   // #0C0C0D
    static let ink    = Color(red: 242/255, green: 242/255, blue: 239/255)  // #F2F2EF
    static let ink2   = Color(red: 150/255, green: 150/255, blue: 143/255)  // #96968F
    static let ink3   = Color(red: 216/255, green: 216/255, blue: 210/255)  // #D8D8D2
    static let accent = Color(red: 232/255, green: 162/255, blue: 48/255)   // #E8A230
    static let danger = Color(red: 217/255, green: 79/255,  blue: 61/255)   // #D94F3D
    static let track  = Color(red: 38/255,  green: 38/255,  blue: 42/255)   // #26262A
    static let line   = Color.white.opacity(0.08)
}

enum SottoInfo {
    static let name = "Sotto"
    static let slug = "sotto"
    static let owner = "luogao"
    static let repo = URL(string: "https://github.com/luogao/\(slug)")!
    static let releases = URL(string: "https://github.com/luogao/\(slug)/releases")!
    static let homepage = URL(string: "https://sotto.rungundam.top")!

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
    /// 底部和「版本」区显示的一行：`v0.1.3 (013)`
    static var versionLine: String { "v\(version) (\(build))" }
}

/// 面板状态。SwiftUI 只管画和收集动作，真正的注册/落盘仍在
/// `SettingsWindowController` 里——热键要真去 Carbon 试注册，模型要走 NSOpenPanel。
final class SettingsModel: ObservableObject {
    @Published var hotKeyText: String = ""
    @Published var hint: String = "保存后立即生效，不用重启。按 Esc 可取消重录。"
    @Published var isCapturing = false
    @Published var loggingEnabled = true
    @Published var modelPathText: String = ""
    @Published var modelSource: String = ""
    @Published var modelSize: String = ""
    @Published var canResetModel = false

    var onToggleCapture: () -> Void = {}
    var onLoggingChange: (Bool) -> Void = { _ in }
    var onPickModel: () -> Void = {}
    var onResetModel: () -> Void = {}

    let logPathText = "~/Library/Caches/sotto/sotto.log"
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var selected = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                rail
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        generalSection.id(1)
                        modelSection.id(2)
                        versionSection.id(3)
                    }
                    .padding(EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            footer
        }
        .frame(width: 620, height: 634)
        .background(SottoTheme.bg)
        .preferredColorScheme(.dark)
    }

    // MARK: - 左栏

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(SottoInfo.name.uppercased())
                .font(.system(size: 10, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(SottoTheme.ink2.opacity(0.75))
            Text("设置")
                .font(.system(size: 13))
                .foregroundStyle(SottoTheme.ink2)
                .padding(.top, 4)

            VStack(spacing: 2) {
                RailItem(n: "01", label: "通用", selected: selected == 1) { selected = 1 }
                RailItem(n: "02", label: "模型", selected: selected == 2) { selected = 2 }
                RailItem(n: "03", label: "版本", selected: selected == 3) { selected = 3 }
            }
            .padding(.top, 20)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 12) {
                RailLink(title: "打开日志") {
                    let url = SottoPaths.logDirectory().appendingPathComponent("sotto.log")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                RailLink(title: "项目主页") {
                    NSWorkspace.shared.open(SottoInfo.repo)
                }
            }
        }
        .padding(EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16))
        .frame(width: 148, height: 600, alignment: .topLeading)
        .background(SottoTheme.bg)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1)
        }
    }

    // MARK: - 01 通用

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(n: "01", title: "通用")

            LabeledRow(title: "全局热键",
                       note: model.isCapturing ? "按下新的组合…" : "任何 app 里按住即说") {
                HStack(spacing: 12) {
                    Text(model.isCapturing ? "按下新的组合键…" : model.hotKeyText)
                        .font(.system(size: model.isCapturing ? 14 : 20,
                                      weight: .semibold,
                                      design: .monospaced))
                        .foregroundStyle(model.isCapturing ? SottoTheme.accent : SottoTheme.ink)
                    Button(model.isCapturing ? "取消" : "重新录制") {
                        model.onToggleCapture()
                    }
                    .buttonStyle(SottoButtonStyle())
                }
            }
            HStack(spacing: 6) {
                Text(model.hint)
                    .font(.system(size: 11))
                    .foregroundStyle(SottoTheme.ink2)
            }
            .padding(.leading, 2)
            .padding(.top, 8)

            Divider().overlay(SottoTheme.line).padding(.vertical, 18)

            LabeledRow(title: "事件日志", note: "只记时间、耗时、字数，不记识别文本") {
                Toggle("", isOn: Binding(
                    get: { model.loggingEnabled },
                    set: { model.loggingEnabled = $0; model.onLoggingChange($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(SottoTheme.accent)
            }
            Text(model.logPathText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SottoTheme.ink2)
                .padding(.top, 8)
        }
    }

    // MARK: - 02 模型

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(n: "02", title: "模型")

            LabeledRow(title: "生效路径",
                       note: model.modelSource) {
                Text(model.modelPathText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SottoTheme.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.modelPathText)
                    .frame(maxWidth: 300, alignment: .trailing)
            }

            LabeledRow(title: "文件大小", note: nil) {
                Text(model.modelSize)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(SottoTheme.ink3)
            }

            HStack(spacing: 8) {
                Button("选择…") { model.onPickModel() }
                    .buttonStyle(SottoButtonStyle())
                Button("恢复默认") { model.onResetModel() }
                    .buttonStyle(SottoButtonStyle())
                    .disabled(!model.canResetModel)
                    .opacity(model.canResetModel ? 1 : 0.4)
                Spacer(minLength: 0)
            }
            .padding(.top, 14)

            Text("发行包自带 medium-q5_0，换模型只需要选一次，不用重启。")
                .font(.system(size: 11))
                .foregroundStyle(SottoTheme.ink2)
                .padding(.top, 10)
        }
    }

    // MARK: - 03 版本

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(n: "03", title: "版本")

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(SottoInfo.versionLine)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SottoTheme.ink)
                Text(buildTag)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(SottoTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(SottoTheme.accent.opacity(0.55), lineWidth: 1)
                    )
            }
            .padding(.bottom, 4)

            Text("菜单栏语音输入 · 本地 whisper 转写 · MIT")
                .font(.system(size: 12))
                .foregroundStyle(SottoTheme.ink2)

            HStack(spacing: 8) {
                Button("查看更新") { NSWorkspace.shared.open(SottoInfo.releases) }
                    .buttonStyle(SottoButtonStyle(primary: true))
                Button("复制诊断信息") { copyDiagnostics() }
                    .buttonStyle(SottoButtonStyle())
            }
            .padding(.top, 16)

            Text("升级：brew upgrade --cask \(SottoInfo.owner)/tap/\(SottoInfo.slug)，或重新下载 DMG。")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SottoTheme.ink2)
                .padding(.top, 12)
        }
    }

    private var buildTag: String {
        SottoInfo.version == "dev" ? "DEV" : "内置引擎"
    }

    private func copyDiagnostics() {
        let text = """
        Sotto \(SottoInfo.versionLine)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        热键：\(model.hotKeyText)
        模型：\(model.modelPathText)（\(model.modelSource)，\(model.modelSize)）
        日志：\(model.logPathText)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - 页脚

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Sotto · MIT")
                .font(.system(size: 10))
                .foregroundStyle(SottoTheme.ink2.opacity(0.6))
            Spacer(minLength: 0)
            Link("v\(SottoInfo.version)", destination: SottoInfo.releases)
                .font(.system(size: 10))
                .foregroundStyle(SottoTheme.ink2)
            Text("·").font(.system(size: 10)).foregroundStyle(SottoTheme.ink2.opacity(0.4))
            Link("github.com/\(SottoInfo.owner)/\(SottoInfo.slug)", destination: SottoInfo.repo)
                .font(.system(size: 10))
                .foregroundStyle(SottoTheme.ink2)
        }
        .padding(.horizontal, 18)
        .frame(height: 34)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
        }
    }
}

// MARK: - 小组件

private struct SectionHeader: View {
    let n: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(n)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(SottoTheme.accent.opacity(0.85))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SottoTheme.ink)
            Rectangle().fill(SottoTheme.line).frame(height: 1)
        }
        .padding(.bottom, 14)
    }
}

private struct LabeledRow<Content: View>: View {
    let title: String
    let note: String?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(SottoTheme.ink3)
                if let note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(SottoTheme.ink2)
                }
            }
            Spacer(minLength: 12)
            content
        }
        .frame(minHeight: 34)
    }
}

private struct RailItem: View {
    let n: String
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(n)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(selected ? SottoTheme.accent : SottoTheme.ink2.opacity(0.7))
                Text(label)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? SottoTheme.ink : SottoTheme.ink2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(selected ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct RailLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(SottoTheme.ink2)
                .underline(false)
        }
        .buttonStyle(.plain)
    }
}

private struct SottoButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: primary ? .semibold : .regular))
            .foregroundStyle(primary ? Color(red: 21/255, green: 14/255, blue: 4/255) : SottoTheme.ink3)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(primary ? SottoTheme.accent : SottoTheme.track)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
