import AppKit
import SwiftUI

enum StatusSection: Hashable {
    case conflict
    case readingSensors
    case noFan
    case error(String)
    case fan(label: String, value: String)
    case temperature(label: String, value: String)
    case manualControls
    case profiles
    case approveHelper
    case repairHelper
    case enableHelper
    case helperError(String)
    case clampNotice(String)
    case lastError(String)
}

struct StatusView: View {
    @ObservedObject var status: StatusViewModel
    @ObservedObject var store: ControlModeStore
    @ObservedObject var helper: HelperInstallModel
    let manual: ManualControlModel
    let log: ControlEventLog
    let menuBar: MenuBarSettings
    let quit: () -> Void

    init(environment: AppEnvironment, quit: @escaping () -> Void = quitApplication) {
        status = environment.status
        store = environment.store
        helper = environment.helperInstall
        manual = environment.manual
        log = environment.log
        menuBar = environment.menuBar
        self.quit = quit
    }

    /// What the popover shows, in order. Kept apart from rendering so every spec state is asserted directly.
    var sections: [StatusSection] {
        var result: [StatusSection] = store.conflictDetected ? [.conflict] : []
        switch status.state {
        case .loading: result.append(.readingSensors)
        case .noFans: result += [.noFan] + temperatureRows
        case .unavailable(let message): result.append(.error(message))
        case .ok: result += fanRows + temperatureRows + helperSections
        }
        if let notice = store.clampNotice { result.append(.clampNotice(notice)) }
        if let error = store.lastError { result.append(.lastError(error)) }
        return result
    }

    private var fanRows: [StatusSection] {
        status.fans.map { .fan(label: $0.label, value: "\($0.currentRPM) RPM") }
    }

    private var temperatureRows: [StatusSection] {
        status.temperatures.map { .temperature(label: $0.sourceLabel, value: String(format: "%.0f °C", $0.celsius)) }
    }

    private var helperSections: [StatusSection] {
        if helper.status == .enabled { return [.manualControls, .profiles] + (helper.needsRepair ? [.repairHelper] : []) }
        if helper.status == .requiresApproval { return [.approveHelper] }
        return [.enableHelper] + (helper.errorMessage.map { [.helperError($0)] } ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Mode", value: store.mode.displayName).bold()
            ForEach(sections, id: \.self) { section in content(for: section) }
            Divider()
            MenuBarSettingsView(settings: menuBar)
            Divider()
            EventLogView(log: log)
            Divider()
            Button("Quit Ventilador", action: quit)
        }
        .padding()
        .frame(width: 340)
        .onAppear(perform: helper.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in helper.refresh() }
    }

    @ViewBuilder private func content(for section: StatusSection) -> some View {
        switch section {
        case .conflict:
            Label("Another app is controlling the fans.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .readingSensors:
            Text("Reading sensors…").foregroundStyle(.secondary)
        case .noFan:
            Text("No fan present — fan control is unavailable on this Mac.")
        case .error(let message):
            Text(message).foregroundStyle(.red)
        case .fan(let label, let value), .temperature(let label, let value):
            LabeledContent(label, value: value)
        case .manualControls:
            ManualControlView(model: manual)
        case .profiles:
            ProfilePickerView(store: store)
        case .approveHelper:
            Text("Approve the Ventilador helper in System Settings › General › Login Items to control fans.").font(.caption)
            Button("Open System Settings", action: helper.openSettings)
        case .repairHelper:
            Text("The helper isn't responding as this version of Ventilador. Repairing reinstalls it; fans return to automatic meanwhile.").font(.caption)
            Button(helper.isRepairing ? "Repairing…" : "Repair Helper", action: helper.repairInBackground).disabled(helper.isRepairing)
        case .enableHelper:
            Text("Changing fan speed needs a small privileged helper: the fan controller only accepts commands from an administrator process.").font(.caption)
            Button("Enable Fan Control", action: helper.enable)
        case .helperError(let message), .lastError(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        case .clampNotice(let notice):
            Text(notice).font(.caption).foregroundStyle(.orange)
        }
    }
}
