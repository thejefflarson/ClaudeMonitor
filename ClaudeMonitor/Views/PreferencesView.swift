import SwiftUI

struct PreferencesView: View {
    @AppStorage("terminalFocusApp") private var terminalFocusApp = "iTerm2"

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 4) {
                Text("Focus terminal when Claude is ready")
                Picker("", selection: $terminalFocusApp) {
                    Text("iTerm2").tag("iTerm2")
                    Text("Mosaic").tag("Mosaic")
                    Text("Disabled").tag("disabled")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .padding()
        .frame(width: 300)
    }
}
