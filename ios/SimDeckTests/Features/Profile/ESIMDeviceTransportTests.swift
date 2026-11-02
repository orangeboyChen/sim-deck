// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import XCTest
@testable import SimDeck

@MainActor
final class ESIMDeviceTransportTests: XCTestCase {
    func testDeviceJSONAcceptsOmittedDisplayMetadata() throws {
        let fixture = try ESIMWireFixture.load()
        for vector in fixture.successResults {
            do {
                let result = try JSONDecoder().decode(CallCommandResult.self, from: Data(vector.plaintext.utf8))
                XCTAssertTrue(result.success)
                assertProfiles(result.esimProfiles ?? [], for: vector.name)
            } catch {
                XCTFail("Go response \(vector.name) failed to decode: \(error)")
            }
        }
    }

    func testLiveTransportDecryptsGoDeviceResultsIncludingEmptyAndUnnamedProfiles() async throws {
        let fixture = try ESIMWireFixture.load()
        for vector in fixture.successResults {
            let api = ESIMWireAPI(fixture: fixture, vector: vector)
            let transport = try makeTransport(api: api)
            do {
                let profiles = try await transport.list(line: line(fixture))
                assertProfiles(profiles, for: vector.name)
                XCTAssertEqual(api.requests.count, 1)
                XCTAssertEqual(api.statusRequests, 1)
            } catch {
                XCTFail("Go encrypted response \(vector.name) failed through live transport: \(error.localizedDescription)")
            }
        }
    }

    func testDownloadDecodesDeviceProfileWithoutDisplayMetadata() async throws {
        let fixture = try ESIMWireFixture.load()
        let vector = try XCTUnwrap(fixture.results.first { $0.name == "without_metadata" })
        let api = ESIMWireAPI(fixture: fixture, vector: vector)
        let profiles = try await makeTransport(api: api).addActivationCode(
            "LPA:1$example.test$synthetic-code", line: line(fixture)
        )
        assertProfiles(profiles, for: vector.name)
    }

    func testAppModelLoadsEmptyAndUnnamedProfilesThroughLiveManagerAndTransport() async throws {
        let fixture = try ESIMWireFixture.load()
        for vector in fixture.successResults {
            let api = ESIMWireAPI(fixture: fixture, vector: vector)
            let metadata = ESIMMetadataStoreFake()
            metadata.listError = URLError(.cannotConnectToHost)
            let manager = LiveESIMProfileManager(metadataStore: metadata, device: try makeTransport(api: api))
            let model = AppModel(esimProfileManager: manager, remoteDeviceRefreshEnabled: false)

            let profiles = try await model.loadESIMProfiles(line: line(fixture))

            XCTAssertEqual(api.requests.count, 1)
            if ["empty", "null", "omitted"].contains(vector.name) {
                XCTAssertEqual(profiles, [])
                XCTAssertEqual(metadata.listCalls, 0)
            } else {
                XCTAssertEqual(profiles.count, 1)
                XCTAssertEqual(profiles.first?.profileID, "89000000000000000001")
                XCTAssertEqual(profiles.first?.isEnabled, false)
                XCTAssertEqual(metadata.listCalls, 1)
            }
        }
    }

    func testMalformedResponseAndTimeoutAreNotReportedAsOffline() async throws {
        let fixture = try ESIMWireFixture.load()
        let vector = try XCTUnwrap(fixture.successResults.first)
        let api = ESIMWireAPI(fixture: fixture, vector: vector)
        let transport = try makeTransport(api: api)
        api.omitResult = true
        await assertError(.invalidResponse) { _ = try await transport.list(line: self.line(fixture)) }
        api.omitResult = false
        api.corruptResult = true
        await assertError(.invalidResponse) { _ = try await transport.list(line: self.line(fixture)) }
        api.corruptResult = false
        api.statusState = "pending"
        let previousRequests = api.statusRequests
        await assertError(.timedOut) { _ = try await transport.list(line: self.line(fixture)) }
        XCTAssertEqual(api.statusRequests - previousRequests, 60)
    }

    func testDeviceRejectionsPreserveTheirReason() async throws {
        let fixture = try ESIMWireFixture.load()
        for vector in fixture.results where !fixture.successResults.contains(where: { $0.name == vector.name }) {
            let api = ESIMWireAPI(fixture: fixture, vector: vector)
            let expected: ESIMProfileManagerError = vector.name == "esim_unavailable" ? .unsupported : .commandRejected(vector.name)
            await assertError(expected) {
                _ = try await self.makeTransport(api: api).list(line: self.line(fixture))
            }
        }
    }

    func testMissingIdentityFailsBeforeSendingACommand() async throws {
        let fixture = try ESIMWireFixture.load()
        let api = ESIMWireAPI(fixture: fixture, vector: try XCTUnwrap(fixture.successResults.first))
        let transport = LiveESIMDeviceProfileTransport(api: api, commandSigner: InstallationCommandSigner())
        await assertError(.identityUnavailable) { _ = try await transport.list(line: self.line(fixture)) }
        XCTAssertTrue(api.requests.isEmpty)
    }

