import Foundation

/// handy-transcribe 的位置。app 只是调用方：P1 从仓库 handy/ 目录调，
/// P2 把二进制塞进 Contents/Resources/bin/ 后只换来源，调用方一行不用改。
struct TranscriberLocation {
    let url: URL?
    let source: String

    var isAvailable: Bool { url != nil }
}

enum TranscriberResolver {
    /// 优先级：HANDY_TRANSCRIBE 环境变量 > bundle 内 Resources/bin > 从可执行文件
    /// 向上找 handy-transcribe（开发态 .build/debug/Handy 与 build/Handy.app 都靠这条）。
    ///
    /// 环境变量指了但文件不可执行时**不回退**：静默换一个二进制跑，会让人以为
    /// 覆盖点生效了，实际调的还是旧的。
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> TranscriberLocation {
        if let override = environment["HANDY_TRANSCRIBE"], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return TranscriberLocation(url: isExecutable(url.path) ? url : nil,
                                       source: "HANDY_TRANSCRIBE")
        }

        if let resources = bundleResourceURL {
            let bundled = resources.appendingPathComponent("bin/handy-transcribe")
            if isExecutable(bundled.path) {
                return TranscriberLocation(url: bundled, source: "bundle")
            }
        }

        var directory = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("handy-transcribe")
            if isExecutable(candidate.path) {
                return TranscriberLocation(url: candidate, source: "dev")
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return TranscriberLocation(url: nil, source: "missing")
    }
}

/// 转写失败。status 与 handy-transcribe 的退出码一致（0 成功、1 用法/音频、
/// 2 模型、3 whisper 缺件）；-1 表示调用方根本没找到可执行文件。
struct TranscribeFailure: Error, CustomStringConvertible {
    let status: Int32
    let stderr: String
    let detail: String?

    var description: String { "transcribe failed status=\(status) \(detail ?? stderr)" }

    /// 给气泡看的一句话：必须能指导下一步，不能只是「失败了」。
    var userMessage: String {
        switch status {
        case 2:
            return "找不到 whisper 模型。把 ggml-*.bin 放到 ~/.cache/whisper.cpp/ 后再试。"
        case 3:
            return "找不到 whisper-cli / whisper-server。先 brew install whisper-cpp，确认在 PATH 里。"
        case -1:
            return "找不到 handy-transcribe。开发态请在 handy/ 目录下运行，或用 HANDY_TRANSCRIBE 指定。"
        default:
            if let last = Self.lastMeaningfulLine(stderr) {
                return "转写失败：\(last)"
            }
            return "转写失败（退出码 \(status)），详见 ~/Library/Caches/handy/whisper-server.log"
        }
    }

    static func lastMeaningfulLine(_ stderr: String) -> String? {
        stderr.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .last?
            .replacingOccurrences(of: "handy-transcribe: ", with: "")
    }
}

struct TranscribeResult {
    let text: String
    /// app 看到的总耗时（从 spawn 到进程退出，含进程启动和读音频）。
    let wallMS: Int
    /// handy-transcribe 自己写进 request 事件的 decode_ms。拿不到就是 nil
    /// （走了 CLI 路径 / 日志被轮转掉了）。
    let decodeMS: Int?
    let audioMS: Int?
    let requestPath: String?
}

/// 调 handy-transcribe 的唯一入口。app 内不做任何解码 / 分段 / 归一——
/// 那些参数是四张卡验证过的，重写一份就等于把回归基线丢了。
///
/// 不传 `--clip`：剪贴板由 app 自己用 NSPasteboard 写（handy-clip 是 `swift`
/// 解释执行的脚本，起一次要近 1 秒，会把 1.5 秒的时延预算吃掉）。
final class TranscribeService {
    let location: TranscriberLocation
    let environment: [String: String]
    let logDirectory: URL

