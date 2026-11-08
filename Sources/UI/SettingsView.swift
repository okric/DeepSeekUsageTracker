import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    @State private var apiKeyInput = ""
    @State private var usageTokenInput = ""
    @State private var apiKeyMessage: String?
    @State private var usageTokenMessage: String?
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
                launchAtLoginContent
            } header: {
                Text("Startup")
            }

            Section {
                privacyContent
            } header: {
                Text("Privacy & Security")
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            model.checkHarnessAvailability()
            model.refreshLaunchAtLoginStatus()
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
                         ? "via DeepSeek Harness — read live from ~/.dsh/.credentials.yaml, nothing is copied or stored"
                         : "via browser sign-in — token kept in the Keychain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.tokenSource == .browser {
                    Button("Sign Out") {
                        model.signOut()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if model.snapshot.needsReauth {
                Label(model.tokenSource == .harness
                      ? "This session was rejected. Re-sign in from DeepSeek Harness."
                      : "This session was rejected. Sign in again.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } else if model.harnessAvailable {
            Label("DeepSeek Harness is signed in — used automatically", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.callout)
        } else {
            Text("If DeepSeek Harness is signed in, this app uses its login automatically (read-only, nothing is stored). Otherwise you can sign in with the browser.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                model.signIn()
            } label: {
                Label("Sign in with DeepSeek…", systemImage: "person.crop.circle.badge.checkmark")
            }
            .disabled(model.isSigningIn)

            Text("Opens platform.deepseek.com and returns through a one-time localhost callback. The token is stored in the Keychain.")
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
            Label("API key available", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.callout)
        }
        Text("Optional override for the official `api.deepseek.com/user/balance` endpoint. When DeepSeek Harness is signed in, its API key is picked up automatically — no copy stored.")
            .font(.caption)
            .foregroundStyle(.secondary)

        SecureField(model.hasAPIKey ? "Paste a key to override the automatic ones" : "sk-…", text: $apiKeyInput)
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

            Spacer()

            if model.hasAPIKey {
                Button("Remove Stored Key", role: .destructive) {
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
            if let updated = model.snapshot.updatedAt {
                Text("Last updated \(updated.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }

            Button("Refresh Now") {
                model.refreshNow()
            }
            .disabled(model.isLoading)

            if model.isLoading {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: Startup

    @ViewBuilder
    private var launchAtLoginContent: some View {
        Toggle("Launch at login", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))
        .disabled(model.isChangingLaunchAtLogin)

        if model.isChangingLaunchAtLogin {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Updating login item…")
                    .font(.caption)
            }
        }

        if model.launchAtLoginNeedsApproval {
            Label(
                "Approval is needed in System Settings → General → Login Items.",
                systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Button("Open Login Items Settings") {
                model.openLoginItemsSettings()
            }
        }

        if let error = model.launchAtLoginError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }

        Text("Starts the menu bar app when you log in. The app must be signed and installed in Applications.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Privacy

    @ViewBuilder
    private var privacyContent: some View {
        Text("The API key and the browser sign-in token are stored as generic passwords in the macOS Keychain with `AfterFirstUnlockThisDeviceOnly`. The DeepSeek Harness login is never copied: it is read live from `~/.dsh/.credentials.yaml` only at request time. There is no `.env`, no plist secrets, no logging of credentials, and no telemetry.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Text("The Harness file is only read when it exists and only from the stable grant record the app documents. It is never watched or written; renew the login from DeepSeek Harness itself and refresh here.")
            .font(.caption2)
            .foregroundStyle(.tertiary)

        Link("Project page: github.com/okric/DeepseekUsageTracker", destination: URL(string: "https://github.com/okric/DeepseekUsageTracker")!)
        Link("Open DeepSeek usage page", destination: URL(string: "https://platform.deepseek.com/usage")!)
    }

    // MARK: Actions

    private func saveAPIKey() {
        let value = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        isSavingAPIKey = true
        apiKeyMessage = nil
        Task {
            do {
                try await model.saveAPIKey(value)
                apiKeyInput = ""
                apiKeyMessage = "API key verified and stored."
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
