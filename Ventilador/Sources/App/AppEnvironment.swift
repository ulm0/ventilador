import AppKit
import Foundation

/// Wires the object graph once per launch; tests build it with mocks through `init`.
final class AppEnvironment {
    let log: ControlEventLog
    let store: ControlModeStore
    let status: StatusViewModel
    let manual: ManualControlModel
    let helperInstall: HelperInstallModel
    let menuBar: MenuBarSettings
    private var observers: [NSObjectProtocol] = []

    static var isHostingTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Test runs must never flash a menu-bar icon on the user's screen.
    static var showsMenuBarIcon: Bool { !isHostingTests }

    init(controller: FanControlling, heartbeat: HeartbeatEmitting, log: ControlEventLog, installer: HelperInstalling,
         menuBar: MenuBarSettings = MenuBarSettings(), pollInterval: TimeInterval = 1, clock: @escaping () -> Date = Date.init) {
        self.log = log
        store = ControlModeStore(controller: controller, log: log, heartbeat: heartbeat, clock: clock)
        status = StatusViewModel(controller: controller, store: store, interval: pollInterval, clock: clock)
        manual = ManualControlModel(store: store, status: status)
        helperInstall = HelperInstallModel(installer: installer)
        self.menuBar = menuBar
    }

    /// The app's entry point. When hosting XCTest the app stays inert — no SMC, no polling, no helper,
    /// no writes to the user's real event log — so tests only ever exercise what they build themselves.
    static func launch(hostingTests: Bool = isHostingTests, helper: HelperClient = .privileged(), logURL: URL = ControlEventLog.defaultURL,
                       installer: HelperInstalling = SMAppServiceHelperInstaller()) -> AppEnvironment {
        guard !hostingTests else {
            let scratchLog = FileManager.default.temporaryDirectory.appendingPathComponent("Ventilador-test-host/events.jsonl")
            return live(openConnection: { throw FanControlError.unsupportedHardware }, helper: helper, logURL: scratchLog, installer: InertHelperInstaller())
        }
        let environment = live(helper: helper, logURL: logURL, installer: installer)
        environment.start()
        return environment
    }

    static func live(openConnection: () throws -> SMCConnection = { try IOKitSMCConnection() }, helper: HelperClient,
                     logURL: URL, installer: HelperInstalling) -> AppEnvironment {
        let reader = (try? openConnection()).map { IOKitSMCController(connection: $0) as FanControlling } ?? UnavailableFanController()
        return AppEnvironment(controller: PrivilegedFanController(reader: reader, helper: helper),
                              heartbeat: HeartbeatEmitter(beat: helper.heartbeat),
                              log: ControlEventLog(fileURL: logURL),
                              installer: installer)
    }

    func start(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter, app: NotificationCenter = .default) {
        store.reconcileLog()
        status.start()
        observers = [
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [store] _ in store.systemDidWake() },
            app.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [store] _ in store.appWillTerminate() },
        ]
    }
}
