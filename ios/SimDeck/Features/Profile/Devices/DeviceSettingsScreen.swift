// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct DeviceSettingsDraft: Equatable {
    var deviceName: String

    init(line: DeviceLineIdentity) {
        deviceName = line.deviceName
    }

    var isValid: Bool { true }
}

struct DeviceSettingsScreen: View {
    let model: AppModel
    let line: DeviceLineIdentity

    @Environment(\.dismiss) private var dismiss
    @State private var draft: DeviceSettingsDraft
    @State private var isWorking = false
    @State private var errorDescription: String?
    @State private var isConfirmingRemoval = false

    private let original: DeviceSettingsDraft

    init(model: AppModel, line: DeviceLineIdentity) {
        self.model = model
        self.line = line
        let draft = DeviceSettingsDraft(line: line)
        original = draft
        _draft = State(initialValue: draft)
    }

    var body: some View {
        Form {
            Section {
                TextField("Device name", text: $draft.deviceName)
                    .textContentType(.name)
            } header: {
                Text("Identity")
            } footer: {
                Text("Names and phone numbers are encrypted on this iPhone before upload.")
            }

            if !model.canEditDeviceProfiles {
                Section {
                    Label(
                        "Restore the encryption key before editing this device.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }

            if let errorDescription {
                Section {
                    Label(errorDescription, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("Remove Device", role: .destructive) {
                    isConfirmingRemoval = true
                }
                .disabled(isWorking)
            } footer: {
                Text("Removing a device disconnects it immediately. To add it again, turn on Device Discovery and restart the modem container.")
            }
        }
        .navigationTitle("Device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
                .disabled(!canSave)
            }
        }
        .confirmationDialog(
            "Remove this device?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Device", role: .destructive) {
                remove()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The modem credential will stop working immediately. This action cannot be undone.")
        }
        .interactiveDismissDisabled(isWorking)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }

    private var canSave: Bool {
        draft.isValid && draft != original && !isWorking && model.canEditDeviceProfiles
    }

    private func save() {
        Task {
            isWorking = true
            errorDescription = nil
            do {
                try await model.saveDeviceName(
                    line: line,
                    deviceName: draft.deviceName
                )
                dismiss()
            } catch {
                errorDescription = error.localizedDescription
                isWorking = false
            }
        }
    }

    private func remove() {
        Task {
            isWorking = true
            errorDescription = nil
            do {
                try await model.removeDevice(line: line)
                dismiss()
            } catch {
                errorDescription = error.localizedDescription
                isWorking = false
            }
        }
    }
}

struct SIMSettingsScreen: View {
    let model: AppModel
    let line: DeviceLineIdentity

    @Environment(\.dismiss) private var dismiss
    @State private var numericID: Int
    @State private var lineName: String
    @State private var phoneNumber: String
    @State private var saveErrorDescription: String?
    @State private var controlErrorDescription: String?
    @State private var slotSettings: SlotSettings?
    @State private var originalSlotSettings: SlotSettings?
    @State private var isLoadingControls = true
    @State private var isWorking = false
    @State private var isProbingWiFiCalling = false
    @State private var activeESIMProfileID: String?
    @State private var activeESIMProfileName: String?
    @State private var showsVoLTERestartConfirmation = false

    init(model: AppModel, line: DeviceLineIdentity) {
        self.model = model
        self.line = line
        _numericID = State(initialValue: line.numericID)
        _lineName = State(initialValue: line.lineName)
        _phoneNumber = State(initialValue: line.phoneNumber)
        let cached = model.slotSettingsByLineID[line.id]
        _slotSettings = State(initialValue: cached)
        _originalSlotSettings = State(initialValue: cached)
        _isLoadingControls = State(initialValue: cached == nil && line.isOnline)
    }

    var body: some View {
        Form {
            Section("SIM Card") {
                Stepper(value: $numericID, in: 1...99) {
                    LabeledContent("SIM ID", value: numericID, format: .number)
                }
                LabeledContent("Type", value: line.simKind.displayName)
                TextField("Line name", text: $lineName)
                TextField("Phone number", text: $phoneNumber)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.numbersAndPunctuation)

            }
            if line.simKind == .eSIM {
                Section {
                    NavigationLink {
                        ESIMManagementScreen(model: model, line: line)
                    } label: {
                        Label("eSIM Configuration", systemImage: "simcard.2")
                    }
                } footer: {
                    Text("Manage the cellular profiles installed on this eSIM.")
                }
                if let activeESIMProfileName {
                    Section("Current eSIM Plan") {
                        LabeledContent("Plan", value: activeESIMProfileName)
                    }
                }
            }
            if let slotSettings {
                SlotControlSection(settings: slotSettingsBinding(for: slotSettings))
                WiFiCallingSection(
                    settings: slotSettingsBinding(for: slotSettings),
                    canRefresh: slotSettings == originalSlotSettings
                        && !isWorking && !isProbingWiFiCalling && line.isOnline,
                    isProbing: isProbingWiFiCalling,
                    refresh: probeWiFiCalling
                )
            } else if isLoadingControls {
                Section("Slot Controls") {
                    HStack {
                        ProgressView()
                        Text("Loading slot controls…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if !line.isOnline {
                Section("Slot Controls") {
                    Label("This SIM is offline.", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                }
            }
            if let controlErrorDescription {
                SlotControlErrorSection(message: controlErrorDescription) {
                    Task { await reloadControls() }
                }
            }
            Section("MMS") {
                NavigationLink("MMS Configuration") { MMSSettingsScreen() }
            }
        }
        .navigationTitle("SIM Card")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isWorking {
                    ProgressView()
                } else {
                    Button("Save") {
                        if slotSettings?.volteEnabled != originalSlotSettings?.volteEnabled {
                            showsVoLTERestartConfirmation = true
                        } else {
                            save(restartModem: false)
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
        .onAppear {
            Task { await reloadControls() }
        }
        .interactiveDismissDisabled(isWorking)
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
        .alert("Unable to Save SIM", isPresented: Binding(
            get: { saveErrorDescription != nil },
            set: { if !$0 { saveErrorDescription = nil } }
        )) {
            Button("OK", role: .cancel) { saveErrorDescription = nil }
        } message: {
            Text(saveErrorDescription ?? "")
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }

    private var canSave: Bool {
        guard model.canEditDeviceProfiles, !isWorking, !isProbingWiFiCalling else { return false }
        return identityChanged || controlsChanged
    }

    private var identityChanged: Bool {
        numericID != line.numericID || lineName != line.lineName || phoneNumber != line.phoneNumber
    }

    private var controlsChanged: Bool {
        slotSettings != nil && slotSettings != originalSlotSettings
    }

    private func slotSettingsBinding(for value: SlotSettings) -> Binding<SlotSettings> {
        Binding(
            get: { slotSettings ?? value },
            set: { slotSettings = $0 }
        )
    }

    private func reloadControls() async {
        if line.simKind == .eSIM {
            slotSettings = nil
            originalSlotSettings = nil
            isLoadingControls = line.isOnline
            guard await loadActiveESIMProfile() else {
                isLoadingControls = false
                return
            }
        }
        await loadSlotSettings()
    }

    private func loadSlotSettings() async {
        if line.simKind != .eSIM, let cached = model.slotSettingsByLineID[line.id] {
            slotSettings = cached
            originalSlotSettings = cached
            isLoadingControls = false
            controlErrorDescription = nil
            return
        }
        isLoadingControls = line.isOnline
        controlErrorDescription = nil
        if line.simKind == .eSIM {
            slotSettings = nil
            originalSlotSettings = nil
        }
        guard line.isOnline else { return }
        do {
            let loaded: SlotSettings
            if line.simKind == .eSIM {
                guard let activeESIMProfileID else { throw ActiveESIMPlanError.unavailable }
                loaded = try await model.loadSlotSettings(line: line, profileID: activeESIMProfileID)
            } else {
                loaded = try await model.loadSlotSettings(line: line)
            }
            slotSettings = loaded
            originalSlotSettings = loaded
        } catch {
            controlErrorDescription = error.localizedDescription
        }
        isLoadingControls = false
    }

    private func loadActiveESIMProfile() async -> Bool {
        activeESIMProfileID = nil
        activeESIMProfileName = nil
        do {
            let profiles = try await model.loadESIMProfiles(line: line)
            let active = profiles.first(where: \.isEnabled)
            activeESIMProfileID = active?.profileID
            activeESIMProfileName = active?.displayName
            return true
        } catch {
            controlErrorDescription = error.localizedDescription
            return false
        }
    }

    private func probeWiFiCalling() {
        Task {
            isProbingWiFiCalling = true
            controlErrorDescription = nil
            do {
                let checked = try await model.probeWiFiCalling(
                    line: line,
                    profileID: line.simKind == .eSIM ? activeESIMProfileID : nil
                )
                slotSettings = checked
                originalSlotSettings = checked
            } catch {
                controlErrorDescription = error.localizedDescription
            }
            isProbingWiFiCalling = false
        }
    }

    private func save(restartModem: Bool) {
        Task {
            isWorking = true
            saveErrorDescription = nil
            do {
                if controlsChanged && line.simKind == .eSIM {
                    try await confirmActiveESIMProfile()
                }
                if identityChanged {
                    try await model.saveSIM(line: line, numericID: numericID, lineName: lineName, phoneNumber: phoneNumber)
                }
                if controlsChanged, let slotSettings {
                    if line.simKind == .eSIM {
                        guard let activeESIMProfileID else { throw ActiveESIMPlanError.unavailable }
                        _ = try await model.saveSlotSettings(slotSettings, line: line, profileID: activeESIMProfileID)
                    } else {
                        _ = try await model.saveSlotSettings(slotSettings, line: line)
                    }
                    if line.simKind == .eSIM {
                        try await confirmActiveESIMProfile()
                    }
                    if restartModem {
                        try await model.restartSlotModem(line: line)
                    }
                }
                dismiss()
            } catch {
                saveErrorDescription = error.localizedDescription
                isWorking = false
            }
        }
    }

    private func confirmActiveESIMProfile() async throws {
        guard let activeESIMProfileID else { throw ActiveESIMPlanError.unavailable }
        let profiles = try await model.loadESIMProfiles(line: line)
        guard profiles.first(where: \.isEnabled)?.profileID == activeESIMProfileID else {
            throw ActiveESIMPlanError.changed
        }
    }
}

private enum ActiveESIMPlanError: LocalizedError {
    case unavailable
    case changed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "Activate an eSIM plan to load its SIM controls.")
        case .changed:
            String(localized: "The active eSIM plan changed. Reload SIM controls before saving.")
        }
    }
}

struct MMSSettingsScreen: View {
    @State private var apn = ""
    @State private var mmsc = ""
    @State private var proxy = ""
    @State private var sizeLimit = 1_024

    var body: some View {
        Form {
            TextField("APN", text: $apn)
            TextField("MMSC", text: $mmsc)
                .textInputAutocapitalization(.never)
            TextField("Proxy", text: $proxy)
                .textInputAutocapitalization(.never)
            Stepper("Size limit: \(sizeLimit) KB", value: $sizeLimit, in: 128...10_240, step: 128)
        }
        .navigationTitle("MMS Configuration")
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

#if DEBUG
#Preview("Device Settings") {
    NavigationStack {
        DeviceSettingsScreen(
            model: .preview(selectedTab: .profile),
            line: PreviewFixtures.devices[0]
        )
    }
}

#Preview("Device Settings - Large Text") {
    NavigationStack {
        DeviceSettingsScreen(
            model: .preview(selectedTab: .profile),
            line: PreviewFixtures.devices[2]
        )
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("MMS Settings") {
    NavigationStack {
        MMSSettingsScreen()
    }
}

#Preview("SIM Settings") {
    NavigationStack {
        SIMSettingsScreen(
            model: .preview(selectedTab: .profile),
            line: PreviewFixtures.devices[0]
        )
    }
}
#endif
