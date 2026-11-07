// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct MessagesScreen: View {
    let state: MessageListState
    let lines: [DeviceLineIdentity]
    let contacts: [ContactRecord]
    let referenceDate: Date
    let defaultLineID: UUID?
    let refreshAction: () async -> Void
    let sendAction: (UUID, String, String) async throws -> Void
    let sendImageAction: (UUID, String, String, MessageImageAttachment) async throws -> Void
    let retryAction: (UUID) async throws -> Void
    let deleteAction: (Set<UUID>) throws -> Void
    let markReadAction: (ConversationID) -> Void
    let markUnreadAction: (ConversationID) -> Void
    let isMutedAction: (ConversationID) -> Bool
    let setMutedAction: (ConversationID, Bool) -> Void
    let callAction: (String) async -> Void

    @Binding private var searchText: String
    @Binding private var selectedLineID: UUID?
    @Binding private var editMode: EditMode
    @Binding private var selectedConversationIDs: Set<ConversationID>
    @State private var conversationsPendingDeletion: [MessageConversation] = []
    @State private var deleteErrorMessage: String?
    @State private var mutedConversationIDs: Set<ConversationID> = []
    @State private var pinnedConversationIDs: Set<ConversationID> = []

    init(
        state: MessageListState,
        lines: [DeviceLineIdentity],
        searchText: Binding<String> = .constant(""),
        selectedLineID: Binding<UUID?> = .constant(nil),
        editMode: Binding<EditMode> = .constant(.inactive),
        selectedConversationIDs: Binding<Set<ConversationID>> = .constant([]),
        contacts: [ContactRecord] = [],
        referenceDate: Date = .now,
        defaultLineID: UUID? = nil,
        refreshAction: @escaping () async -> Void = {},
        sendAction: @escaping (UUID, String, String) async throws -> Void = { _, _, _ in },
        sendImageAction: @escaping (
            UUID,
            String,
            String,
            MessageImageAttachment
        ) async throws -> Void = { _, _, _, _ in },
        retryAction: @escaping (UUID) async throws -> Void = { _ in },
        deleteAction: @escaping (Set<UUID>) throws -> Void = { _ in },
        markReadAction: @escaping (ConversationID) -> Void = { _ in },
        markUnreadAction: @escaping (ConversationID) -> Void = { _ in },
        isMutedAction: @escaping (ConversationID) -> Bool = { _ in false },
        setMutedAction: @escaping (ConversationID, Bool) -> Void = { _, _ in },
        callAction: @escaping (String) async -> Void = { _ in }
    ) {
        self.state = state
        self.lines = lines
        _searchText = searchText
        _selectedLineID = selectedLineID
        _editMode = editMode
        _selectedConversationIDs = selectedConversationIDs
        self.contacts = contacts
        self.referenceDate = referenceDate
        self.defaultLineID = defaultLineID
        self.refreshAction = refreshAction
        self.sendAction = sendAction
        self.sendImageAction = sendImageAction
        self.retryAction = retryAction
        self.deleteAction = deleteAction
        self.markReadAction = markReadAction
        self.markUnreadAction = markUnreadAction
        self.isMutedAction = isMutedAction
        self.setMutedAction = setMutedAction
        self.callAction = callAction
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading messages")
            case .loaded(let conversations) where conversations.isEmpty:
                refreshableEmptyState {
                    ContentUnavailableView(
                        "No Messages",
                        systemImage: "message",
                        description: Text("Messages sent through sim-deck appear here.")
                    )
                }
            case .loaded(let conversations):
                conversationList(conversations)
            case .failed:
                refreshableEmptyState {
                    ContentUnavailableView(
                        "Messages Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Check the server connection and try again.")
                    )
                }
            }
        }
        .environment(\.editMode, $editMode)
        .toolbar(editMode.isEditing ? .hidden : .visible, for: .tabBar)
        .task {
            synchronizeMutedConversations()
            synchronizePinnedConversations()
        }
        .refreshable {
            await refreshAction()
        }
        .contentMargins(.bottom, editMode.isEditing ? 64 : 0, for: .scrollContent)
        .overlay(alignment: .bottom) {
            if editMode.isEditing {
                messageSelectionBar
            }
        }
        .onChange(of: editMode) { _, newMode in
            if !newMode.isEditing {
                selectedConversationIDs.removeAll()
            }
        }
        .onChange(of: allConversationIDs) { _, conversationIDs in
            selectedConversationIDs.formIntersection(conversationIDs)
            if conversationIDs.isEmpty {
                editMode = .inactive
            }
        }
        .alert("Delete Conversations?", isPresented: deletionConfirmationIsPresented) {
            Button("Delete", role: .destructive) {
                deletePendingConversations()
            }
            Button("Cancel", role: .cancel) {
                conversationsPendingDeletion = []
            }
        } message: {
            Text("All messages in the selected conversations will be removed from this iPhone.")
        }
        .alert("Unable to Delete", isPresented: deleteErrorIsPresented) {
            Button("OK", role: .cancel) {
                deleteErrorMessage = nil
            }
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }

    private func refreshableEmptyState<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        GeometryReader { proxy in
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }

    private func conversationList(_ conversations: [MessageConversation]) -> some View {
        let contactIndex = ContactRecordIndex(contacts: contacts)
        let filtered = filteredConversations(conversations)

        return Group {
            if filtered.isEmpty {
                refreshableEmptyState {
                    ContentUnavailableView.search(text: searchText)
                }
            } else {
                List(selection: editMode.isEditing ? $selectedConversationIDs : nil) {
                    ForEach(filtered) { group in
                        conversationRow(
                            group,
                            contact: contactIndex.contact(for: group.summary.remoteNumber)
                        )
                            .tag(group.id)
                            .listRowInsets(
                                EdgeInsets(top: 0, leading: 26, bottom: 0, trailing: 16)
                            )
                            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                                dimensions[.leading] + 58
                            }
                    }
                }
                .listStyle(.plain)
                .onChange(of: filtered.map(\.id)) { _, conversationIDs in
                    selectedConversationIDs.formIntersection(conversationIDs)
                }
            }
        }
    }

    @ViewBuilder
    private func conversationRow(
        _ group: MessageConversationListGroup,
        contact: ContactRecord?
    ) -> some View {
        let conversation = group.summary
        if editMode.isEditing {
            ConversationRow(
                conversation: conversation,
                linePresentation: group.latestConversation.linePresentation(in: lines),
                contact: contact,
                referenceDate: referenceDate,
                isMuted: mutedConversationIDs.contains(group.id),
                isEditing: true
            )
            .contentShape(.rect)
        } else {
            NavigationLink(value: group.id) {
                ConversationRow(
                    conversation: conversation,
                    linePresentation: group.latestConversation.linePresentation(in: lines),
                    contact: contact,
                    referenceDate: referenceDate,
                    isMuted: mutedConversationIDs.contains(group.id),
                    isPinned: pinnedConversationIDs.contains(group.id),
                    isEditing: false
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .navigationLinkIndicatorVisibility(.hidden)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if conversation.unreadCount > 0 {
                    Button {
                        group.conversationIDs.forEach(markReadAction)
                    } label: {
                        Image(systemName: "message.badge.filled.fill")
                    }
                    .tint(.blue)
                    .accessibilityLabel("Read")
                } else {
                    Button {
                        group.conversationIDs.forEach(markUnreadAction)
                    } label: {
                        Image(systemName: "message.badge.filled.fill")
                    }
                    .tint(.blue)
                    .accessibilityLabel("Unread")
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    conversationsPendingDeletion = group.members
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete")

                let isMuted = mutedConversationIDs.contains(group.id)
                Button {
                    setConversationMuted(!isMuted, group: group)
                } label: {
                    Image(systemName: isMuted ? "bell.fill" : "bell.slash.fill")
                }
                .tint(.indigo)
                .accessibilityLabel(isMuted ? "Show Alerts" : "Hide Alerts")
            }
            .contextMenu {
                Button {
                    togglePinned(group)
                } label: {
                    Label(
                        pinnedConversationIDs.contains(group.id) ? "Unpin" : "Pin",
                        systemImage: pinnedConversationIDs.contains(group.id)
                            ? "pin.slash"
                            : "pin"
                    )
                }

                if conversation.unreadCount > 0 {
                    Button {
                        group.conversationIDs.forEach(markReadAction)
                    } label: {
                        Label("Mark as Read", systemImage: "message.badge.filled.fill")
                    }
                } else {
                    Button {
                        group.conversationIDs.forEach(markUnreadAction)
                    } label: {
                        Label("Mark as Unread", systemImage: "message.badge.filled.fill")
                    }
                }

                let isMuted = mutedConversationIDs.contains(group.id)
                Button {
                    setConversationMuted(!isMuted, group: group)
                } label: {
                    Label(
                        isMuted ? "Show Alerts" : "Hide Alerts",
                        systemImage: isMuted ? "bell" : "bell.slash"
                    )
                }

                Divider()

                Button(role: .destructive) {
                    conversationsPendingDeletion = group.members
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var messageSelectionBar: some View {
        SelectionActionBar {
            Button(selectionReadActionTitle) {
                performSelectionReadAction()
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .disabled(!canPerformSelectionReadAction)
        } trailing: {
            Button(role: .destructive) {
                conversationsPendingDeletion = selectedConversations.flatMap(\.members)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(selectedConversationIDs.isEmpty)
        }
    }

    private var allConversationIDs: Set<ConversationID> {
        guard case .loaded(let conversations) = state else { return [] }
        return Set(MessageConversationListGroup.group(conversations).map(\.id))
    }

    private var visibleConversations: [MessageConversationListGroup] {
        guard case .loaded(let conversations) = state else { return [] }
        return filteredConversations(conversations)
    }

    private var selectedConversations: [MessageConversationListGroup] {
        visibleConversations.filter { selectedConversationIDs.contains($0.id) }
    }

    private var selectionReadActionTitle: LocalizedStringKey {
        guard !selectedConversationIDs.isEmpty else { return "Read All" }
        return selectedConversations.contains(where: { $0.summary.unreadCount > 0 })
            ? "Read"
            : "Unread"
    }

    private var canPerformSelectionReadAction: Bool {
        if selectedConversationIDs.isEmpty {
            return visibleConversations.contains(where: { $0.summary.unreadCount > 0 })
        }
        return !selectedConversations.isEmpty
    }

    private func performSelectionReadAction() {
        if selectedConversationIDs.isEmpty {
            for group in visibleConversations where group.summary.unreadCount > 0 {
                group.conversationIDs.forEach(markReadAction)
            }
            return
        }

        let conversations = selectedConversations
        let marksRead = conversations.contains(where: { $0.summary.unreadCount > 0 })
        for group in conversations {
            if marksRead {
                group.conversationIDs.forEach(markReadAction)
            } else {
                group.conversationIDs.forEach(markUnreadAction)
            }
        }
    }

    private func filteredConversations(
        _ conversations: [MessageConversation]
    ) -> [MessageConversationListGroup] {
        MessageConversationListGroup.group(
            conversations.filter { selectedLineID == nil || $0.lineID == selectedLineID }
        ).filter { group in
            group.members.contains { $0.matches(searchText) }
        }
        .enumerated()
        .sorted { lhs, rhs in
            let lhsPinned = pinnedConversationIDs.contains(lhs.element.id)
            let rhsPinned = pinnedConversationIDs.contains(rhs.element.id)
            if lhsPinned != rhsPinned { return lhsPinned }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    private func synchronizeMutedConversations() {
        guard case .loaded(let conversations) = state else {
            mutedConversationIDs = []
            return
        }
        mutedConversationIDs = Set(MessageConversationListGroup.group(conversations).compactMap { group in
            group.members.contains { isMutedAction($0.id) } ? group.id : nil
        })
    }

    private func synchronizePinnedConversations() {
        guard case .loaded(let conversations) = state else {
            pinnedConversationIDs = []
            return
        }
        pinnedConversationIDs = Set(MessageConversationListGroup.group(conversations).compactMap { group in
            group.members.contains { MessageConversationPinStore.isPinned($0.id) } ? group.id : nil
        })
    }

    private func togglePinned(_ group: MessageConversationListGroup) {
        let isPinned = !pinnedConversationIDs.contains(group.id)
        for id in group.conversationIDs {
            MessageConversationPinStore.setPinned(isPinned, conversationID: id)
        }
        withAnimation(.snappy) {
            if isPinned {
                pinnedConversationIDs.insert(group.id)
            } else {
                pinnedConversationIDs.remove(group.id)
            }
        }
    }

    private func setConversationMuted(_ isMuted: Bool, group: MessageConversationListGroup) {
        group.conversationIDs.forEach { setMutedAction($0, isMuted) }
        if isMuted {
            mutedConversationIDs.insert(group.id)
        } else {
            mutedConversationIDs.remove(group.id)
        }
    }

    private var deletionConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { !conversationsPendingDeletion.isEmpty },
            set: { isPresented in
                if !isPresented { conversationsPendingDeletion = [] }
            }
        )
    }

    private var deleteErrorIsPresented: Binding<Bool> {
        Binding(
            get: { deleteErrorMessage != nil },
            set: { isPresented in
                if !isPresented { deleteErrorMessage = nil }
            }
        )
    }

    private func deletePendingConversations() {
        let messageIDs = Set(conversationsPendingDeletion.flatMap(\.messages).map(\.id))
        do {
            try deleteAction(messageIDs)
            selectedConversationIDs.subtract(conversationsPendingDeletion.map(\.id))
            conversationsPendingDeletion = []
        } catch {
            conversationsPendingDeletion = []
            deleteErrorMessage = error.localizedDescription
        }
    }

}

#if DEBUG
#Preview("Messages") {
    NavigationStack {
        MessagesScreen(state: .loaded(PreviewFixtures.conversations), lines: PreviewFixtures.devices)
    }
}

#Preview("Messages - Empty") {
    NavigationStack {
        MessagesScreen(state: .loaded([]), lines: PreviewFixtures.devices)
    }
}

#Preview("Messages - Loading") {
    NavigationStack {
        MessagesScreen(state: .loading, lines: PreviewFixtures.devices)
    }
}

#Preview("Messages - Offline") {
    NavigationStack {
        MessagesScreen(state: .failed, lines: PreviewFixtures.devices)
    }
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Messages - Dark Accessibility") {
    NavigationStack {
        MessagesScreen(state: .loaded(PreviewFixtures.conversations), lines: PreviewFixtures.devices)
    }
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Messages - Simplified Chinese") {
    NavigationStack {
        MessagesScreen(state: .loaded(PreviewFixtures.conversations), lines: PreviewFixtures.devices)
    }
    .environment(\.locale, Locale(identifier: "zh-Hans"))
}

#Preview("Messages - Removed SIM") {
    NavigationStack {
        MessagesScreen(
            state: .loaded([PreviewFixtures.conversations[0]]),
            lines: []
        )
    }
}
#endif
