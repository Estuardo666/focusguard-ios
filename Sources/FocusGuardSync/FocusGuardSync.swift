import Foundation
import FocusGuardDomain
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SyncMutationEnvelope: Codable, Equatable, Sendable {
    public let idempotencyKey: String
    public let aggregateType: String
    public let aggregateID: UUID
    public let expectedRevision: Int
    public let operation: String
    public let payloadJSON: String
    public let clientCreatedAt: Date

    public init(idempotencyKey: String = UUID().uuidString,
                aggregateType: String,
                aggregateID: UUID,
                expectedRevision: Int,
                operation: String,
                payloadJSON: String,
                clientCreatedAt: Date = Date()) throws {
        guard (16...128).contains(idempotencyKey.count),
              !aggregateType.isEmpty, aggregateType.count <= 64,
              !operation.isEmpty, operation.count <= 64,
              aggregateID.uuidString != "00000000-0000-0000-0000-000000000000",
              expectedRevision >= 0,
              payloadJSON.utf8.count <= 1_048_576,
              let data = payloadJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] else {
            throw DomainError.invalid("Sync mutation envelope is invalid")
        }
        self.idempotencyKey = idempotencyKey
        self.aggregateType = aggregateType
        self.aggregateID = aggregateID
        self.expectedRevision = expectedRevision
        self.operation = operation
        self.payloadJSON = payloadJSON
        self.clientCreatedAt = clientCreatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case idempotencyKey
        case aggregateType
        case aggregateID = "aggregateId"
        case expectedRevision
        case operation
        case payloadJSON = "payloadJson"
        case clientCreatedAt = "clientCreatedAtUtc"
    }
}

public enum SyncOutboxError: Error, Equatable, Sendable {
    case invalidCursor
    case nonMonotonicCursor
    case invalidBatchSize
}

/// Actor-isolated local outbox used by iOS/iPadOS/macOS clients.
/// The production implementation will hydrate this state from SwiftData; the
/// actor and invariants remain independent from the persistence technology.
public actor SyncOutbox {
    private var pendingMutations: [String: SyncMutationEnvelope] = [:]
    private var localCursor: Int64 = 0

    public init() {}

    public func enqueue(_ mutation: SyncMutationEnvelope) {
        pendingMutations[mutation.idempotencyKey] = mutation
    }

    public func nextBatch(limit: Int = 50) throws -> [SyncMutationEnvelope] {
        guard (1...500).contains(limit) else { throw SyncOutboxError.invalidBatchSize }
        let ordered = pendingMutations.values.sorted {
            if $0.clientCreatedAt == $1.clientCreatedAt {
                return $0.idempotencyKey < $1.idempotencyKey
            }
            return $0.clientCreatedAt < $1.clientCreatedAt
        }
        return Array(ordered.prefix(limit))
    }

    public func acknowledge(idempotencyKeys: Set<String>) {
        for key in idempotencyKeys { pendingMutations.removeValue(forKey: key) }
    }

    public func pendingCount() -> Int { pendingMutations.count }

    public func cursor() -> String {
        String(localCursor)
    }

    public func advanceCursor(to value: String) throws {
        guard let parsed = Int64(value), parsed >= 0 else { throw SyncOutboxError.invalidCursor }
        guard parsed >= localCursor else { throw SyncOutboxError.nonMonotonicCursor }
        localCursor = parsed
    }
}

public struct FocusGuardBackendClientConfiguration: Sendable {
    public let baseURL: URL
    public let deviceID: UUID
    public let bearerToken: String?

    public init(
        baseURL: URL,
        deviceID: UUID,
        bearerToken: String? = nil,
        allowInsecureHTTP: Bool = false
    ) throws {
        guard baseURL.scheme == "https" || (allowInsecureHTTP && baseURL.scheme == "http"),
              baseURL.host != nil else {
            throw FocusGuardBackendClientError.invalidRequest("Backend base URL must use HTTPS")
        }
        guard deviceID.uuidString != "00000000-0000-0000-0000-000000000000" else {
            throw FocusGuardBackendClientError.invalidRequest("Device ID is required")
        }
        self.baseURL = baseURL
        self.deviceID = deviceID
        self.bearerToken = bearerToken
    }
}

public struct BackendDevice: Codable, Equatable, Sendable {
    public let id: UUID
    public let platform: PlatformFamily
    public let displayName: String
    public let platformVersion: String
    public let capabilities: [String]
    public let lastSeenUTC: Date
    public let isRevoked: Bool

    private enum CodingKeys: String, CodingKey {
        case id, platform, displayName, platformVersion, capabilities
        case lastSeenUTC = "lastSeenUtc"
        case isRevoked
    }
}

