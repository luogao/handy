#!/usr/bin/env swift
// handy-mic — 第 3 段：麦克风录音。
//
//   ./handy-mic --list          列出音频输入设备；无设备时输出 devices(0)、exit 0
//   ./handy-mic --record 3      录 3 秒到 ~/Library/Caches/handy/recordings/*.wav
//   ./handy-mic --hotkey        常驻：按住 ⌃⌥H 录、松开落盘（RegisterEventHotKey，不用 CGEventTap）
//   ./handy-mic --check         只注册热键并报告状态，1 秒内退出（本机没有麦克风也能验）
//   ./handy-mic --help
//
// 无设备时 --record / --hotkey 立刻 exit 3，**不会**卡在 requestAccess 的 20 秒等待上：
// 先用 AVCaptureDevice.DiscoverySession 数设备，0 个就直接报错，根本不调用 requestAccess。
//
// 用 RegisterEventHotKey 而不是 CGEventTap：Carbon 热键只消费注册过的那一个组合，
// 不装事件拦截，⌘C / ⌘V 等其他快捷键不受影响；也不需要辅助功能 / 输入监控权限。
import AVFoundation
import AppKit
import Carbon.HIToolbox

let hotkeyCombo = "ctrl+opt+H"
let hotkeyKeyCode = UInt32(kVK_ANSI_H)
let hotkeyModifiers = UInt32(controlKey | optionKey)
let hotkeySignature: OSType = 0x484E4459  // 'HNDY'
let hotkeyIDValue: UInt32 = 1

let minRecordSeconds: TimeInterval = 0.2   // 松手太快：丢弃并提示，不报错
let maxRecordSeconds: TimeInterval = 60    // 热键松开事件丢了也不会无限录

let usage = """
usage: handy-mic --list            列出音频输入设备
       handy-mic --record <秒>     录固定时长到 WAV
       handy-mic --hotkey          常驻：按住 \(hotkeyCombo) 录，松开落盘
       handy-mic --check           注册热键并报告状态后退出
       handy-mic --help
"""

let fm = FileManager.default
let env = ProcessInfo.processInfo.environment

func die(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(("handy-mic: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

func envDir(_ key: String, default def: String) -> String {
    if let v = env[key], !v.isEmpty { return (v as NSString).expandingTildeInPath }
    return def
}

let recordDir = envDir("HANDY_RECORD_DIR",
                       default: NSHomeDirectory() + "/Library/Caches/handy/recordings")

let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func log(_ message: String) {
    FileHandle.standardError.write(("\(iso.string(from: Date())) \(message)\n").data(using: .utf8)!)
}

/// whisper 直接能吃的格式：16kHz / 单声道 / 16-bit PCM。
let recorderSettings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVSampleRateKey: 16000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
]

func inputDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone],
                                     mediaType: .audio,
                                     position: .unspecified).devices
}

func ensureMicPermission() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .notDetermined:
        // 只有确认设备存在后才走到这里；无设备的分支在调用前就 exit 3 了。
        var granted = false
        let sem = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            granted = ok
            sem.signal()
        }
        sem.wait()
        return granted
    default:
        return false
    }
}

func makeOutputURL() -> URL {
    let dir = URL(fileURLWithPath: recordDir)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o700])
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd-HHmmss-SSS"
    return dir.appendingPathComponent("handy-\(f.string(from: Date())).wav")
}

func fileSize(_ url: URL) -> Int {
    let attrs = try? fm.attributesOfItem(atPath: url.path)
    return (attrs?[.size] as? NSNumber)?.intValue ?? 0
}

// MARK: - 录音状态

final class MicController {
    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var currentURL: URL?
    private var maxWork: DispatchWorkItem?

    var isRecording: Bool { recorder != nil }

    func start() {
        guard recorder == nil else { return }  // 连按只算一次
        let url = makeOutputURL()
        do {
            let rec = try AVAudioRecorder(url: url, settings: recorderSettings)
            guard rec.prepareToRecord(), rec.record() else {
                log("record_start_failed file=\(url.path)")
                return
            }
            recorder = rec
            startedAt = Date()
            currentURL = url
            log("rec start file=\(url.path)")
            let work = DispatchWorkItem { [weak self] in self?.stop(reason: "max_duration") }
            maxWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + maxRecordSeconds, execute: work)
        } catch {
            log("record_error \(error.localizedDescription)")
        }
    }

    func stop(reason: String = "released") {
        guard let rec = recorder, let started = startedAt, let url = currentURL else { return }
        maxWork?.cancel()
        maxWork = nil
        let held = Date().timeIntervalSince(started)
        let t0 = Date()
        rec.stop()  // 同步收尾，返回时文件已写完
        let writeMs = Date().timeIntervalSince(t0) * 1000
        recorder = nil
        startedAt = nil
        currentURL = nil

        if held < minRecordSeconds {
            try? fm.removeItem(at: url)
            log(String(format: "too short held_ms=%.0f (<200ms) discarded", held * 1000))
            return
        }
        log(String(format: "saved reason=%@ held=%.2fs write_ms=%.0f bytes=%d file=%@",
                   reason, held, writeMs, fileSize(url), url.path))
    }
}

