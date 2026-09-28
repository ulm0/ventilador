import SwiftUI

@main
struct VentiladorApp: App {
    private let environment = AppEnvironment.launch()

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(AppEnvironment.showsMenuBarIcon)) {
            StatusView(environment: environment)
        } label: {
            MenuBarLabel(environment: environment)
        }
        .menuBarExtraStyle(.window)
    }
}
