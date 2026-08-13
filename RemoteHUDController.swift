import AppKit

/// AppleTV-style on-screen HUD overlay.
///
/// A borderless, floating, non-activating panel centered on the main screen
/// that fades in, holds briefly, and fades out. Used for connect / disconnect /
/// low-battery events so the user gets an immediate visible signal even when
/// system notifications are denied or muted.
final class RemoteHUDController {
    enum Kind {
        case connected
        case disconnected
        case lowBattery
    }

    private final class HUDPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let panel: HUDPanel
    private let visualEffect: NSVisualEffectView
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var hideWorkItem: DispatchWorkItem?

    init() {
        let size = NSSize(width: 320, height: 132)
        panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.alphaValue = 0

        visualEffect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 18
        visualEffect.layer?.masksToBounds = true

        panel.contentView = visualEffect

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .labelColor

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        visualEffect.addSubview(iconView)
        visualEffect.addSubview(titleLabel)
        visualEffect.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
            iconView.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 18),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -16),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -16),
        ])
    }

    /// Present a HUD event. Coalesces with any in-flight HUD by replacing it.
    func present(kind: Kind, title: String, subtitle: String?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.present(kind: kind, title: title, subtitle: subtitle) }
            return
        }

        iconView.image = image(for: kind)
        iconView.contentTintColor = tint(for: kind)
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty

        centerOnScreen()

        hideWorkItem?.cancel()

        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        let hold: TimeInterval = kind == .lowBattery ? 2.4 : 1.6
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    func dismissImmediately() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.dismissImmediately() }
            return
        }
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    private func dismiss() {
        hideWorkItem = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if self.panel.alphaValue == 0 { self.panel.orderOut(nil) }
        })
    }

    private func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func image(for kind: Kind) -> NSImage? {
        let symbol: String
        switch kind {
        case .connected: symbol = "dot.radiowaves.left.and.right"
        case .disconnected: symbol = "antenna.radiowaves.left.and.right.slash"
        case .lowBattery: symbol = "battery.25"
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
            return image.withSymbolConfiguration(config)
        }
        return nil
    }

    private func tint(for kind: Kind) -> NSColor {
        switch kind {
        case .connected: return .systemGreen
        case .disconnected: return .systemRed
        case .lowBattery: return .systemOrange
        }
    }
}
