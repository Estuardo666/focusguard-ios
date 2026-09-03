import Foundation
import Testing
import FocusGuardDomain
@testable import FocusGuardSync

@Test func outboxDeduplicatesByIdempotencyKeyAndAcknowledges() async throws {
    let outbox = SyncOutbox()
    let key = String(repeating: "a", count: 16)
    let mutation = try SyncMutationEnvelope(
        idempotencyKey: key,
        aggregateType: "Profile",
        aggregateID: UUID(),
        expectedRevision: 0,
        operation: "upsert",
        payloadJSON: "{\"name\":\"Deep Work\"}")

    await outbox.enqueue(mutation)
    await outbox.enqueue(mutation)
    #expect(await outbox.pendingCount() == 1)
    #expect(try await outbox.nextBatch().count == 1)
    await outbox.acknowledge(idempotencyKeys: [key])
    #expect(await outbox.pendingCount() == 0)
}

@Test func cursorCannotMoveBackwards() async throws {
    let outbox = SyncOutbox()
    try await outbox.advanceCursor(to: "10")
    #expect(await outbox.cursor() == "10")
    await #expect(throws: SyncOutboxError.nonMonotonicCursor) {
        try await outbox.advanceCursor(to: "9")
    }
}

@Test func syncEnvelopeMatchesBackendWireContract() throws {
    let envelope = try SyncMutationEnvelope(
        idempotencyKey: String(repeating: "b", count: 16),
        aggregateType: "FocusSession",
        aggregateID: UUID(),
        expectedRevision: 3,
        operation: "start",
        payloadJSON: "{\"state\":\"Active\"}",
        clientCreatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let object = try #require(
        JSONSerialization.jsonObject(with: encoder.encode(envelope)) as? [String: Any])

    #expect(object["aggregateId"] != nil)
    #expect(object["payloadJson"] as? String == "{\"state\":\"Active\"}")
    #expect(object["clientCreatedAtUtc"] as? String == "2023-11-14T22:13:20Z")
    #expect(object["aggregateID"] == nil)
}

@Test func rejectsZeroAggregateID() throws {
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    #expect(throws: DomainError.self) {
        try SyncMutationEnvelope(
            idempotencyKey: String(repeating: "c", count: 16),
            aggregateType: "Profile",
            aggregateID: zero,
            expectedRevision: 0,
            operation: "upsert",
            payloadJSON: "{}")
    }
}

