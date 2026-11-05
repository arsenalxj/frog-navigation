import AppKit
import Combine
import ServiceManagement

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var changing = false
    @Published var error: String?
    private let isolated: Bool

    init(isolated: Bool = false) {
        self.isolated = isolated
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ value: Bool) {
        guard !isolated else {
            error = "隔离运行不修改系统登录项，请在正式安装的应用中设置。"
            return
        }
        guard !changing else { return }
        changing = true
        error = nil
        Task {
            do {
                if value { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch {
                self.error = "系统未能\(value ? "启用" : "停用")登录启动：\(error.localizedDescription)。请将青蛙导航安装到“应用程序”后重试，或在系统登录项中手动设置。"
            }
            refresh()
            changing = false
        }
    }

    func openSettings() {
        guard !isolated else {
            error = "隔离运行不打开系统登录项设置。"
            return
        }
        SMAppService.openSystemSettingsLoginItems()
    }
}
