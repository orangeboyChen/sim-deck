// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct SlotSettingsScreen: View {
    let model: AppModel
    let line: DeviceLineIdentity
    let profileID: String?
    let profileName: String?
    let isActiveProfile: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var settings: SlotSettings?
    @State private var original: SlotSettings?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isProbing = false
    @State private var showsVoLTERestartConfirmation = false
    @State private var errorDescription: String?

    init(model: AppModel, line: DeviceLineIdentity, profileID: String? = nil, profileName: String? = nil, isActiveProfile: Bool = true) {
        self.model = model
        self.line = line
        self.profileID = profileID
        self.profileName = profileName
        self.isActiveProfile = isActiveProfile
        let cached = profileID == nil ? model.slotSettingsByLineID[line.id] : nil
        _settings = State(initialValue: cached)
        _original = State(initialValue: cached)
        _isLoading = State(initialValue: cached == nil)
    }

    var body: some View {
        Form {
            SlotIdentitySection(line: line)
            if let settings {
                SlotControlSection(settings: binding(for: settings), isActiveProfile: isActiveProfile)
                WiFiCallingSection(
                    settings: binding(for: settings),
                    canRefresh: isActiveProfile && settings.wifiCallingEnabled && settings == original && !isSaving && !isProbing,
                    isProbing: isProbing,
                    refresh: probeWiFiCalling
                )
            } else if isLoading {
                Section {
                    HStack {
                        ProgressView()
                        Text("Loading slot controls…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let errorDescription {
                SlotControlErrorSection(message: errorDescription, retry: load)
            }
        }
        .navigationTitle(profileName ?? (line.slotIndex.map { String(localized: "Slot \($0)") } ?? String(localized: "Slot")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") {
                        if isActiveProfile && settings?.volteEnabled != original?.volteEnabled {
                            showsVoLTERestartConfirmation = true
                        } else {
                            save(restartModem: false)
                        }
                    }
                        .disabled(!canSave)
                }
            }
        }
        .task { await loadSettings() }
        .interactiveDismissDisabled(isSaving)
        .confirmationDialog(
            "Restart Modem to Apply VoLTE?",
            isPresented: $showsVoLTERestartConfirmation,
            titleVisibility: .visible
        ) {
            Button("Save and Restart") { save(restartModem: true) }
            Button("Save Without Restart") { save(restartModem: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("VoLTE changes require a modem restart. Restarting temporarily takes this SIM offline.")
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }

    private var canSave: Bool {
        guard let settings, let original else { return false }
        return settings != original && !isSaving && !isProbing && line.isOnline
    }

    private func binding(for value: SlotSettings) -> Binding<SlotSettings> {
        Binding(
            get: { settings ?? value },
            set: { settings = $0 }
        )
    }

    private func load() {
        Task { await loadSettings() }
    }

    private func loadSettings() async {
        if profileID == nil, let cached = model.slotSettingsByLineID[line.id] {
            settings = cached
            original = cached
            isLoading = false
            errorDescription = nil
            return
        }
        isLoading = true
        errorDescription = nil
        do {
            let loaded: SlotSettings
            if let profileID {
                loaded = try await model.loadSlotSettings(line: line, profileID: profileID)
            } else {
                loaded = try await model.loadSlotSettings(line: line)
            }
            settings = loaded
            original = loaded
        } catch {
            errorDescription = error.localizedDescription
        }
        isLoading = false
    }

    private func save(restartModem: Bool) {
        guard let settings else { return }
        Task {
            isSaving = true
            errorDescription = nil
            do {
                if let profileID {
                    _ = try await model.saveSlotSettings(settings, line: line, profileID: profileID)
                } else {
                    _ = try await model.saveSlotSettings(settings, line: line)
                }
                if restartModem {
                    try await model.restartSlotModem(line: line)
                }
                dismiss()
            } catch {
                errorDescription = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func probeWiFiCalling() {
        guard isActiveProfile else { return }
        Task {
            isProbing = true
            errorDescription = nil
            do {
                let checked = try await model.probeWiFiCalling(line: line, profileID: profileID)
                settings = checked
                original = checked
            } catch {
                errorDescription = error.localizedDescription
            }
            isProbing = false
        }
    }
}

private struct SlotIdentitySection: View {
    let line: DeviceLineIdentity

    var body: some View {
        Section("Slot") {
            LabeledContent("Device", value: line.deviceName)
            LabeledContent("Status", value: line.isOnline ? String(localized: "Online") : String(localized: "Offline"))
            if line.simID != nil {
                LabeledContent("Line", value: line.displayName)
            }
        }
    }
}

struct SlotControlSection: View {
    @Binding var settings: SlotSettings
    var isActiveProfile = true

    var body: some View {
        Section {
            Toggle("Airplane Mode", isOn: $settings.airplaneModeEnabled)
            Toggle("Mobile Data", isOn: $settings.dataEnabled)
                .disabled(settings.airplaneModeEnabled)
            Toggle("Incoming Calls", isOn: $settings.incomingCallsEnabled)
                .disabled(settings.airplaneModeEnabled)
            Toggle("Incoming SMS", isOn: $settings.incomingSMSEnabled)
                .disabled(settings.airplaneModeEnabled)
            Toggle("VoLTE", isOn: $settings.volteEnabled)
                .disabled(settings.airplaneModeEnabled)
        } header: {
            Text("Slot Controls")
        } footer: {
            if !isActiveProfile {
                Text("Preferences for this plan are saved on the device and applied when the plan is activated.")
            } else if settings.airplaneModeEnabled {
                Text("Airplane mode disables cellular data, incoming calls, and incoming SMS. Your individual choices are restored when airplane mode is turned off.")
            } else {
                Text("These controls are end-to-end encrypted and applied directly by the modem device. VoLTE requires compatible modem firmware, carrier provisioning, and a modem restart after the setting changes.")
            }
        }
    }
}

struct WiFiCallingSection: View {
    @Binding var settings: SlotSettings
    let canRefresh: Bool
    let isProbing: Bool
    let refresh: () -> Void

    var body: some View {
        Section {
            Toggle("Wi-Fi Calling", isOn: $settings.wifiCallingEnabled)
                .disabled(isProbing)
            if settings.wifiCallingEnabled {
                LabeledContent("Gateway check", value: statusDescription)
                Button("Check Again", action: refresh)
                    .disabled(!canRefresh)
            }
        } header: {
            Text("Wi-Fi Calling")
        } footer: {
            Text("This device can check for a carrier gateway, but cannot yet register with carrier IMS over Wi-Fi. Calls still use the cellular modem.")
        }
    }

    private var statusDescription: String {
        if isProbing { return String(localized: "Checking…") }
        switch settings.wifiCallingStatus {
        case "off": return String(localized: "Off")
        case "inactive_profile": return String(localized: "Activate this plan to check")
        case "gateway_found": return String(localized: "Gateway found; calling unavailable")
        case "gateway_not_found": return String(localized: "No standard gateway found")
        case "probe_failed": return String(localized: "Check failed")
        default: return String(localized: "Not checked")
        }
    }
}

struct SlotControlErrorSection: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Button("Retry", action: retry)
        }
    }
}

#if DEBUG
#Preview("Slot Controls") {
    NavigationStack {
        SlotSettingsScreen(
            model: .preview(selectedTab: .profile),
            line: PreviewFixtures.devices[0]
        )
    }
}

#Preview("Slot Controls - Dark Large Text") {
    NavigationStack {
        SlotSettingsScreen(
            model: .preview(selectedTab: .profile),
            line: PreviewFixtures.devices[2]
        )
    }
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
