import Combine
import Foundation

/// Slider drafts for manual control; applying hands the chosen RPM to the ControlModeStore.
final class ManualControlModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let fan: Fan
        var draft: Double
        var id: Fan.ID { fan.id }
        var range: ClosedRange<Double> { Double(fan.minSafeRPM)...Double(fan.maxSafeRPM) }
    }

    @Published var rows: [Row] = []
    @Published var allDraft: Double = 0
    private let store: ControlModeStore
    private var subscription: AnyCancellable?

    init(store: ControlModeStore, status: StatusViewModel) {
        self.store = store
        subscription = status.$fans.sink { [weak self] in self?.sync(fans: $0) }
    }

    var showsBulkControl: Bool { rows.count > 1 }

    /// Spans every fan's range; each fan is clamped to its own range when applied.
    var allRange: ClosedRange<Double> {
        guard let low = rows.map(\.range.lowerBound).min(), let high = rows.map(\.range.upperBound).max() else { return 0...1 }
        return low...high
    }

    /// Keeps in-progress drafts across polls; new fans start at their current speed.
    func sync(fans: [Fan]) {
        rows = fans.map { fan in Row(fan: fan, draft: rows.first { $0.id == fan.id }?.draft ?? Double(fan.currentRPM)) }
        if allDraft == 0, let first = fans.first { allDraft = Double(first.currentRPM) }
    }

    func apply(_ id: Fan.ID) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        store.setManual(targets: [id: Int(row.draft.rounded())])
    }

    func applyAll() {
        store.setManualForAll(rpm: Int(allDraft.rounded()))
    }

    func revert() {
        store.revertToAutomatic()
    }
}
