import SwiftUI

struct ProfilePickerView: View {
    @ObservedObject var store: ControlModeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Profiles").font(.headline)
            HStack {
                ForEach(BuiltInProfiles.all) { profile in
                    Button(profile.name, action: selectAction(profile.id))
                        .help(profile.summary)
                        .fontWeight(store.mode == .profile(profile.id) ? .bold : .regular)
                }
            }
            .controlSize(.small)
        }
    }

    func selectAction(_ id: FanProfile.ID) -> () -> Void {
        { store.selectProfile(id) }
    }
}