public struct BackendMutationResult: Codable, Equatable, Sendable {
    public let idempotencyKey: String
    public let accepted: Bool
    public let duplicate: Bool
    public let conflict: Bool
    public let reason: String?
    public let currentRevision: Int?

    public init(
        idempotencyKey: String,
        accepted: Bool,
        duplicate: Bool,
        conflict: Bool,
        reason: String?,
        currentRevision: Int?
    ) {
        self.idempotencyKey = idempotencyKey
        self.accepted = accepted
        self.duplicate = duplicate
        self.conflict = conflict
        self.reason = reason
        self.currentRevision = currentRevision
    }
}

public struct BackendPushResponse: Codable, Equatable, Sendable {
    public let results: [BackendMutationResult]
    public let cursor: String
    public let serverUTC: Date

    public init(results: [BackendMutationResult], cursor: String, serverUTC: Date) {
        self.results = results
        self.cursor = cursor
        self.serverUTC = serverUTC
    }

    private enum CodingKeys: String, CodingKey {
        case results, cursor
        case serverUTC = "serverUtc"
    }
}

public struct BackendSyncChange: Codable, Equatable, Sendable {
    public let sequence: Int64
    public let aggregateType: String
    public let aggregateID: UUID
    public let operation: String
    public let payloadJSON: String
    public let changedAtUTC: Date

    public init(
        sequence: Int64,
        aggregateType: String,
        aggregateID: UUID,
        operation: String,
        payloadJSON: String,
        changedAtUTC: Date
    ) {
        self.sequence = sequence
        self.aggregateType = aggregateType
        self.aggregateID = aggregateID
        self.operation = operation
        self.payloadJSON = payloadJSON
        self.changedAtUTC = changedAtUTC
    }

    private enum CodingKeys: String, CodingKey {
        case sequence, aggregateType
        case aggregateID = "aggregateId"
        case operation
        case payloadJSON = "payloadJson"
        case changedAtUTC = "changedAtUtc"
    }
}

public struct BackendPullResponse: Codable, Equatable, Sendable {
    public let changes: [BackendSyncChange]
    public let cursor: String
    public let hasMore: Bool
    public let serverUTC: Date

    public init(changes: [BackendSyncChange], cursor: String, hasMore: Bool, serverUTC: Date) {
        self.changes = changes
        self.cursor = cursor
        self.hasMore = hasMore
        self.serverUTC = serverUTC
    }

    private enum CodingKeys: String, CodingKey {
        case changes, cursor, hasMore
        case serverUTC = "serverUtc"
    }
}

/// Defense-in-depth validation for data read from the sync feed. The backend
/// validates mutations before they are written, but a client must still refuse
/// an unexpected response (for example after a compromised proxy or a server
/// regression) before materializing it into SwiftData/Screen Time state.
public enum BackendSyncChangeValidationError: Error, Equatable, Sendable {
    case invalidSequence
    case invalidCursor
    case invalidBatchSize
    case invalidAggregateID
    case unsupportedAggregateType
    case unsupportedOperation
    case invalidPayload
    case forbiddenPrivateTokenField
}

public enum BackendSyncChangeValidator {
    private static let supportedTypes: Set<String> = [
        "profile", "platformpolicy", "schedule", "focussession"
    ]
    private static let allowedOperations: Set<String> = [
        "upsert", "delete", "start", "stop", "cancel", "complete", "pause", "resume"
    ]
    private static let forbiddenTokenFields: Set<String> = [
        "applicationtoken", "applicationtokens", "categorytoken", "categorytokens",
        "webdomaintoken", "webdomaintokens", "familyactivityselection",
        "screentimetoken", "screentimetokens"
    ]

