import FocusGuardSync
import FocusGuardDomain
import Foundation
import SwiftData

/// SwiftData-backed adapter for the platform-neutral sync invariants.
///
/// The adapter deliberately stores only mutation metadata and JSON payloads.
/// Screen Time selections/tokens remain in the App Group and are never turned
/// into cloud identifiers. A caller can hydrate `SyncCoordinator` from this
/// store, retry a batch with the same idempotency keys, and commit the cursor
/// only after its local materialization transaction succeeds.
@MainActor
final class ScreenTimeSyncStore {
    enum StoreError: Error, Equatable {
        case invalidPendingMutation(String)
        case invalidCursor
    }

    private let modelContext: ModelContext
    private let deviceID: UUID

    init(modelContext: ModelContext, deviceID: UUID) {
        self.modelContext = modelContext
        self.deviceID = deviceID
    }

    func pendingMutations(limit: Int = 50) throws -> [SyncMutationEnvelope] {
        guard (1...500).contains(limit) else {
            throw SyncOutboxError.invalidBatchSize
        }

        let records = try modelContext.fetch(
            FetchDescriptor<LocalPendingMutationRecord>(
                sortBy: [SortDescriptor(\.createdAt)]))

        return try records.prefix(limit).map { record in
            guard let aggregateID = record.aggregateID,
                  let storedExpectedRevision = record.expectedRevision,
                  let expectedRevision = Int(exactly: storedExpectedRevision) else {
                throw StoreError.invalidPendingMutation(record.idempotencyKey)
            }

            do {
                return try SyncMutationEnvelope(
                    idempotencyKey: record.idempotencyKey,
                    aggregateType: record.aggregateType,
                    aggregateID: aggregateID,
                    expectedRevision: expectedRevision,
                    operation: record.operation,
                    payloadJSON: record.payloadJSON,
                    clientCreatedAt: record.createdAt)
            } catch {
                throw StoreError.invalidPendingMutation(record.idempotencyKey)
            }
        }
    }

    /// Inserts a mutation once. Reusing an idempotency key is intentionally a
    /// no-op so a retry cannot silently replace the original payload.
    func enqueue(_ mutation: SyncMutationEnvelope) throws {
        let records = try modelContext.fetch(FetchDescriptor<LocalPendingMutationRecord>())
        guard records.first(where: { $0.idempotencyKey == mutation.idempotencyKey }) == nil else {
            return
        }

        guard let storedExpectedRevision = Int64(exactly: mutation.expectedRevision) else {
            throw StoreError.invalidPendingMutation(mutation.idempotencyKey)
        }

        modelContext.insert(LocalPendingMutationRecord(
            idempotencyKey: mutation.idempotencyKey,
            aggregateType: mutation.aggregateType,
            aggregateID: mutation.aggregateID,
            operation: mutation.operation,
            expectedRevision: storedExpectedRevision,
            payloadJSON: mutation.payloadJSON,
            createdAt: mutation.clientCreatedAt))
        try modelContext.save()
    }

    func markAttempted(_ idempotencyKeys: Set<String>, at date: Date = .now) throws {
        guard !idempotencyKeys.isEmpty else { return }
        let records = try modelContext.fetch(FetchDescriptor<LocalPendingMutationRecord>())
        for record in records where idempotencyKeys.contains(record.idempotencyKey) {
            record.attemptCount += 1
            record.lastAttemptAt = date
        }
        try modelContext.save()
    }

    func acknowledge(_ idempotencyKeys: Set<String>) throws {
        guard !idempotencyKeys.isEmpty else { return }
        let records = try modelContext.fetch(FetchDescriptor<LocalPendingMutationRecord>())
        for record in records where idempotencyKeys.contains(record.idempotencyKey) {
            modelContext.delete(record)
        }
        try modelContext.save()
    }

    func appliedCursor() throws -> String {
        try metadata().serverCursor.description
    }

    /// Commits a pulled cursor only after the caller has materialized the
    /// complete response locally. This prevents a crash from skipping changes.
    func commit(cursor: String, serverUTC: Date) throws {
        guard let value = Int64(cursor), value >= 0 else {
            throw StoreError.invalidCursor
        }
        let record = try metadata()
        guard value >= record.serverCursor else {
            throw SyncOutboxError.nonMonotonicCursor
        }
        let previousClock = try TrustedClockState(
            lastObservedUTC: record.lastObservedLocalTime,
            latestServerUTC: record.lastServerTime)
        let clock = previousClock.recording(localNow: .now, serverNow: serverUTC)
        record.serverCursor = value
        record.lastServerTime = clock.latestServerUTC
        record.lastObservedLocalTime = clock.lastObservedUTC
        record.clockTrustRaw = clock.trust.rawValue
        record.lastSuccessfulSyncAt = .now
        try modelContext.save()
    }

    private func metadata() throws -> LocalSyncMetadataRecord {
        let records = try modelContext.fetch(FetchDescriptor<LocalSyncMetadataRecord>())
        if let existing = records.first(where: { $0.key == "default" && $0.deviceID == deviceID }) {
            return existing
        }

        let record = LocalSyncMetadataRecord(deviceID: deviceID)
        modelContext.insert(record)
        try modelContext.save()
        return record
    }
}

/// Connects the durable SwiftData outbox to the REST transport without making
/// the backend part of enforcement. A failed network call leaves the outbox
/// untouched; a failed local materialization leaves the pull cursor unchanged,
/// so the same remote batch is replayed safely on the next foreground/wake.
@MainActor
final class ScreenTimeSyncEngine {
    enum EngineError: Error, Equatable {
        case invalidBatch
    }

    private let store: ScreenTimeSyncStore
    private let remote: any FocusGuardSyncRemote

    init(store: ScreenTimeSyncStore, remote: any FocusGuardSyncRemote) {
        self.store = store
        self.remote = remote
    }

    func runOnce(
        batchLimit: Int = 50,
        pullLimit: Int = 100,
        applying apply: @escaping @Sendable ([BackendSyncChange]) async throws -> Void
    ) async throws -> SyncRunResult {
        guard (1...500).contains(batchLimit), (1...500).contains(pullLimit) else {
            throw EngineError.invalidBatch
        }

        let cursor = try store.appliedCursor()
        let mutations = try store.pendingMutations(limit: batchLimit)
        let keys = Set(mutations.map(\.idempotencyKey))
        try store.markAttempted(keys)

        let pushed: BackendPushResponse?
        if mutations.isEmpty {
            pushed = nil
        } else {
            let response = try await remote.push(cursor: cursor, mutations: mutations)
            let acknowledged = Set(response.results.compactMap { result in
                result.accepted || (result.duplicate && !result.conflict)
                    ? result.idempotencyKey
                    : nil
            })
            // Conflicts and rejected mutations stay in the outbox for a
            // resolver to inspect; only accepted or clean duplicates leave it.
            try store.acknowledge(acknowledged)
            pushed = response
        }

        // Never use pushed.cursor as our local cursor: it may include another
        // device's changes. Pull from the last durably materialized cursor.
        let pulled = try await remote.pull(cursor: cursor, limit: pullLimit)
        // Treat the sync feed as untrusted input. The backend performs the
        // authoritative validation, while this second check prevents a
        // malformed/compromised response from reaching SwiftData or Screen
        // Time materialization and leaves the cursor replayable on failure.
        try BackendSyncChangeValidator.validateBatch(
            pulled.changes,
            cursor: pulled.cursor)
        try await apply(pulled.changes)
        try store.commit(cursor: pulled.cursor, serverUTC: pulled.serverUTC)
        return SyncRunResult(pushed: pushed, pulled: pulled)
    }
}
