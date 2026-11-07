// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import XCTest
@testable import SimDeck

final class MessageConversationListGroupTests: XCTestCase {
    func testGroupsSameNumberAcrossSIMsAndKeepsLatestPreview() throws {
        let firstLine = UUID(uuidString: "01900000-0000-7000-8000-000000000001")!
        let secondLine = UUID(uuidString: "01900000-0000-7000-8000-000000000002")!
        let older = conversation(
            lineID: firstLine,
            number: "+86 135 0000 0000",
            unread: 1,
            body: "older",
            time: 100
        )
        let newer = conversation(
            lineID: secondLine,
            number: "13500000000",
            unread: 2,
            body: "newer",
            time: 200
        )

        let group = try XCTUnwrap(MessageConversationListGroup.group([newer, older]).first)

        XCTAssertEqual(MessageConversationListGroup.group([newer, older]).count, 1)
        XCTAssertEqual(Set(group.conversationIDs), Set([older.id, newer.id]))
        XCTAssertEqual(group.summary.unreadCount, 3)
        XCTAssertEqual(group.summary.messages.map(\.body), ["older", "newer"])
        XCTAssertEqual(group.latestConversation.id, newer.id)
        XCTAssertEqual(older.lineAlternatives(in: [older, newer]).count, 2)
    }

    func testKeepsDifferentNumbersSeparate() {
        let line = UUID()
        let conversations = [
            conversation(lineID: line, number: "10086", unread: 0, body: "a", time: 100),
            conversation(lineID: line, number: "10010", unread: 0, body: "b", time: 200),
        ]

        XCTAssertEqual(MessageConversationListGroup.group(conversations).count, 2)
    }

    private func conversation(
        lineID: UUID,
        number: String,
        unread: Int,
        body: String,
        time: TimeInterval
    ) -> MessageConversation {
        MessageConversation(
            lineID: lineID,
            remoteNumber: number,
            contactName: nil,
            unreadCount: unread,
            messages: [MessageItem(
                id: UUID(),
                direction: .received,
                body: body,
                attachment: nil,
                sentAt: Date(timeIntervalSince1970: time),
                status: .delivered
            )]
        )
    }
}
