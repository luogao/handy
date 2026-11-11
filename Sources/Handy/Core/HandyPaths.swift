import Foundation

/// 运行期用到的目录。全部走环境变量可覆盖，和 handy-mic / handy-transcribe 的
/// 既有约定一致（测试并行跑时用 HANDY_LOG_DIR / HANDY_RECORD_DIR 隔离）。
enum HandyPaths {
    static func logDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL {
        if let value = environment["HANDY_LOG_DIR"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/handy")
    }

    static func recordingsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL {
        if let value = environment["HANDY_RECORD_DIR"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        return logDirectory(environment: environment, home: home)
            .appendingPathComponent("recordings")
    }
}
