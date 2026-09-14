import AppKit

struct FinderJumpScreen: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
}

enum FinderJumpOverlayLayout {
    static func frame(targetAXFrame: CGRect, screens: [FinderJumpScreen], primaryScreenHeight: CGFloat) -> CGRect? {
        guard targetAXFrame.width > 0, targetAXFrame.height > 0,
              [targetAXFrame.minX, targetAXFrame.minY, targetAXFrame.width, targetAXFrame.height, primaryScreenHeight].allSatisfy(\.isFinite) else { return nil }
        let target = CGRect(x: targetAXFrame.minX, y: primaryScreenHeight - targetAXFrame.maxY,
                            width: targetAXFrame.width, height: targetAXFrame.height)
        guard let screen = screens.max(by: {
            area($0.frame.intersection(target)) < area($1.frame.intersection(target))
        }), area(screen.frame.intersection(target)) > 0 else { return nil }
        let available = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = CGSize(width: min(520, available.width), height: 44)
        guard size.width >= 240, available.height >= size.height else { return nil }
        let x = min(max(target.midX - size.width / 2, available.minX), available.maxX - size.width)
        for y in [target.minY - size.height - 6, target.maxY + 6] {
            let result = CGRect(origin: CGPoint(x: x, y: y), size: size)
            if available.contains(result) { return result }
        }
        return nil
    }

    private static func area(_ frame: CGRect) -> CGFloat { frame.isNull ? 0 : frame.width * frame.height }
}

@MainActor
protocol FinderJumpOverlayPresenting: AnyObject {
    var onActivate: (() -> Void)? { get set }
    func show(directory: URL, target: FinderJumpTarget, shortcutAvailable: Bool, navigating: Bool)
    func hide()
}

@MainActor
final class FinderJumpOverlay: FinderJumpOverlayPresenting {
    var onActivate: (() -> Void)?
    private var panel: FinderJumpPanel?
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "⌃G")
    private var button: FinderJumpOverlayButton?

    func show(directory: URL, target: FinderJumpTarget, shortcutAvailable: Bool, navigating: Bool) {
        let screens = NSScreen.screens
        guard let primary = screens.first,
              let frame = FinderJumpOverlayLayout.frame(targetAXFrame: target.frame,
                  screens: screens.map { FinderJumpScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) },
                  primaryScreenHeight: primary.frame.maxY) else { hide(); return }
        if panel == nil { makePanel() }
        nameLabel.stringValue = "\(directory.lastPathComponent.isEmpty ? directory.path : directory.lastPathComponent)（Finder）"
        pathLabel.stringValue = (directory.path as NSString).abbreviatingWithTildeInPath
        shortcutLabel.stringValue = navigating ? "…" : shortcutAvailable ? "⌃G" : ""
        button?.isEnabled = !navigating
        button?.toolTip = "前往 \(directory.path)"
        button?.setAccessibilityLabel("前往 Finder 目录：\(directory.path)")
        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() {
        let panel = FinderJumpPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false; panel.level = .floating
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true
        panel.canHide = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        let material = NSVisualEffectView()
        material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = 10; material.layer?.masksToBounds = true
        panel.contentView = material
        let button = FinderJumpOverlayButton(title: "", target: self, action: #selector(activate))
        button.isBordered = false; button.focusRingType = .none
        button.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(button)
        let icon = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        pathLabel.font = .systemFont(ofSize: 10.5); pathLabel.textColor = .secondaryLabelColor
        for label in [nameLabel, pathLabel] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        shortcutLabel.font = .systemFont(ofSize: 12); shortcutLabel.textColor = .secondaryLabelColor
        let text = NSStackView(views: [nameLabel, pathLabel])
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 1
        let row = NSStackView(views: [icon, text, shortcutLabel])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(row)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: material.leadingAnchor), button.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            button.topAnchor.constraint(equalTo: material.topAnchor), button.bottomAnchor.constraint(equalTo: material.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12), row.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: button.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20), shortcutLabel.widthAnchor.constraint(equalToConstant: 28)
        ])
        self.panel = panel; self.button = button
    }

    @objc private func activate() { onActivate?() }
}

final class FinderJumpPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FinderJumpOverlayButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // 标签和 stack view 覆盖整行时仍把首击交给按钮。
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
}
