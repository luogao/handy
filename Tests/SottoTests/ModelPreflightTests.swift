import Foundation
import Testing
@testable import Sotto

// MARK: - 预检三态

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sotto-model-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// 造一个指定大小、指定前 4 字节的文件。用内存里的 Data 写，测试完随目录删掉。
private func writeModel(at url: URL, size: Int, magic: String) throws {
    var data = Data(magic.utf8)
    if size > data.count {
        data.append(Data(repeating: 0, count: size - data.count))
    }
    try data.write(to: url)
}

@Test func 模型文件不存在时预检报缺失() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("not-there.bin").path

    #expect(ModelPreflight.check(path: path) == ModelFileProblem.missing)
}

@Test func 四KB垃圾文件预检报无法读取() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("garbage.bin")
    // 随机字节，前 4 字节几乎必然不是 ggml；大小也远小于 1MB。
    try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: url)

    #expect(ModelPreflight.check(path: url.path) == ModelFileProblem.unreadable)
}

@Test func 小于一MB的ggml文件仍报无法读取() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("small.bin")
    // magic 对、但只有 512KB：不能因为前 4 字节对了就放行。
    try writeModel(at: url, size: 512 * 1024, magic: "ggml")

    #expect(ModelPreflight.check(path: url.path) == ModelFileProblem.unreadable)
}

@Test func 首四字节不是ggml的大文件报无法读取() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("riff.bin")
    try writeModel(at: url, size: 2 * 1024 * 1024, magic: "RIFF")

    #expect(ModelPreflight.check(path: url.path) == ModelFileProblem.unreadable)
}

@Test func 合法ggml模型通过预检() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("ok.bin")
    try writeModel(at: url, size: 2 * 1024 * 1024, magic: "ggml")

    #expect(ModelPreflight.check(path: url.path) == nil)
}

@Test func 真模型的小端magic也通过预检() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("real-format.bin")
    // whisper.cpp 按本机字节序写 0x67676d6c，落盘是 lmgg。
    try writeModel(at: url, size: 2 * 1024 * 1024, magic: "lmgg")

    #expect(ModelPreflight.check(path: url.path) == nil)
}

@Test func 指向合法模型的符号链接通过预检() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("real.bin")
    try writeModel(at: target, size: 2 * 1024 * 1024, magic: "ggml")
    let link = directory.appendingPathComponent("模型 链接.bin")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    #expect(ModelPreflight.check(path: link.path) == nil)
}

@Test func 悬空符号链接按缺失处理() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let link = directory.appendingPathComponent("dangling.bin")
    try FileManager.default.createSymbolicLink(
        at: link, withDestinationURL: directory.appendingPathComponent("gone.bin")
    )

    #expect(ModelPreflight.check(path: link.path) == ModelFileProblem.missing)
}

@Test func 目录路径按无法读取处理() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let subdirectory = directory.appendingPathComponent("model.bin")
    try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

    #expect(ModelPreflight.check(path: subdirectory.path) == ModelFileProblem.unreadable)
}

@Test func 预检阈值是一MB() {
    #expect(ModelPreflight.minimumBytes == 1_048_576)
    #expect(ModelPreflight.magic == Data("ggml".utf8))
    #expect(ModelPreflight.magicLittleEndian == Data("lmgg".utf8))
}

// MARK: - 参数拼装：未设置绝不传 --model

@Test func 未设置模型路径时参数里没有model() {
    #expect(TranscribeService.arguments(wavPath: "/tmp/a.wav", modelPath: nil)
            == ["/tmp/a.wav"])
    #expect(TranscribeService.arguments(wavPath: "/tmp/a.wav", modelPath: "   ")
            == ["/tmp/a.wav"])
    #expect(TranscribeService.arguments(wavPath: "/tmp/a.wav", modelPath: "")
            == ["/tmp/a.wav"])
}

@Test func 自定义模型路径会追加model参数() {
    #expect(TranscribeService.arguments(wavPath: "/tmp/a.wav", modelPath: "/tmp/m.bin")
            == ["/tmp/a.wav", "--model", "/tmp/m.bin"])
    // 中文 + 空格必须原样进参数，不能编码。
    #expect(TranscribeService.arguments(wavPath: "/tmp/a.wav",
                                        modelPath: "/tmp/测试 目录/m.bin")
            == ["/tmp/a.wav", "--model", "/tmp/测试 目录/m.bin"])
}
