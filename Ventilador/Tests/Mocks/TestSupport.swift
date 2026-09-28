@testable import Ventilador
import AppKit
import ServiceManagement
import SwiftUI
import XCTest

final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func advance(_ seconds: TimeInterval) { now += seconds }
    var read: () -> Date { { [unowned self] in self.now } }
}

extension Fan {
    static func stub(id: String = "0", currentRPM: Int = 1200, min: Int = 1000, max: Int = 4900, target: Int? = nil) -> Fan {
        Fan(id: id, label: "Fan \((Int(id) ?? 0) + 1)", currentRPM: currentRPM, minSafeRPM: min, maxSafeRPM: max, targetRPM: target)!
    }
}

/// Runs the main run loop in event-tracking mode (what a slider drag or open menu does) for `seconds`.
func spinTrackingRunLoop(for seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
    }
}

func temporaryLogURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("VentiladorTests-\(UUID().uuidString)")
        .appendingPathComponent("events.jsonl")
}

/// Spins the run loop until `condition` holds or the timeout passes.
@discardableResult
func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

/// Windows kept alive so rendered views keep observing (e.g. notification subscriptions) until the run ends.
nonisolated(unsafe) private var liveWindows: [NSWindow] = []

/// Hosts a SwiftUI view in an offscreen window so its whole body is evaluated.
@discardableResult
@MainActor func render<V: View>(_ view: V, keepAlive: Bool = false) -> NSView {
    let host = NSHostingView(rootView: view.frame(width: 360))
    host.sizingOptions = [] // keep the window fixed; letting content resize it loops constraint passes
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 1200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    if keepAlive { liveWindows.append(window) }
    return host
}

final class MockHeartbeat: HeartbeatEmitting {
    var onOverrideLost: ((HeartbeatStatus) -> Void)?
    private(set) var isRunning = false
    private(set) var startCount = 0

    func start() {
        startCount += 1
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}

final class MockHelperInstaller: HelperInstalling {
    var status: SMAppService.Status = .notRegistered
    var statusAfterRegister: SMAppService.Status = .requiresApproval
    var registerError: Error?
    private(set) var registerCount = 0
    private(set) var openCount = 0

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = statusAfterRegister
    }

    func openSystemSettings() {
        openCount += 1
    }
}

/// App object graph over a MockSMCController with a controllable clock.
struct Harness {
    let smc: MockSMCController
    let heartbeat = MockHeartbeat()
    let installer = MockHelperInstaller()
    let clock = TestClock()
    let env: AppEnvironment

    init(fans: [Fan] = [.stub()], temperatures: [String: Double] = ["CPU": 60], helper: SMAppService.Status = .enabled, pollInterval: TimeInterval = 1) {
        smc = MockSMCController(fans: fans)
        installer.status = helper
        env = AppEnvironment(controller: smc, heartbeat: heartbeat, log: ControlEventLog(fileURL: temporaryLogURL()),
                             installer: installer, pollInterval: pollInterval, clock: clock.read)
        setTemperatures(temperatures)
    }

    var store: ControlModeStore { env.store }
    var status: StatusViewModel { env.status }
    var log: [ControlEventLogEntry] { env.log.entries }

    /// Fresh readings stamped "now"; pass `age` to make them old.
    func setTemperatures(_ values: [String: Double], age: TimeInterval = 0) {
        smc.temperatures = values.sorted { $0.key < $1.key }
            .map { TemperatureReading(sourceLabel: $0.key, celsius: $0.value, readAt: clock.now - age) }
    }
}
