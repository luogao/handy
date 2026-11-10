#!/usr/bin/env swift
// handy-transcribe — 第 4 段：WAV → 分段转写 → 词典校正 → （可选）剪贴板。
//
//   ./handy-transcribe <wav> [--model <path>] [--terms "A|B|C"] [--clip] [--keep-hant]
//                       [--no-server] [--server-status] [--stop-server]
//
// 最终文本打到 stdout；--clip 时再交给 handy-clip 写剪贴板并弹提示。
//
// 两条转写路径，默认优先常驻 server：
//   server：起一个 whisper-server（模型只加载一次），每段 POST /inference；
//   cli   ：每段 spawn 一次 whisper-cli，每段都重载一次模型（旧路径，--no-server）。
// 为什么要有 server 路径：CLI 每跑一段都要重载一次模型（~0.75s），超过 28 秒的口述
// 还要切段，端到端 3.16–3.59s 破 3.0s 线；server 把这份开销摊到一次。
// 分段/热词/接上文的策略不变。
//
// 策略（DYVI-106 的 `seg+hotword+dict` + DYVI-114 实测的长度上限）：
//   1. ≤28 秒整段一次请求；超过才切，切点取 [cursor+8, cursor+28] 内的静音中点，
//      取最靠近 cursor+25 的那个，找不到就硬切在 +25 秒
//   2. 每段 --prompt = 热词表 + 上一段末尾 40 字（首段只放热词），整条 prompt 以「。」收尾
//   3. 结果过一遍词典校正（recover_terms 的两档匹配）
// 为什么 ≤28 秒不切：每多一次 /inference 就多付一次 30 秒窗口的编码（本机 ~0.55s）。
// 24 秒音频单请求 1.61s，切三段 2.79s；12.68 秒 1.12s vs 1.70s（DYVI-114 H1）。
// 为什么超过 28 秒必须切：30 秒是 whisper 的硬窗口，31 秒单请求会跳过后半段
// （DYVI-114 H2：31.0/40.0 秒单请求「顺便看看30秒以上的长句子…太长而」整段被吞）。
// 为什么 prompt 以「。」收尾：热词 prompt 不封口时模型会把它当待续写内容原样复读
// （DYVI-114 H4：12/16 秒音频 + 5 个热词，整段输出就是热词表本身）；句号封口后复读消失。
//
// 分段在进程内用 AVAudioFile 做，运行时不调用 ffmpeg / ffprobe——POC 的 run.py
// 靠 ffmpeg silencedetect 分段，那是度量台的口径；产品链路不能给用户装 ffmpeg 的
// 隐含依赖。这里的静音检测是等价的简化实现（10ms 帧 RMS、-35dB、≥0.25s）。
//
// 退出码：0 成功；1 用法 / 音频 / whisper 失败；2 模型不存在；3 找不到 whisper-cli。
// 2 和 3 排在最前：缺东西要在 1 秒内说清楚，不要等读完音频才报错。

import AVFoundation
import Darwin
import Foundation

// MARK: - 常量

let sampleRate: Double = 16000
let silenceThresholdDB: Float = -35      // 与 POC 的 ffmpeg silencedetect 同口径
let silenceMinDuration: Double = 0.25
let segmentMinSeconds: Double = 8
let segmentMaxSeconds: Double = 28      // 留 2 秒余量给 whisper 的 30 秒硬窗口
let segmentTargetSeconds: Double = 25
let carryCharacters = 40

let defaultModel = NSHomeDirectory() + "/.cache/whisper.cpp/ggml-medium-q5_0.bin"
let defaultTermsFile = NSHomeDirectory() + "/Library/Application Support/Handy/terms.txt"

let exitUsage: Int32 = 1
let exitModel: Int32 = 2
let exitWhisper: Int32 = 3

let usage = """
usage: handy-transcribe <wav> [--model <path>] [--terms "A|B|C"] [--clip]
                            [--keep-hant] [--debug] [--no-server]
       handy-transcribe --server-status | --stop-server
       handy-transcribe --log-stats [--since 7d|24h|2026-11-03|<ISO8601>]

  <wav>            16kHz/单声道/16bit WAV（其他格式会转）
  --model <path>   whisper 模型路径，默认 \(defaultModel)
  --terms "A|B|C"  热词表，'|' 分隔；默认读 \(defaultTermsFile)
  --clip           转写完写剪贴板并弹提示（交给 handy-clip）
  --keep-hant      保留 whisper 输出的繁体，默认转成简体
  --debug          whisper 的日志不再丢弃，打到 stderr
  --no-server      强制旧 whisper-cli 路径（每段重载模型，慢；对照与兜底用）
  --server-status  打印常驻 server 的状态 / 端口 / PID，然后退出
  --stop-server    停掉常驻 server（连同它的看门狗），然后退出
  --log-stats      统计 whisper-server.log 里的生命周期事件，默认近 7 天
  --since <when>   配合 --log-stats：7d / 24h / 30m / 2026-11-03 / ISO8601
"""

let env = ProcessInfo.processInfo.environment
let debug = CommandLine.arguments.contains("--debug")

// MARK: - 常驻 server 的文件与默认值

/// 与 handy-clip / handy-hint 共用 `~/Library/Caches/handy`；HANDY_LOG_DIR 可覆盖（测试并行时用）。
let cacheDir: String = {
    if let d = env["HANDY_LOG_DIR"], !d.isEmpty { return (d as NSString).expandingTildeInPath }
    return NSHomeDirectory() + "/Library/Caches/handy"
}()
let portFile = cacheDir + "/whisper-server.port"
let metaFile = cacheDir + "/whisper-server.json"
let heartbeatFile = cacheDir + "/whisper-server.heartbeat"
let serverLogFile = cacheDir + "/whisper-server.log"
let defaultServerPort = 8931
let portScanCount = 20
/// 起 server 的参数版本。改 runInternalServe 里的参数就换这个值，老进程会在下次调用时被换掉。
let serverVariant = "whisper-server/v1"
/// 空闲自退。验收要把 600s 压到 20s，所以走环境变量而不是命令行开关。
let serverIdleSeconds: Double = {
    guard let raw = env["HANDY_SERVER_IDLE_SECONDS"], let value = Double(raw) else { return 600 }
    return min(max(value, 5), 86400)      // 小于 5s 会在一次推理中途被看门狗误杀
}()

// MARK: - 事件日志（whisper-server.log）
//
// 日志是「可统计的事件流」，不是一次性调试输出：
//   <ISO8601 毫秒> <文件内字节偏移> handy event=<类型> k=v ...   由本程序写的事件行
//   <ISO8601 毫秒> <文件内字节偏移> server <原始行>               server 子进程输出（经中继）
// 追加写、不截断，单文件过 5MB 轮转成 `.1`，当前 + `.1` 共 2 份。
// 不记识别文本、音频内容、wav 路径（隐私线；见 transcribeViaServer 的 multipart 文件名）。

/// 单文件上限。轮转时机是下一次写日志，所以实际大小会略过头一点。
let logMaxBytes: Int64 = 5 * 1024 * 1024

let logStampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter
}()

func logStamp(_ date: Date = Date()) -> String { logStampFormatter.string(from: date) }

func logEvent(_ body: String, to path: String = serverLogFile) {
    appendLogLine(path, "handy event=" + body)
}

/// 本进程只需要检查一次老格式。
var logFormatChecked = false

/// 老版本（≤ DYVI-117 之前）留下的日志全是没有时间戳的 ggml 行，留在当前文件里会让
/// `sort -c` 永远失败、前缀计数也对不上。第一次写新格式前把它整份挪成 `.1`
/// （正好复用轮转的两份上限），当前日志从干净的新格式开始，历史也没丢。
func migrateLegacyLog(_ path: String) {
    let fd = open(path, O_RDWR)
    guard fd >= 0 else { return }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { return }
    defer { flock(fd, LOCK_UN) }

    var locked = stat()
    guard fstat(fd, &locked) == 0, locked.st_size > 0 else { return }
    // 只有「锁住的还是当前文件」才动手：别的进程可能刚轮转过或迁移过。
    var onDisk = stat()
    guard stat(path, &onDisk) == 0,
          onDisk.st_ino == locked.st_ino, onDisk.st_dev == locked.st_dev else { return }

    var head = [UInt8](repeating: 0, count: 24)
    let count = pread(fd, &head, head.count, 0)
    // 新格式首行一定以 `YYYY-MM-DDT` 开头。
    let looksNew = count >= 11
        && (0..<4).allSatisfy { (48...57).contains(head[$0]) }
        && head[4] == UInt8(ascii: "-") && head[7] == UInt8(ascii: "-")
        && head[10] == UInt8(ascii: "T")
    guard !looksNew else { return }
    rename(path, path + ".1")
}

