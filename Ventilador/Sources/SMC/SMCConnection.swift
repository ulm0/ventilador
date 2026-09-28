import Foundation
import IOKit

protocol SMCConnection: AnyObject {
    func call(_ input: SMCParamStruct) throws -> SMCParamStruct
}

final class IOKitSMCConnection: SMCConnection {
    private let connection: io_connect_t

    init(connection: io_connect_t) {
        self.connection = connection
    }

    convenience init(serviceName: String = "AppleSMC") throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(serviceName))
        guard service != IO_OBJECT_NULL else { throw FanControlError.unsupportedHardware }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = IO_OBJECT_NULL
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else {
            throw FanControlError.sensorUnavailable(detail: "cannot open \(serviceName) (IOKit error \(result))")
        }
        self.init(connection: connection)
    }

    deinit {
        IOServiceClose(connection)
    }

    func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(connection, SMCParamStruct.selector, &input, MemoryLayout<SMCParamStruct>.stride, &output, &outputSize)
        guard result == kIOReturnSuccess else {
            throw FanControlError.sensorUnavailable(detail: "SMC call failed (IOKit error \(result))")
        }
        return output
    }
}
