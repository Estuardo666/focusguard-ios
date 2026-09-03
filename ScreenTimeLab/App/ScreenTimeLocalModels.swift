import Foundation
import SwiftData

/// Local, device-owned copy of a profile. Platform tokens are intentionally not
/// stored here: Family Controls selections belong to the authorized device.
@Model
final class LocalProfileRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var summary: String
    var accentHex: String?
    var commonPolicyJSON: String
    var updatedAt: Date
    var serverRevision: Int64

    init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        accentHex: String? = nil,
        commonPolicyJSON: String = "{}",
        updatedAt: Date = .now,
        serverRevision: Int64 = 0
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.accentHex = accentHex
        self.commonPolicyJSON = commonPolicyJSON
        self.updatedAt = updatedAt
        self.serverRevision = serverRevision
    }
}

/// Durable local state machine snapshot. The absolute end date is what keeps
/// enforcement active while the app, network, or backend is unavailable.
@Model
final class LocalSessionRecord {
    @Attribute(.unique) var id: UUID
    var profileID: UUID
    var stateRaw: String
    var startDate: Date
    var endDate: Date
    var strictModeEnabled: Bool
    var phaseIndex: Int
    var updatedAt: Date
    var serverRevision: Int64

    init(
        id: UUID,
        profileID: UUID,
        stateRaw: String,
        startDate: Date,
        endDate: Date,
        strictModeEnabled: Bool,
        phaseIndex: Int = 0,
        updatedAt: Date = .now,
        serverRevision: Int64 = 0
    ) {
        self.id = id
        self.profileID = profileID
        self.stateRaw = stateRaw
        self.startDate = startDate
        self.endDate = endDate
        self.strictModeEnabled = strictModeEnabled
        self.phaseIndex = phaseIndex
        self.updatedAt = updatedAt
        self.serverRevision = serverRevision
    }
}

/// Device-owned recurring schedule. Weekdays and local seconds are stored as
/// plain values so the record remains independent from Apple scheduler APIs;
/// the shared domain materializes it into UTC windows when needed.
@Model
final class LocalScheduleRecord {
    @Attribute(.unique) var id: UUID
    var profileID: UUID
    var timeZoneID: String
    var dstPolicyRaw: String
    var weekdaysRaw: String
    var startSeconds: Int
    var endSeconds: Int
    var isEnabled: Bool
    var updatedAt: Date
    var serverRevision: Int64

    init(
        id: UUID = UUID(),
        profileID: UUID,
        timeZoneID: String,
        dstPolicyRaw: String = "ShiftForward",
        weekdaysRaw: String = "Monday,Tuesday,Wednesday,Thursday,Friday",
        startSeconds: Int = 8 * 60 * 60 + 30 * 60,
        endSeconds: Int = 12 * 60 * 60,
        isEnabled: Bool = true,
        updatedAt: Date = .now,
        serverRevision: Int64 = 0
    ) {
        self.id = id
        self.profileID = profileID
        self.timeZoneID = timeZoneID
        self.dstPolicyRaw = dstPolicyRaw
        self.weekdaysRaw = weekdaysRaw
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
        self.serverRevision = serverRevision
    }
}

/// Durable outbox item. `payloadJSON` contains a single mutation object and is
/// retried with the same idempotency key until the backend acknowledges it.
@Model
final class LocalPendingMutationRecord {
    @Attribute(.unique) var idempotencyKey: String
    var aggregateType: String
    var aggregateID: UUID?
    var operation: String
    var expectedRevision: Int64?
    var payloadJSON: String
    var createdAt: Date
    var attemptCount: Int
    var lastAttemptAt: Date?

    init(
        idempotencyKey: String,
        aggregateType: String,
        aggregateID: UUID? = nil,
        operation: String,
        expectedRevision: Int64? = nil,
        payloadJSON: String,
        createdAt: Date = .now,
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil
    ) {
        self.idempotencyKey = idempotencyKey
        self.aggregateType = aggregateType
        self.aggregateID = aggregateID
        self.operation = operation
        self.expectedRevision = expectedRevision
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
    }
}

/// Singleton sync metadata for the current account/device. A server cursor is
/// only an optimization; active enforcement never depends on it being fresh.
@Model
final class LocalSyncMetadataRecord {
    @Attribute(.unique) var key: String
    var deviceID: UUID
    var serverCursor: Int64
    var lastSuccessfulSyncAt: Date?
    var lastServerTime: Date?
    var lastObservedLocalTime: Date?
    var clockTrustRaw: String

    init(
        key: String = "default",
        deviceID: UUID,
        serverCursor: Int64 = 0,
        lastSuccessfulSyncAt: Date? = nil,
        lastServerTime: Date? = nil,
        lastObservedLocalTime: Date? = nil,
        clockTrustRaw: String = "noSample"
    ) {
        self.key = key
        self.deviceID = deviceID
        self.serverCursor = serverCursor
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.lastServerTime = lastServerTime
        self.lastObservedLocalTime = lastObservedLocalTime
        self.clockTrustRaw = clockTrustRaw
    }
}

enum FocusGuardModelContainerFactory {
    /// Builds the local store. The shared app-group container is preferred so the
    /// Screen Time extensions can read the same database, but sideloaded builds are
    /// re-signed without that entitlement, so fall back to the app's own container
    /// instead of failing to launch.
    static func make() throws -> ModelContainer {
        // SwiftData traps (rather than throwing) when the app group is not
        // provisioned, so probe for it before asking for that container.
        let groupContainer: ModelConfiguration.GroupContainer = isAppGroupAvailable
            ? .identifier(ScreenTimeLabConstants.appGroup)
            : .none
        do {
            return try makeContainer(groupContainer: groupContainer)
        } catch {
            return try makeInMemory()
        }
    }

    static var isAppGroupAvailable: Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ScreenTimeLabConstants.appGroup) != nil
    }

    static func makeInMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: FocusGuardSchemaV1.self)
        let configuration = ModelConfiguration(
            "FocusGuardLocalMemory",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func makeContainer(
        groupContainer: ModelConfiguration.GroupContainer
    ) throws -> ModelContainer {
        let schema = Schema(versionedSchema: FocusGuardSchemaV1.self)
        let configuration = ModelConfiguration(
            "FocusGuardLocal",
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: groupContainer,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: FocusGuardMigrationPlan.self,
            configurations: [configuration])
    }
}

enum FocusGuardSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static let models: [any PersistentModel.Type] = [
        LocalProfileRecord.self,
        LocalSessionRecord.self,
        LocalScheduleRecord.self,
        LocalPendingMutationRecord.self,
        LocalSyncMetadataRecord.self
    ]
}

enum FocusGuardMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [FocusGuardSchemaV1.self]
    static let stages: [MigrationStage] = []
}
