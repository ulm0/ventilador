import Foundation

enum FanControlError: Error, Equatable, LocalizedError {
    case sensorUnavailable(detail: String)
    case writeFailed(detail: String)
    case unsupportedHardware
    /// A complete message already phrased by the privileged helper.
    case helperRejected(message: String)

    var errorDescription: String? {
        switch self {
        case .sensorUnavailable(let detail): return "Sensor data unavailable: \(detail)"
        case .writeFailed(let detail): return "Fan control failed: \(detail)"
        case .unsupportedHardware: return "This Mac's fan hardware is not supported."
        case .helperRejected(let message): return message
        }
    }
}

func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}