/// 追加一行，前缀 `<ISO8601 毫秒> <文件内字节偏移> `。
///
/// 第二个字段不是给人看的，是给 `sort -c` 用的：同一毫秒里常有成批的 ggml 行，
/// 光靠毫秒时间戳排不出来，加上这个严格递增的偏移才能保证整文件始终有序。
/// 时间戳在**拿到锁之后**才取，所以跨进程（CLI / 看门狗 / 中继）也满足
/// 「落盘顺序 = 时间戳顺序」，事件间隔可以直接拿 awk 算。
///
/// 任何一步失败都只是丢掉这一行：日志写失败不许改变转写结果或退出码。
func appendLogLine(_ path: String, _ body: String) {
    if !logFormatChecked {
        logFormatChecked = true
        migrateLegacyLog(path)
    }
    // 轮转会让 fd 指向被改名后的旧 inode，所以每一步都要重新确认「锁住的还是当前文件」。
    for _ in 0..<3 {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        guard flock(fd, LOCK_EX) == 0 else { close(fd); return }

        var onDisk = stat()
        var locked = stat()
        let stillCurrent = stat(path, &onDisk) == 0 && fstat(fd, &locked) == 0
            && onDisk.st_ino == locked.st_ino && onDisk.st_dev == locked.st_dev
        if !stillCurrent {
            flock(fd, LOCK_UN); close(fd); continue
        }
        if locked.st_size > logMaxBytes {
            // 在锁里改名：后到的进程拿到锁时会发现 inode 变了，不会重复轮转把 .1 抹掉。
            // rename 原子覆盖旧的 .1，所以当前 + .1 最多两份。
            rename(path, path + ".1")
            flock(fd, LOCK_UN); close(fd); continue
        }
        let line = logStamp() + " " + String(format: "%08lld", Int64(locked.st_size))
            + " " + body + "\n"
        _ = line.utf8CString.withUnsafeBytes { buffer in
            write(fd, buffer.baseAddress, buffer.count - 1)   // 去掉结尾的 NUL
        }
        flock(fd, LOCK_UN); close(fd)
        return
    }
}

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(("handy-transcribe: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

func note(_ message: String) {
    guard debug else { return }
    FileHandle.standardError.write(("handy-transcribe: " + message + "\n").data(using: .utf8)!)
}

/// 这个可执行文件所在的 handy/ 目录（包装脚本会传 HANDY_DIR，不传就按 .build/ 回退）。
let handyDir: String = {
    if let d = env["HANDY_DIR"], !d.isEmpty { return d }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return exe.deletingLastPathComponent().deletingLastPathComponent().path
}()

// MARK: - 内部模式（给 spawn 出来的自己用，不在 usage 里）

// 两个内部模式都先 setsid：server 与看门狗要活过父进程，也不能被终端的 Ctrl-C
// 打到（macOS 没有 util-linux 的 setsid 命令，但 libc 的 setsid(2) 在）。
if CommandLine.arguments.count > 1 {
    switch CommandLine.arguments[1] {
    case "--internal-serve":
        runInternalServe(Array(CommandLine.arguments.dropFirst(2)))
    case "--internal-watchdog":
        runInternalWatchdog(Array(CommandLine.arguments.dropFirst(2)))
    case "--internal-relay":
        runInternalRelay(Array(CommandLine.arguments.dropFirst(2)))
    default:
        break
    }
}

// MARK: - 参数

var wavPath: String?
var modelPath = defaultModel
var termsOverride: [String]?
var writeClipboard = false
var keepHant = false
var termsFile = defaultTermsFile
var useServer = true
var printServerStatus = false
var stopServer = false
var normalizeSelfTest = false
var printLogStats = false
var sinceValue: String?

var args = Array(CommandLine.arguments.dropFirst())
var index = 0
func nextValue(_ flag: String) -> String {
    index += 1
    guard index < args.count else { fail("\(flag) 缺参数\n" + usage, exitUsage) }
    return args[index]
}

while index < args.count {
    let arg = args[index]
    switch arg {
    case "--help", "-h":
        print(usage)
        exit(0)
    case "--model":
        // 标准化：meta 里记的模型路径要和这次比，`./x` 与绝对路径不能算两个模型。
        let expanded = (nextValue(arg) as NSString).expandingTildeInPath
        modelPath = URL(fileURLWithPath: expanded).standardizedFileURL.path
    case "--terms":
        termsOverride = nextValue(arg).split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    case "--terms-file":
        termsFile = (nextValue(arg) as NSString).expandingTildeInPath
    case "--clip":
        writeClipboard = true
    case "--keep-hant":
        keepHant = true
    case "--no-server":
        useServer = false
    case "--server-status":
        printServerStatus = true
    case "--stop-server":
        stopServer = true
    case "--normalize-selftest":
        normalizeSelfTest = true
    case "--log-stats":
        printLogStats = true
    case "--since":
        sinceValue = nextValue(arg)
    case "--debug":
        break                      // 已在上面读过
    default:
        guard !arg.hasPrefix("--") else { fail("未知选项 \(arg)\n" + usage, exitUsage) }
        guard wavPath == nil else { fail("只能给一个 WAV\n" + usage, exitUsage) }
        wavPath = arg
    }
    index += 1
}

// 这几个开关不需要 WAV / 模型：出问题时手边往往只有一条命令。
if stopServer { stopResidentServer() }                 // 内部 exit
if printServerStatus { reportServerStatus() }          // 内部 exit
if normalizeSelfTest { runNormalizeSelfTest() }        // 内部 exit
if printLogStats { runLogStats() }                     // 内部 exit

guard let inputPath = wavPath else { fail("缺 WAV 路径\n" + usage, exitUsage) }

// MARK: - 前置检查（顺序由验收口径定：先模型 2，再 whisper-cli 3）

guard FileManager.default.fileExists(atPath: modelPath) else {
    fail("模型不存在：\(modelPath)（用 --model 指一个 ggml-*.bin）", exitModel)
}

/// 只在 PATH 里找，不硬编码 Homebrew 路径：找不到就是 3，让调用方知道环境缺件。
func findExecutable(_ name: String) -> String? {
    let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    for dir in path.split(separator: ":") {
        let candidate = String(dir) + "/" + name
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

/// server 模式只需要 whisper-server；只有回退到 CLI 时才需要 whisper-cli。
/// 两条都缺才早退 3，避免「有 server 却因为没装 CLI 报错」和「没 server 还要等读完音频」。
let whisperServerPath = useServer ? findExecutable("whisper-server") : nil
let whisperCLIPath = findExecutable("whisper-cli")
if whisperServerPath == nil && whisperCLIPath == nil {
    fail("找不到 whisper-cli / whisper-server（brew install whisper-cpp，且要在 PATH 里）", exitWhisper)
}

guard FileManager.default.fileExists(atPath: inputPath) else {
    fail("音频不存在：\(inputPath)", exitUsage)
}

// MARK: - 词表

func loadTerms() -> [String] {
    if let override = termsOverride { return override }
    guard let data = FileManager.default.contents(atPath: termsFile),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

let terms = loadTerms()
let hotwords = terms.joined(separator: " ")

// MARK: - 读音频 → 16kHz 单声道 Float

enum AudioError: Error, CustomStringConvertible {
    case unreadable(String)
    case convertFailed(String)

    var description: String {
        switch self {
        case .unreadable(let m): return m
        case .convertFailed(let m): return m
        }
    }
}

func loadSamples(url: URL) throws -> [Float] {
    let file: AVAudioFile
    do {
        file = try AVAudioFile(forReading: url)
    } catch {
        throw AudioError.unreadable("读不了音频 \(url.path)：\(error.localizedDescription)")
    }
    let inFormat = file.processingFormat
    guard inFormat.channelCount > 0, file.length > 0 else {
        throw AudioError.unreadable("音频是空的：\(url.path)")
    }
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                              sampleRate: sampleRate, channels: 1,
                              interleaved: false)!

    // 快路径：handy-mic 落盘的就是 16k/单声道，直接整块读。
    if inFormat.sampleRate == sampleRate && inFormat.channelCount == 1 {
        let capacity = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: capacity) else {
            throw AudioError.unreadable("分配缓冲区失败")
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else {
            throw AudioError.unreadable("音频不是浮点 PCM")
        }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    // 慢路径：采样率或声道数不对，用 AVAudioConverter 拉成 16k/单声道。
    guard let converter = AVAudioConverter(from: inFormat, to: target) else {
        throw AudioError.convertFailed("不支持从 \(inFormat) 转 16kHz 单声道")
    }
    let chunkFrames: AVAudioFrameCount = 16384
    var samples: [Float] = []
    let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunkFrames)!
    var supplied = false

    func drain() throws {
        let ratio = sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 4096
        let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity)!
        supplied = false
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return inBuffer
        }
        // .inputRanDry 是正常的（这一块喂完了），只有 .error 才算失败。
        if let conversionError {
            throw AudioError.convertFailed("重采样失败：\(conversionError.localizedDescription)")
        }
        if let data = outBuffer.floatChannelData, outBuffer.frameLength > 0 {
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0],
                                                           count: Int(outBuffer.frameLength)))
        }
    }

    // 读到文件末尾为止。不能靠 frameLength == 0 收尾：AVAudioFile 越过末尾再读会抛
    // 一个信息全空的 _GenericObjCError（打印出来就是 "nilError"）。
    while file.framePosition < file.length {
        try file.read(into: inBuffer, frameCount: chunkFrames)
        guard inBuffer.frameLength > 0 else { break }
        try drain()
    }
    // 把重采样器里剩余的几个采样冲出来。
    let tail = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096)!
    converter.convert(to: tail, error: nil) { _, status in
        status.pointee = .endOfStream
        return nil
    }
    if let data = tail.floatChannelData, tail.frameLength > 0 {
        samples.append(contentsOf: UnsafeBufferPointer(start: data[0],
                                                       count: Int(tail.frameLength)))
    }
    return samples
}