@Test func decodesServerClockFromPullResponse() throws {
    let json = """
    {
      "changes": [{
        "sequence": 4,
        "aggregateType": "Profile",
        "aggregateId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "operation": "upsert",
        "payloadJson": "{\\"name\\":\\"Deep Work\\"}",
        "changedAtUtc": "2026-01-01T00:00:00Z"
      }],
      "cursor": "4",
      "hasMore": false,
      "serverUtc": "2026-01-01T00:00:01Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try decoder.decode(BackendPullResponse.self, from: Data(json.utf8))
    #expect(response.cursor == "4")
    #expect(response.serverUTC == Date(timeIntervalSince1970: 1_767_225_601))
    #expect(response.changes.first?.aggregateID.uuidString.lowercased() == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
}

@Test func backendChangeValidatorAcceptsValidProfile() throws {
    let change = BackendSyncChange(
        sequence: 1,
        aggregateType: "Profile",
        aggregateID: UUID(),
        operation: "upsert",
        payloadJSON: "{\"name\":\"Deep Work\"}",
        changedAtUTC: Date())

    try BackendSyncChangeValidator.validateBatch([change], cursor: "1")
}

@Test func backendChangeValidatorRejectsPrivateScreenTimeTokens() throws {
    let change = BackendSyncChange(
        sequence: 1,
        aggregateType: "PlatformPolicy",
        aggregateID: UUID(),
        operation: "upsert",
        payloadJSON: "{\"platform\":\"AppleMobile\",\"policyJson\":{\"applicationTokens\":[\"opaque\"]}}",
        changedAtUTC: Date())

    #expect(throws: BackendSyncChangeValidationError.forbiddenPrivateTokenField) {
        try BackendSyncChangeValidator.validate(change)
    }
}

@Test func backendChangeValidatorRejectsSerializedPrivateScreenTimeTokens() throws {
    let change = BackendSyncChange(
        sequence: 1,
        aggregateType: "PlatformPolicy",
        aggregateID: UUID(),
        operation: "upsert",
        payloadJSON: "{\"platform\":\"AppleMobile\",\"policyJson\":\"{\\\"familyActivitySelection\\\":{}}\"}",
        changedAtUTC: Date())

    #expect(throws: BackendSyncChangeValidationError.forbiddenPrivateTokenField) {
        try BackendSyncChangeValidator.validate(change)
    }
}

@Test func backendChangeValidatorRejectsMalformedSerializedPolicy() throws {
    let change = BackendSyncChange(
        sequence: 1,
        aggregateType: "PlatformPolicy",
        aggregateID: UUID(),
        operation: "upsert",
        payloadJSON: "{\"platform\":\"AppleMobile\",\"policyJson\":\"not-json\"}",
        changedAtUTC: Date())

    #expect(throws: BackendSyncChangeValidationError.invalidPayload) {
        try BackendSyncChangeValidator.validate(change)
    }
}

@Test func backendChangeValidatorRequiresOrderedChangesAndCoveredCursor() throws {
    let first = BackendSyncChange(
        sequence: 2,
        aggregateType: "Profile",
        aggregateID: UUID(),
        operation: "upsert",
        payloadJSON: "{\"name\":\"A\"}",
        changedAtUTC: Date())
    let duplicate = BackendSyncChange(
        sequence: 2,
        aggregateType: "Profile",
        aggregateID: UUID(),
        operation: "upsert",
        payloadJSON: "{\"name\":\"B\"}",
        changedAtUTC: Date())
    #expect(throws: BackendSyncChangeValidationError.invalidSequence) {
        try BackendSyncChangeValidator.validateBatch([first, duplicate], cursor: "2")
    }

    #expect(throws: BackendSyncChangeValidationError.invalidCursor) {
        try BackendSyncChangeValidator.validateBatch([first], cursor: "1")
    }

    #expect(throws: BackendSyncChangeValidationError.invalidBatchSize) {
        try BackendSyncChangeValidator.validateBatch(
            Array(repeating: first, count: 501),
            cursor: "2")
    }
}

@Test func coordinatorDoesNotSkipChangesAfterPush() async throws {
    let coordinator = try SyncCoordinator()
    let mutation = try SyncMutationEnvelope(
        idempotencyKey: String(repeating: "d", count: 16),
        aggregateType: "Profile",
        aggregateID: UUID(),
        expectedRevision: 0,
        operation: "upsert",
        payloadJSON: "{}")
    await coordinator.enqueue(mutation)

    let remote = TestRemote()
    let first = try await coordinator.synchronize(with: remote)
    #expect(first.pushed?.cursor == "2")
    #expect(await coordinator.cursor() == "0")
    #expect(await coordinator.pendingCount() == 0)
    #expect(await remote.pushCursors() == ["0"])
    #expect(await remote.pullCursors() == ["0"])

    try await coordinator.commitPulledBatch(first.pulled)
    #expect(await coordinator.cursor() == "2")

    _ = try await coordinator.synchronize(with: remote)
    #expect(await remote.pullCursors() == ["0", "2"])
}

@Test func backendClientDefaultsToHttps() throws {
    #expect(throws: FocusGuardBackendClientError.self) {
        _ = try FocusGuardBackendClientConfiguration(
            baseURL: try #require(URL(string: "http://localhost:8080")),
            deviceID: UUID())
    }
    _ = try FocusGuardBackendClientConfiguration(
        baseURL: try #require(URL(string: "http://localhost:8080")),
        deviceID: UUID(),
        allowInsecureHTTP: true)
}

@Test func coordinatorKeepsConflictForResolution() async throws {
    let coordinator = try SyncCoordinator()
    let key = String(repeating: "e", count: 16)
    let mutation = try SyncMutationEnvelope(
        idempotencyKey: key,
        aggregateType: "Profile",
        aggregateID: UUID(),
        expectedRevision: 0,
        operation: "upsert",
        payloadJSON: "{}")
    await coordinator.enqueue(mutation)

    let remote = ConflictRemote()
    _ = try await coordinator.synchronize(with: remote)
    #expect(await coordinator.pendingCount() == 1)
}

@Test func coordinatorRejectsBackwardPullCursor() async throws {
    let coordinator = try SyncCoordinator(initialCursor: "10")
    let response = try await coordinator.synchronize(with: BackwardCursorRemote())

    await #expect(throws: SyncOutboxError.nonMonotonicCursor) {
        try await coordinator.commitPulledBatch(response.pulled)
    }
    #expect(await coordinator.cursor() == "10")
}

@Test func coordinatorKeepsCursorWhenMaterializationFails() async throws {
    let coordinator = try SyncCoordinator()
    let remote = TestRemote()

    await #expect(throws: ApplyError.self) {
        _ = try await coordinator.synchronize(
            with: remote,
            applying: { _ in throw ApplyError.failed })
    }
    #expect(await coordinator.cursor() == "0")
}

@Test func coordinatorRejectsMalformedRemoteChangeBeforeMaterialization() async throws {
    let coordinator = try SyncCoordinator()
    let remote = InvalidChangeRemote()
    let probe = ApplyProbe()

    await #expect(throws: BackendSyncChangeValidationError.forbiddenPrivateTokenField) {
        _ = try await coordinator.synchronize(
            with: remote,
            applying: { _ in await probe.markCalled() })
    }
    #expect(await probe.wasCalled() == false)
    #expect(await coordinator.cursor() == "0")
}

@Test func coordinatorCommitsCursorAfterMaterializationSucceeds() async throws {
    let coordinator = try SyncCoordinator()
    let remote = TestRemote()

    _ = try await coordinator.synchronize(
        with: remote,
        applying: { changes in
            #expect(changes.count == 1)
        })
    #expect(await coordinator.cursor() == "2")
}

private actor TestRemote: FocusGuardSyncRemote {
    private var pushes: [String] = []
    private var pulls: [String] = []

    func push(cursor: String, mutations: [SyncMutationEnvelope]) async throws -> BackendPushResponse {
        pushes.append(cursor)
        return BackendPushResponse(
            results: mutations.map {
                BackendMutationResult(
                    idempotencyKey: $0.idempotencyKey,
                    accepted: true,
                    duplicate: false,
                    conflict: false,
                    reason: nil,
                    currentRevision: 1)
            },
            cursor: "2",
            serverUTC: Date(timeIntervalSince1970: 1_700_000_001))
    }

    func pull(cursor: String, limit: Int) async throws -> BackendPullResponse {
        pulls.append(cursor)
        return BackendPullResponse(
            changes: [BackendSyncChange(
                sequence: 1,
                aggregateType: "Profile",
                aggregateID: UUID(),
                operation: "upsert",
                payloadJSON: "{}",
                changedAtUTC: Date(timeIntervalSince1970: 1_700_000_000))],
            cursor: "2",
            hasMore: false,
            serverUTC: Date(timeIntervalSince1970: 1_700_000_001))
    }

    func pushCursors() -> [String] { pushes }
    func pullCursors() -> [String] { pulls }
}

private actor ConflictRemote: FocusGuardSyncRemote {
    func push(cursor: String, mutations: [SyncMutationEnvelope]) async throws -> BackendPushResponse {
        BackendPushResponse(
            results: mutations.map {
                BackendMutationResult(
                    idempotencyKey: $0.idempotencyKey,
                    accepted: false,
                    duplicate: true,
                    conflict: true,
                    reason: "The aggregate revision is stale.",
                    currentRevision: 2)
            },
            cursor: cursor,
            serverUTC: Date(timeIntervalSince1970: 1_700_000_001))
    }

    func pull(cursor: String, limit: Int) async throws -> BackendPullResponse {
        BackendPullResponse(
            changes: [],
            cursor: cursor,
            hasMore: false,
            serverUTC: Date(timeIntervalSince1970: 1_700_000_001))
    }
}

private actor BackwardCursorRemote: FocusGuardSyncRemote {
    func push(cursor: String, mutations: [SyncMutationEnvelope]) async throws -> BackendPushResponse {
        BackendPushResponse(results: [], cursor: cursor, serverUTC: Date())
    }

    func pull(cursor: String, limit: Int) async throws -> BackendPullResponse {
        BackendPullResponse(
            changes: [],
            cursor: "9",
            hasMore: false,
            serverUTC: Date())
    }
}

private actor InvalidChangeRemote: FocusGuardSyncRemote {
    func push(cursor: String, mutations: [SyncMutationEnvelope]) async throws -> BackendPushResponse {
        BackendPushResponse(results: [], cursor: cursor, serverUTC: Date())
    }

    func pull(cursor: String, limit: Int) async throws -> BackendPullResponse {
        BackendPullResponse(
            changes: [BackendSyncChange(
                sequence: 1,
                aggregateType: "PlatformPolicy",
                aggregateID: UUID(),
                operation: "upsert",
                payloadJSON: "{\"platform\":\"AppleMobile\",\"applicationTokens\":[]}",
                changedAtUTC: Date())],
            cursor: "1",
            hasMore: false,
            serverUTC: Date())
    }
}

private actor ApplyProbe {
    private var called = false

    func markCalled() { called = true }
    func wasCalled() -> Bool { called }
}

private enum ApplyError: Error {
    case failed
}
