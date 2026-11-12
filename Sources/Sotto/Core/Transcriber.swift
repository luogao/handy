import Foundation

/// sotto-transcribe 的位置。app 只是调用方：P1 从仓库 sotto/ 目录调，
/// P2 把二进制塞进 Contents/Resources/bin/ 后只换来源，调用方一行不用改。
struct TranscriberLocation {
    let url: URL?
    let source: String

    var isAvailable: Bool { url != nil }
}

enum TranscriberResolver {
    /// 优先级：SOTTO_TRANSCRIBE 环境变量 > bundle 内 Resources/bin > 从可执行文件
    /// 向上找 sotto-transcribe（开发态 .build/debug/Sotto 与 build/Sotto.app 都靠这条）。
    ///
    /// 环境变量指了但文件不可执行时**不回退**：静默换一个二进制跑，会让人以为
    /// 覆盖点生效了，实际调的还是旧的。
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> TranscriberLocation {
        if let override = environment["SOTTO_TRANSCRIBE"], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return TranscriberLocation(url: isExecutable(url.path) ? url : nil,
                                       source: "SOTTO_TRANSCRIBE")
        }

        if let resources = bundleResourceURL {
            let bundled = resources.appendingPathComponent("bin/sotto-transcribe")
            if isExecutable(bundled.path) {
                return TranscriberLocation(url: bundled, source: "bundle")
            }
        }

        var directory = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("sotto-transcribe")
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

/// 模型文件预检的两种失败。文案是卡里逐字定死的，别改写。
///
/// 拆成「缺失」和「无法读取」两类，是因为用户的下一步动作不同：前者多半是
/// 路径没了/选错了，后者是文件不完整。一句笼统的「模型有问题」等于让人猜。
enum ModelFileProblem: String {
    case missing = "model_missing"
    case unreadable = "model_unreadable"

    var mainMessage: String {
        switch self {
        case .missing: return "模型文件未找到"
        case .unreadable: return "模型文件无法读取"
        }
    }

    var detailMessage: String {
        switch self {
        case .missing: return "在「设置 › 模型」里重新选择 .bin 文件"
        case .unreadable: return "文件可能不完整，请重新选择一次"
        }
    }
}

/// spawn 之前对模型文件做的三态判定。
///
/// 为什么要预检：whisper 对「文件不存在」和「文件是垃圾」报出来的都是同一类
/// 通用错误，甚至可能先加载半天才崩。在 app 侧 4 个字节就能分清，没必要把
/// 进程创建、模型加载的开销和含糊的 stderr 一起付掉。
enum ModelPreflight {
    /// whisper 的 ggml 模型动辄几百 MB；小于 1MB 的不可能是能用的模型。
    /// 阈值卡在 1MB 是卡里定的，宁可把畸形小文件挡在外面。
    static let minimumBytes: UInt64 = 1_048_576
    /// GGML_FILE_MAGIC = 0x67676d6c，whisper.cpp 按本机字节序写盘，所以真模型
    /// 的前 4 字节是 `lmgg` 而不是字面上的 `ggml`（实测 ggml-medium-q5_0.bin
    /// 开头就是 6c 6d 67 67）。两种都认：只认 `ggml` 会把真模型判成损坏。
    static let magic = Data("ggml".utf8)
    static let magicLittleEndian = Data("lmgg".utf8)

    static func check(path: String, fileManager: FileManager = .default) -> ModelFileProblem? {
        // 先解析符号链接：attributesOfItem 看的是链接本身（大小只有几十字节），
        // 不解析的话「指向真模型的链接」会被误判成损坏。悬空链接解析后不存在，
        // 按缺失报。
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
            return .missing
        }
        // 目录不是模型文件；按「无法读取」报，而不是假装它存在就能用。
        guard !isDirectory.boolValue else { return .unreadable }
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolved),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size >= minimumBytes else {
            return .unreadable
        }
        guard let handle = FileHandle(forReadingAtPath: resolved) else { return .unreadable }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: magic.count),
              head == magic || head == magicLittleEndian else {
            return .unreadable
        }
        return nil
    }
}

/// 转写失败。status 与 sotto-transcribe 的退出码一致（0 成功、1 用法/音频、
/// 2 模型、3 whisper 缺件）；-1 表示调用方根本没找到可执行文件。
struct TranscribeFailure: Error, CustomStringConvertible {
    let status: Int32
    let stderr: String
    let detail: String?
    /// 非 nil 表示这次失败是预检判出来的模型问题（没 spawn 进程）。
    var modelProblem: ModelFileProblem?
    /// 预检失败时被判定的那个路径，写日志用。
    var modelPath: String?

    var description: String { "transcribe failed status=\(status) \(detail ?? stderr)" }

    /// 给气泡看的主文案：必须能指导下一步，不能只是「失败了」。
    var userMessage: String {
        if let modelProblem { return modelProblem.mainMessage }
        switch status {
        case 2:
            // 预检通过后 CLI 仍报 2（文件在预检和加载之间被删了）——按「缺失」
            // 报，和预检走同一条文案，别让同一个问题有两种说法。
            return ModelFileProblem.missing.mainMessage
        case 3:
            return "找不到 whisper-cli / whisper-server。先 brew install whisper-cpp，确认在 PATH 里。"
        case -1:
            return "找不到 sotto-transcribe。开发态请在 sotto/ 目录下运行，或用 SOTTO_TRANSCRIBE 指定。"
        default:
            if let last = Self.lastMeaningfulLine(stderr) {
                return "转写失败：\(last)"
            }
            return "转写失败（退出码 \(status)），详见 ~/Library/Caches/sotto/whisper-server.log"
        }
    }

