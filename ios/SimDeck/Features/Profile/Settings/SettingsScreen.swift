// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct SettingsScreen: View {
    let model: AppModel

    var body: some View {
        List {
            Section("Account") {
                SettingsLink("Server", subtitle: "Connection and sign-in", symbol: "server.rack", color: .blue) {
                    ServerSettingsScreen(model: model)
                }
                SettingsLink("Security", subtitle: "Passkeys and recovery", symbol: "lock.shield", color: .orange) {
                    SecuritySettingsScreen(model: model)
                }
            }

            Section("Communication") {
                SettingsLink("Default Lines", subtitle: "Choose SIMs for calls and messages", symbol: "simcard.2", color: .teal) {
                    DefaultLineSettingsScreen(model: model)
                }
                SettingsLink("Notifications", subtitle: "Calls and message alerts", symbol: "bell", color: .blue) {
                    NotificationSettingsScreen()
                }
                SettingsLink("Contacts", subtitle: "Contact access", symbol: "person.crop.circle", color: .teal) {
                    ContactsSettingsScreen()
                }
            }

            Section("SIM Cards") {
                SettingsLink("All SIM Cards", subtitle: "Manage paired SIMs", symbol: "simcard", color: .green) {
                    SIMManagementScreen(model: model)
                }
            }

            Section("Data") {
                SettingsLink("Messages & Storage", subtitle: "Encrypted history and cache", symbol: "externaldrive", color: .indigo) {
                    StorageSettingsScreen(model: model)
                }
            }

            Section("Other") {
                SettingsLink("Advanced", subtitle: "Connection diagnostics", symbol: "gearshape.2", color: .gray) {
                    AdvancedSettingsScreen(connection: model.serverConnection)
                }
                SettingsLink("About", subtitle: "App version and licenses", symbol: "info.circle", color: .gray) {
                    AboutScreen()
                }
            }

            Section {
                NavigationLink {
                    DataDeletionScreen()
                } label: {
                    HStack(spacing: 12) {
                        ProfileIconTile(symbol: "trash", color: .red)
                        Text("Delete Account & Server Data")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

private struct SettingsLink<Destination: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let symbol: String
    let color: Color
    @ViewBuilder let destination: () -> Destination

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        symbol: String,
        color: Color,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.color = color
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                ProfileIconTile(symbol: symbol, color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
        }
    }
}

#if DEBUG
#Preview("Settings") {
    NavigationStack {
        SettingsScreen(model: .preview(selectedTab: .profile))
    }
}

#Preview("Settings - Accessibility Chinese") {
    NavigationStack {
        SettingsScreen(model: .preview(selectedTab: .profile))
    }
    .environment(\.dynamicTypeSize, .accessibility5)
    .environment(\.locale, Locale(identifier: "zh-Hans"))
}
#endif
