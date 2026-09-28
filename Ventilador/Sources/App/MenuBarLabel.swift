import SwiftUI

/// The menu bar item: a template SF Symbol (so it matches every other menu bar icon in light, dark and
/// tinted bars) plus the readings the user chose. The symbol fills while an override is active.
struct MenuBarLabel: View {
    @ObservedObject var status: StatusViewModel
    @ObservedObject var store: ControlModeStore
    @ObservedObject var settings: MenuBarSettings

    init(environment: AppEnvironment) {
        status = environment.status
        store = environment.store
        settings = environment.menuBar
    }

    static func symbolName(for mode: ControlMode) -> String {
        mode == .automatic ? "fan" : "fan.fill"
    }

    var text: String {
        settings.text(temperatures: status.temperatures, fans: status.fans)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Self.symbolName(for: store.mode))
            if !text.isEmpty {
                Text(text).monospacedDigit()
            }
        }
    }
}
