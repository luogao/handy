import Carbon.HIToolbox
import Foundation

/// 全局热键。用 Carbon 的 RegisterEventHotKey，不装事件拦截：
/// 只消费注册过的这一个组合，⌘C/⌘V 等其它快捷键不受影响，也**不需要**辅助功能
/// 或输入监控权限（键盘事件拦截类 API 都要 TCC，v0.1 明确不碰）。
///
/// 按键与松开都会来事件，正好对应「按住说话、松手转写」。
final class HotKeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x484E4459   // 'HNDY'，与 handy-mic 同值
    private let hotKeyID: UInt32 = 1

    /// 事件处理器只装一次；换组合只换注册，避免重复 InstallEventHandler 叠回调。
    @discardableResult
    func installHandler() -> OSStatus {
        guard handlerRef == nil else { return noErr }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        return InstallEventHandler(GetApplicationEventTarget(), handyHotKeyHandler,
                                   types.count, &types,
                                   Unmanaged.passUnretained(self).toOpaque(),
                                   &handlerRef)
    }

    /// 换组合 = 先注销旧的再注册新的。新组合注册失败时**旧组合已经不在了**，
    /// 调用方（AppDelegate）负责把旧组合再注册回去，不能让用户按什么都没反应。
    @discardableResult
    func register(_ combo: HotKeyCombo) -> OSStatus {
        unregisterHotKey()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: hotKeyID)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
        }
        return status
    }

    func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    fileprivate func handle(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }
        var hkID = EventHotKeyID()
        let err = GetEventParameter(event,
                                    EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID),
                                    nil,
                                    MemoryLayout<EventHotKeyID>.size,
                                    nil,
                                    &hkID)
        guard err == noErr, hkID.signature == signature, hkID.id == hotKeyID else {
            return OSStatus(eventNotHandledErr)
        }
        let kind = GetEventKind(event)
        // 录音的启停和 UI 都在主线程；Carbon 回调在事件线程。
        DispatchQueue.main.async { [weak self] in
            if kind == UInt32(kEventHotKeyPressed) {
                self?.onPress?()
            } else if kind == UInt32(kEventHotKeyReleased) {
                self?.onRelease?()
            }
        }
        return noErr
    }

    deinit {
        unregisterHotKey()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}

private func handyHotKeyHandler(_ callRef: EventHandlerCallRef?,
                                _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    return manager.handle(event)
}
