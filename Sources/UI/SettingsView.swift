import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    @State private var apiKeyInput = ""
    @State private var usageTokenInput = ""
    @State private var apiKeyMessage: String?
    @State private var usageTokenMessage: String?
    @State private var harnessMessage: String?
    @State private var isSavingAPIKey = false
    @State private var isSavingUsageToken = false
    @State private var showUsageToken = false

    var body: some View {
        Form {
            Section {
                accountContent
            } header: {
                Text("Account")
            }

            Section {
                apiKeyContent
            } header: {
                Text("API Key")
            }

            Section {
                usageTokenContent
            } header: {
                Text("Usage Token Fallback")
            }

            Section {
                refreshContent
            } header: {
                Text("Refresh")
            }

            Section {
                privacyContent
            } header: {
                Text("Privacy & Security")
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 740)
        .onAppear {
            model.checkHarnessAvailability()
        }
    }

    // MARK: Account

    @ViewBuilder
    private var accountContent: some View {
        if model.hasOAuthToken {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.accountName ?? "Signed in to DeepSeek")
                        .font(.headline)
                    Text(model.tokenSource == .harness
                         ? "via DeepSeek Harness"
                         : "via browser sign-in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sign Out") {
                    model.signOut()
                    harnessMessage = nil
                }
                .buttonStyle(.bordered)
            }

            if model.snapshot.needsReauth {
                Label("This session was rejected. Sign in again or re-import the Harness login.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if model.tokenSource == .harness, model.harnessAvailable {
                Button("Re-import Harness Login") {
                    importHarness()
                }
                .buttonStyle(.bordered)
                .disabled(model.isImportingHarness)
            }
        } else {
            Text("Reuse the DeepSeek account you're already signed into in DeepSeek Harness, or sign in with the browser.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.harnessAvailable {
                Button {
                    importHarness()
                } label: {
                    Label("Use DeepSeek Harness Login", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isImportingHarness || model.isSigningIn)

                Text("Reads ~/.dsh/.credentials.yaml once. The account token is copied to your Keychain; the app never watches or uploads that file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("No Harness credential file found at ~/.dsh/.credentials.yaml.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                model.signIn()
            } label: {
                Label("Sign in with DeepSeek…", systemImage: "person.crop.circle.badge.checkmark")
            }
            .disabled(model.isSigningIn || model.isImportingHarness)

            Text("Opens platform.deepseek.com and returns through a one-time localhost callback. The token is stored in Keychain.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if model.isSigningIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the browser…")
                        .font(.caption)
                    Spacer()
                    Button("Cancel") { model.cancelSignIn() }
                }
            }
            if model.isImportingHarness {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Importing Harness login…")
                        .font(.caption)
                }
            }
        }

        if let harnessMessage {
            Text(harnessMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let lastError = model.lastError, !model.isSigningIn {
            Text(lastError)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    // MARK: API key

    @ViewBuilder
    private var apiKeyContent: some View {
        if model.hasAPIKey {
            Label("API key saved in Keychain", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.callout)
        } else {
            Text("Optional. Uses the official `api.deepseek.com/user/balance` endpoint. Without a key the app uses the signed-in platform account for balance.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        SecureField(model.hasAPIKey ? "Paste a new key to replace" : "sk-…", text: $apiKeyInput)
            .textFieldStyle(.roundedBorder)
            .onSubmit { saveAPIKey() }

        HStack(spacing: 10) {
            Button(model.hasAPIKey ? "Replace API Key" : "Save API Key") {
                saveAPIKey()
            }
            .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingAPIKey)

            if isSavingAPIKey {
                ProgressView().controlSize(.small)
            }

            if !model.hasAPIKey, model.harnessAvailable {
                Button("Import from Harness") {
                    importHarnessAPIKey()
                }
                .disabled(isSavingAPIKey)
            }

            Spacer()

            if model.hasAPIKey {
                Button("Remove", role: .destructive) {
                    model.removeAPIKey()
                    apiKeyMessage = nil
                }
            }
        }

        if let apiKeyMessage {
            Text(apiKeyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Usage token

    @ViewBuilder
    private var usageTokenContent: some View {
        Text("Only needed if the account sign-in cannot read usage. On platform.deepseek.com, run `localStorage.getItem(\"userToken\")` in the browser console and paste the value here.")
            .font(.caption)
            .foregroundStyle(.secondary)

        DisclosureGroup("Manual usage token", isExpanded: $showUsageToken) {
            if model.hasUsageToken {
                Label("Usage token saved in Keychain", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                Button("Remove Usage Token", role: .destructive) {
                    model.removeUsageToken()
                    usageTokenMessage = nil
                }
            }

            SecureField("Paste userToken", text: $usageTokenInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveUsageToken() }

            HStack {
                Button(model.hasUsageToken ? "Replace Usage Token" : "Save Usage Token") {
                    saveUsageToken()
                }
                .disabled(usageTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingUsageToken)

                if isSavingUsageToken {
                    ProgressView().controlSize(.small)
                }
            }

            if let usageTokenMessage {
                Text(usageTokenMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Refresh

    @ViewBuilder
    private var refreshContent: some View {
        Picker("Refresh every", selection: Binding(
            get: { model.refreshInterval },
            set: { model.setRefreshInterval($0) }
        )) {
            Text("1 minute").tag(TimeInterval(60))
            Text("5 minutes").tag(TimeInterval(300))
            Text("15 minutes").tag(TimeInterval(900))
            Text("30 minutes").tag(TimeInterval(1800))
        }
        .pickerStyle(.menu)

        HStack {
            Button("Refresh Now") {
                model.refreshNow()
            }
            .disabled(model.isLoading)

            if model.isLoading {
                ProgressView().controlSize(.small)
            }
        }

        if let updated = model.snapshot.updatedAt {
            Text("Last updated \(updated.formatted(date: .omitted, time: .standard))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Privacy

    @ViewBuilder
    private var privacyContent: some View {
        Text("The API key, account token, and optional usage token are stored as generic passwords in the macOS Keychain with `AfterFirstUnlockThisDeviceOnly`. Nothing is written to `.env`, plists, or logs, and there is no telemetry.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Text("The Harness importer reads ~/.dsh/.credentials.yaml only when you click the import button. It copies the token (and API key, if present) into this app's Keychain; it does not watch or modify the Harness file.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Text("DeepSeek's browser sign-in uses the same PKCE authorization flow as DeepSeek Harness. It is undocumented and may change; the API key and manual token are fallbacks.")
            .font(.caption2)
            .foregroundStyle(.tertiary)

        Link("Open DeepSeek usage page", destination: URL(string: "https://platform.deepseek.com/usage")!)
        Link("GitHub: okric", destination: URL(string: "https://github.com/okric")!)
    }

    // MARK: Actions

    private func importHarness() {
        harnessMessage = nil
        Task {
            do {
                try await model.importHarnessLogin()
                harnessMessage = "Harness login imported."
            } catch {
                harnessMessage = error.localizedDescription
            }
        }
    }

    private func importHarnessAPIKey() {
        apiKeyMessage = nil
        Task {
            do {
                try await model.importHarnessAPIKey()
                apiKeyMessage = "API key imported from Harness."
            } catch {
                apiKeyMessage = error.localizedDescription
            }
        }
    }

    private func saveAPIKey() {
        let value = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        isSavingAPIKey = true
        apiKeyMessage = nil
        Task {
            do {
                try await model.saveAPIKey(value)
                apiKeyInput = ""
                apiKeyMessage = "API key verified and saved."
            } catch {
                apiKeyMessage = error.localizedDescription
            }
            isSavingAPIKey = false
        }
    }

    private func saveUsageToken() {
        let value = usageTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        isSavingUsageToken = true
        usageTokenMessage = nil
        Task {
            do {
                try await model.saveUsageToken(value)
                usageTokenInput = ""
                usageTokenMessage = "Usage token verified and saved."
            } catch {
                usageTokenMessage = error.localizedDescription
            }
            isSavingUsageToken = false
        }
    }
}


#if DEBUG
#Preview("Settings — connected") {
    SettingsView(model: AppModel.preview())
}
#endif