let mic = MicController()

// MARK: - 全局热键（Carbon）

var hotKeyRef: EventHotKeyRef?
var hotKeyHandlerRef: EventHandlerRef?

func hotKeyHandler(_ callRef: EventHandlerCallRef?, _ event: EventRef?,
                   _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hkID = EventHotKeyID()
    let err = GetEventParameter(event,
                                EventParamName(kEventParamDirectObject),
                                EventParamType(typeEventHotKeyID),
                                nil,
                                MemoryLayout<EventHotKeyID>.size,
                                nil,
                                &hkID)
    guard err == noErr, hkID.signature == hotkeySignature, hkID.id == hotkeyIDValue else {
        return OSStatus(eventNotHandledErr)
    }
    let kind = GetEventKind(event)
    DispatchQueue.main.async {
        if kind == UInt32(kEventHotKeyPressed) {
            mic.start()
        } else if kind == UInt32(kEventHotKeyReleased) {
            mic.stop()
        }
    }
    return noErr
}

func registerHotKey() -> OSStatus {
    var types = [
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                      eventKind: UInt32(kEventHotKeyPressed)),
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                      eventKind: UInt32(kEventHotKeyReleased)),
    ]
    let installStatus = InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler,
                                            types.count, &types, nil, &hotKeyHandlerRef)
    guard installStatus == noErr else { return installStatus }
    let id = EventHotKeyID(signature: hotkeySignature, id: hotkeyIDValue)
    return RegisterEventHotKey(hotkeyKeyCode, hotkeyModifiers, id,
                               GetApplicationEventTarget(), 0, &hotKeyRef)
}

// MARK: - 子命令

func runList() -> Never {
    let devices = inputDevices()
    print("devices(\(devices.count))")
    for d in devices {
        print("  - \(d.localizedName)")
    }
    exit(0)
}

func runRecord(seconds: Double) -> Never {
    let devices = inputDevices()
    guard !devices.isEmpty else { die("no audio input device", 3) }
    guard ensureMicPermission() else { die("microphone permission denied", 4) }

    let url = makeOutputURL()
    let rec: AVAudioRecorder
    do {
        rec = try AVAudioRecorder(url: url, settings: recorderSettings)
    } catch {
        die("创建录音器失败：\(error.localizedDescription)")
    }
    guard rec.prepareToRecord(), rec.record() else { die("启动录音失败") }

    Thread.sleep(forTimeInterval: seconds)
    let captured = rec.currentTime
    rec.stop()

    print("file=\(url.path)")
    print(String(format: "duration=%.2fs requested=%.2fs bytes=%d",
                 captured, seconds, fileSize(url)))
    exit(0)
}

func runCheck() -> Never {
    let devices = inputDevices()
    print("devices(\(devices.count))")
    let status = registerHotKey()
    print("hotkey=\(hotkeyCombo) registered=\(status == noErr ? 1 : 0) id=\(hotkeyIDValue) osstatus=\(status)")
    print("accessibility_trusted=\(AXIsProcessTrusted() ? 1 : 0)")
    print("input_monitoring=\(CGPreflightListenEventAccess() ? 1 : 0)")
    if let ref = hotKeyRef {
        UnregisterEventHotKey(ref)
        print("hotkey_unregistered=1")
    }
    exit(status == noErr ? 0 : 5)
}

func runHotkey() -> Never {
    let devices = inputDevices()
    guard !devices.isEmpty else { die("no audio input device", 3) }
    guard ensureMicPermission() else { die("microphone permission denied", 4) }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let status = registerHotKey()
    guard status == noErr else { die("注册热键失败 osstatus=\(status)", 5) }
    log("hotkey=\(hotkeyCombo) registered id=\(hotkeyIDValue) devices=\(devices.count) "
        + "out=\(recordDir)")
    app.run()
    exit(0)
}

// MARK: - 入口

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else {
    FileHandle.standardError.write((usage + "\n").data(using: .utf8)!)
    exit(1)
}

switch first {
case "--help", "-h":
    print(usage)
    exit(0)

case "--list":
    runList()

case "--record":
    guard args.count == 2, let seconds = Double(args[1]), seconds > 0 else {
        die("--record 需要一个正数秒数\n" + usage)
    }
    runRecord(seconds: seconds)

case "--hotkey":
    runHotkey()

case "--check":
    runCheck()

default:
    die("未知选项 \(first)\n" + usage)
}
