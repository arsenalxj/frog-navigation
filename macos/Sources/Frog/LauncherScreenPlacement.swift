import AppKit

struct LauncherDisplay: Equatable {
    let id: UInt32
    let frame: CGRect
    let visibleFrame: CGRect

    init(id: UInt32, frame: CGRect, visibleFrame: CGRect? = nil) {
        self.id = id; self.frame = frame; self.visibleFrame = visibleFrame ?? frame
    }

    init?(_ screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        self.init(id: number.uint32Value, frame: screen.frame, visibleFrame: screen.visibleFrame)
    }
}

struct LauncherScreenPlacement {
    private var previous: LauncherDisplay?

    mutating func update(visible: Bool, requestedID: UInt32?, mouse: CGPoint,
                         displays: [LauncherDisplay], fallbackID: UInt32?) -> LauncherDisplay? {
        let requested = requestedID.flatMap { id in displays.first { $0.id == id } }
        let underMouse = displays.first { NSMouseInRect(mouse, $0.frame, false) }
        let fallback = fallbackID.flatMap { id in displays.first { $0.id == id } }
        guard let target = requested ?? underMouse ?? fallback ?? displays.first else { return nil }
        // 收起动画中窗口仍可见；目标屏幕或布局变化时也必须立即更新。
        guard !visible || previous != target else { return nil }
        previous = target
        return target
    }
}