// MARK: - 静音检测与分段

/// 静音区间（秒）。等价于 ffmpeg `silencedetect=noise=-35dB:d=0.25`；
/// 尾部一直静音时 end 取音频末尾（ffmpeg 也只报 start，run.py 自己补的 end）。
func detectSilences(_ samples: [Float]) -> [(start: Double, end: Double)] {
    let frame = Int(sampleRate * 0.01)          // 10ms 一帧
    guard frame > 0, samples.count >= frame else { return [] }
    let frameCount = samples.count / frame
    var silent = [Bool](repeating: false, count: frameCount)
    for f in 0..<frameCount {
        var sum: Float = 0
        let base = f * frame
        for i in 0..<frame {
            let v = samples[base + i]
            sum += v * v
        }
        let rms = (sum / Float(frame)).squareRoot()
        // rms == 0 时 log10 是 -inf，直接判静音
        silent[f] = rms > 0 ? (20 * log10(rms) < silenceThresholdDB) : true
    }
    var out: [(Double, Double)] = []
    var f = 0
    while f < frameCount {
        guard silent[f] else { f += 1; continue }
        let startFrame = f
        while f < frameCount && silent[f] { f += 1 }
        let endFrame = f
        let start = Double(startFrame) * 0.01
        let duration = Double(endFrame - startFrame) * 0.01
        if duration >= silenceMinDuration {
            let end = endFrame >= frameCount ? Double(samples.count) / sampleRate
                                             : Double(endFrame) * 0.01
            out.append((start, end))
        }
    }
    return out
}

struct Segment {
    let start: Double
    let end: Double
    var duration: Double { end - start }
}

/// 照 run.py `split_audio`：切点优先取窗口内的静音中点，取最靠近「当前位置 +25s」的那个；
/// 没有静音就硬切在 +25s。硬切可能切在词中间，这是已知代价（POC.md「这版方案还差什么」）。
/// 循环条件是 `duration - cursor > segmentMaxSeconds`，所以 ≤28s 的音频一段都不切，
/// 整段走一次请求（DYVI-114 H1：请求次数才是热态时延的瓶颈）。
func planSegments(duration: Double, silences: [(start: Double, end: Double)]) -> [Segment] {
    guard duration > 0 else { return [] }
    let mids = silences.map { ($0.start + $0.end) / 2 }
    var cuts: [Double] = [0]
    var cursor = 0.0
    while duration - cursor > segmentMaxSeconds {
        let lo = cursor + segmentMinSeconds
        let hi = cursor + segmentMaxSeconds
        let candidates = mids.filter { $0 >= lo && $0 <= hi }
        let target = cursor + segmentTargetSeconds
        let cut = candidates.min { abs($0 - target) < abs($1 - target) } ?? target
        cuts.append(cut)
        cursor = cut
    }
    cuts.append(duration)
    var segments: [Segment] = []
    for i in 0..<(cuts.count - 1) where cuts[i + 1] > cuts[i] {
        segments.append(Segment(start: cuts[i], end: cuts[i + 1]))
    }
    return segments
}

func writeSegment(_ samples: [Float], _ segment: Segment, to url: URL) throws {
    let from = max(0, Int(segment.start * sampleRate))
    let to = min(samples.count, Int(segment.end * sampleRate))
    guard to > from else { throw AudioError.unreadable("分段长度为零") }
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: 1, interleaved: false)!
    let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let out = try AVAudioFile(forWriting: url, settings: settings)
    let frames = AVAudioFrameCount(to - from)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let dst = buffer.floatChannelData![0]
    samples.withUnsafeBufferPointer { src in
        dst.update(from: src.baseAddress! + from, count: Int(frames))
    }
    try out.write(from: buffer)
}

// MARK: - whisper-cli 子进程

func transcribeSegment(_ wav: URL, prompt: String?, outBase: URL, cli: String) throws -> String {
    // 显式对齐 server 的解码参数，别依赖 CLI 默认值：
    // cli.cpp 的默认是 -bs 5（beam search），而 server 是 beam_size=-1（真 greedy）+ best_of 2。
    // `-bs 1` 走 cli.cpp 的 greedy 分支（beam_size > 1 才算 beam），`-bo 2` 与 server 的
    // best_of 一致；少一个都会在长音频上分叉（24s：煮干 vs 主干）。
    // `-nf` 和 server 请求里的 temperature_inc=0 配对：两边都关掉温度回退，否则回退会用
    // server 进程里跨请求累积的 rng 采样，同一段音频连发会漂。
    // 不用 -bs 8：server 带 beam 8 时 24s 从 2.8s 涨到 4.6s、破 3.5s 线，长驻进程第二个请求
    // 起还会翻回 greedy；统一 greedy 后整组 CER 1.96% 仍在线内。
    var arguments = ["-m", modelPath, "-l", "zh", "-f", wav.path,
                     "--no-timestamps", "-otxt", "-of", outBase.path, "-bs", "1", "-bo", "2", "-nf"]
    if let prompt, !prompt.isEmpty {
        arguments += ["--prompt", prompt]
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cli)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        throw AudioError.unreadable("启动 whisper-cli 失败：\(error.localizedDescription)")
    }
    // 必须边跑边读：whisper-cli 日志不少，管道写满会把它卡住。
    let handle = pipe.fileHandleForReading
    var log = Data()
    while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        if debug { log.append(chunk) }
    }
    process.waitUntilExit()
    if debug, let text = String(data: log, encoding: .utf8) {
        FileHandle.standardError.write(text.data(using: .utf8)!)
    }
    guard process.terminationStatus == 0 else {
        throw AudioError.unreadable("whisper-cli 退出码 \(process.terminationStatus)")
    }
    let txtURL = URL(fileURLWithPath: outBase.path + ".txt")
    guard let data = try? Data(contentsOf: txtURL),
          let text = String(data: data, encoding: .utf8) else {
        throw AudioError.unreadable("whisper-cli 没有产出文本")
    }
    // 一个 30 秒窗口可能吐多行；段内不带换行，拼回去才是一句话。
    return text.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined()
}

// MARK: - 常驻 whisper-server

