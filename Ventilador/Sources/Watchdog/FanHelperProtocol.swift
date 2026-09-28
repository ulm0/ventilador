import Foundation
import os
import Security

enum HelperConstants {
    static let appBundleIdentifier = "com.ulm0.ventilador"
    static let machServiceName = "com.ulm0.ventilador.helper"
    static let plistName = "com.ulm0.ventilador.helper.plist"
    static let heartbeatTimeout: TimeInterval = 3
    /// Syntactically valid, never satisfiable: used when the app's signature can't be read (fail closed).
    static let denyAllRequirement = "identifier \"\(appBundleIdentifier)\" and !identifier \"\(appBundleIdentifier)\""

    /// The app bundle that embeds this helper at Contents/MacOS/.
    static func containingApp(ofHelperAt executable: URL?) -> URL? {
        executable?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Who may command the root helper. A Team-ID-signed helper accepts only the app identifier signed by the
    /// same team. An ad-hoc helper (local builds) pins its containing app's designated requirement — that
    /// exact build. Evaluated per connection, so a rebuilt app is accepted without restarting the helper.
    static func clientRequirement(forAppAt app: URL?, helperTeam: String? = ownTeamIdentifier()) -> String {
        if let helperTeam {
            return "anchor apple generic and identifier \"\(appBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(helperTeam)\""
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard let app,
              SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text
        else {
            Logger(subsystem: machServiceName, category: "security")
                .fault("Could not read the app's signature at \(app?.path ?? "nil", privacy: .public); refusing all clients")
            return denyAllRequirement
        }
        return text as String
    }

    /// The Team ID this process is signed with, or nil when ad-hoc signed.
    static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        SecCodeCopySelf([], &code)
        code.map { _ = SecCodeCopyStaticCode($0, [], &staticCode) }
        staticCode.map { _ = SecCodeCopySigningInformation($0, SecCSFlags(rawValue: kSecCSSigningInformation), &info) }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// Heartbeat replies, as plain integers so they cross XPC unchanged.
enum HeartbeatReply {
    static let noOverride = 0
    static let active = 1
    static let revertPending = 2
}

/// XPC interface of the privileged helper — the only process that writes fan SMC keys.
@objc protocol FanHelperProtocol {
    /// Replies with an error message, or nil on success. The helper re-clamps every request.
    func setTargetRPM(fanID: String, rpm: Int, reply: @escaping (String?) -> Void)
    func revertToAutomatic(reply: @escaping (String?) -> Void)
    /// Replies a HeartbeatReply value for the caller's override.
    func heartbeat(reply: @escaping (Int) -> Void)
}
