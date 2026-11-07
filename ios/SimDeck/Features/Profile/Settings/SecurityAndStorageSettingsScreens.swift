import SwiftUI

struct SecuritySettingsScreen: View {
    let model: AppModel
    @State private var isRegisteringPasskey = false
    @State private var isRevokingSession = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ProfilePageHeader(
                    title: "Security",
                    detail: "Manage passkeys, trusted iPhones, and history recovery.",
                    symbol: "lock.shield",
                    color: .orange
                )
            }
            Section("Passkeys") {
                if model.passkeys.isEmpty {
                    Text("No passkeys registered")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.passkeys) { passkey in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Passkey")
                            if let createdAt = passkey.createdAt {
                                Text("Registered \(createdAt, format: .dateTime.year().month().day())")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button {
                    isRegisteringPasskey = true
                    Task {
                        defer { isRegisteringPasskey = false }
                        do { try await model.registerPasskey() }
                        catch { errorMessage = error.localizedDescription }
                    }
                } label: {
                    Label("Register Another Passkey", systemImage: "plus.circle")
                }
                .disabled(isRegisteringPasskey || !model.serverConnection.isSignedIn)
            }
            Section("Trusted Devices") {
                NavigationLink("Trusted iPhones") {
                    TrustedDevicesScreen(model: model)
                }
            }
            Section("Encryption") {
                LabeledContent("End-to-end encryption", value: "Active")
                LabeledContent("Recovery") {
                    KeyRecoveryStatusLabel(state: model.keyRecoveryState)
                }
            }
            Section {
                Button("Revoke This Session", role: .destructive) {
                    isRevokingSession = true
                    Task {
                        defer { isRevokingSession = false }
                        do { try await model.revokeCurrentSession() }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
                .disabled(isRevokingSession || !model.serverConnection.isSignedIn)
            } footer: {
                Text("Revoking this session signs out this iPhone and clears its local history.")
            }
        }
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Passkey", isPresented: .init(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

struct TrustedDevicesScreen: View {
    let model: AppModel

    var body: some View {
        List {
            Section {
                ProfilePageHeader(
                    title: "Trusted iPhones",
                    detail: "This installation has its own identity and approval.",
                    symbol: "iphone",
                    color: .blue
                )
            }
            Section {
                if let installationID = model.installationID {
                    LabeledContent("Installation ID", value: String(installationID.uuidString.prefix(8)) + "…")
                } else {
                    Label("Not Registered", systemImage: "iphone.slash")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("This iPhone")
            } footer: {
                Text("Other trusted iPhones are managed during installation approval.")
            }
        }
        .navigationTitle("Trusted iPhones")
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

struct StorageSettingsScreen: View {
    let model: AppModel
    @State private var errorMessage: String?
    @State private var isClearingCache = false

    var body: some View {
        Form {
            Section {
                ProfilePageHeader(
                    title: "Encrypted History",
                    detail: "Calls and messages are stored encrypted on this iPhone.",
                    symbol: "lock.doc",
                    color: .indigo
                )
            }
            Section {
                Button("Clear Cache", role: .destructive) {
                    Task { await clearCacheAndRestoreHistory() }
                }
                .disabled(isClearingCache)
                if isClearingCache {
                    ProgressView("Restoring history…")
                }
            } header: {
                Text("Local Cache")
            } footer: {
                Text("Clearing the cache reloads encrypted history from your server.")
            }
        }
        .navigationTitle("Messages & Storage")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Clear Cache", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }

    private func clearCacheAndRestoreHistory() async {
        isClearingCache = true
        defer { isClearingCache = false }
        do {
            try await model.clearLocalHistoryCacheAndRestoreFromServer()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct AdvancedSettingsScreen: View {
    let connection: ServerConnectionManager
    private var diagnosticReport: String {
        "Sim Deck diagnostics\nServer: \(connection.address.isEmpty ? "Not configured" : "Configured")\nState: \(String(describing: connection.state))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("UDP", value: "Automatic")
                LabeledContent("TCP", value: "Automatic")
            } header: {
                Text("Media Ports")
            } footer: {
                Text("Media ports are supplied by the server and cannot be changed on this iPhone.")
            }
            Section("Diagnostics") {
                ShareLink(item: diagnosticReport) {
                    Label("Export Redacted Diagnostics", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

struct AboutScreen: View {
    private var version: String {
        let release = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(release) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                ProfilePageHeader(
                    title: "Sim Deck",
                    detail: "Calls and messages through your connected SIM cards.",
                    symbol: "simcard.2",
                    color: .blue
                )
            }
            Section {
                LabeledContent("App Version", value: version)
            }
            Section("What Sim Deck Does") {
                Text("Make and receive calls and text messages on this iPhone using SIM cards in your connected Sim Deck device.")
                Text("These calls and messages use the SIM in your Sim Deck device, not the SIM in this iPhone.")
            }
            Section("What You Need") {
                Text("A reachable Sim Deck server, a paired device, and an active SIM card are required for calls and messages.")
            }
            Section("Third-Party Software") {
                NavigationLink("WebRTC License") {
                    WebRTCLicenseScreen()
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

private struct WebRTCLicenseScreen: View {
    private var licenseText: String? {
        guard let url = Bundle.main.url(forResource: "WebRTC-License", withExtension: "txt") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    var body: some View {
        ScrollView {
            if let licenseText {
                Text(licenseText)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    .padding(20)
            } else {
                ContentUnavailableView("License Unavailable", systemImage: "doc.text", description: Text("The WebRTC license could not be loaded."))
            }
        }
        .navigationTitle("WebRTC License")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

struct DataDeletionScreen: View {
    var body: some View {
        Form {
            Section {
                ProfilePageHeader(
                    title: "Delete Account & Server Data",
                    detail: "Account deletion affects your devices and encrypted history.",
                    symbol: "trash",
                    color: .red
                )
            }
            Section {
                Text("This permanently deletes the owner account, devices, messages, attachments, and call history from the server.")
            }
            Section {
                Label("Account deletion is not available until the server exposes the authenticated deletion endpoint.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("Delete Data")
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

#if DEBUG
#Preview("Security Settings") {
    NavigationStack { SecuritySettingsScreen(model: .preview()) }
}

#Preview("Trusted iPhones") {
    NavigationStack { TrustedDevicesScreen(model: .preview()) }
}

#Preview("Storage Settings") {
    NavigationStack { StorageSettingsScreen(model: .preview()) }
}

#Preview("Advanced Settings") {
    NavigationStack { AdvancedSettingsScreen(connection: AppModel.preview().serverConnection) }
}

#Preview("About") {
    NavigationStack { AboutScreen() }
}

#Preview("Delete Data") {
    NavigationStack { DataDeletionScreen() }
}
#endif
