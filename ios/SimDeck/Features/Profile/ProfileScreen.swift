// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

enum ProfileNavigationRoute: Hashable {
    case deviceManagement
    case simManagement
    case settings
    case sim(UUID)
}

struct ProfileScreen: View {
    let model: AppModel

    var body: some View {
        let lines = model.devices.filter { $0.simID != nil }

        List {
            if !model.serverConnection.isSignedIn {
                Section {
                    NavigationLink {
                        ServerSettingsScreen(model: model)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Sign In with Passkey")
                                    .font(.headline)
                                Text("Connect to your server")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "person.badge.key.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }

            Section {
                ProfileOverviewCard(lines: lines)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 2, trailing: 0))
                    .listRowBackground(Color.clear)
            }

            if !lines.isEmpty {
                SIMCardsSection(
                    lines: lines,
                    serviceStates: model.slotSettingsByLineID
                )
            }

            Section("Manage") {
                ProfileActionLink(
                    title: "Device Management",
                    subtitle: "Pair and manage devices",
                    systemImage: "simcard.2",
                    color: .blue,
                    route: .deviceManagement
                )
                ProfileActionLink(
                    title: "Settings",
                    subtitle: "Security, notifications, and more",
                    systemImage: "gearshape",
                    color: .purple,
                    route: .settings
                )
            }
        }
        .refreshable {
            await model.refreshDevices()
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

private struct ProfileOverviewCard: View {
    let lines: [DeviceLineIdentity]

    private var onlineCount: Int {
        lines.count(where: \.isOnline)
    }

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                if lines.isEmpty {
                    Text("No SIM Cards")
                        .font(.title3.weight(.semibold))
                    Text("Add a device in Device Management.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Online SIM Cards")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(onlineCount, format: .number)
                            .foregroundStyle(onlineCount > 0 ? .primary : .secondary)
                        Text("/ \(lines.count)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .accessibilityLabel(Text("\(onlineCount) of \(lines.count) SIM cards online"))
                }
            }

            Spacer(minLength: 0)

            Image(systemName: lines.isEmpty ? "simcard" : "simcard.2.fill")
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 58, height: 58)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.accentColor.opacity(0.10))
        }
    }
}

private struct ProfileActionLink: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    let color: Color
    let route: ProfileNavigationRoute

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 36, height: 36)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)

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

private struct SIMCardsSection: View {
    let lines: [DeviceLineIdentity]
    let serviceStates: [UUID: SlotSettings]

    var body: some View {
        Section("SIM Cards") {
            ForEach(lines) { line in
                NavigationLink(value: ProfileNavigationRoute.sim(line.id)) {
                    SIMRadioStatusRow(
                        line: line,
                        serviceState: serviceStates[line.id]
                    )
                }
            }
        }
    }
}

struct SIMRadioStatusRow: View {
    let line: DeviceLineIdentity
    let serviceState: SlotSettings?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 12) {
                    ProfileSIMBadge(line: line)
                    VStack(alignment: .leading, spacing: 8) {
                        SIMLineDescription(line: line, serviceState: serviceState)
                        SIMRadioStatusSummary(
                            isOnline: line.isOnline,
                            status: line.radioStatus
                        )
                    }
                }
            } else {
                HStack(spacing: 12) {
                    ProfileSIMBadge(line: line)
                    SIMLineDescription(line: line, serviceState: serviceState)
                    Spacer(minLength: 6)
                    SIMRadioStatusSummary(
                        isOnline: line.isOnline,
                        status: line.radioStatus
                    )
                }
            }
        }
        .frame(minHeight: 56)
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: Text {
        if !line.lineName.isEmpty && line.lineName != line.displayName {
            return Text(
                "SIM \(line.numericID), \(line.displayName), \(line.lineName), \(servicePresentation.title), \(line.radioAccessibilityDescription)"
            )
        }
        return Text(
            "SIM \(line.numericID), \(line.displayName), \(servicePresentation.title), \(line.radioAccessibilityDescription)"
        )
    }

    private var servicePresentation: ProfileSIMServicePresentation {
        ProfileSIMServicePresentation(line: line, state: serviceState)
    }
}

private struct ProfileSIMBadge: View {
    let line: DeviceLineIdentity

    var body: some View {
        SIMBadge(line: line, size: 22, color: line.isOnline ? .blue : .secondary)
            .frame(width: 38, height: 38)
            .background(
                line.isOnline ? Color.blue.opacity(0.10) : Color.secondary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .accessibilityHidden(true)
    }
}

private struct SIMLineDescription: View {
    let line: DeviceLineIdentity
    let serviceState: SlotSettings?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(line.displayName)
                .font(.body.weight(.semibold))
                .lineLimit(2)
            if !line.lineName.isEmpty && line.lineName != line.displayName {
                Text(line.lineName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ProfileSIMServiceStatus(
                presentation: ProfileSIMServicePresentation(
                    line: line,
                    state: serviceState
                )
            )
        }
    }
}

private struct SIMRadioStatusSummary: View {
    let isOnline: Bool
    let status: CellularRadioStatus?

