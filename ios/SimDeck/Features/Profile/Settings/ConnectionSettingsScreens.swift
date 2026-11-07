// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit
import Contacts

struct ServerSettingsScreen: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.serverConnection.isSignedIn {
                Form {
                    Section {
                        ProfilePageHeader(
                            title: "Server Connection",
                            detail: "Manage this iPhone's connection to your server.",
                            symbol: "server.rack",
                            color: .blue
                        )
                    }
                    ServerSignedInSection(model: model)
                    ServerVersionSection()
                }
            } else {
                ServerSignInContent(model: model)
            }
        }
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

private struct ServerSignInContent: View {
    let model: AppModel
    @Bindable private var connection: ServerConnectionManager
    @State private var password = ""
    @State private var isWorking = false
    @State private var isSigningInWithPasskey = false
    @State private var showsPasswordSignIn = false
    @State private var actionError: String?

    init(model: AppModel) {
        self.model = model
        _connection = Bindable(wrappedValue: model.serverConnection)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ServerSignInHeader()
                    .padding(.bottom, 32)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Server address")
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: 12) {
                        Image(systemName: "network")
                            .foregroundStyle(.secondary)
                        TextField("https://sim-deck.example.com", text: $connection.address)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.URL)
                            .submitLabel(.done)
                            .onChange(of: connection.address) {
                                actionError = nil
                            }
                        if !connection.address.isEmpty {
                            Button {
                                connection.address = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("Clear server address")
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 56)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(.bottom, 24)

                Button {
                    Task { await signInWithPasskey() }
                } label: {
                    HStack(spacing: 10) {
                        if isSigningInWithPasskey {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "person.badge.key")
                        }
                        Text("Sign In with Passkey")
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                .disabled(!canSignInWithPasskey)

                Button {
                    withAnimation { showsPasswordSignIn.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Use Admin Password")
                        Image(systemName: showsPasswordSignIn ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(.top, 12)
                .accessibilityAddTraits(showsPasswordSignIn ? .isSelected : [])

                if showsPasswordSignIn {
                    VStack(alignment: .leading, spacing: 12) {
                        SecureField("Administrator password", text: $password)
                            .textContentType(.password)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                        Button {
                            Task { await signIn() }
                        } label: {
                            if isWorking && !isSigningInWithPasskey {
                                ProgressView()
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            } else {
                                Text("Sign In with Password")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 14))
                        .disabled(!canSignIn)
                    }
                    .padding(.top, 8)
                }

                if connection.state == .failed && actionError == nil {
                    ServerConnectionStatusLabel(state: connection.state)
                        .font(.footnote)
                        .padding(.top, 20)
                }
                if let actionError {
                    Text(actionError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.top, 12)
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .padding(.top, 32)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var canSignIn: Bool {
        canSignInWithPasskey && !password.isEmpty
    }

    private var canSignInWithPasskey: Bool {
        !isWorking
            && !connection.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func signInWithPasskey() async {
        isWorking = true
        isSigningInWithPasskey = true
        actionError = nil
        defer {
            isSigningInWithPasskey = false
            isWorking = false
        }
        do {
            try await model.signInWithPasskey()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func signIn() async {
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            try await model.signInToServer(password: password)
            password = ""
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private struct ServerSignInHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "person.badge.key.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 8) {
                Text("Connect to your server")
                    .font(.title2.weight(.bold))
                Text("Use a passkey saved on this iPhone or in iCloud Keychain.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ServerSignedInSection: View {
    let model: AppModel
    @Bindable private var connection: ServerConnectionManager
    @State private var isWorking = false
    @State private var actionResult: LocalizedStringResource?
    @State private var actionError: String?

    init(model: AppModel) {
        self.model = model
        _connection = Bindable(wrappedValue: model.serverConnection)
    }

    var body: some View {
        Section("Server") {
            TextField("Server address", text: $connection.address)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.URL)
                .disabled(true)

            ServerConnectionStatusRow("Status", state: connection.state)

            Button("Test Connection") {
                Task { await testConnection() }
            }
            .disabled(isWorking)
        }

        Section {
            Button("Sign Out", role: .destructive) {
                Task { await signOut() }
            }
            .disabled(isWorking)
        } footer: {
            Text("Signing out removes local messages and calls from this iPhone.")
        }

        if let actionResult {
            Section {
                Text(actionResult)
                    .foregroundStyle(.green)
            }
        }
        if let actionError {
            Section {
                Text(actionError)
                    .foregroundStyle(.red)
            }
        }
    }

    private func testConnection() async {
        isWorking = true
        actionResult = nil
        actionError = nil
        defer { isWorking = false }
        do {
            try await model.testServerConnection()
            actionResult = "Connection succeeded"
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func signOut() async {
        isWorking = true
        actionResult = nil
        actionError = nil
        defer { isWorking = false }
        do {
            try await model.signOutFromServer()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private struct ServerVersionSection: View {
    var body: some View {
        Section("Version") {
            LabeledContent("API", value: "v1")
        }
    }
}

struct ServerConnectionStatusLabel: View {
    let state: ServerConnectionState

    var body: some View {
        switch state {
        case .disconnected:
            ServerConnectionStateContent(
                title: "Not Connected",
                systemImage: "network.slash",
                color: .secondary
            )
        case .connecting:
            ServerConnectionStateContent(
                title: "Connecting",
                systemImage: "arrow.triangle.2.circlepath",
                color: .secondary
            )
        case .connected:
            ServerConnectionStateContent(
                title: "Connected",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        case .failed:
            ServerConnectionStateContent(
                title: "Connection Failed",
                systemImage: "exclamationmark.triangle.fill",
                color: .red
            )
        }
    }
}

private struct ServerConnectionStateContent: View {
    let title: LocalizedStringKey
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
        }
        .foregroundStyle(color)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ServerConnectionStatusRow: View {
    let title: LocalizedStringKey
    let state: ServerConnectionState

    init(_ title: LocalizedStringKey, state: ServerConnectionState) {
        self.title = title
        self.state = state
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title)
                Spacer()
                ServerConnectionStatusLabel(state: state)
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                ServerConnectionStatusLabel(state: state)
            }
        }
    }
}

struct CallsAndMessagesSettingsScreen: View {
    @Bindable var model: AppModel
    @AppStorage(NotificationPreferences.messageNotificationsKey, store: NotificationPreferences.sharedDefaults) private var messageNotifications = true
    @AppStorage(NotificationPreferences.incomingCallNotificationsKey, store: NotificationPreferences.sharedDefaults) private var incomingCallNotifications = true
    @AppStorage(NotificationPreferences.showMessagePreviewKey, store: NotificationPreferences.sharedDefaults) private var showMessagePreview = true

    var body: some View {
        Form {
            Section("Calls") {
                LinePickerRow(
                    "Default call SIM",
                    lines: model.devices,
                    selection: $model.defaultCallLineID
                )
                Toggle("Incoming call notifications", isOn: Binding(
                    get: { incomingCallNotifications },
                    set: { value in
                        incomingCallNotifications = value
                        NotificationCenter.default.post(
                            name: .simDeckIncomingCallPreferenceChanged,
                            object: value
                        )
                    }
                ))
            }
            Section {
                LinePickerRow(
                    "Default message SIM",
                    lines: model.devices,
                    selection: $model.defaultMessageLineID
                )
                Toggle("Message notifications", isOn: Binding(
                    get: { messageNotifications },
                    set: { value in
                        messageNotifications = value
                        NotificationCenter.default.post(
                            name: .simDeckMessageNotificationPreferenceChanged,
                            object: value
                        )
                    }
                ))
                Toggle("Show message preview", isOn: $showMessagePreview)
                    .disabled(!messageNotifications)
            } header: {
                Text("Messages")
            } footer: {
                Text("Message previews show message content in notifications.")
            }
            Section {
                NavigationLink {
                    ContactsSettingsScreen()
                } label: {
                    HStack(spacing: 12) {
                        ProfileIconTile(symbol: "person.crop.circle", color: .teal)
                        Text("Contact Access")
                    }
                }
            } header: {
                Text("Contacts")
            } footer: {
                Text("Show names from this iPhone in calls and messages.")
            }
        }
        .navigationTitle("Calls & Messages")
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

private struct LinePickerRow: View {
    let title: LocalizedStringKey
    let lines: [DeviceLineIdentity]
    @Binding var selection: UUID?

    init(_ title: LocalizedStringKey, lines: [DeviceLineIdentity], selection: Binding<UUID?>) {
        self.title = title
        self.lines = lines
        _selection = selection
    }

    var body: some View {
        Picker(title, selection: availableSelection) {
            Text("Automatic").tag(UUID?.none)
            ForEach(lines) { line in
                Text(line.displayName).tag(Optional(line.id))
            }
        }
    }

    private var availableSelection: Binding<UUID?> {
        Binding(
            get: {
                guard let selection, lines.contains(where: { $0.id == selection }) else { return nil }
                return selection
            },
            set: { selection = $0 }
        )
    }
}

struct ContactsSettingsScreen: View {
    @State private var authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    @State private var isRequesting = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Access") {
                    Text(statusLabel)
                }
                if authorizationStatus == .notDetermined {
                    Button {
                        requestAccess()
                    } label: {
                        if isRequesting { ProgressView() } else { Text("Allow Contacts Access") }
                    }
                    .disabled(isRequesting)
                }
                Link("Open System Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
            } header: {
                Text("Permission")
            } footer: {
                Text("Show names from this iPhone in calls and messages.")
            }
        }
        .navigationTitle("Contacts")
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }

    private var statusLabel: LocalizedStringResource {
        switch authorizationStatus {
        case .authorized: "Allowed"
        case .denied, .restricted: "Denied"
        case .limited: "Limited"
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }

    private func requestAccess() {
        isRequesting = true
        Task {
            let granted = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
            authorizationStatus = granted ? .authorized : CNContactStore.authorizationStatus(for: .contacts)
            isRequesting = false
        }
    }
}

#if DEBUG
#Preview("Server Settings") {
    NavigationStack { ServerSettingsScreen(model: .preview(selectedTab: .profile)) }
}

#Preview("Calls and Messages") {
    NavigationStack { CallsAndMessagesSettingsScreen(model: .preview(selectedTab: .profile)) }
}

#Preview("Contacts Settings") {
    NavigationStack { ContactsSettingsScreen() }
}
#endif