    /// 副文案：模型问题才有，别的失败仍然只给一句主文案。
    var userDetail: String? {
        if let modelProblem { return modelProblem.detailMessage }
        if status == 2 { return ModelFileProblem.missing.detailMessage }
        return nil
    }

    /// 气泡实际显示的内容（主文案 + 副文案两行）。
    var bubbleMessage: String {
        guard let userDetail else { return userMessage }
        return userMessage + "\n" + userDetail
    }

    static func lastMeaningfulLine(_ stderr: String) -> String? {
        stderr.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .last?
            .replacingOccurrences(of: "sotto-transcribe: ", with: "")
    }
}

struct TranscribeResult {
    let text: String
    /// app 看到的总耗时（从 spawn 到进程退出，含进程启动和读音频）。
    let wallMS: Int
    /// sotto-transcribe 自己写进 request 事件的 decode_ms。拿不到就是 nil
    /// （走了 CLI 路径 / 日志被轮转掉了）。
    let decodeMS: Int?
    let audioMS: Int?
    let requestPath: String?
    /// 这次实际用的模型：自定义路径，或 `default`（未设置，交给 CLI 的默认值）。
    /// 日志 `event=request model=...` 直接用它，避免调用方再猜一遍。
    let modelLabel: String
}

/// 调 sotto-transcribe 的唯一入口。app 内不做任何解码 / 分段 / 归一——
/// 那些参数是四张卡验证过的，重写一份就等于把回归基线丢了。
///
/// 不传 `--clip`：剪贴板由 app 自己用 NSPasteboard 写（sotto-clip 是 `swift`
/// 解释执行的脚本，起一次要近 1 秒，会把 1.5 秒的时延预算吃掉）。
final class TranscribeService {
    let location: TranscriberLocation
    let environment: [String: String]
    let logDirectory: URL
    /// 设置里的自定义模型；nil 表示未设置。设成 var 是为了设置面板改完后
    /// 不用重启 app：下一次转写前由 AppDelegate 从 AppSettings 重新读进来。
    var modelPath: String?

    init(location: TranscriberLocation = TranscriberResolver.resolve(),
         environment: [String: String] = ProcessInfo.processInfo.environment,
         logDirectory: URL? = nil,
         modelPath: String? = nil) {
        self.location = location
        self.environment = environment
        self.logDirectory = logDirectory ?? SottoPaths.logDirectory(environment: environment)
        self.modelPath = SottoPaths.normalizeModelPath(modelPath)
    }

    /// 模型解析只走这一条：自定义（非空）→ 否则默认路径。
    /// `passesModelArgument` 为 false 时**不传 `--model`**，让 CLI 用自己的
    /// 默认值——默认模型只有 CLI 一份真相源。
    struct ModelPlan: Equatable {
        let path: String
        let passesModelArgument: Bool
        let logLabel: String
    }

    static func modelPlan(
        customPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        bundledModel: URL? = SottoPaths.bundledModelPath()
    ) -> ModelPlan {
        if let custom = SottoPaths.normalizeModelPath(customPath) {
            return ModelPlan(path: custom, passesModelArgument: true, logLabel: custom)
        }
        // 发行包自带模型时必须显式 `--model`：CLI 的默认值是
        // `~/.cache/whisper.cpp/ggml-medium-q5_0.bin`，干净机器上那个文件不存在，
        // 不传参数会直接 exit 2，用户看到「模型文件未找到」——而模型就在 app 里。
        if let bundledModel {
            return ModelPlan(path: bundledModel.path, passesModelArgument: true, logLabel: "bundle")
        }
        let fallback = SottoPaths.defaultModelPath(environment: environment, home: home).path
        return ModelPlan(path: fallback, passesModelArgument: false, logLabel: "default")
    }

    /// 纯参数拼装，单测直接钉住「未设置不传 --model」这条。
    static func arguments(wavPath: String, modelPath: String?) -> [String] {
        var arguments = [wavPath]
        if let model = SottoPaths.normalizeModelPath(modelPath) {
            arguments.append(contentsOf: ["--model", model])
        }
        return arguments
    }

    /// plan → CLI 参数。`passesModelArgument` 为 true 时把 plan 的路径交给 CLI，
    /// 否则完全交给 CLI 自己的默认值。
    static func arguments(wavPath: String, plan: ModelPlan) -> [String] {
        arguments(wavPath: wavPath, modelPath: plan.passesModelArgument ? plan.path : nil)
    }

    func transcribe(wavURL: URL) throws -> TranscribeResult {
        guard let executable = location.url else {
            throw TranscribeFailure(status: -1, stderr: "", detail: location.source)
        }

        // 预检必须在 spawn 之前：失败就直接抛，不创建进程。这样既能省一次
        // 进程创建，也不会让 CLI 的通用错误盖掉「缺失」和「损坏」的区别。
        let plan = Self.modelPlan(customPath: modelPath, environment: environment)
        if let problem = ModelPreflight.check(path: plan.path) {
            throw TranscribeFailure(status: 2, stderr: "", detail: "preflight",
                                    modelProblem: problem, modelPath: plan.path)
        }

        let logOffset = Self.fileSize(logDirectory.appendingPathComponent("whisper-server.log"))

        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(wavPath: wavURL.path, plan: plan)
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

        // 两个管道都必须边跑边读：sotto-transcribe 往 stderr 打不少行，写满管道
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
                                requestPath: stats?.requestPath,
                                modelLabel: plan.logLabel)
    }

    // MARK: - 从 server 日志里读回这一次的 decode_ms

    /// sotto-transcribe 每次调用写一条 `event=request ... decode_ms=...`。
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
        where line.contains(" sotto event=request ") {
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
    /// 的 bin；sotto-transcribe 只在 PATH 里找 whisper-cli / whisper-server，
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
