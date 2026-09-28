@testable import Ventilador
import XCTest

/// The production composition root, tested explicitly rather than credited from the test host's launch.
@MainActor final class AppLaunchRegressionTests: XCTestCase {
    /// TESTS-4: while hosting tests the app touches no hardware, no helper and not the user's real log.
    func test_testHostLaunchIsInert() {
        let env = AppEnvironment.launch(hostingTests: true, helper: .privileged(machServiceName: "com.ulm0.ventilador.test.absent"),
                                        installer: MockHelperInstaller())
        XCTAssertFalse(env.status.isPolling)
        XCTAssertNotEqual(env.log.fileURL, ControlEventLog.defaultURL)
        XCTAssertEqual(env.helperInstall.status, .notFound, "no ServiceManagement query while hosting tests")
        env.status.refresh()
        XCTAssertEqual(env.status.state, .unavailable("This Mac's fan hardware is not supported."))
    }

    func test_inertInstallerNeverRegistersOrOpensSettings() {
        let installer = InertHelperInstaller()
        XCTAssertThrowsError(try installer.register())
        installer.openSystemSettings()
        XCTAssertEqual(installer.status, .notFound)
    }

    /// Production launch: real AppleSMC (read-only) and polling from the first second.
    func test_productionLaunchStartsPollingTheRealSensors() {
        let xpc = XPCHarness()
        let env = AppEnvironment.launch(hostingTests: false, helper: xpc.makeClient(), logURL: temporaryLogURL(), installer: MockHelperInstaller())
        defer { env.status.stop() }

        XCTAssertTrue(env.status.isPolling)
        XCTAssertNotEqual(env.status.state, .loading, "the first poll happens at launch")
    }

    /// TESTS-5: the live object graph wires the heartbeat to the helper, so a healthy app keeps its override.
    func test_liveWiring_keepsAnOverrideAliveThroughRealHeartbeats() {
        let xpc = XPCHarness()
        let env = AppEnvironment.live(openConnection: { xpc.smc.readOnlyView() }, helper: xpc.makeClient(), logURL: temporaryLogURL(),
                                      installer: MockHelperInstaller())
        env.status.refresh()
        env.store.setManual(targets: ["0": 3000])
        XCTAssertEqual(xpc.smc.value("F0Md"), 1)

        xpc.helperClock.advance(2.5)
        RunLoop.current.run(until: Date().addingTimeInterval(HeartbeatEmitter.defaultInterval + 0.3))
        xpc.helperClock.advance(2.5)
        xpc.service.tick()

        XCTAssertTrue(xpc.service.overrideActive, "the live heartbeat reached the helper in time")
        env.store.revertToAutomatic()
        XCTAssertEqual(xpc.smc.value("F0Md"), 0)
    }

    /// TESTS-9: the bundled launchd plist matches what the app registers and the helper serves.
    func test_bundledDaemonPlistMatchesTheHelper() throws {
        let plistURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(HelperConstants.plistName)")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: plistURL) as? [String: Any])

        XCTAssertEqual(plist["Label"] as? String, HelperConstants.machServiceName)
        XCTAssertEqual((plist["MachServices"] as? [String: Bool])?[HelperConstants.machServiceName], true)
        let program = try XCTUnwrap(plist["BundleProgram"] as? String)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent(program).path))
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], [try XCTUnwrap(Bundle.main.bundleIdentifier)])
    }
}
