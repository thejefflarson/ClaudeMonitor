import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var keyInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preferences").font(.title2).bold()

            VStack(alignment: .leading, spacing: 6) {
                Text("Anthropic Admin API Key").font(.headline)
                Text("Requires an Admin key (sk-ant-admin…) from console.anthropic.com → Settings → API Keys.\nStored securely in macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("sk-ant-admin-…", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if !keyInput.isEmpty { store.saveApiKey(keyInput) }
                    dismiss()
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { keyInput = store.apiKey ?? "" }
    }
}
