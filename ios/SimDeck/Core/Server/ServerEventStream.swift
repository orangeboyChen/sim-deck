// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import OSLog
import Connect
import RelayProtocol

@MainActor
protocol EncryptedEventStream: AnyObject {
    func receive() async throws -> EncryptedEventPage
    func acknowledge(sequence: Int64) async throws
    func close()
}
@MainActor
protocol EncryptedEventStreamOpening: AnyObject {
    func openEncryptedEventStream(afterSequence: Int64) async throws -> any EncryptedEventStream
}
@MainActor
final class ServerConnectEncryptedEventStream: EncryptedEventStream {
    private let stream: any Connect.BidirectionalAsyncStreamInterface<
        Relay_Communication_V1_WatchEventsRequest,
        Relay_Communication_V1_WatchEventsResponse
    >
    private var cursor: Int64
    private var pendingAcknowledgement: Int64?

    init(
        stream: any Connect.BidirectionalAsyncStreamInterface<
            Relay_Communication_V1_WatchEventsRequest,
            Relay_Communication_V1_WatchEventsResponse
        >,
        afterSequence: Int64
    ) throws {
        guard afterSequence >= 0 else {
            throw ServerConnectionError.invalidResponse
        }
        self.stream = stream
        self.cursor = afterSequence
        try stream.send(Relay_Communication_V1_WatchEventsRequest.with {
            $0.afterSequence = afterSequence
        })
    }

    func receive() async throws -> EncryptedEventPage {
        guard pendingAcknowledgement == nil else {
            throw ServerConnectionError.invalidResponse
        }
        for await result in stream.results() {
            switch result {
            case .headers:
                continue
            case .complete(_, let error, _):
                if let error { throw error }
                throw ServerConnectionError.eventStreamUnavailable
            case .message(let response):
                let events = try response.events.map(ServerConnectionManager.eventEnvelope(from:))
                if response.heartbeat {
                    guard events.isEmpty, response.nextSequence == cursor else {
                        throw ServerConnectionError.invalidResponse
                    }
                    return EncryptedEventPage(events: [], nextSequence: cursor, isHeartbeat: true)
                }
                guard !events.isEmpty,
                      response.nextSequence > cursor,
                      events.last?.sequence == response.nextSequence else {
                    throw ServerConnectionError.invalidResponse
                }
                var previousSequence = cursor
                for event in events {
                    guard event.sequence > previousSequence else {
                        throw ServerConnectionError.invalidResponse
                    }
                    previousSequence = event.sequence
                }
                pendingAcknowledgement = response.nextSequence
                return EncryptedEventPage(events: events, nextSequence: response.nextSequence)
            }
        }
        throw ServerConnectionError.eventStreamUnavailable
    }

    func acknowledge(sequence: Int64) async throws {
        guard pendingAcknowledgement == sequence else {
            throw ServerConnectionError.invalidResponse
        }
        try stream.send(Relay_Communication_V1_WatchEventsRequest.with {
            $0.acknowledgedSequence = sequence
        })
        cursor = sequence
        pendingAcknowledgement = nil
    }

