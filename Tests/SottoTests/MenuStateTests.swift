import Foundation
import Testing
@testable import Sotto

@Test func 初始状态与文案() {
    #expect(RecordingState.idle.actionTitle == "开始")
    #expect(RecordingState.listening.actionTitle == "停止")
}

@Test func 点一次开始再点一次停止() {
    var state = RecordingState.idle
    state = state.toggled
    #expect(state == .listening)
    #expect(state.actionTitle == "停止")
    state = state.toggled
    #expect(state == .idle)
    #expect(state.actionTitle == "开始")
}

@Test func 菜单固定项文案() {
    #expect(MenuCopy.settings == "设置…")
    #expect(MenuCopy.quit == "退出")
}

@Test func InfoPlist的固定值没被改坏() throws {
    // bundle id / 可执行名是 P1 麦克风授权的键：TCC 按 bundle id + 签名记账，
    // 这几个值一变，已经授权过的机器要重新弹一次授权。用测试把它们钉死。
    let sottoDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SottoTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // sotto/
    let data = try Data(contentsOf: sottoDir.appendingPathComponent("Resources/Info.plist"))
    let plist = try #require(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )

    #expect(plist["CFBundleIdentifier"] as? String == "top.rungundam.sotto")
    #expect(plist["CFBundleName"] as? String == "Sotto")
    #expect(plist["CFBundleExecutable"] as? String == "Sotto")
    #expect(plist["CFBundleDisplayName"] as? String == "Sotto")
    #expect(plist["CFBundleShortVersionString"] as? String == "0.1.2")
    #expect(plist["CFBundleVersion"] as? String == "012")
    #expect(plist["LSMinimumSystemVersion"] as? String == "13.0")
    #expect(plist["LSUIElement"] as? Bool == true)
    // P0 不申请权限，但文案要先在；P1 的授权弹窗直接用这一条。
    #expect((plist["NSMicrophoneUsageDescription"] as? String)?.isEmpty == false)
}
