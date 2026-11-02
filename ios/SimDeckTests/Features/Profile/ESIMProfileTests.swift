// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
import RelayProtocol
@testable import SimDeck

final class ESIMProfileTests: XCTestCase {
    @MainActor
    func testEmptyModemProfileListDoesNotRequireServerMetadata() async throws {
        let metadata = ESIMMetadataStoreFake()
        metadata.listError = TestError.failed
        let manager = LiveESIMProfileManager(metadataStore: metadata, device: FakeESIMDeviceTransport())
        let line = DeviceLineIdentity(
            id: UUID(),
            deviceID: UUID(),
            simID: UUID(),
            numericID: 2,
            deviceName: "Modem",
            lineName: "",
            phoneNumber: "",
            isOnline: true,
            commandPublicKey: nil,
            simKind: .eSIM
        )

        let profiles = try await manager.loadProfiles(line: line)
        XCTAssertEqual(profiles, [])
        XCTAssertEqual(metadata.listCalls, 0)
    }

    @MainActor
    func testModemProfilesRemainAvailableWhenServerMetadataFails() async throws {
        let metadata = ESIMMetadataStoreFake()
        metadata.listError = TestError.failed
        let device = FakeESIMDeviceTransport(profiles: [
            DeviceESIMProfile(
                profileID: "89000000000000000001",
                iccid: "89000000000000000001",
                enabled: false,
                nickname: "",
                provider: ""
            )
        ])
        let manager = LiveESIMProfileManager(metadataStore: metadata, device: device)
        let line = DeviceLineIdentity(
            id: UUID(),
            deviceID: UUID(),
            simID: UUID(),
            numericID: 2,
            deviceName: "Modem",
            lineName: "",
            phoneNumber: "",
            isOnline: true,
            commandPublicKey: nil,
            simKind: .eSIM
        )

        let profiles = try await manager.loadProfiles(line: line)
        XCTAssertEqual(profiles.map(\.profileID), ["89000000000000000001"])
        XCTAssertEqual(profiles.first?.iccid, "89000000000000000001")
        XCTAssertEqual(metadata.listCalls, 1)
    }

    func testSuccessfulCommandWithoutProfilesIsAnEmptyList() throws {
        let result = try JSONDecoder().decode(
            CallCommandResult.self,
            from: #"{"version":1,"success":true,"call_state":"idle"}"#.data(using: .utf8)!
        )

        XCTAssertEqual(result.esimProfiles ?? [], [])
    }

    func testDisplayNamePrefersCustomNameThenProfileIDThenICCID() {
        XCTAssertEqual(
            ESIMProfile(profileID: "profile-1", name: "Travel").displayName,
            "Travel"
        )
        XCTAssertEqual(
            ESIMProfile(profileID: "profile-1").displayName,
            "profile-1"
        )
        XCTAssertEqual(
            ESIMProfile(profileID: "", iccid: "8986000000000000001").displayName,
            "8986000000000000001"
        )
    }

    func testDetailSubtitleContainsOperatorAndICCID() {
        let profile = ESIMProfile(
            profileID: "profile-1",
            iccid: "8986000000000000001",
            operatorName: "Example Mobile"
        )

        XCTAssertEqual(
            profile.detailSubtitle,
            "Example Mobile · 8986000000000000001"
        )
    }
}

@MainActor
private final class FakeESIMDeviceTransport: ESIMDeviceProfileTransport {
    let profiles: [DeviceESIMProfile]

    init(profiles: [DeviceESIMProfile] = []) {
        self.profiles = profiles
    }

    func list(line: DeviceLineIdentity) async throws -> [DeviceESIMProfile] { profiles }
    func addActivationCode(_ code: String, line: DeviceLineIdentity) async throws -> [DeviceESIMProfile] { [] }
    func setEnabled(_ enabled: Bool, profileID: String, line: DeviceLineIdentity) async throws {}
    func rename(_ name: String, profileID: String, line: DeviceLineIdentity) async throws {}
    func delete(profileID: String, line: DeviceLineIdentity) async throws {}
}

@MainActor
final class ESIMMetadataStoreFake: ESIMProfileMetadataStore {
    var listCalls = 0
    var listError: Error?

    func listESIMProfiles(simID: UUID) async throws -> [Relay_Communication_V1_EsimProfile] {
        listCalls += 1
        if let listError { throw listError }
        return []
    }

    func addESIMProfile(simID: UUID, profileID: String, name: String, iccid: String, operatorName: String) async throws -> Relay_Communication_V1_EsimProfile {
        throw TestError.failed
    }

    func renameESIMProfile(simID: UUID, profileID: String, name: String) async throws -> Relay_Communication_V1_EsimProfile {
        throw TestError.failed
    }

    func setESIMProfileEnabled(simID: UUID, profileID: String, enabled: Bool) async throws -> Relay_Communication_V1_EsimProfile {
        throw TestError.failed
    }

    func deleteESIMProfile(simID: UUID, profileID: String) async throws {
        throw TestError.failed
    }
}

private enum TestError: Error {
    case failed
}
