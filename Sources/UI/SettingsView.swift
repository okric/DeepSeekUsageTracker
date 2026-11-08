import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                accountContent
            } header: {
                Text("Account")
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
        if !model.harnessAvailable {
            Label("DeepSeek Harness not found", systemImage: "xmark.seal")
                .foregroundStyle(.orange)
                .font(.callout)
            Text("This tracker has exactly one identity source: the DeepSeek Harness credential file at ~/.dsh/.credentials.yaml. Install DeepSeek Harness and sign in there — the tracker picks it up on the next refresh; nothing is copied or stored.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                model.openHarnessApp()
            } label: {
                Label("Open DeepSeek Harness", systemImage: "app.badge")
            }
        } else if let setupError = model.harnessSetupError {
            Label(setupError, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
            Button {
                model.openHarnessApp()
            } label: {
                Label("Open DeepSeek Harness", systemImage: "app.badge")
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.accountName ?? "Signed in via DeepSeek Harness")
                        .font(.headline)
                    Text("read live from ~/.dsh/.credentials.yaml — nothing is copied or stored")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }

        if let lastError = model.lastError {
            Text(lastError)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
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
        Text("This app stores no secrets of its own. The DeepSeek Harness login is read live from `~/.dsh/.credentials.yaml` (owner-readable) only at request time; there are no Keychain items, no `.env`, no plist secrets, no logging of credentials, and no telemetry.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Text("The Harness file is never watched or written. Renew the login from DeepSeek Harness itself and refresh here; a revoked session shows up as a rejected-request warning with an open-DSH action.")
            .font(.caption2)
            .foregroundStyle(.tertiary)

        Link("Project page: github.com/okric/DeepseekUsageTracker", destination: URL(string: "https://github.com/okric/DeepseekUsageTracker")!)
    }
}


#if DEBUG
#Preview("Settings — connected") {
    SettingsView(model: AppModel.preview())
}
#endif
