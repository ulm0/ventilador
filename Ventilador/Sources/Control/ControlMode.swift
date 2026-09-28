import Foundation

enum ControlMode: Equatable {
    case automatic
    case manual(targets: [Fan.ID: Int])
    case profile(FanProfile.ID)

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .manual: return "Manual"
        case .profile(let id): return BuiltInProfiles.find(id)?.name ?? id
        }
    }

    func transitionKind(to next: ControlMode) -> ControlModeTransition {
        switch (self, next) {
        case (.automatic, .automatic): return .none
        case let (.manual(old), .manual(new)): return old == new ? .none : .targetsChanged
        case let (.profile(old), .profile(new)): return old == new ? .none : .modeChanged
        default: return .modeChanged
        }
    }
}

enum ControlModeTransition: Equatable {
    case none
    case modeChanged
    case targetsChanged
}