    public static func validate(_ change: BackendSyncChange) throws {
        guard change.sequence > 0 else { throw BackendSyncChangeValidationError.invalidSequence }
        let aggregateType = change.aggregateType.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard supportedTypes.contains(aggregateType) else {
            throw BackendSyncChangeValidationError.unsupportedAggregateType
        }
        let operation = change.operation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard allowedOperations.contains(operation) else {
            throw BackendSyncChangeValidationError.unsupportedOperation
        }
        if aggregateType != "focussession" && operation != "upsert" && operation != "delete" {
            throw BackendSyncChangeValidationError.unsupportedOperation
        }
        let emptyID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        guard change.aggregateID != emptyID else {
            throw BackendSyncChangeValidationError.invalidAggregateID
        }
        guard change.payloadJSON.utf8.count <= 1_048_576,
              let data = change.payloadJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] else {
            throw BackendSyncChangeValidationError.invalidPayload
        }
        try rejectPrivateTokenFields(in: object)
    }

    /// Validates ordering and cursor coverage in addition to each change.
    /// `cursor` is deliberately not advanced here; the caller must materialize
    /// the batch and commit it transactionally afterwards.
    public static func validateBatch(_ changes: [BackendSyncChange], cursor: String) throws {
        guard let cursorValue = Int64(cursor), cursorValue >= 0 else {
            throw BackendSyncChangeValidationError.invalidCursor
        }
        guard changes.count <= 500 else {
            throw BackendSyncChangeValidationError.invalidBatchSize
        }
        var previousSequence: Int64 = 0
        for change in changes {
            try validate(change)
            guard change.sequence > previousSequence else {
                throw BackendSyncChangeValidationError.invalidSequence
            }
            previousSequence = change.sequence
        }
        guard cursorValue >= previousSequence else {
            throw BackendSyncChangeValidationError.invalidCursor
        }
    }

    private static func rejectPrivateTokenFields(in value: Any) throws {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                if forbiddenTokenFields.contains(key.lowercased()) {
                    throw BackendSyncChangeValidationError.forbiddenPrivateTokenField
                }
                // PlatformPolicy.policyJson may itself be a JSON string. It is
                // still untrusted and must not smuggle opaque Screen Time
                // tokens through the shared cloud payload.
                if key.caseInsensitiveCompare("policyJson") == .orderedSame,
                   let policyText = nested as? String {
                    guard let policyData = policyText.data(using: .utf8),
                          let policyObject = try? JSONSerialization.jsonObject(with: policyData),
                          policyObject is [String: Any] else {
                        throw BackendSyncChangeValidationError.invalidPayload
                    }
                    try rejectPrivateTokenFields(in: policyObject)
                }
                try rejectPrivateTokenFields(in: nested)
            }
        } else if let array = value as? [Any] {
            for nested in array {
                try rejectPrivateTokenFields(in: nested)
            }
        }
    }
}

public enum FocusGuardBackendClientError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case invalidResponse
    case httpStatus(Int, String)
    case emptyResponse
}

/// Small REST client for the shared sync contract. It intentionally has no
/// retry loop: callers persist mutations in `SyncOutbox`/SwiftData and retry
/// with the same idempotency key according to their platform lifecycle.
public final class FocusGuardBackendClient: @unchecked Sendable {
    private let configuration: FocusGuardBackendClientConfiguration
    private let session: URLSession

    public init(
        configuration: FocusGuardBackendClientConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    public func registerDevice(
        platform: PlatformFamily,
        displayName: String,
        platformVersion: String,
        capabilities: [String] = []
    ) async throws -> BackendDevice {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !platformVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FocusGuardBackendClientError.invalidRequest("Device display name and platform version are required")
        }
        let body = DeviceRegistrationPayload(
            deviceID: configuration.deviceID,
            platform: platform,
            displayName: displayName,
            platformVersion: platformVersion,
            capabilities: Array(Set(capabilities)).sorted())
        return try await send(
            path: "v1/devices",
            method: "POST",
            body: body,
            decodeAs: BackendDevice.self)
    }

    public func push(
        cursor: String,
        mutations: [SyncMutationEnvelope]
    ) async throws -> BackendPushResponse {
        guard !cursor.isEmpty, mutations.count <= 500 else {
            throw FocusGuardBackendClientError.invalidRequest("Cursor or mutation count is invalid")
        }
        let body = SyncPushPayload(
            deviceID: configuration.deviceID,
            cursor: cursor,
            mutations: mutations)
        return try await send(
            path: "v1/sync/push",
            method: "POST",
            body: body,
            decodeAs: BackendPushResponse.self)
    }

    public func pull(cursor: String, limit: Int = 100) async throws -> BackendPullResponse {
        guard !cursor.isEmpty, (1...500).contains(limit) else {
            throw FocusGuardBackendClientError.invalidRequest("Cursor or pull limit is invalid")
        }
        var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent("v1/sync/pull"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "deviceId", value: configuration.deviceID.uuidString),
            URLQueryItem(name: "cursor", value: cursor),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components?.url else {
            throw FocusGuardBackendClientError.invalidRequest("Unable to build pull URL")
        }
        return try await send(
            url: url,
            method: "GET",
            body: Optional<EmptyPayload>.none,
            decodeAs: BackendPullResponse.self)
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body?,
        decodeAs: Response.Type
    ) async throws -> Response {
        try await send(
            url: configuration.baseURL.appendingPathComponent(path),
            method: method,
            body: body,
            decodeAs: decodeAs)
    }