    var body: some View {
        Group {
            if isOnline, let status, let signalBars = status.signalBars {
                HStack(spacing: 5) {
                    CellularSignalIndicator(bars: signalBars)
                    Text(status.technology.displayName)
                }
                .font(.subheadline.weight(.semibold))
            } else if isOnline, let status {
                Text(status.technology == .unknown ? String(localized: "No signal") : status.technology.displayName)
                    .font(.subheadline.weight(.semibold))
            } else if isOnline {
                Text("Signal unavailable")
                    .foregroundStyle(.secondary)
            } else {
                Text("Offline")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ProfileSIMServicePresentation {
    let title: String
    let color: Color

    init(line: DeviceLineIdentity, state: SlotSettings?) {
        guard line.isOnline else {
            title = String(localized: "Offline")
            color = .secondary
            return
        }

        switch state {
        case let settings?:
            if settings.airplaneModeEnabled {
                title = String(localized: "Airplane Mode")
                color = .yellow
            } else {
                let services = [
                    settings.incomingCallsEnabled ? String(localized: "Calls") : nil,
                    settings.incomingSMSEnabled ? String(localized: "SMS") : nil,
                    settings.dataEnabled ? String(localized: "Data") : nil,
                ].compactMap { $0 }
                title = services.isEmpty
                    ? String(localized: "No Services Enabled")
                    : services.joined(separator: " · ")
                color = .green
            }
        case nil:
            // Keep the row quiet until the first settings snapshot arrives. A
            // refresh should not replace a previously rendered value with a
            // transient loading state.
            title = "—"
            color = .secondary
        }
    }
}

private struct ProfileSIMServiceStatus: View {
    let presentation: ProfileSIMServicePresentation

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(presentation.color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(presentation.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}


struct KeyRecoveryStatusLabel: View {
    let state: KeyRecoveryState

    var body: some View {
        switch state {
        case .checking:
            ProfileStatusValue(
                title: "Checking",
                systemImage: "icloud",
                color: .secondary
            )
        case .available:
            ProfileStatusValue(
                title: "Available",
                systemImage: "icloud.fill",
                color: .blue
            )
        case .approvalRequired:
            ProfileStatusValue(
                title: "Approval required",
                systemImage: "person.badge.key",
                color: .orange
            )
        case .unavailable:
            ProfileStatusValue(
                title: "Unavailable",
                systemImage: "exclamationmark.icloud",
                color: .red
            )
        }
    }
}

private struct ProfileStatusValue: View {
    let title: LocalizedStringKey
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
        }
        .foregroundStyle(color)
    }
}

#if DEBUG
#Preview("Me - Multiple SIMs") {
    NavigationStack {
        ProfileScreen(model: .preview(selectedTab: .profile))
    }
}

#Preview("Me - Empty") {
    NavigationStack {
        ProfileScreen(
            model: .preview(
                selectedTab: .profile,
                devices: [],
                keyRecoveryState: .checking
            )
        )
    }
}

#Preview("Me - Offline and Dark") {
    NavigationStack {
        ProfileScreen(
            model: .preview(
                selectedTab: .profile,
                devices: PreviewFixtures.devices.map { line in
                    var offlineLine = line
                    offlineLine.isOnline = false
                    offlineLine.radioStatus = nil
                    return offlineLine
                }
            )
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Me - Airplane Mode") {
    NavigationStack {
        ProfileScreen(
            model: .preview(
                selectedTab: .profile,
                slotSettings: SlotSettings(
                    dataEnabled: true,
                    airplaneModeEnabled: true,
                    incomingCallsEnabled: true,
                    incomingSMSEnabled: true
                )
            )
        )
    }
}

#Preview("Me - No Enabled Services") {
    NavigationStack {
        ProfileScreen(
            model: .preview(
                selectedTab: .profile,
                slotSettings: SlotSettings(
                    dataEnabled: false,
                    airplaneModeEnabled: false,
                    incomingCallsEnabled: false,
                    incomingSMSEnabled: false
                )
            )
        )
    }
}

#Preview("Me - Accessibility Chinese") {
    NavigationStack {
        ProfileScreen(model: .preview(selectedTab: .profile))
    }
    .environment(\.dynamicTypeSize, .accessibility5)
    .environment(\.locale, Locale(identifier: "zh-Hans"))
}

#endif
