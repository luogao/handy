import AppKit

/// 屏幕顶部的一句提示气泡。
///
/// 用非激活的 NSPanel 而不是 UNUserNotificationCenter：后者要求 app 在系统里
/// 注册通知，bundle 外的开发态直接不可用，而且会多一条「通知」权限记录。
/// 这个 panel 不抢焦点（nonactivatingPanel + orderFrontRegardless），
/// 用户正在输入框里打字也不会被打断。
///
/// 背景用纯色而不是 NSVisualEffectView：vibrancy 会跟着背后的窗口变亮变暗，
/// 浅色窗口下白字直接看不见（第一版就踩了）。固定深底白字在哪都读得出来。
final class HUD {
    private var panel: NSPanel?
    private var container: NSView?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, isError: Bool = false) {
        if Thread.isMainThread {
            present(text, isError: isError)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.present(text, isError: isError)
            }
        }
    }

    private func present(_ text: String, isError: Bool) {
        let panel = panel ?? makePanel()
        self.panel = panel
        label?.stringValue = text
        label?.textColor = isError ? NSColor.systemRed : NSColor.white

        let size = Self.size(for: text, maxWidth: 360)
        panel.setContentSize(size)
        // 面板复用时 contentView 不会自动按新尺寸重排子视图，这里显式摆一次。
        container?.frame = NSRect(origin: .zero, size: size)
        label?.frame = NSRect(x: 26, y: 14, width: size.width - 52, height: size.height - 28)
        position(panel)

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 2.8 : 1.5), execute: work)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 48),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .transient, .ignoresCycle]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 48))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.92).cgColor
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        label.frame = container.bounds.insetBy(dx: 26, dy: 14)
        label.autoresizingMask = [.width, .height]
        container.addSubview(label)

        panel.contentView = container
        self.container = container
        self.label = label
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.maxY - size.height - 28))
    }

    private static func size(for text: String, maxWidth: CGFloat) -> NSSize {
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth - 16, height: 0),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let width = min(maxWidth, ceil(bounds.width) + 16) + 52
        let height = ceil(bounds.height) + 28
        return NSSize(width: max(140, width), height: max(44, height))
    }
}
