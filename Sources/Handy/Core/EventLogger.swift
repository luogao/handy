import Foundation

/// 事件日志：一行一个事件，前缀是毫秒级 UTC 时间戳。
///
/// 只收「事件名 + 元数据字段」，接口里没有任何放文本的位置——隐私线（不写识别
/// 文本 / 剪贴板内容 / 音频内容）靠类型挡住，而不是靠调用方自觉。
/// 写日志的任何失败都只丢这一行：日志子系统不许把转写拖下水。
final class EventLogger {
    let fileURL: URL
    /// 每次写之前现读，设置面板一关就立刻生效，不用重启。
    private let isEnabled: () -> Bool
    private let lock = NSLock()

    init(directory: URL? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         isEnabled: @escaping () -> Bool) {
        let dir = directory ?? HandyPaths.logDirectory(environment: environment)
        self.fileURL = dir.appendingPathComponent("handy.log")
        self.isEnabled = isEnabled
    }

    func write(event: String, fields: [(String, String)] = []) {
        guard isEnabled() else { return }
        let line = Self.line(event: event, fields: fields, at: Date()) + "\n"
        lock.lock()
        defer { lock.unlock() }
        Self.append(line, to: fileURL)
    }

    // MARK: - 纯函数（单测直接用）

    /// `<ISO8601 毫秒> event=<名字> k=v ...`。
    /// 值里不允许出现空白/换行：一个字段拆成两半会让日志没法按空格解析。
    static func line(event: String, fields: [(String, String)], at date: Date) -> String {
        var parts = ["event=" + sanitize(event)]
        for (key, value) in fields {
            parts.append(sanitize(key) + "=" + sanitize(value))
        }
        return timestamp(date) + " " + parts.joined(separator: " ")
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }

    private static func sanitize(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return cleaned.isEmpty ? "-" : cleaned
    }

    private static func append(_ line: String, to url: URL) {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        // 目录不存在就建；建不出来也只丢日志。0700：日志里有使用习惯（什么时候说话）。
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBytes { buffer in
            // 显式写 Darwin：类里的 `write(event:fields:)` 会遮住同名的 C 函数。
            Darwin.write(fd, buffer.baseAddress, buffer.count)
        }
    }
}