    init(location: TranscriberLocation = TranscriberResolver.resolve(),
         environment: [String: String] = ProcessInfo.processInfo.environment,
         logDirectory: URL? = nil) {
        self.location = location
        self.environment = environment
        self.logDirectory = logDirectory ?? HandyPaths.logDirectory(environment: environment)
    }

    func transcribe(wavURL: URL) throws -> TranscribeResult {
        guard let executable = location.url else {
            throw TranscribeFailure(status: -1, stderr: "", detail: location.source)
        }
        let logOffset = Self.fileSize(logDirectory.appendingPathComponent("whisper-server.log"))

        let process = Process()
        process.executableURL = executable
        process.arguments = [wavURL.path]
        process.environment = Self.childEnvironment(from: environment)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let started = Date()
        do {
            try process.run()
        } catch {
            throw TranscribeFailure(status: -1, stderr: error.localizedDescription,
                                    detail: "spawn")
        }

        // 两个管道都必须边跑边读：handy-transcribe 往 stderr 打不少行，写满管道
        // 会把子进程卡死，waitUntilExit 就永远不返回。
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()
        let wallMS = Int(Date().timeIntervalSince(started) * 1000)

        let stderrText = String(decoding: errData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw TranscribeFailure(status: process.terminationStatus, stderr: stderrText,
                                    detail: nil)
        }

        let text = String(decoding: outData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscribeFailure(status: 1, stderr: stderrText, detail: "empty output")
        }

        let stats = requestStats(since: logOffset, startedAt: started)
        return TranscribeResult(text: text, wallMS: wallMS,
                                decodeMS: stats?.decodeMS,
                                audioMS: stats?.audioMS,
                                requestPath: stats?.requestPath)
    }

    // MARK: - 从 server 日志里读回这一次的 decode_ms

    /// handy-transcribe 每次调用写一条 `event=request ... decode_ms=...`。
    /// 从「调用前的文件长度」往后读，最后一条 request 就是这一次的。
    /// 日志被轮转/被删都不影响转写本身，只是 decode_ms 变 nil。
    private func requestStats(since offset: UInt64, startedAt: Date)
        -> (decodeMS: Int, audioMS: Int, requestPath: String)? {
        let url = logDirectory.appendingPathComponent("whisper-server.log")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size >= offset ? offset : 0
        do { try handle.seek(toOffset: start) } catch { return nil }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        var found: (Int, Int, String)?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n")
        where line.contains(" handy event=request ") {
            // 日志可能在两次调用之间被轮转/重建，防止把上一次（甚至更早）的
            // request 当成本次结果：时间戳必须落在本次调用开始之后。
            if let stamp = line.split(separator: " ").first,
               let date = Self.logDate(String(stamp)),
               date < startedAt.addingTimeInterval(-2) {
                continue
            }
            var decode: Int?
            var audio: Int?
            var path = "-"
            for token in line.split(separator: " ") {
                let pair = token.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "decode_ms": decode = Int(pair[1])
                case "audio_ms": audio = Int(pair[1])
                case "path": path = String(pair[1])
                default: break
                }
            }
            if let decode { found = (decode, audio ?? 0, path) }
        }
        return found
    }

    /// 从 Finder 双击起的 app 拿到的 PATH 是 launchd 的那份，通常不含 Homebrew
    /// 的 bin；handy-transcribe 只在 PATH 里找 whisper-cli / whisper-server，
    /// 不补这两个目录的话 GUI 里会一直报「找不到 whisper」（终端里却好好的）。
    static func childEnvironment(from environment: [String: String]) -> [String: String] {
        var env = environment
        let fallback = "/usr/bin:/bin:/usr/sbin:/sbin"
        var entries = (env["PATH"] ?? fallback).split(separator: ":").map(String.init)
        for directory in ["/opt/homebrew/bin", "/usr/local/bin"] where !entries.contains(directory) {
            entries.append(directory)
        }
        env["PATH"] = entries.joined(separator: ":")
        return env
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static let logDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func logDate(_ text: String) -> Date? {
        logDateFormatter.date(from: text)
    }
}
