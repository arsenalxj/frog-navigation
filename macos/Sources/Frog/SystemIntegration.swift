import AppKit
import Combine
import CoreImage
import ImageIO
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var changing = false
    @Published var error: String?

    init() { refresh() }
    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }
    func setEnabled(_ value: Bool) {
        guard !changing else { return }
        changing = true; error = nil
        Task {
            do {
                if value { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch {
                self.error = "系统未能\(value ? "启用" : "停用")登录启动：\(error.localizedDescription)。请将青蛙导航安装到“应用程序”后重试，或在系统登录项中手动添加。"
            }
            refresh(); changing = false
        }
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum WallpaperLoader {
    @MainActor
    static func load(for screen: NSScreen) async -> NSImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1400,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            let input = CIImage(cgImage: thumbnail)
            let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24]).cropped(to: input.extent)
            return CIContext(options: [.cacheIntermediates: false]).createCGImage(blurred, from: input.extent)
        }.value
        return image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
}

extension LauncherModel {
    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择青蛙导航数据目录"
        panel.prompt = "使用此目录"
        panel.message = "选中目录内的 bookmarks.json 将作为书签数据。空目录会保存当前已有书签。"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.directoryURL = store.directory
        runPanel(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let previous = self.store.directory
                    try await self.store.switchDirectory(url)
                    if self.store.directory != previous {
                        self.resetAfterReplacingData(); self.notify("已切换数据目录")
                    }
                } catch { self.notify(error.localizedDescription) }
            }
        }
    }
    func exportBackup() {
        let panel = NSSavePanel()
        panel.title = "另存青蛙导航备份"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "青蛙导航-Bookmarks-\(formatter.string(from: Date())).json"
        runPanel(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do { try await self.store.exportBackup(to: url); self.notify("备份已保存至 \(url.path)") }
                catch { self.notify(error.localizedDescription) }
            }
        }
    }
    func restoreBackup() {
        let panel = NSOpenPanel()
        panel.title = "恢复青蛙导航备份"
        panel.prompt = "恢复备份"
        panel.message = "恢复后将替换当前数据目录中的全部书签和分组。"
        panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        runPanel(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await self.store.restoreBackup(from: url)
                    self.resetAfterReplacingData()
                    self.notify("已恢复 \(self.store.document.bookmarks.count) 个书签和 \(self.store.document.groups.count) 个文件夹")
                } catch { self.notify(error.localizedDescription) }
            }
        }
    }
    private func runPanel(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        withSystemPanel?(true)
        let done: (NSApplication.ModalResponse) -> Void = { response in
            self.withSystemPanel?(false)
            completion(response)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) }
        else { panel.begin(completionHandler: done) }
    }
}