    func testRequiredFieldsAndWrongMetadataTypesStillFailDecoding() throws {
        for json in [
            #"{"iccid":"89000000000000000001","enabled":false}"#,
            #"{"profile_id":"89000000000000000001","iccid":"89000000000000000001"}"#,
            #"{"profile_id":"89000000000000000001","iccid":"89000000000000000001","enabled":false,"nickname":42}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(DeviceESIMProfile.self, from: Data(json.utf8)))
        }
        let nullMetadata = try JSONDecoder().decode(DeviceESIMProfile.self, from: Data(
            #"{"profile_id":"89000000000000000001","iccid":"89000000000000000001","enabled":false,"nickname":null,"provider":null}"#.utf8
        ))
        XCTAssertEqual(nullMetadata.nickname, "")
        XCTAssertEqual(nullMetadata.provider, "")
    }

    private func assertError(_ expected: ESIMProfileManagerError, operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? ESIMProfileManagerError, expected)
            XCTAssertFalse(error.localizedDescription.localizedCaseInsensitiveContains("offline"))
        }
    }

    private func assertProfiles(_ profiles: [DeviceESIMProfile], for name: String) {
        if ["empty", "null", "omitted"].contains(name) {
            XCTAssertEqual(profiles, [], name)
        } else {
            XCTAssertEqual(profiles.count, 1, name)
            XCTAssertEqual(profiles.first?.profileID, "89000000000000000001", name)
            XCTAssertEqual(profiles.first?.iccid, "89000000000000000001", name)
            XCTAssertEqual(profiles.first?.enabled, false, name)
            XCTAssertEqual(profiles.first?.nickname, ["nickname_only", "full_metadata"].contains(name) ? "Travel" : "", name)
            XCTAssertEqual(profiles.first?.provider, ["provider_only", "full_metadata"].contains(name) ? "Example Mobile" : "", name)
        }
    }

    private func makeTransport(api: ESIMWireAPI) throws -> LiveESIMDeviceProfileTransport {
        let senderKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: api.fixture.senderPrivateKey)
        return LiveESIMDeviceProfileTransport(
            api: api,
            commandSigner: InstallationCommandSigner(identity: api.identity),
            makeCommandID: { api.fixture.commandID },
            makeSenderKey: { senderKey },
            waitBeforePollingAgain: {}
        )
    }

    private func line(_ fixture: ESIMWireFixture) -> DeviceLineIdentity {
        DeviceLineIdentity(
            id: fixture.deviceID, deviceID: fixture.deviceID,
            simID: UUID(uuidString: "01900000-0000-7000-8000-000000000403")!,
            numericID: 2, deviceName: "EC20F", lineName: "", phoneNumber: "",
            isOnline: false, commandPublicKey: fixture.devicePublicKey, simKind: .eSIM
        )
    }
}

private struct ESIMWireFixture: Decodable {
    let deviceID: UUID
    let commandID: UUID
    let devicePublicKey: Data
    let senderPrivateKey: Data
    let results: [Vector]

    var successResults: [Vector] {
        results.filter { !["esim_unavailable", "wrong_sim_slot", "modem_rejected"].contains($0.name) }
    }

    struct Vector: Decodable {
        let name: String
        let plaintext: String
        let nonce: Data
        let ciphertext: Data
    }

    static func load() throws -> ESIMWireFixture {
        let url = try XCTUnwrap(Bundle(for: ESIMDeviceTransportTests.self).url(forResource: "esim-command-results", withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ESIMWireFixture.self, from: data)
    }
}

@MainActor
private final class ESIMWireAPI: EncryptedCallCommandAPI {
    let fixture: ESIMWireFixture
    let vector: ESIMWireFixture.Vector
    let identity = InstallationIdentity(
        id: UUID(uuidString: "01900000-0000-7000-8000-000000000405")!,
        signingPrivateKey: Data(repeating: 3, count: 32),
        keyAgreementPrivateKey: Data(repeating: 4, count: 32),
        pendingRevocationIDs: []
    )
    private(set) var requests: [EncryptedCallCommandRequest] = []
    private(set) var statusRequests = 0
    var statusState = "completed"
    var omitResult = false
    var corruptResult = false

    init(fixture: ESIMWireFixture, vector: ESIMWireFixture.Vector) {
        self.fixture = fixture
        self.vector = vector
    }

    func commandRecipient(deviceID: UUID) async throws -> Data { fixture.devicePublicKey }
    func eventVerificationKey(deviceID: UUID) async throws -> Data { Data(repeating: 0, count: 32) }

    func enqueueCommand(deviceID: UUID, command: EncryptedCallCommandRequest) async throws {
        XCTAssertEqual(deviceID, fixture.deviceID)
        XCTAssertEqual(command.id, fixture.commandID)
        requests.append(command)
    }

    func commandStatus(deviceID: UUID, commandID: UUID) async throws -> EncryptedCallCommandStatus {
        statusRequests += 1
        return EncryptedCallCommandStatus(
            id: commandID, deviceUUID: deviceID, state: statusState,
            result: omitResult ? nil : EncryptedCallCommandResult(
                nonce: vector.nonce,
                ciphertext: corruptResult ? Data(repeating: 0, count: vector.ciphertext.count) : vector.ciphertext
            )
        )
    }

    func encryptedEvents(afterSequence: Int64) async throws -> EncryptedEventPage {
        EncryptedEventPage(events: [], nextSequence: afterSequence)
    }
}
