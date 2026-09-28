import Foundation

/// Root LaunchDaemon entry point (registered by the app via SMAppService). Process glue only: the wiring
/// lives in HelperRuntime and the decisions in HelperService / WatchdogCore, all covered by the app's tests.
@main
enum HelperMain {
    static func main() {
        let connection: SMCConnection
        do {
            connection = try IOKitSMCConnection()
        } catch {
            FileHandle.standardError.write(Data("fan helper: \(describe(error))\n".utf8))
            exit(EXIT_FAILURE)
        }
        let app = HelperConstants.containingApp(ofHelperAt: Bundle.main.executableURL)
        let runtime = HelperRuntime(service: HelperService(controller: IOKitSMCController(connection: connection)),
                                    listener: NSXPCListener(machServiceName: HelperConstants.machServiceName),
                                    clientRequirement: { HelperConstants.clientRequirement(forAppAt: app) },
                                    exit: { exit(EXIT_SUCCESS) })
        withExtendedLifetime(runtime) { dispatchMain() }
    }
}
