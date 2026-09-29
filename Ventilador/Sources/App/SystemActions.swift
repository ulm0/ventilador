import AppKit
import ServiceManagement

// The only code no automated test may execute: each call hands control to macOS — registering a
// real root daemon, opening System Settings, or quitting the (test host) process.
// scripts/check-coverage.sh exempts exactly this file; every other Sources/ file must stay at 100%.

func registerDaemon(_ service: SMAppService) throws {
    try service.register()
}

func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
}

func quitApplication() {
    // Called from a button action, which always runs on the main thread.
    MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
}