/// 写进 `whisper-server.json` 的登记信息。模型路径也记下来：换了 --model 就不能复用旧 server。
/// variant 记启动参数版本：以后改 server 的启动参数（beam、线程数…），老进程必须换掉，
/// 否则新代码会连上一个参数不对的旧 server。
struct ServerMeta: Codable {
    let port: Int
    let pid: Int32
    let model: String
    let variant: String?
}

enum ServerError: Error, CustomStringConvertible {
    case http(String)
    case badResponse(String)

    var description: String {
        switch self {
        case .http(let m): return m
        case .badResponse(let m): return m
        }
    }
}

/// 只在回退时打一行（不带 --debug 也打）：这是运行状态，不是调试日志。
func fallbackToCLI(_ reason: String) {
    FileHandle.standardError.write(
        ("handy-transcribe: fallback=cli (" + reason + ")\n").data(using: .utf8)!)
}

func readMeta(at path: String) -> ServerMeta? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(ServerMeta.self, from: data)
}

func writeMeta(_ meta: ServerMeta) {
    guard let data = try? JSONEncoder().encode(meta) else { return }
    try? data.write(to: URL(fileURLWithPath: metaFile), options: .atomic)
}

func touchHeartbeat() {
    // 看门狗看这个文件的 mtime 判空闲；写失败不影响转写，下一次还会再写。
    try? String(Date().timeIntervalSince1970).write(toFile: heartbeatFile, atomically: true, encoding: .utf8)
}

func removeStateFiles() {
    for path in [portFile, metaFile, heartbeatFile] {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// 只清掉属于 pid 的那份登记：看门狗醒来时可能已经有新 server 接手了。
func removeStateFiles(in dir: String, ifPID pid: Int32) {
    let metaPath = dir + "/whisper-server.json"
    guard let meta = readMeta(at: metaPath), meta.pid == pid else { return }
    for name in ["whisper-server.port", "whisper-server.json", "whisper-server.heartbeat"] {
        try? FileManager.default.removeItem(atPath: dir + "/" + name)
    }
}

func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

func terminate(pid: pid_t, grace: Double = 3) {
    guard pid > 0, isAlive(pid) else { return }
    kill(pid, SIGTERM)
    let deadline = Date().addingTimeInterval(grace)
    while Date() < deadline {
        if !isAlive(pid) { return }
        usleep(100_000)
    }
    kill(pid, SIGKILL)
    usleep(100_000)
}

// 探测用短超时，推理用长超时——同一个 session 会把 0.2s 的超时套到 12s 音频上。
// 用 static 而不是顶层 let：`--server-status` 在顶层语句流里比这里先执行，
// 顶层的 let 还没轮到初始化，取到的是空引用（第一次实现就卡死在这儿）。
enum ServerHTTP {
    static let probe: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.2
        config.timeoutIntervalForResource = 0.2
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static let inference: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}

/// 同步跑一个请求：顶层流程是线性的，用信号量把 async 收回来比回调套回调清楚。
func synchronously(_ session: URLSession,
                   _ request: URLRequest) -> Result<(Data, HTTPURLResponse), Error> {
    var outcome: Result<(Data, HTTPURLResponse), Error> =
        .failure(ServerError.badResponse("没有收到响应"))
    let semaphore = DispatchSemaphore(value: 0)
    session.dataTask(with: request) { data, response, error in
        if let error {
            outcome = .failure(error)
        } else if let http = response as? HTTPURLResponse, let data {
            outcome = .success((data, http))
        }
        semaphore.signal()
    }.resume()
    semaphore.wait()
    return outcome
}

/// 光「端口在答」不够：G 用例里 8931 上可能蹲着 python -m http.server。
/// whisper-server 的 `Server:` 头是 `whisper.cpp`，拿它认人。
func serverAnswers(port: Int) -> Bool {
    guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 0.2
    switch synchronously(ServerHTTP.probe, request) {
    case .failure:
        return false
    case .success(let (_, http)):
        let server = http.value(forHTTPHeaderField: "Server")?.lowercased() ?? ""
        return http.statusCode == 200 && server.contains("whisper.cpp")
    }
}

func waitForServer(port: Int, pid: pid_t, timeout: Double) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if serverAnswers(port: port) { return true }
        if pid > 0 && !isAlive(pid) { return false }   // 进程已经没了，别等满 5 秒
        if Date() >= deadline { return false }
        usleep(50_000)
    }
}

func portIsFree(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return bound == 0
}

func pickFreePort() -> Int? {
    for port in defaultServerPort..<(defaultServerPort + portScanCount) where portIsFree(port) {
        return port
    }
    return nil
}

/// 用 argv[0] 把自己再拉起来（内部模式里再 setsid + exec）。
let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path

/// 父进程退出后它还得活着：Process 不会替父进程收尸子进程，内部模式里再 setsid
/// 让它脱离当前会话/进程组，终端 Ctrl-C 打不到它。
func spawnDetached(_ arguments: [String], log: String?) throws -> pid_t {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: selfPath)
    process.arguments = arguments
    process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
    var environment = ProcessInfo.processInfo.environment
    // 追加写，绝不截断。以前这里的 createFile(atPath:contents:nil) 会在每次 spawn 时清空
    // 文件——只补 seekToEndOfFile 没用，createFile 本身就已经截断了；O_APPEND 才是对的。
    // 日志打不开时退回 /dev/null：日志写不进去只该丢日志，不能拖累 server 拉起。
    if let log, let fd = { () -> Int32? in
        let fd = open(log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        return fd >= 0 ? fd : nil
    }() {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        process.standardOutput = handle
        process.standardError = handle
        // 让 --internal-serve 知道该把子进程输出转发到哪里（中继要用）。
        environment["HANDY_SERVER_LOG"] = log
    } else {
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
    }
    process.environment = environment
    do {
        try process.run()
    } catch {
        throw ServerError.badResponse("spawn 失败：\(error.localizedDescription)")
    }
    return process.processIdentifier
}

/// 有可用的登记就直接用；模型变了/进程死了就换；起不来返回 nil 让调用方回退 CLI。
func prepareServer() -> Int? {
    guard useServer else { return nil }
    guard let serverBin = whisperServerPath else {
        fallbackToCLI("PATH 里没有 whisper-server")
        return nil
    }
    try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)

    if let meta = readMeta(at: metaFile) {
        if meta.model == modelPath, meta.variant == serverVariant, meta.port > 0,
           waitForServer(port: meta.port, pid: pid_t(meta.pid), timeout: 1.0) {
            return meta.port
        }
        // 登记在，但模型不对或进程已死：是我们自己起的才收掉，不动别人的进程。
        if isAlive(pid_t(meta.pid)) {
            logEvent("stop reason=replace port=\(meta.port) pid=\(meta.pid)")
            terminate(pid: pid_t(meta.pid))
        } else {
            // 「其他」的退出方式：进程自己没了（崩了 / 被人 kill），登记还在。
            logEvent("stop reason=gone port=\(meta.port) pid=\(meta.pid)")
        }
        removeStateFiles()
    } else {
        // 只有旧版端口文件、没有 PID 登记：不知道是谁的，只清文件不杀进程。
        removeStateFiles()
    }

    guard let port = pickFreePort() else {
        fallbackToCLI("\(defaultServerPort)–\(defaultServerPort + portScanCount - 1) 没有空闲端口")
        return nil
    }
    let spawnStarted = Date()
    do {
        let pid = try spawnDetached(["--internal-serve", String(port), modelPath, serverBin],
                                    log: serverLogFile)
        let ready = waitForServer(port: port, pid: pid, timeout: 5.0)
        let startMS = Int(Date().timeIntervalSince(spawnStarted) * 1000)
        guard ready else {
            terminate(pid: pid)
            logEvent("spawn_fail port=\(port) pid=\(pid) start_ms=\(startMS) reason=timeout")
            fallbackToCLI("whisper-server 5 秒内没就绪")
            return nil
        }
        // 启动耗时只有就绪后才知道，所以这行写在 ready 前面、时间戳却是就绪时刻；
        // 真实的 spawn 时刻 = 时间戳 - start_ms。事件顺序仍是 spawn → ready。
        logEvent("spawn port=\(port) pid=\(pid) model=\(modelPath) start_ms=\(startMS)")
        logEvent("ready port=\(port) pid=\(pid) ready_ms=\(startMS) rss_mb=\(residentMB(pid: pid) ?? 0)")
        writeMeta(ServerMeta(port: port, pid: Int32(pid), model: modelPath, variant: serverVariant))
        try? String(port).write(toFile: portFile, atomically: true, encoding: .utf8)
        touchHeartbeat()
        // 看门狗自己也脱离父进程；它盯着心跳文件，空闲超时就 SIGTERM server 并清登记。
        _ = try? spawnDetached(["--internal-watchdog", String(pid),
                                String(serverIdleSeconds), cacheDir], log: nil)
        return port
    } catch {
        let startMS = Int(Date().timeIntervalSince(spawnStarted) * 1000)
        logEvent("spawn_fail port=\(port) start_ms=\(startMS) reason=\(error)")
        fallbackToCLI("拉起 whisper-server 失败：\(error.localizedDescription)")
        return nil
    }
}

