import Foundation

/// `Sotto --transcribe-file <wav> [--json]`
///
/// 时延验收的调试入口：走的是 app 内同一条 TranscribeService（不是另写一套
/// shell 调用），所以量到的就是「app 里点完松手之后要等多久」。
/// 不初始化 NSApplication，也不碰麦克风 / 剪贴板 / 界面。
enum TranscribeFileCommand {
    static func run(arguments: [String]) -> Never {
        guard let flagIndex = arguments.firstIndex(of: "--transcribe-file"),
              flagIndex + 1 < arguments.count else {
            FileHandle.standardError.write(Data("--transcribe-file 需要一个 WAV 路径\n".utf8))
            exit(2)
        }
        let wavPath = (arguments[flagIndex + 1] as NSString).expandingTildeInPath
        let asJSON = arguments.contains("--json")
        // 和 GUI 走同一份设置：否则设置里选了自定义模型，时延验收量的还是默认模型。
        let service = TranscribeService(modelPath: AppSettings().modelPath)

        guard FileManager.default.fileExists(atPath: wavPath) else {
            emitFailure(status: 2, message: "音频不存在：\(wavPath)", wav: wavPath, asJSON: asJSON)
        }

        do {
            let result = try service.transcribe(wavURL: URL(fileURLWithPath: wavPath))
            if asJSON {
                var object: [String: Any] = [
                    "file": wavPath,
                    "exit": 0,
                    "wall_ms": result.wallMS,
                    "chars": result.text.count,
                    "path": result.requestPath ?? "-",
                    "text": result.text,
                ]
                object["decode_ms"] = result.decodeMS ?? result.wallMS
                object["decode_source"] = result.decodeMS == nil ? "wall" : "request_event"
                if let audio = result.audioMS { object["audio_ms"] = audio }
                print(json(object))
            } else {
                print("file=\(wavPath)")
                print("decode_ms=\(result.decodeMS ?? result.wallMS) wall_ms=\(result.wallMS) "
                      + "chars=\(result.text.count) path=\(result.requestPath ?? "-")")
                print("text=\(result.text)")
            }
            exit(0)
        } catch let failure as TranscribeFailure {
            emitFailure(status: failure.status == -1 ? 1 : failure.status,
                        message: failure.userMessage, wav: wavPath, asJSON: asJSON,
                        detail: failure.description)
        } catch {
            emitFailure(status: 1, message: error.localizedDescription, wav: wavPath,
                        asJSON: asJSON)
        }
    }

    private static func emitFailure(status: Int32, message: String, wav: String, asJSON: Bool,
                                    detail: String? = nil) -> Never {
        FileHandle.standardError.write(Data("sotto: \(message)\n".utf8))
        if asJSON {
            var object: [String: Any] = ["file": wav, "exit": Int(status), "error": message]
            if let detail { object["detail"] = detail }
            print(json(object))
        } else {
            print("file=\(wav)")
            print("decode_ms=- wall_ms=- chars=0 path=-")
            print("error=\(message)")
        }
        exit(status)
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
