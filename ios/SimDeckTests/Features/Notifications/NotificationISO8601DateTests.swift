// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import XCTest
@testable import SimDeck

final class NotificationISO8601DateTests: XCTestCase {
    private struct Timestamp: Decodable {
        let occurredAt: Date
    }

    func testDecodesDeviceEventTimestampWithMilliseconds() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(NotificationISO8601Date.decode)
        let timestamp = try decoder.decode(
            Timestamp.self,
            from: Data(#"{"occurredAt":"2026-11-07T08:09:10.123Z"}"#.utf8)
        )
        XCTAssertEqual(timestamp.occurredAt.timeIntervalSince1970, 1_794_038_950.123, accuracy: 0.001)
        XCTAssertEqual(
            NotificationISO8601Date.signedNanoseconds(timestamp.occurredAt),
            1_794_038_950_123_000_000
        )
    }

    func testDecodesWholeSecondTimestamp() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(NotificationISO8601Date.decode)
        let timestamp = try decoder.decode(
            Timestamp.self,
            from: Data(#"{"occurredAt":"2026-11-07T08:09:10Z"}"#.utf8)
        )
        XCTAssertEqual(timestamp.occurredAt.timeIntervalSince1970, 1_794_038_950, accuracy: 0.001)
    }
}