/// ready 事件里的 RSS：`ps` 的 rss 是 KB。读不到就返回 0（不记 ?，字段保持纯数字）。
func residentMB(pid: pid_t) -> Int? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "rss=", "-p", String(pid)]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle(forWritingAtPath: "/dev/null")
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let kb = Int(String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)), kb > 0 else { return nil }
    return kb / 1024
}

func transcribeViaServer(_ wav: URL, prompt: String?, port: Int) throws -> String {
    let audio = try Data(contentsOf: wav)
    let boundary = "handy-" + UUID().uuidString
    var body = Data()
    func add(_ text: String) { body.append(Data(text.utf8)) }
    func field(_ name: String, _ value: String) {
        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        add(value)
        add("\r\n")
    }

    // 文件名固定成 `audio`：server 会把它原样打进 stderr（`processing 'audio'` / `Received request: audio`），
    // 传真实分段名（seg00.wav）就漏进了日志。它只用来给服务端的临时文件起名，不影响解码。
    add("--\(boundary)\r\n")
    add("Content-Disposition: form-data; name=\"file\"; filename=\"audio\"\r\n")
    add("Content-Type: audio/wav\r\n\r\n")
    body.append(audio)
    add("\r\n")
    field("response_format", "json")
    field("language", "zh")
    // 关温度回退：server 的 `-nf` 是死参数（只解析/打印，不写 wparams），请求里
    // temperature_inc=0 才真正生效。回退采样用长驻进程里只 seed 一次的 rng，
    // 是同一 server 连发时文本漂移的来源；CLI 侧对应 -nf，两条路径都走纯 argmax。
    field("temperature", "0")
    field("temperature_inc", "0")
    if let prompt, !prompt.isEmpty { field("prompt", prompt) }
    add("--\(boundary)--\r\n")

    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    request.timeoutInterval = 120

    let (data, http) = try synchronously(ServerHTTP.inference, request).get()
    guard http.statusCode == 200 else {
        throw ServerError.http("HTTP \(http.statusCode)：\(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
    }
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    guard let object, let text = object["text"] as? String else {
        throw ServerError.badResponse("响应里没有 text：\(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
    }
    touchHeartbeat()
    // 与 CLI 的 .txt 同口径：段内多行拼成一句，段间不加换行。
    return text.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined()
}

func reportServerStatus() -> Never {
    guard let meta = readMeta(at: metaFile) else {
        print("server=stopped")
        exit(1)
    }
    if waitForServer(port: meta.port, pid: pid_t(meta.pid), timeout: 0.5) {
        print("server=running port=\(meta.port) pid=\(meta.pid) model=\(meta.model)")
        exit(0)
    }
    print("server=stopped port=\(meta.port) pid=\(meta.pid)")
    exit(1)
}

func stopResidentServer() -> Never {
    if let meta = readMeta(at: metaFile) {
        logEvent("stop reason=--stop-server port=\(meta.port) pid=\(meta.pid)")
        terminate(pid: pid_t(meta.pid))
        removeStateFiles(in: cacheDir, ifPID: meta.pid)
        print("server=stopped port=\(meta.port) pid=\(meta.pid)")
    } else {
        removeStateFiles()
        print("server=stopped")
    }
    exit(0)
}

// MARK: - 日志统计（--log-stats）

/// 解析 `--since`：`7d` / `24h` / `30m` / `90s` 这类相对值，或 `2026-11-03` / ISO8601 绝对时间。
func parseSince(_ raw: String?) -> (date: Date, label: String) {
    guard let raw, !raw.isEmpty else {
        return (Date().addingTimeInterval(-7 * 86400), "近 7 天")
    }
    let lowered = raw.lowercased()
    if let unit = lowered.last, "smhd".contains(unit),
       let value = Double(lowered.dropLast()), value >= 0 {
        let seconds: Double
        switch unit {
        case "s": seconds = value
        case "m": seconds = value * 60
        case "h": seconds = value * 3600
        default: seconds = value * 86400
        }
        return (Date().addingTimeInterval(-seconds), "近 \(raw)")
    }
    let dayFormatter = DateFormatter()
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    dayFormatter.dateFormat = "yyyy-MM-dd"
    if let date = dayFormatter.date(from: raw) { return (date, "\(raw) 起") }
    if let date = ISO8601DateFormatter().date(from: raw) { return (date, "\(raw) 起") }
    fail("--since 看不懂：\(raw)（要 7d / 24h / 30m / 2026-11-03 / ISO8601）", exitUsage)
}

func median(_ values: [Int]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    if sorted.count % 2 == 1 { return Double(sorted[sorted.count / 2]) }
    return (Double(sorted[sorted.count / 2 - 1]) + Double(sorted[sorted.count / 2])) / 2
}

/// 一行 → (时间戳, `handy event=...` 之后的部分)。不是事件行（server 转发 / 坏行）返回 nil。
func parseEvent(_ line: Substring) -> (date: Date, body: String)? {
    let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
    guard fields.count == 4, fields[2] == "handy",
          let date = logStampFormatter.date(from: String(fields[0])) else { return nil }
    return (date, String(fields[3]))
}

/// 读当前 + `.1` 两份日志，按时间归并后算统计。默认近 7 天，`--since` 可改。
func runLogStats() -> Never {
    let (since, label) = parseSince(sinceValue)
    var events: [(date: Date, body: String)] = []
    for path in [serverLogFile + ".1", serverLogFile] {   // 旧的一份在前
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let event = parseEvent(line), event.date >= since else { continue }
            events.append(event)
        }
    }
    events.sort { $0.date < $1.date }      // 两份文件拼接后按时间归并

    var spawns = 0, idleExits = 0, stops = 0, requests = 0, serverRequests = 0, cliRequests = 0
    var readySamples: [Int] = []
    var coldSamples: [Int] = []            // spawn 之后第一个 request：等就绪的 start_ms + decode_ms
    var warmSamples: [Int] = []            // 同一 spawn 里后续 request 的 decode_ms
    var coldCount = 0
    var waitingFirstRequest = false
    var pendingStartMS = 0                 // 当前这次 spawn 的启动耗时，等第一个 request 来结账
    for event in events {
        let tokens = event.body.split(separator: " ")
        guard let head = tokens.first, head.hasPrefix("event=") else { continue }
        var values: [String: String] = [:]
        for token in tokens.dropFirst() {
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { values[String(pair[0])] = String(pair[1]) }
        }
        switch head.dropFirst("event=".count) {
        case "spawn":
            spawns += 1
            waitingFirstRequest = true
            pendingStartMS = Int(values["start_ms"] ?? "") ?? 0
        case "ready":
            if let ms = Int(values["ready_ms"] ?? "") { readySamples.append(ms) }
        case "idle_exit":
            idleExits += 1
        case "stop":
            stops += 1
        case "request":
            requests += 1
            if values["path"] == "server" { serverRequests += 1 } else { cliRequests += 1 }
            let wasFirst = waitingFirstRequest
            waitingFirstRequest = false
            if wasFirst { coldCount += 1 }
            // 冷启动增量只比单段请求：多段会把分段数混进耗时里，比出来的差不是冷启动的锅。
            // 冷启动的账要把「等 server 就绪」算进来——那才是用户在冷启动时多付的钱。
            guard values["segs"] == "1", let decode = Int(values["decode_ms"] ?? "") else { break }
            if wasFirst { coldSamples.append(pendingStartMS + decode) } else { warmSamples.append(decode) }
        default:
            break
        }
    }

    let readyText = readySamples.isEmpty ? "-"
        : "\(Int(median(readySamples).rounded()))ms"
    let incrementText: String
    if coldSamples.isEmpty || warmSamples.isEmpty {
        incrementText = "-"
    } else {
        incrementText = String(format: "%+.2fs",
                               (median(coldSamples) - median(warmSamples)) / 1000)
    }
    print("spawn 次数：\(spawns)（\(label)）")
    print("idle_exit 次数：\(idleExits)")
    print("平均就绪耗时：\(readyText)")
    print("冷启动（spawn 后首个 request）次数：\(coldCount)")
    print("平均冷启动增量：\(incrementText)")
    print("stop 次数：\(stops)　request 次数：\(requests)（server \(serverRequests) / cli \(cliRequests)）")
    print("日志：\(serverLogFile)（+ .1）")
    exit(0)
}

/// spawn 出来的自己：setsid 后 exec whisper-server。exec 不换 PID，
/// 所以父进程拿到的 processIdentifier 就是 server 的 PID。
func runInternalServe(_ arguments: [String]) -> Never {
    guard arguments.count == 3, let port = Int(arguments[0]) else { exit(exitUsage) }
    let model = arguments[1]
    let server = arguments[2]
    _ = setsid()
    // 子进程的 stdout/stderr 也要有时间戳，否则整份日志就排不了序。
    // 做法：spawn 一个中继进程读管道，本进程照旧 exec 成 server——exec 不换 PID，
    // 所以 --server-status / 看门狗 / terminate 拿到的仍然是 server 自己的 pid。
    if let logPath = env["HANDY_SERVER_LOG"], !logPath.isEmpty, pipeServerOutput(to: logPath) {
        // 中继没了（崩溃 / 被杀）也只丢日志：写管道返回 EPIPE，别把 server 一起带走。
        signal(SIGPIPE, SIG_IGN)
    }
    // 别跟着 CLI 传 -bs 8：实测把解码拖慢一倍（0.09 → 0.19 s/秒音频），24s 三段要 4.6s，破 3.5s 线。
    // CLI 路径同样用 greedy（见 transcribeSegment），两条路径才能逐字一致。
    // 也别指望 -nf：whisper.cpp 1.9.2 的 whisper-server 只解析/打印 no_fallback，
    // 从不写进 wparams（server.cpp:949 无条件用 temperature_inc=0.2），关不掉温度回退；
    // 回退用的 rng 在长驻进程里只 seed 一次，1.9.2 没有重置 API，只能靠 wrapper 归一兜住。
    let parts: [String] = [server, "-m", model, "-l", "zh",
                           "--host", "127.0.0.1", "--port", String(port),
                           "--no-timestamps"]
    var command: [UnsafeMutablePointer<CChar>?] = []
    for part in parts { command.append(strdup(part)) }
    command.append(nil)
    execv(server, &command)
    fail("无法启动 whisper-server：\(server)", exitWhisper)
}

/// 把本进程的 stdout/stderr 接到管道上，再 spawn 一个中继进程把管道内容逐行写进日志。
/// 返回 true 表示已接管；false 时调用方保持 spawn 时接的日志文件（降级：那些行没有时间戳）。
///
/// 为什么不是线程：exec 之后本进程就只剩 whisper-server，没有任何 Swift 代码能继续读管道。
/// 为什么不是 fork：Swift 的 Darwin overlay 明确禁用它（多线程下不安全），posix_spawn 是正路。
func pipeServerOutput(to logPath: String) -> Bool {
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else { return false }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    // 中继必须自己关掉写端，否则它永远等不到 EOF（server 退出后管道仍有写端存在）。
    posix_spawn_file_actions_addclose(&actions, fds[1])
    defer { posix_spawn_file_actions_destroy(&actions) }

    // 参数里只有 fd 号，日志路径走 HANDY_SERVER_LOG：argv 不出现 "whisper-server" 字样，
    // 免得 `pgrep -fl whisper-server` 数进程时把中继算进去。
    // 注意不能用顶层 let selfPath：--internal-serve 在顶层语句流里先于它初始化，
    // 取到的是零值（第一次实现就崩在这儿）。argv[0] 就是父进程 spawn 时给的可执行路径。
    let executable = CommandLine.arguments[0]
    let argv: [UnsafeMutablePointer<CChar>?] = [
        strdup(executable), strdup("--internal-relay"), strdup(String(fds[0])), nil,
    ]
    defer { for pointer in argv where pointer != nil { free(pointer) } }

    var relayPID: pid_t = 0
    let spawned = posix_spawn(&relayPID, executable, &actions, nil, argv, environ)
    if spawned == 0 {
        close(fds[0])
        dup2(fds[1], STDOUT_FILENO)
        dup2(fds[1], STDERR_FILENO)
        if fds[1] > STDERR_FILENO { close(fds[1]) }
        return true
    }
    // spawn 失败：关掉管道，退回 spawn 时接的文件。
    close(fds[0])
    close(fds[1])
    return false
}

/// spawn 出来的自己：从继承来的 fd 读 server 输出，逐行加时间戳写日志。
/// 日志路径走环境变量（不放进 argv），理由见 pipeServerOutput。
func runInternalRelay(_ arguments: [String]) -> Never {
    guard arguments.count == 1, let fd = Int32(arguments[0]), fd >= 0,
          let logPath = env["HANDY_SERVER_LOG"], !logPath.isEmpty else { exit(0) }
    relayServerOutput(readFD: fd, logPath: logPath)
}

/// 中继循环。EOF（server 退出）后把半行也写掉再走。
///
/// 已知口径：server 的 stderr 在非 tty 下被 libc 整块缓冲（约 4KB 一块），所以转发行的
/// 时间戳是「缓冲区刷出时刻」，不是 server 写下那行的时刻；成批出现是正常的。
/// 不用 pty 换取逐行刷新：中继若意外退出，pty 写端会堵死 server，而管道写端只会 EPIPE，
/// 顶多丢日志——日志子系统绝不允许把转写拖下水。事件行（spawn/ready/…）由本程序直接写，
/// 时刻永远准确。
func relayServerOutput(readFD: Int32, logPath: String) -> Never {
    var pending: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = read(readFD, &chunk, chunk.count)
        if count <= 0 { break }
        pending.append(contentsOf: chunk[0..<count])
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Array(pending[..<newline])
            pending.removeFirst(newline + 1)
            appendLogLine(logPath, "server " + sanitizedServerLine(line))
        }
    }
    if !pending.isEmpty {
        appendLogLine(logPath, "server " + sanitizedServerLine(pending))
    }
    _exit(0)
}

