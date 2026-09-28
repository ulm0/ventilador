import SwiftUI

struct ManualControlView: View {
    @ObservedObject var model: ManualControlModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Manual speed").font(.headline)
            ForEach($model.rows) { $row in
                HStack {
                    Text(row.fan.label)
                    Slider(value: $row.draft, in: row.range)
                    Text("\(Int(row.draft)) RPM").monospacedDigit()
                    Button("Apply", action: applyAction(row.id))
                }
            }
            if model.showsBulkControl {
                HStack {
                    Text("All fans")
                    Slider(value: $model.allDraft, in: model.allRange)
                    Text("\(Int(model.allDraft)) RPM").monospacedDigit()
                    Button("Apply to all", action: model.applyAll)
                }
            }
            Button("Revert to Automatic", action: model.revert)
        }
    }

    func applyAction(_ id: Fan.ID) -> () -> Void {
        { model.apply(id) }
    }
}
