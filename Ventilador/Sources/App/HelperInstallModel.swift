import Combine
import Foundation
import ServiceManagement

final class HelperInstallModel: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRepairing = false
    /// The helper is registered but still doesn't answer as this app's build, even after a repair.
    @Published private(set) var needsRepair = false
    private let installer: HelperInstalling
    private let expectedBuild: Int
    private let probe: (@Sendable () -> Int?)?

    /// `probe` asks the running helper for its build; without one the helper is assumed current.
    init(installer: HelperInstalling, expectedBuild: Int = 0, probe: (@Sendable () -> Int?)? = nil) {
        self.installer = installer
        self.expectedBuild = expectedBuild
        self.probe = probe
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

    /// Run once per launch. An update replaces the app on disk but not the root helper process already
    /// running (or the registration macOS holds for it), so a registered helper that isn't this build is
    /// reinstalled here — no user action needed.
    @MainActor func selfHeal() async {
        refresh()
        guard status == .enabled, !(await helperIsCurrent()) else { return }
        await repair()
    }

    /// Unregister and register again. Fans return to automatic while the helper restarts.
    @MainActor func repair() async {
        isRepairing = true
        defer { isRepairing = false }
        try? await installer.unregister()
        enable()
        needsRepair = false
        if errorMessage == nil, status == .enabled { needsRepair = !(await helperIsCurrent()) }
    }

    /// The button action: the popover must not wait for the helper to restart.
    @MainActor func repairInBackground() {
        Task { await repair() }
    }

    @MainActor private func helperIsCurrent() async -> Bool {
        guard let probe else { return true }
        return await Task.detached(operation: probe).value == expectedBuild
    }

    func openSettings() {
        installer.openSystemSettings()
    }
}
