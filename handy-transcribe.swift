#!/usr/bin/env swift
// handy-transcribe — 第 4 段：WAV → 分段转写 → 词典校正 → （可选）剪贴板。
//
//   ./handy-transcribe <wav> [--model <path>] [--terms "A|B|C"] [--clip] [--keep-hant]
//
// 最终文本打到 stdout；--clip 时再交给 handy-clip 写剪贴板并弹提示。
//
// 策略照 DYVI-106 实测出来的那一行（POC.md 末节 `seg+hotword+dict`）：
//   1. 8–12 秒一段，切点取静音中点；窗口里找不到静音就硬切在 ~11 秒
//   2. 每段 --prompt = 热词表 + 上一段末尾 40 字（首段只放热词）
//   3. 结果过一遍词典校正（recover_terms 的两档匹配）
// 为什么必须分段：单个 30 秒窗口塞热词 prompt 会把整段写成 prompt 原文（已复现）。
//
// 分段在进程内用 AVAudioFile 做，运行时不调用 ffmpeg / ffprobe——POC 的 run.py
// 靠 ffmpeg silencedetect 分段，那是度量台的口径；产品链路不能给用户装 ffmpeg 的
// 隐含依赖。这里的静音检测是等价的简化实现（10ms 帧 RMS、-35dB、≥0.25s）。
//
// 退出码：0 成功；1 用法 / 音频 / whisper 失败；2 模型不存在；3 找不到 whisper-cli。
// 2 和 3 排在最前：缺东西要在 1 秒内说清楚，不要等读完音频才报错。

import AVFoundation
import Foundation

// MARK: - 常量

let sampleRate: Double = 16000
let silenceThresholdDB: Float = -35      // 与 POC 的 ffmpeg silencedetect 同口径
let silenceMinDuration: Double = 0.25
let segmentMinSeconds: Double = 8
let segmentMaxSeconds: Double = 12
let segmentTargetSeconds: Double = 11
let carryCharacters = 40

let defaultModel = NSHomeDirectory() + "/.cache/whisper.cpp/ggml-medium-q5_0.bin"
let defaultTermsFile = NSHomeDirectory() + "/Library/Application Support/Handy/terms.txt"

let exitUsage: Int32 = 1
let exitModel: Int32 = 2
let exitWhisper: Int32 = 3

let usage = """
usage: handy-transcribe <wav> [--model <path>] [--terms "A|B|C"] [--clip]
                            [--keep-hant] [--debug]

  <wav>            16kHz/单声道/16bit WAV（其他格式会转）
  --model <path>   whisper 模型路径，默认 \(defaultModel)
  --terms "A|B|C"  热词表，'|' 分隔；默认读 \(defaultTermsFile)
  --clip           转写完写剪贴板并弹提示（交给 handy-clip）
  --keep-hant      保留 whisper 输出的繁体，默认转成简体
  --debug          whisper 的日志不再丢弃，打到 stderr
"""

let env = ProcessInfo.processInfo.environment
let debug = CommandLine.arguments.contains("--debug")

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

// MARK: - 参数

var wavPath: String?
var modelPath = defaultModel
var termsOverride: [String]?
var writeClipboard = false
var keepHant = false
var termsFile = defaultTermsFile

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
        modelPath = (nextValue(arg) as NSString).expandingTildeInPath
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
    case "--debug":
        break                      // 已在上面读过
    default:
        guard !arg.hasPrefix("--") else { fail("未知选项 \(arg)\n" + usage, exitUsage) }
        guard wavPath == nil else { fail("只能给一个 WAV\n" + usage, exitUsage) }
        wavPath = arg
    }
    index += 1
}

guard let inputPath = wavPath else { fail("缺 WAV 路径\n" + usage, exitUsage) }

// MARK: - 前置检查（顺序由验收口径定：先模型 2，再 whisper-cli 3）

guard FileManager.default.fileExists(atPath: modelPath) else {
    fail("模型不存在：\(modelPath)（用 --model 指一个 ggml-*.bin）", exitModel)
}

/// 只在 PATH 里找，不硬编码 Homebrew 路径：找不到就是 3，让调用方知道环境缺件。
func findWhisperCLI() -> String? {
    let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    for dir in path.split(separator: ":") {
        let candidate = String(dir) + "/whisper-cli"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

guard let whisperCLI = findWhisperCLI() else {
    fail("找不到 whisper-cli（brew install whisper-cpp，且要在 PATH 里）", exitWhisper)
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

/// 照 run.py `split_audio`：切点优先取窗口内的静音中点，取最靠近「当前位置 +11s」的那个；
/// 没有静音就硬切在 +11s。硬切可能切在词中间，这是已知代价（POC.md「这版方案还差什么」）。
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

func transcribeSegment(_ wav: URL, prompt: String?, outBase: URL) throws -> String {
    var arguments = ["-m", modelPath, "-l", "zh", "-f", wav.path,
                     "--no-timestamps", "-otxt", "-of", outBase.path, "-bs", "8"]
    if let prompt, !prompt.isEmpty {
        arguments += ["--prompt", prompt]
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: whisperCLI)
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

// MARK: - 繁 → 简

/// whisper 的中文输出默认常是繁体（POC 量 CER 时用 zhconv 归一，产品输出也得归）。
/// 用系统 ICU 的 Hant-Hans，不引第三方词表——手写几百字映射表漏一个字就错一次（POC.md）。
func toSimplified(_ text: String) -> String {
    guard !keepHant, !text.isEmpty else { return text }
    let mutable = NSMutableString(string: text) as CFMutableString
    CFStringTransform(mutable, nil, "Hant-Hans" as CFString, false)
    return mutable as String
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

var pieces: [String] = []
var previous = ""
for (i, segment) in segments.enumerated() {
    let segURL = workDir.appendingPathComponent(String(format: "seg%02d.wav", i))
    let outBase = workDir.appendingPathComponent(String(format: "seg%02d", i))
    do {
        try writeSegment(samples, segment, to: segURL)
    } catch {
        fail("写分段失败：\(error)", exitUsage)
    }
    // 首段只放热词；后续段再带上一段末尾 40 字，断句处的错少一半（POC 实测）。
    var prompt = hotwords
    if !previous.isEmpty {
        prompt += (prompt.isEmpty ? "" : " ") + String(previous.suffix(carryCharacters))
    }
    let raw: String
    do {
        raw = try transcribeSegment(segURL, prompt: prompt.isEmpty ? nil : prompt, outBase: outBase)
    } catch {
        fail("\(error)", exitUsage)
    }
    let simplified = toSimplified(raw)
    note(String(format: "seg%d %.2f-%.2fs chars=%d", i, segment.start, segment.end, simplified.count))
    pieces.append(simplified)
    previous = simplified
}

let (corrected, substitutions) = recoverTerms(Array(toSimplified(pieces.joined())), terms: terms)
if debug, !substitutions.isEmpty {
    note("dict " + substitutions.map { "\($0.0)→\($0.1)(\($0.2))" }.joined(separator: " "))
}

let text = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
guard !text.isEmpty else { fail("转写结果为空", exitUsage) }

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
