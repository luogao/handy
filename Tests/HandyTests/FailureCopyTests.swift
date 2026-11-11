import Foundation
import Testing
@testable import Handy

// MARK: - 模型失败文案（卡里逐字，不许改写）

@Test func 模型缺失文案逐字() {
    let failure = TranscribeFailure(status: 2, stderr: "", detail: "preflight",
                                    modelProblem: .missing, modelPath: "/tmp/m.bin")
    #expect(failure.userMessage == "模型文件未找到")
    #expect(failure.userDetail == "在「设置 › 模型」里重新选择 .bin 文件")
    #expect(failure.bubbleMessage == "模型文件未找到\n在「设置 › 模型」里重新选择 .bin 文件")
    #expect(failure.modelPath == "/tmp/m.bin")
}

@Test func 模型损坏文案逐字() {
    let failure = TranscribeFailure(status: 2, stderr: "", detail: "preflight",
                                    modelProblem: .unreadable, modelPath: "/tmp/m.bin")
    #expect(failure.userMessage == "模型文件无法读取")
    #expect(failure.userDetail == "文件可能不完整，请重新选择一次")
    #expect(failure.bubbleMessage == "模型文件无法读取\n文件可能不完整，请重新选择一次")
}

@Test func 模型问题有独立的日志码() {
    #expect(ModelFileProblem.missing.rawValue == "model_missing")
    #expect(ModelFileProblem.unreadable.rawValue == "model_unreadable")
}

@Test func 预检通过后CLI仍报模型错误时按缺失处理() {
    // 预检和 CLI 加载之间文件被删的竞态：文案跟预检保持一致，不能有两套说法。
    let failure = TranscribeFailure(status: 2, stderr: "模型不存在", detail: nil)
    #expect(failure.modelProblem == nil)
    #expect(failure.userMessage == "模型文件未找到")
    #expect(failure.userDetail == "在「设置 › 模型」里重新选择 .bin 文件")
}

// MARK: - 其他失败路径不回归

@Test func 非模型失败仍然只有一条文案() {
    let whisperMissing = TranscribeFailure(status: 3, stderr: "", detail: nil)
    #expect(whisperMissing.userMessage.contains("whisper-cpp"))
    #expect(whisperMissing.userDetail == nil)
    #expect(whisperMissing.bubbleMessage == whisperMissing.userMessage)

    let binaryMissing = TranscribeFailure(status: -1, stderr: "", detail: "missing")
    #expect(binaryMissing.userMessage.contains("HANDY_TRANSCRIBE"))
    #expect(binaryMissing.userDetail == nil)
}

@Test func 转写失败摘要仍取stderr最后一行() {
    let failure = TranscribeFailure(status: 1, stderr: "handy-transcribe: 转写结果为空\n",
                                    detail: nil)
    #expect(failure.userMessage == "转写失败：转写结果为空")
    #expect(failure.userDetail == nil)
}
