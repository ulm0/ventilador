import Foundation
import ServiceManagement

protocol HelperInstalling {
    var status: SMAppService.Status { get }
    func register() throws
    func openSystemSettings()
}

/// Stands in while the app hosts tests: never talks to ServiceManagement, whose status queries can block.
struct InertHelperInstaller: HelperInstalling {
    var status: SMAppService.Status { .notFound }
    func register() throws { throw FanControlError.unsupportedHardware }
    func openSystemSettings() {}
}

/// Registers the bundled LaunchDaemon; macOS then asks the user to approve it in Login Items.
struct SMAppServiceHelperInstaller: HelperInstalling {
    private let service: SMAppService
    private let registerService: (SMAppService) throws -> Void
    private let openSettings: () -> Void

    init(plistName: String = HelperConstants.plistName,
         registerService: @escaping (SMAppService) throws -> Void = registerDaemon,
         openSettings: @escaping () -> Void = openLoginItemsSettings) {
        service = .daemon(plistName: plistName)
        self.registerService = registerService
        self.openSettings = openSettings
    }

    var status: SMAppService.Status { service.status }

    func register() throws {
        try registerService(service)
    }

    func openSystemSettings() {
        openSettings()
    }
}
