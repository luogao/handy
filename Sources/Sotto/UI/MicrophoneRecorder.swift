import AVFoundation
import Foundation

struct Recording {
    let url: URL
    let audioMS: Int
    let writeMS: Int
}

/// 录音。采集参数、落盘方式、时长上限全部照抄 `sotto/sotto-mic.swift`
/// （AVAudioRecorder + 16kHz/单声道/16bit PCM）——那是被 chain.sh 验证过的路径。
///
/// 任务书里写的是 AVAudioEngine，但同一句话又要求「采样率、格式、写盘方式照抄，
/// 别自己换」。sotto-mic 用的是 AVAudioRecorder：换 AVAudioEngine 就要自己接
/// tap 缓冲、自己写 AVAudioFile，等于把已验证的落盘路径重写一遍，收益为零、
/// 风险全是新的。所以这里保留 AVAudioRecorder，WAV 字节和 CLI 路径一致。
final class MicrophoneRecorder {
    static let minSeconds: TimeInterval = 0.2    // 松手太快：丢弃并提示，不报错
    static let maxSeconds: TimeInterval = 60     // 松开事件丢了也不会无限录

    /// whisper 直接能吃的格式：16kHz / 单声道 / 16-bit PCM。与 sotto-mic.swift 逐字一致。
    static let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    /// 录满上限时由本类主动收尾，外面负责转写。
    var onMaxDuration: (() -> Void)?

    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var currentURL: URL?
    private var maxWork: DispatchWorkItem?

    var isRecording: Bool { recorder != nil }

    static func inputDeviceCount() -> Int {
        // .microphone 这个 deviceType 是 macOS 14 才有的；包的最低版本是 13，
        // 13 上退回旧的 devices(for:)——只用来数个数，不参与录音参数。
        if #available(macOS 14.0, *) {
            return AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone],
                                                    mediaType: .audio,
                                                    position: .unspecified).devices.count
        }
        return AVCaptureDevice.devices(for: .audio).count
    }

    static func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// 返回 false 表示没起来（没设备 / 权限 / 录音器初始化失败），调用方负责提示。
    func start() -> Bool {
        guard recorder == nil else { return true }   // 连按只算一次
        let url = Self.makeOutputURL()
        do {
            let rec = try AVAudioRecorder(url: url, settings: Self.settings)
            guard rec.prepareToRecord(), rec.record() else { return false }
            recorder = rec
            startedAt = Date()
            currentURL = url
            let work = DispatchWorkItem { [weak self] in
                self?.onMaxDuration?()
            }
            maxWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxSeconds, execute: work)
            return true
        } catch {
            return false
        }
    }

    /// 收尾并落盘。太短（<200ms）时删文件返回 nil。
    func stop() -> Recording? {
        guard let rec = recorder else { return nil }
        maxWork?.cancel()
        maxWork = nil
        let held = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let writeStarted = Date()
        rec.stop()   // 同步收尾，返回时文件已写完
        let writeMS = Int(Date().timeIntervalSince(writeStarted) * 1000)
        let url = currentURL
        recorder = nil
        startedAt = nil
        currentURL = nil

        guard let url else { return nil }
        guard held >= Self.minSeconds else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return Recording(url: url, audioMS: Int(held * 1000), writeMS: writeMS)
    }

    /// 退出 / 丢弃：停掉并删文件，不转写。
    func cancel() {
        maxWork?.cancel()
        maxWork = nil
        recorder?.stop()
        recorder = nil
        startedAt = nil
        if let url = currentURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentURL = nil
    }

    private static func makeOutputURL() -> URL {
        let directory = SottoPaths.recordingsDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = "sotto-\(formatter.string(from: Date())).wav"
        return directory.appendingPathComponent(name)
    }
}