/// server 的 stderr 会打上传文件名（`operator(): processing 'audio'`）。文件名已经固定成 audio，
/// 这里再兜一道底：任何 .wav 文件名和临时目录路径都换成 `<audio>` / `<path>`。
/// 隐私线要求日志里 grep 不到 `.wav` 或 `/tmp/`；宁可少一行细节，也不让路径漏出来。
func sanitizedServerLine(_ bytes: [UInt8]) -> String {
    var text = String(decoding: bytes, as: UTF8.self)
    text = text.replacingOccurrences(of: #"\S*\.wav\b"#, with: "<audio>",
                                     options: .regularExpression)
    text = text.replacingOccurrences(of: #"/(?:tmp|var/folders)/\S*"#, with: "<path>",
                                     options: .regularExpression)
    return text
}

/// spawn 出来的自己：空闲超过 idle 就收掉 server。参数里刻意不出现 "whisper-server"
/// 字样——验收用 `pgrep -fl whisper-server` 数进程，看门狗不能把自己算进去。
func runInternalWatchdog(_ arguments: [String]) -> Never {
    guard arguments.count == 3,
          let rawPID = Int32(arguments[0]),
          let idle = Double(arguments[1]) else { exit(exitUsage) }
    let pid = pid_t(rawPID)
    let dir = arguments[2]
    let metaPath = dir + "/whisper-server.json"
    let heartbeatPath = dir + "/whisper-server.heartbeat"
    let logPath = dir + "/whisper-server.log"
    _ = setsid()
    let started = Date()      // 看门狗紧跟 server 拉起，这个时刻≈ server 启动时刻
    while true {
        sleep(2)
        guard let meta = readMeta(at: metaPath), meta.pid == rawPID else { exit(0) }
        guard isAlive(pid) else {
            // 「其他」的退出方式：server 自己没了。看门狗是唯一还会注意到这件事的进程。
            logEvent("stop reason=gone pid=\(rawPID) alive_s=\(Int(Date().timeIntervalSince(started)))",
                     to: logPath)
            removeStateFiles(in: dir, ifPID: rawPID)
            exit(0)
        }
        let age: Double
        if let attributes = try? FileManager.default.attributesOfItem(atPath: heartbeatPath),
           let modified = attributes[.modificationDate] as? Date {
            age = Date().timeIntervalSince(modified)
        } else {
            age = .infinity      // 心跳文件被人删了，按空闲处理
        }
        if age >= idle {
            logEvent("idle_exit pid=\(rawPID) idle_s=\(Int(age)) alive_s=\(Int(Date().timeIntervalSince(started)))",
                     to: logPath)
            terminate(pid: pid)
            removeStateFiles(in: dir, ifPID: rawPID)
            exit(0)
        }
    }
}