    func close() {
        stream.cancel()
    }
}
@MainActor
final class MessageEventMonitor {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SimDeck",
        category: "MessageEventMonitor"
    )

    private let opener: any EncryptedEventStreamOpening
    private let currentSequence: () -> Int64
    private let synchronizeThrough: (Int64) async -> Bool
    private let onDisconnected: () -> Void
    private let onConnectionQualityChanged: (Bool) -> Void
    private let probeServer: () async -> Bool
    private let waitBeforeReconnect: () async throws -> Void
    private let waitBeforeHeartbeatCheck: () async throws -> Void
    private var task: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var activeStream: (any EncryptedEventStream)?
    private var streamGeneration: UUID?
    private var wantsUpdates = false
    private var networkIsAvailable = true
    private var receivedServerActivity = false
    private var missedHeartbeats = 0
    private var connectionIsDegraded = false

    init(
        opener: any EncryptedEventStreamOpening,
        currentSequence: @escaping () -> Int64,
        synchronizeThrough: @escaping (Int64) async -> Bool,
        onDisconnected: @escaping () -> Void = {},
        onConnectionQualityChanged: @escaping (Bool) -> Void = { _ in },
        probeServer: @escaping () async -> Bool = { false },
        waitBeforeReconnect: @escaping () async throws -> Void = {
            try await Task.sleep(for: .seconds(2))
        },
        waitBeforeHeartbeatCheck: @escaping () async throws -> Void = {
            try await Task.sleep(for: .seconds(15))
        }
    ) {
        self.opener = opener
        self.currentSequence = currentSequence
        self.synchronizeThrough = synchronizeThrough
        self.onDisconnected = onDisconnected
        self.onConnectionQualityChanged = onConnectionQualityChanged
        self.probeServer = probeServer
        self.waitBeforeReconnect = waitBeforeReconnect
        self.waitBeforeHeartbeatCheck = waitBeforeHeartbeatCheck
    }

    var isRunning: Bool { task != nil }

    func start() {
        wantsUpdates = true
        guard networkIsAvailable else { return }
        guard task == nil else { return }
        let generation = UUID()
        streamGeneration = generation
        receivedServerActivity = false
        missedHeartbeats = 0
        task = Task { [weak self] in
            await self?.run(generation: generation)
        }
        heartbeatTask = Task { [weak self] in
            await self?.monitorHeartbeats(generation: generation)
        }
    }

    func stop() {
        wantsUpdates = false
        cancelActiveStream()
    }

    func networkPathDidChange(isAvailable: Bool) {
        networkIsAvailable = isAvailable
        guard wantsUpdates else { return }
        cancelActiveStream()
        if isAvailable {
            start()
        }
    }

    private func cancelActiveStream() {
        streamGeneration = nil
        task?.cancel()
        task = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        activeStream?.close()
        activeStream = nil
        updateConnectionQuality(degraded: false)
    }

    private func run(generation: UUID) async {
        defer {
            if streamGeneration == generation {
                streamGeneration = nil
                task = nil
            }
        }
        while streamGeneration == generation && !Task.isCancelled {
            do {
                let sequence = currentSequence()
                Self.logger.info("Opening encrypted message event stream after sequence \(sequence, privacy: .public)")
                let stream = try await opener.openEncryptedEventStream(afterSequence: sequence)
                guard streamGeneration == generation, !Task.isCancelled else {
                    stream.close()
                    return
                }
                activeStream = stream
                defer {
                    stream.close()
                    if activeStream === stream {
                        activeStream = nil
                    }
                }

                while streamGeneration == generation && !Task.isCancelled {
                    let page = try await stream.receive()
                    guard streamGeneration == generation, !Task.isCancelled else { return }
                    receivedServerActivity = true
                    if page.isHeartbeat {
                        updateConnectionQuality(degraded: false)
                        continue
                    }
                    let synchronized = await synchronizeThrough(page.nextSequence)
                    guard streamGeneration == generation, !Task.isCancelled else { return }
                    guard synchronized else {
                        throw ServerConnectionError.eventStreamUnavailable
                    }
                    try await stream.acknowledge(sequence: page.nextSequence)
                    updateConnectionQuality(degraded: false)
                    Self.logger.debug(
                        "Acknowledged encrypted message events through sequence \(page.nextSequence, privacy: .public)"
                    )
                }
            } catch {
                guard streamGeneration == generation, !Task.isCancelled else { return }
                Self.logger.error(
                    "Encrypted message event stream disconnected: \(String(reflecting: error), privacy: .public)"
                )
                onDisconnected()
                do {
                    try await waitBeforeReconnect()
                } catch {
                    return
                }
            }
        }
    }

    private func monitorHeartbeats(generation: UUID) async {
        while streamGeneration == generation && !Task.isCancelled {
            do {
                try await waitBeforeHeartbeatCheck()
            } catch {
                return
            }
            guard streamGeneration == generation, !Task.isCancelled else { return }
            if receivedServerActivity {
                receivedServerActivity = false
                missedHeartbeats = 0
                updateConnectionQuality(degraded: false)
            } else {
                missedHeartbeats += 1
                if missedHeartbeats >= 3 {
                    missedHeartbeats = 0
                    let reachable = await probeServer()
                    guard streamGeneration == generation, !Task.isCancelled else { return }
                    Self.logger.warning(
                        "Encrypted event stream missed three heartbeat checks; server reachable: \(reachable, privacy: .public)"
                    )
                    updateConnectionQuality(degraded: !reachable)
                    if reachable {
                        activeStream?.close()
                    }
                }
            }
        }
    }

    private func updateConnectionQuality(degraded: Bool) {
        guard connectionIsDegraded != degraded else { return }
        connectionIsDegraded = degraded
        onConnectionQualityChanged(degraded)
    }
}
