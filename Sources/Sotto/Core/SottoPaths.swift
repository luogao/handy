import Foundation

/// 运行期用到的目录。全部走环境变量可覆盖，和 sotto-mic / sotto-transcribe 的
/// 既有约定一致（测试并行跑时用 SOTTO_LOG_DIR / SOTTO_RECORD_DIR 隔离）。
enum SottoPaths {
    static func logDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL {
        if let value = environment["SOTTO_LOG_DIR"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/sotto")
    }

    static func recordingsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL {
        if let value = environment["SOTTO_RECORD_DIR"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        return logDirectory(environment: environment, home: home)
            .appendingPathComponent("recordings")
    }

    /// 默认 whisper 模型在哪，全 app 只在这里回答一次。
    ///
    /// 和 sotto-transcribe 的默认值保持同一个文件；app 不复制一份常量，否则
    /// 两边升级时容易一边改了另一边没改。`SOTTO_MODEL` 是测试用的覆盖点：
    /// 预检 / 展示可以指向临时文件，不用碰 500MB 的真模型。
    static func defaultModelPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL {
        if let value = environment["SOTTO_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
                .standardizedFileURL
        }
        // 发行包里模型跟着 app 走：安装目录下没有开发树、用户也没跑过下载脚本，
        // 只认 ~/.cache 会让「下载即用」落空。内置模型优先，其次才是用户缓存。
        if let bundled = bundledModelPath() {
            return bundled
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".cache/whisper.cpp/ggml-medium-q5_0.bin")
    }

    /// 打包进 `Contents/Resources/models/` 的模型；开发态（swift run）没有这个目录，
    /// 返回 nil 就退回用户缓存路径。
    static func bundledModelPath(bundle: Bundle = .main) -> URL? {
        guard let url = bundle.url(forResource: "ggml-medium-q5_0",
                                   withExtension: "bin",
                                   subdirectory: "models"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 设置里存的是绝对路径：`~` 展开、去掉 `./` `../`，但**不做 URL 编码**，
    /// 中文和空格原样保留（编码后的 `%20` 直接拿去 open 会找不到文件）。
    /// 空串 / 全空白返回 nil，表示「未设置」，调用方据此决定不传 `--model`。
    static func normalizeModelPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// 展示用：把 home 前缀缩成 `~`，和卡里的 `默认：~/.cache/...` 一致。
    static func abbreviateHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + String(path.dropFirst(prefix.count))
    }

    /// 设置面板「生效路径」那一行的文案：未设置显示默认 + 来源，已设置显示
    /// 自定义路径 + 来源。做成纯函数是为了能在单测里逐字钉住，不依赖 UI。
    static func modelPathDescription(
        customPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        if let custom = normalizeModelPath(customPath) {
            return "自定义：\(custom)"
        }
        let fallback = defaultModelPath(environment: environment, home: home).path
        return "默认：\(abbreviateHome(fallback, home: home))"
    }
}
