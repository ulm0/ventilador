import Combine
import Foundation
import ServiceManagement

final class HelperInstallModel: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?
    private let installer: HelperInstalling

    init(installer: HelperInstalling) {
        self.installer = installer
        status = installer.status
    }

    func refresh() {
        status = installer.status
    }

    func enable() {
        do {
            try installer.register()
            errorMessage = nil
        } catch {
            errorMessage = describe(error)
        }
        refresh()
    }

    func openSettings() {
        installer.openSystemSettings()
    }
}