// MARK: - 繁 → 简

/// whisper 的中文输出默认常是繁体（POC 量 CER 时用 zhconv 归一，产品输出也得归）。
/// 用系统 ICU 的 Hant-Hans，不引第三方词表——手写几百字映射表漏一个字就错一次（POC.md）。
func toSimplified(_ text: String) -> String {
    guard !keepHant, !text.isEmpty else { return text }
    let mutable = NSMutableString(string: text) as CFMutableString
    CFStringTransform(mutable, nil, "Hant-Hans" as CFString, false)
    return mutable as String
}

/// 夹在两个数字中间的标点有语义，归一不能删：「3.5」≠「35」、「8-12 秒」≠「812 秒」。
func isDigitPunctuation(_ chars: [Character], _ i: Int) -> Bool {
    guard i > 0, i + 1 < chars.count else { return false }
    return chars[i - 1].isNumber && chars[i + 1].isNumber
}

/// 落盘前的确定性归一：繁 → 简（`--keep-hant` 时跳过）+ 去标点 + 空白收敛成单个空格。
/// 为什么去标点：whisper 的「有没有句号 / 全角还是半角」会随解码状态漂（长驻 server 尤其明显，
/// 见 server 的 rng 残留），而标点不承担转写语义（CER 口径本来就 drop_punct）。归一后同一段
/// 音频的可见输出稳定：`快遞。` / `快递` / `快递!!` 都得到 `快递`。
func normalizeText(_ text: String) -> String {
    let chars = Array(toSimplified(text))
    var out = ""
    var pendingSpace = false
    for (i, ch) in chars.enumerated() {
        if ch.isWhitespace {
            if !out.isEmpty { pendingSpace = true }
            continue
        }
        if ch.isPunctuation, !isDigitPunctuation(chars, i) { continue }
        if pendingSpace {
            out.append(" ")
            pendingSpace = false
        }
        out.append(ch)
    }
    return out
}

/// 归一函数的最小单测入口：`handy-transcribe --normalize-selftest`。
/// 纯函数，不碰模型 / 音频 / 网络；apps/handy/tests/normalize_test.sh 调它。
func runNormalizeSelfTest() -> Never {
    let cases: [(String, String)] = [
        ("快遞。", "快递"),
        ("快递", "快递"),
        ("快递!!", "快递"),
        ("快遞，快遞", "快递快递"),
        ("快遞，", "快递"),
        ("  快递 ", "快递"),
        ("  快遞 \n 快递\t", "快递 快递"),
        ("：，。！？；、", ""),
        (":,.!?;", ""),
        ("MacBook Pro", "MacBook Pro"),
        ("温度 3.5s，涨到 4.6s", "温度 3.5s涨到 4.6s"),
        ("改成 8-12 秒一段", "改成 8-12 秒一段"),
        ("1,000 元和 3.5 元", "1,000 元和 3.5 元"),
        ("", ""),
    ]
    // 归一只能压字形和标点，不许把字词差异也抹平（抹平就是掩盖问题）。
    let mustDiffer: [(String, String)] = [
        ("公位", "工位"),
    ]
    var failed = 0
    for (input, expected) in cases {
        let got = normalizeText(input)
        if got == expected {
            print("PASS \(input.debugDescription) → \(got.debugDescription)")
        } else {
            failed += 1
            print("FAIL \(input.debugDescription) → \(got.debugDescription)，期望 \(expected.debugDescription)")
        }
    }
    for (a, b) in mustDiffer {
        if normalizeText(a) == normalizeText(b) {
            failed += 1
            print("FAIL \(a.debugDescription) 与 \(b.debugDescription) 归一后相同，字词差异被抹平")
        } else {
            print("PASS \(a.debugDescription) ≠ \(b.debugDescription)（归一不抹字词）")
        }
    }
    print(failed == 0 ? "normalize-selftest: PASS" : "normalize-selftest: FAIL")
    exit(failed == 0 ? 0 : 1)
}

// MARK: - 词典校正（recover_terms 的 Swift 版）

func isLatinLetter(_ c: Character) -> Bool {
    c.isASCII && c.isLetter
}

func isLatinAlnum(_ c: Character) -> Bool {
    c.isASCII && (c.isLetter || c.isNumber)
}

func latinKey(_ characters: [Character]) -> String {
    String(characters.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }).lowercased()
}

/// 文本里所有拉丁片段窗口：k 个相邻片段（只隔空格/连字符），返回 (start, end, key)。
func latinWindows(_ text: [Character]) -> [(start: Int, end: Int, key: String)] {
    var runs: [(Int, Int)] = []
    var i = 0
    while i < text.count {
        guard isLatinLetter(text[i]) else { i += 1; continue }
        let start = i
        while i < text.count && (isLatinAlnum(text[i]) || text[i] == "-") { i += 1 }
        runs.append((start, i))
    }
    var out: [(Int, Int, String)] = []
    for a in 0..<runs.count {
        for k in 1...3 {
            let b = a + k - 1
            guard b < runs.count else { break }
            if k > 1 {
                var separated = true
                for x in a..<b {
                    let gap = text[runs[x].1..<runs[x + 1].0]
                    if !gap.allSatisfy({ $0.isWhitespace || $0 == "-" }) { separated = false; break }
                }
                if !separated { break }   // 片段之间夹了别的字，不是同一个词
            }
            let start = runs[a].0, end = runs[b].1
            out.append((start, end, latinKey(Array(text[start..<end]))))
        }
    }
    return out
}

/// 最长公共块（Python difflib 的 find_longest_match：最长优先，同长取最早）。
func longestMatch(_ a: [Character], _ b: [Character]) -> (Int, Int, Int) {
    var bestI = 0, bestJ = 0, bestSize = 0
    var previous: [Int: Int] = [:]
    for i in 0..<a.count {
        var current: [Int: Int] = [:]
        for j in 0..<b.count where a[i] == b[j] {
            let length = (previous[j - 1] ?? 0) + 1
            current[j] = length
            if length > bestSize {
                bestI = i - length + 1
                bestJ = j - length + 1
                bestSize = length
            }
        }
        previous = current
    }
    return (bestI, bestJ, bestSize)
}

/// 匹配上的总字符数，对应 difflib SequenceMatcher 的 M。
func matchingTotal(_ a: [Character], _ b: [Character]) -> Int {
    var total = 0
    var queue: [(Int, Int, Int, Int)] = [(0, a.count, 0, b.count)]
    while let (aLo, aHi, bLo, bHi) = queue.popLast() {
        guard aLo < aHi, bLo < bHi else { continue }
        let (i, j, size) = longestMatch(Array(a[aLo..<aHi]), Array(b[bLo..<bHi]))
        guard size > 0 else { continue }
        total += size
        queue.append((aLo, aLo + i, bLo, bLo + j))
        queue.append((aLo + i + size, aHi, bLo + j + size, bHi))
    }
    return total
}

func similarity(_ a: [Character], _ b: [Character]) -> Double {
    guard !a.isEmpty || !b.isEmpty else { return 1 }
    return 2 * Double(matchingTotal(a, b)) / Double(a.count + b.count)
}

