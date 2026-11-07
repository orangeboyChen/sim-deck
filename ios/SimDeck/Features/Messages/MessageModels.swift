// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

struct ConversationID: Hashable, Sendable {
    let deviceUUID: UUID
    let remoteNumber: String
}

enum MessageTimestampFormatter {
    static func string(from date: Date, relativeTo referenceDate: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDate(date, inSameDayAs: referenceDate) {
            return date.formatted(.dateTime.hour().minute())
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: referenceDate),
           calendar.isDate(date, inSameDayAs: yesterday) {
            let formatter = RelativeDateTimeFormatter()
            formatter.dateTimeStyle = .named
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: referenceDate).capitalized
        }
        if let weekInterval = calendar.dateInterval(of: .weekOfYear, for: referenceDate),
           weekInterval.contains(date) {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

struct MessageConversation: Identifiable, Equatable, Sendable, Codable {
    let lineID: UUID
    var lineSnapshot: LineHistorySnapshot?
    let remoteNumber: String
    var contactName: String?
    var unreadCount: Int
    var messages: [MessageItem]

    init(
        lineID: UUID,
        lineSnapshot: LineHistorySnapshot? = nil,
        remoteNumber: String,
        contactName: String?,
        unreadCount: Int,
        messages: [MessageItem]
    ) {
        self.lineID = lineID
        self.lineSnapshot = lineSnapshot
        self.remoteNumber = remoteNumber
        self.contactName = contactName
        self.unreadCount = unreadCount
        self.messages = messages
    }

    var id: ConversationID {
        ConversationID(deviceUUID: lineID, remoteNumber: remoteNumber)
    }

    var displayName: String {
        guard let contactName, !contactName.isEmpty else {
            return PhoneNumberDisplayFormatter.string(from: remoteNumber)
        }
        return contactName
    }

    var lastMessage: MessageItem? {
        messages.last
    }

    func linePresentation(in lines: [DeviceLineIdentity]) -> LineHistoryPresentation {
        LineHistoryPresentation(
            line: lines.first(where: { $0.id == lineID }),
            snapshot: lineSnapshot
        )
    }

    func lineAlternatives(in conversations: [MessageConversation]) -> [MessageConversation] {
        let normalizedRemoteNumber = Self.numberKey(remoteNumber)
        return conversations.filter {
            Self.numberKey($0.remoteNumber) == normalizedRemoteNumber
        }
    }

    static func numberKey(_ number: String) -> String {
        let normalized = DialString.normalized(number)
        if normalized.hasPrefix("+86"), normalized.count == 14,
           normalized.dropFirst(3).first == "1" {
            return String(normalized.dropFirst(3))
        }
        return normalized
    }

    func matches(_ query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return true }

        return displayName.localizedCaseInsensitiveContains(normalizedQuery)
            || remoteNumber.localizedCaseInsensitiveContains(normalizedQuery)
            || messages.contains { $0.body.localizedCaseInsensitiveContains(normalizedQuery) }
    }
}

struct MessageConversationListGroup: Identifiable {
    let members: [MessageConversation]

    var id: ConversationID { members[0].id }
    var conversationIDs: [ConversationID] { members.map(\.id) }

    var summary: MessageConversation {
        let latest = members.max {
            ($0.lastMessage?.sentAt ?? .distantPast) < ($1.lastMessage?.sentAt ?? .distantPast)
        } ?? members[0]
        return MessageConversation(
            lineID: members[0].lineID,
            lineSnapshot: latest.lineSnapshot,
            remoteNumber: members[0].remoteNumber,
            contactName: members.compactMap(\.contactName).first,
            unreadCount: members.reduce(0) { $0 + $1.unreadCount },
            messages: members.flatMap(\.messages).sorted { $0.sentAt < $1.sentAt }
        )
    }

    var latestConversation: MessageConversation {
        members.max {
            ($0.lastMessage?.sentAt ?? .distantPast) < ($1.lastMessage?.sentAt ?? .distantPast)
        } ?? members[0]
    }

    static func group(_ conversations: [MessageConversation]) -> [Self] {
        var groups: [Self] = []
        var indices: [String: Int] = [:]
        for conversation in conversations {
            let key = MessageConversation.numberKey(conversation.remoteNumber)
            if let index = indices[key] {
                groups[index] = Self(members: groups[index].members + [conversation])
            } else {
                indices[key] = groups.count
                groups.append(Self(members: [conversation]))
            }
        }
        return groups.map { group in
            Self(members: group.members.sorted {
                $0.lineID.uuidString < $1.lineID.uuidString
            })
        }
    }
}

struct MessageItem: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let sourceID: String?
    let direction: MessageDirection
    let body: String
    let attachment: MessageImageAttachment?
    let sentAt: Date
    var status: MessageDeliveryStatus

    init(
        id: UUID,
        sourceID: String? = nil,
        direction: MessageDirection,
        body: String,
        attachment: MessageImageAttachment?,
        sentAt: Date,
        status: MessageDeliveryStatus
    ) {
        self.id = id
        self.sourceID = sourceID
        self.direction = direction
        self.body = body
        self.attachment = attachment
        self.sentAt = sentAt
        self.status = status
    }

    var displaysDeliveryStatus: Bool {
        direction == .sent
    }
}

struct MessageImageAttachment: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let data: Data?
    let mimeType: String?
    let filename: String?
    let systemImageName: String?

    init(
        id: UUID = UUID(),
        data: Data,
        mimeType: String,
        filename: String
    ) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.filename = filename
        systemImageName = nil
    }

    init(id: UUID = UUID(), systemImageName: String) {
        self.id = id
        data = nil
        mimeType = nil
        filename = nil
        self.systemImageName = systemImageName
    }
}

enum MessageDirection: Equatable, Sendable, Codable {
    case received
    case sent
}

enum MessageDeliveryStatus: Equatable, Sendable, Codable {
    case sending
    case sent
    case delivered
    case failed
}

enum MessageListState: Equatable, Sendable {
    case loading
    case loaded([MessageConversation])
    case failed
}
