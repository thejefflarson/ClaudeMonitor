import SwiftUI

struct PreferencesView: View {
    @AppStorage("iterm2FocusEnabled") private var iterm2FocusEnabled = true

    var body: some View {
        Form {
            Toggle("Focus iTerm2 when Claude is ready", isOn: $iterm2FocusEnabled)
        }
        .padding()
        .frame(width: 300)
    }
}
