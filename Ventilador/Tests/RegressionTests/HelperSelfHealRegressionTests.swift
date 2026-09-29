@testable import Ventilador
import ServiceManagement
import SwiftUI
import XCTest

/// After an update the root helper process (and the registration macOS keeps for it) still belongs to the old
/// build. The app must notice at launch and reinstall the helper by itself.
@MainActor final class HelperSelfHealRegressionTests: XCTestCase {
    private final class Builds: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Int?]
        private(set) var asked = 0
        init(_ answers: [Int?]) { self.answers = answers }
        func next() -> Int? {
            lock.lock()
            defer { lock.unlock() }
            asked += 1
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
    }

    private func model(_ installer: MockHelperInstaller, _ builds: Builds, expected: Int = 3) -> HelperInstallModel {
        HelperInstallModel(installer: installer, expectedBuild: expected, probe: builds.next)
    }

    private func enabledInstaller() -> MockHelperInstaller {
        let installer = MockHelperInstaller()
        installer.status = .enabled
        installer.statusAfterRegister = .enabled
        return installer
    }

    // MARK: launch behaviour

    func test_staleHelperIsReinstalledAtLaunch() async {
        let installer = enabledInstaller()
        let model = model(installer, Builds([2, 3]))

        await model.selfHeal()

        XCTAssertEqual(installer.unregisterCount, 1)
        XCTAssertEqual(installer.registerCount, 1)
        XCTAssertEqual(model.status, .enabled)
        XCTAssertFalse(model.needsRepair)
        XCTAssertFalse(model.isRepairing)
    }

    func test_helperFromBeforeVersioningIsReinstalled() async {
        let installer = enabledInstaller()
        await model(installer, Builds([nil, 3])).selfHeal()
        XCTAssertEqual(installer.registerCount, 1, "no answer to the version question = an old or dead helper")
    }

    func test_currentHelperIsLeftAlone() async {
        let installer = enabledInstaller()
        await model(installer, Builds([3])).selfHeal()
        XCTAssertEqual(installer.unregisterCount + installer.registerCount, 0)
    }

    func test_notEnabledHelperIsNeverProbedOrTouched() async {
        for status in [SMAppService.Status.notRegistered, .requiresApproval, .notFound] {
            let installer = MockHelperInstaller()
            installer.status = status
            let builds = Builds([1])
            await model(installer, builds).selfHeal()
            XCTAssertEqual(installer.unregisterCount + installer.registerCount, 0, "\(status)")
            XCTAssertEqual(builds.asked, 0, "\(status)")
        }
    }

    func test_withoutAProbeTheHelperIsAssumedCurrent() async {
        let installer = enabledInstaller()
        await HelperInstallModel(installer: installer).selfHeal()
        XCTAssertEqual(installer.unregisterCount, 0)
    }

    // MARK: repair outcomes

    func test_repairStillMismatchedOffersTheRepairButton() async {
        let installer = enabledInstaller()
        let model = model(installer, Builds([2]))

        await model.selfHeal()

        XCTAssertEqual(installer.registerCount, 1, "one automatic attempt, never a loop")
        XCTAssertTrue(model.needsRepair)
    }

    func test_repairNeedingApprovalAsksForApproval() async {
        let installer = enabledInstaller()
        installer.statusAfterRegister = .requiresApproval
        let builds = Builds([2])
        let model = model(installer, builds)

        await model.selfHeal()

        XCTAssertEqual(model.status, .requiresApproval)
        XCTAssertFalse(model.needsRepair)
        XCTAssertEqual(builds.asked, 1, "nothing to probe until the user approves")
    }

    func test_repairIgnoresAnUnregisterErrorAndReportsARegisterError() async {
        let installer = enabledInstaller()
        installer.unregisterError = FanControlError.helperRejected(message: "not registered")
        installer.registerError = FanControlError.helperRejected(message: "denied")
        let model = model(installer, Builds([2]))

        await model.repair()

        XCTAssertEqual(installer.unregisterCount, 1)
        XCTAssertEqual(model.errorMessage, "denied")
        XCTAssertFalse(model.needsRepair)
    }

    func test_repairButtonClearsTheOfferOnceTheHelperAnswers() async {
        let installer = enabledInstaller()
        let model = model(installer, Builds([2, 2, 3]))
        await model.selfHeal()
        XCTAssertTrue(model.needsRepair)

        await model.repair()

        XCTAssertFalse(model.needsRepair)
        XCTAssertEqual(installer.registerCount, 2)
    }

    func test_repairButtonRunsInTheBackground() async {
        let installer = enabledInstaller()
        let model = model(installer, Builds([3]))

        model.repairInBackground()
        while installer.registerCount == 0 { await Task.yield() }
        while model.isRepairing { await Task.yield() }

        XCTAssertEqual(installer.unregisterCount, 1)
        XCTAssertFalse(model.needsRepair)
    }

    // MARK: wiring and views

    func test_popoverOffersRepairOnlyWhenNeeded() async {
        let h = Harness(helper: .enabled)
        h.installer.statusAfterRegister = .enabled
        let env = AppEnvironment(controller: h.smc, heartbeat: h.heartbeat, log: ControlEventLog(fileURL: temporaryLogURL()),
                                 installer: h.installer, expectedBuild: 3, probe: { 2 }, clock: h.clock.read)
        env.status.refresh()
        XCTAssertFalse(StatusView(environment: env).sections.contains(.repairHelper))

        await env.helperInstall.selfHeal()

        XCTAssertTrue(StatusView(environment: env).sections.contains(.repairHelper))
        render(StatusView(environment: env))
    }

    func test_installerUnregistersTheBundledService() async throws {
        var unregistered = 0
        let installer = SMAppServiceHelperInstaller(registerService: { _ in }, unregisterService: { _ in unregistered += 1 }, openSettings: {})
        try await installer.unregister()
        XCTAssertEqual(unregistered, 1)
        do {
            try await InertHelperInstaller().unregister()
            XCTFail("inert installer must not unregister")
        } catch {}
    }

    func test_buildNumberIsReadFromTheAppBundle() {
        XCTAssertGreaterThan(HelperConstants.build(ofAppAt: Bundle.main.bundleURL), 0)
        XCTAssertEqual(HelperConstants.build(ofAppAt: nil), 0)
        XCTAssertEqual(HelperConstants.build(ofAppAt: URL(fileURLWithPath: "/nonexistent.app")), 0)
    }

    // MARK: over real XPC

    func test_helperReportsItsBuildOverXPC() {
        let xpc = XPCHarness(build: 3)
        XCTAssertEqual(xpc.makeClient().helperBuild(), 3)
        XCTAssertEqual(xpc.makeClient().probeBuild(), 3)
        xpc.service.version { XCTAssertEqual($0, 3) }
    }

    func test_deadOrSilentHelperReportsNoBuild() {
        let xpc = XPCHarness(build: 3)
        let client = xpc.makeClient()
        xpc.stopListening()
        XCTAssertNil(client.helperBuild())

        let silent = SilentHelper()
        let silentClient = HelperClient(callTimeout: 0.3, cooldown: 5) { silent.makeConnection() }
        XCTAssertNil(silentClient.probeBuild())
        XCTAssertEqual(silent.connectionsAccepted, 1)
        let start = Date()
        XCTAssertNil(silentClient.helperBuild())
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.3, "the probe left the app's own client out of its cooldown")
    }
}
