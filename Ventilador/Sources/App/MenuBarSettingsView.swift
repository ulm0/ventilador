import SwiftUI

struct MenuBarSettingsView: View {
    @ObservedObject var settings: MenuBarSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Menu bar").font(.headline)
            Toggle("CPU temperature", isOn: $settings.showCPUTemperature)
            Toggle("GPU temperature", isOn: $settings.showGPUTemperature)
            Toggle("Fan speed", isOn: $settings.showFanSpeed)
            Picker("Unit", selection: $settings.unit) {
                ForEach(TemperatureUnit.allCases) { unit in Text(unit.label).tag(unit) }
            }
            .pickerStyle(.segmented)
        }
        .toggleStyle(.checkbox)
    }
}