    private func send<Body: Encodable, Response: Decodable>(
        url: URL,
        method: String,
        body: Body?,
        decodeAs: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.deviceID.uuidString, forHTTPHeaderField: "X-FocusGuard-Device-Id")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(body)
        }
        if let bearerToken = configuration.bearerToken,
           !bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FocusGuardBackendClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data.prefix(4_096), encoding: .utf8) ?? ""
            throw FocusGuardBackendClientError.httpStatus(httpResponse.statusCode, body)
        }
        guard !data.isEmpty else { throw FocusGuardBackendClientError.emptyResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }

    private struct EmptyPayload: Encodable {}

    private struct DeviceRegistrationPayload: Encodable {
        let deviceID: UUID
        let platform: PlatformFamily
        let displayName: String
        let platformVersion: String
        let capabilities: [String]

        private enum CodingKeys: String, CodingKey {
            case deviceID = "deviceId"
            case platform, displayName, platformVersion, capabilities
        }
    }

    private struct SyncPushPayload: Encodable {
        let deviceID: UUID
        let cursor: String
        let mutations: [SyncMutationEnvelope]

        private enum CodingKeys: String, CodingKey {
            case deviceID = "deviceId"
            case cursor, mutations
        }
    }
}

public protocol FocusGuardSyncRemote: Sendable {
    func push(cursor: String, mutations: [SyncMutationEnvelope]) async throws -> BackendPushResponse
    func pull(cursor: String, limit: Int) async throws -> BackendPullResponse
}

extension FocusGuardBackendClient: FocusGuardSyncRemote {}

public struct SyncRunResult: Equatable, Sendable {
    public let pushed: BackendPushResponse?
    public let pulled: BackendPullResponse

    public init(pushed: BackendPushResponse?, pulled: BackendPullResponse) {
        self.pushed = pushed
        self.pulled = pulled
    }
}

/// Coordinates one sync pass without allowing a server cursor to skip remote
/// changes. A caller must apply `pulled.changes` to its local store and then
/// call `commitPulledBatch`; until that succeeds, the same batch is replayable.
public actor SyncCoordinator {
    private let outbox: SyncOutbox
    private var appliedCursor: String

    public init(initialCursor: String = "0") throws {
        guard let value = Int64(initialCursor), value >= 0 else {
            throw SyncOutboxError.invalidCursor
        }
        self.outbox = SyncOutbox()
        self.appliedCursor = String(value)
    }

    public func enqueue(_ mutation: SyncMutationEnvelope) async {
        await outbox.enqueue(mutation)
    }

    public func pendingCount() async -> Int {
        await outbox.pendingCount()
    }

    public func cursor() -> String { appliedCursor }

    public func synchronize(
        with remote: any FocusGuardSyncRemote,
        batchLimit: Int = 50,
        pullLimit: Int = 100
    ) async throws -> SyncRunResult {
        guard (1...500).contains(batchLimit), (1...500).contains(pullLimit) else {
            throw SyncOutboxError.invalidBatchSize
        }
        let batch = try await outbox.nextBatch(limit: batchLimit)
        let pushed: BackendPushResponse?
        if batch.isEmpty {
            pushed = nil
        } else {
            let response = try await remote.push(cursor: appliedCursor, mutations: batch)
            let acknowledged = Set(response.results.compactMap { result in
                result.accepted || (result.duplicate && !result.conflict) ? result.idempotencyKey : nil
            })
            await outbox.acknowledge(idempotencyKeys: acknowledged)
            pushed = response
        }

        // Do not replace `appliedCursor` with pushed.cursor. The latter can
        // include changes created by another device that this client has not
        // materialized yet.
        let pulled = try await remote.pull(cursor: appliedCursor, limit: pullLimit)
        try BackendSyncChangeValidator.validateBatch(
            pulled.changes,
            cursor: pulled.cursor)
        return SyncRunResult(pushed: pushed, pulled: pulled)
    }

    /// Runs one sync pass and confirms the pulled cursor only after the caller
    /// has durably materialized every change. If the applicator throws (for
    /// example because the app crashed during a SwiftData transaction), the
    /// cursor stays unchanged and the batch is replayed on the next pass.
    public func synchronize(
        with remote: any FocusGuardSyncRemote,
        applying apply: @escaping @Sendable ([BackendSyncChange]) async throws -> Void,
        batchLimit: Int = 50,
        pullLimit: Int = 100
    ) async throws -> SyncRunResult {
        let result = try await synchronize(
            with: remote,
            batchLimit: batchLimit,
            pullLimit: pullLimit)
        try BackendSyncChangeValidator.validateBatch(
            result.pulled.changes,
            cursor: result.pulled.cursor)
        try await apply(result.pulled.changes)
        try await commitPulledBatch(result.pulled)
        return result
    }

    public func commitPulledBatch(_ response: BackendPullResponse) async throws {
        guard let current = Int64(appliedCursor),
              let next = Int64(response.cursor),
              next >= current else {
            throw SyncOutboxError.nonMonotonicCursor
        }
        try await outbox.advanceCursor(to: response.cursor)
        appliedCursor = response.cursor
    }
}