/// 把转写里的英文专名拉回词表写法。
///
/// 两档匹配（阈值照 POC 实测，别调）：
///   1. 字母序列完全相同、只是大小写不同 → 只校大小写
///   2. 音近形变 → 相似度 ≥ 0.60、首字母相同、长度差不超过 max(2, 一半)
/// 首字母不同不套，是为了挡住 Monica/Quotient 这类长得像但不是同一个词的误伤。
/// 与 run.py 的差别只有一处：那边每个词只改第一处，这里把每处都改（匹配口径和阈值不变）。
func recoverTerms(_ text: [Character], terms: [String]) -> (String, [(String, String, Double)]) {
    var taken: [(Int, Int)] = []
    var substitutions: [(Int, Int, String, String, Double)] = []

    func isFree(_ start: Int, _ end: Int) -> Bool {
        !taken.contains { $0.0 < end && start < $0.1 }
    }

    for term in terms.sorted(by: { $0.count > $1.count }) {
        let want = Array(term).filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let wantKey = String(want).lowercased()
        guard !wantKey.isEmpty else { continue }
        let windows = latinWindows(text).filter { isFree($0.start, $0.end) && !$0.key.isEmpty }

        // 第一档：字母序列完全相同。有这一档命中就不再走模糊匹配——这是 run.py 的
        // 短路条件，少了它「Hermes agent」会被同句里的「Hermes」窗口再套一次。
        let sameKey = windows.filter { $0.key == wantKey }
        if !sameKey.isEmpty {
            for window in sameKey {
                // 已经规范的那几处也要占住，别让后面更短的窗口重复套。
                taken.append((window.start, window.end))
                let original = String(text[window.start..<window.end])
                if original != term {
                    substitutions.append((window.start, window.end, original, term, 2.0))
                }
            }
            continue
        }

        // 第二档：音近形变。按相似度从高到低取，互不重叠；每个词每处都改。
        var candidates: [(ratio: Double, start: Int, end: Int)] = []
        for window in windows {
            let keyChars = Array(window.key)
            if abs(keyChars.count - wantKey.count) > max(2, Int(Double(wantKey.count) * 0.5)) {
                continue                       // 长度差太多，不像同一个词
            }
            guard keyChars.first == wantKey.first else { continue }   // 首字母不同不套
            let ratio = similarity(keyChars, Array(wantKey))
            guard ratio >= 0.60 else { continue }
            candidates.append((ratio, window.start, window.end))
        }
        for candidate in candidates.sorted(by: { $0.ratio > $1.ratio })
        where isFree(candidate.start, candidate.end) {
            let original = String(text[candidate.start..<candidate.end])
            substitutions.append((candidate.start, candidate.end, original, term, candidate.ratio))
            taken.append((candidate.start, candidate.end))
        }
    }

    var result = text
    for sub in substitutions.sorted(by: { $0.0 > $1.0 }) {   // 从右往左，下标不失效
        result.replaceSubrange(sub.0..<sub.1, with: Array(sub.3))
    }
    return (String(result),
            substitutions.map { ($0.2, $0.3, ($0.4 * 100).rounded() / 100) })
}

// MARK: - 主链路

let inputURL = URL(fileURLWithPath: inputPath)
let started = Date()
let workDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("handy-transcribe-\(ProcessInfo.processInfo.processIdentifier)")
do {
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
} catch {
    fail("建临时目录失败：\(error.localizedDescription)", exitUsage)
}
defer { try? FileManager.default.removeItem(at: workDir) }

let samples: [Float]
do {
    samples = try loadSamples(url: inputURL)
} catch {
    fail("\(error)", exitUsage)
}

let duration = Double(samples.count) / sampleRate
let silences = detectSilences(samples)
let segments = planSegments(duration: duration, silences: silences)
guard !segments.isEmpty else { fail("音频太短或读不出内容", exitUsage) }
note(String(format: "audio=%.2fs segments=%d silences=%d",
            duration, segments.count, silences.count))

// 先把所有分段落盘：server 中途失败要整份回退 CLI 重跑，这些 wav 不该写两遍。
var segmentURLs: [URL] = []
for (i, segment) in segments.enumerated() {
    let segURL = workDir.appendingPathComponent(String(format: "seg%02d.wav", i))
    do {
        try writeSegment(samples, segment, to: segURL)
    } catch {
        fail("写分段失败：\(error)", exitUsage)
    }
    segmentURLs.append(segURL)
}

/// 分段顺序 + 热词 + 接上文的策略只有这一份；换引擎（server / cli）不换策略。
/// 返回拼好的分段文本和引擎总耗时（ms）——后者就是 request 事件里的 decode_ms。
func transcribeAll(_ engine: (URL, String?, Int) throws -> String) throws -> ([String], Int) {
    var pieces: [String] = []
    var previous = ""
    var decodeMS = 0
    for (i, segURL) in segmentURLs.enumerated() {
        // 首段只放热词；后续段再带上一段末尾 40 字，断句处的错少一半（POC 实测）。
        var prompt = hotwords
        if !previous.isEmpty {
            prompt += (prompt.isEmpty ? "" : " ") + String(previous.suffix(carryCharacters))
        }
        // 句号封口：热词 prompt 不封口时，模型会把它当成待续写的内容原样复读，
        // 整段输出就是热词表本身（DYVI-114 H4，12/16 秒音频 + 5 个热词可稳定复现）。
        if !prompt.isEmpty { prompt += "。" }
        let engineStarted = Date()
        let raw = try engine(segURL, prompt.isEmpty ? nil : prompt, i)
        decodeMS += Int(Date().timeIntervalSince(engineStarted) * 1000)
        let simplified = normalizeText(raw)
        note(String(format: "seg%d %.2f-%.2fs chars=%d",
                    i, segments[i].start, segments[i].end, simplified.count))
        pieces.append(simplified)
        previous = simplified
    }
    return (pieces, decodeMS)
}

var pieces: [String] = []
var transcribed = false
var decodeMS = 0
var requestPath = "cli"
if let port = prepareServer() {
    do {
        (pieces, decodeMS) = try transcribeAll { wav, prompt, _ in
            try transcribeViaServer(wav, prompt: prompt, port: port)
        }
        transcribed = true
        requestPath = "server"
    } catch {
        // 跑到一半 server 没了：整份结果丢掉重跑 CLI，别把两条路径的段拼在一起。
        fallbackToCLI("server 请求失败：\(error)")
    }
}
if !transcribed {
    guard let cli = whisperCLIPath else {
        fail("找不到 whisper-cli（brew install whisper-cpp，且要在 PATH 里）", exitWhisper)
    }
    do {
        (pieces, decodeMS) = try transcribeAll { wav, prompt, i in
            let outBase = workDir.appendingPathComponent(String(format: "seg%02d", i))
            return try transcribeSegment(wav, prompt: prompt, outBase: outBase, cli: cli)
        }
    } catch {
        fail("\(error)", exitUsage)
    }
}

let (corrected, substitutions) = recoverTerms(Array(normalizeText(pieces.joined())), terms: terms)
if debug, !substitutions.isEmpty {
    note("dict " + substitutions.map { "\($0.0)→\($0.1)(\($0.2))" }.joined(separator: " "))
}

let text = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
guard !text.isEmpty else { fail("转写结果为空", exitUsage) }

// 一次转写一条 request 事件（不是每段一条）：统计要的是「这一次调用花了多久、几个字」。
// 只记元数据——不记文本、不记音频、不记 wav 路径。
logEvent("request path=\(requestPath) segs=\(segments.count) audio_ms=\(Int(duration * 1000)) "
    + "decode_ms=\(decodeMS) chars=\(text.count)")

if writeClipboard {
    let clip = handyDir + "/handy-clip"
    guard FileManager.default.isExecutableFile(atPath: clip) else {
        fail("找不到 handy-clip（\(clip)）", exitUsage)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: clip)
    process.arguments = [text]          // 整段作为单个参数，换行不会被拆
    process.standardOutput = FileHandle.standardError   // 别污染 stdout
    process.standardError = FileHandle.standardError
    do {
        try process.run()
    } catch {
        fail("启动 handy-clip 失败：\(error.localizedDescription)", exitUsage)
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fail("handy-clip 退出码 \(process.terminationStatus)", exitUsage)
    }
}

note(String(format: "elapsed_ms=%.0f", Date().timeIntervalSince(started) * 1000))
print(text)
exit(0)
