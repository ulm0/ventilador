import Combine
import Foundation

/// Polls sensors, publishes what the popover shows, and forwards each poll to the ControlModeStore.
final class StatusViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case ok
        case noFans
        case unavailable(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var fans: [Fan] = []
    @Published private(set) var temperatures: [TemperatureReading] = []
    private let controller: FanControlling
    private let store: ControlModeStore
    private let interval: TimeInterval
    private let clock: () -> Date
    private var timer: Timer?

    init(controller: FanControlling, store: ControlModeStore, interval: TimeInterval = 1, clock: @escaping () -> Date = Date.init) {
        self.controller = controller
        self.store = store
        self.interval = interval
        self.clock = clock
    }

    var isPolling: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        refresh()
        let model = MainThreadRef(self)
        let timer = Timer(timeInterval: interval, repeats: true) { _ in model.value?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Never shows stale or fabricated values: a failed or stale read replaces them with an error state.
    func refresh() {
        do {
            let fans = try controller.discoverFans()
            let readings = try controller.readTemperatures()
            if let stale = readings.first(where: { isStale(readAt: $0.readAt, asOf: clock()) }) {
                throw FanControlError.sensorUnavailable(detail: "\(stale.sourceLabel) reading is stale")
            }
            self.fans = fans
            temperatures = readings
            state = fans.isEmpty ? .noFans : .ok
            store.ingest(fans: fans, temperatures: readings, hardwareManual: controller.detectsConflictingController())
        } catch {
            fans = []
            temperatures = []
            state = .unavailable(describe(error))
            store.ingestFailure(error)
        }
    }
}
