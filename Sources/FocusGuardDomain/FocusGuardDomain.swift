import Foundation

public enum PlatformFamily: String, Codable, Sendable {
    case windows = "Windows"
    case appleMobile = "AppleMobile"
    case macOS = "MacOS"
}

public enum RuleAction: String, Codable, Sendable {
    case allow
    case block
}

public enum ApplicationMatchKind: String, Codable, Sendable {
    case exactPath
    case folder
    case sha256
    case fileName
    case localSelection
    case category
}

public struct ProfileID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public static func new() -> ProfileID { ProfileID(rawValue: UUID()) }
}

public struct Profile: Codable, Equatable, Sendable {
    public let id: ProfileID
    public let name: String
    public let description: String?
    public let accentHex: String?

    public init(id: ProfileID, name: String, description: String? = nil, accentHex: String? = nil) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.count <= 80 else {
            throw DomainError.invalid("Profile name must contain 1 to 80 characters")
        }
        let normalizedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedDescription == nil || normalizedDescription!.count <= 160 else {
            throw DomainError.invalid("Profile description must contain at most 160 characters")
        }
        let normalizedAccent = accentHex?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalizedAccent == nil || Self.isAccentHex(normalizedAccent!) else {
            throw DomainError.invalid("Profile accent must be #RRGGBB")
        }
        self.id = id
        self.name = normalizedName
        self.description = normalizedDescription?.isEmpty == true ? nil : normalizedDescription
        self.accentHex = normalizedAccent
    }

    public static func isAccentHex(_ value: String) -> Bool {
        value.count == 7 && value.first == "#" && value.dropFirst().allSatisfy { $0.isHexDigit }
    }
}

public struct ApplicationRule: Codable, Equatable, Sendable {
    public let id: UUID
    public let action: RuleAction
    public let matchKind: ApplicationMatchKind
    public let value: String

    public init(id: UUID = UUID(), action: RuleAction, matchKind: ApplicationMatchKind, value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw DomainError.invalid("Application rule value is required") }
        self.id = id
        self.action = action
        self.matchKind = matchKind
        self.value = normalized
    }
}

public struct WebsiteRule: Codable, Equatable, Sendable {
    public let id: UUID
    public let action: RuleAction
    public let pattern: String

    public init(id: UUID = UUID(), action: RuleAction, pattern: String) throws {
        let normalized = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, !normalized.contains("?"), !normalized.contains("#") else {
            throw DomainError.invalid("Website patterns cannot contain query strings or fragments")
        }
        self.id = id
        self.action = action
        self.pattern = normalized
    }
}

public enum BreakEnforcement: String, Codable, Sendable {
    case keepFocusRules
    case allowConfiguredRules
}

/// Configuration shared by all clients. It describes intent only; concrete
/// application/site targets live in the platform/device rule sets below.
public struct CommonProfilePolicy: Codable, Equatable, Sendable {
    public let profileID: ProfileID
    public let defaultSessionDuration: TimeInterval
    public let strictMode: StrictModeOptions
    public let cycleConfiguration: FocusCycleConfiguration?
    public let breakEnforcement: BreakEnforcement

    public init(
        profileID: ProfileID,
        defaultSessionDuration: TimeInterval,
        strictMode: StrictModeOptions,
        cycleConfiguration: FocusCycleConfiguration? = nil,
        breakEnforcement: BreakEnforcement = .keepFocusRules
    ) throws {
        guard (60...30 * 24 * 60 * 60).contains(defaultSessionDuration) else {
            throw DomainError.invalid("Default session duration is invalid")
        }
        if cycleConfiguration == nil, defaultSessionDuration < 60 {
            throw DomainError.invalid("A timer policy must have a valid duration")
        }
        self.profileID = profileID
        self.defaultSessionDuration = defaultSessionDuration
        self.strictMode = strictMode
        self.cycleConfiguration = cycleConfiguration
        self.breakEnforcement = breakEnforcement
    }
}

/// Windows rules retain their executable/path semantics and are never reduced
/// to an Apple Screen Time token or category.
public struct WindowsDeviceRules: Codable, Equatable, Sendable {
    public let applicationRules: [ApplicationRule]
    public let websiteRules: [WebsiteRule]

    public init(applicationRules: [ApplicationRule] = [], websiteRules: [WebsiteRule] = []) {
        self.applicationRules = applicationRules
        self.websiteRules = websiteRules
    }
}

/// Screen Time selections are private to the authorized device. Only a local
/// binding identity/revision is represented here; opaque tokens never enter a
/// cloud DTO or a cross-device payload.
public struct AppleMobileDeviceRules: Codable, Equatable, Sendable {
    public let bindingID: UUID
    public let selectionRevision: Int
    public let includesApplicationTokens: Bool
    public let includesCategoryTokens: Bool
    public let includesWebDomainTokens: Bool

    public init(
        bindingID: UUID,
        selectionRevision: Int,
        includesApplicationTokens: Bool,
        includesCategoryTokens: Bool,
        includesWebDomainTokens: Bool
    ) throws {
        let emptyBinding = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        guard bindingID != emptyBinding, selectionRevision >= 0 else {
            throw DomainError.invalid("Apple device binding is invalid")
        }
        guard includesApplicationTokens || includesCategoryTokens || includesWebDomainTokens else {
            throw DomainError.invalid("Apple device binding must contain at least one selected target")
        }
        self.bindingID = bindingID
        self.selectionRevision = selectionRevision
        self.includesApplicationTokens = includesApplicationTokens
        self.includesCategoryTokens = includesCategoryTokens
        self.includesWebDomainTokens = includesWebDomainTokens
    }
}

/// macOS rules express only capabilities measured and approved for the Mac
/// target. Unsupported values must be rejected by the Mac enforcement engine.
public struct MacOSDeviceRules: Codable, Equatable, Sendable {
    public let applicationBundleIdentifiers: [String]
    public let websiteDomains: [String]
    public let capabilities: [String]

    public init(
        applicationBundleIdentifiers: [String] = [],
        websiteDomains: [String] = [],
        capabilities: [String] = []
    ) throws {
        let bundles = Self.normalized(applicationBundleIdentifiers)
        let domains = Self.normalized(websiteDomains, lowercased: true)
        let measuredCapabilities = Self.normalized(capabilities)
        guard bundles.allSatisfy({ $0.contains(".") }),
              domains.allSatisfy({ !$0.contains("/") && !$0.contains("?") && !$0.contains("#") }) else {
            throw DomainError.invalid("macOS device rules contain an invalid target")
        }
        self.applicationBundleIdentifiers = bundles
        self.websiteDomains = domains
        self.capabilities = measuredCapabilities
    }

    private static func normalized(_ values: [String], lowercased: Bool = false) -> [String] {
        var seen = Set<String>()
        return values
            .map { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return lowercased ? trimmed.lowercased() : trimmed
            }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }
}

public enum SessionState: String, Codable, Sendable {
    case draft = "Draft"
    case activating = "Activating"
    case active = "Active"
    case expired = "Expired"
    case stopped = "Stopped"
    case recoveryPending = "RecoveryPending"
    case recovered = "Recovered"
    case failed = "Failed"
}

public struct StrictModeOptions: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let recoveryDelay: TimeInterval

    public init(enabled: Bool, recoveryDelay: TimeInterval = 0) throws {
        guard recoveryDelay >= 0, recoveryDelay <= 24 * 60 * 60 else {
            throw DomainError.invalid("Recovery delay must be between 0 and 24 hours")
        }
        if !enabled && recoveryDelay != 0 { throw DomainError.invalid("Normal mode cannot have recovery delay") }
        self.enabled = enabled
        self.recoveryDelay = recoveryDelay
    }
}

public enum SessionMode: String, Codable, Sendable { case simpleTimer, focusCycle }
public enum SessionPhaseKind: String, Codable, Sendable { case focus, shortBreak, longBreak }
public enum CycleTerminationMode: String, Codable, Sendable { case cycleCount, totalDuration }

public enum ScheduleWeekday: String, Codable, CaseIterable, Hashable, Sendable {
    case sunday = "Sunday"
    case monday = "Monday"
    case tuesday = "Tuesday"
    case wednesday = "Wednesday"
    case thursday = "Thursday"
    case friday = "Friday"
    case saturday = "Saturday"

    fileprivate var calendarWeekday: Int {
        switch self {
        case .sunday: 1
        case .monday: 2
        case .tuesday: 3
        case .wednesday: 4
        case .thursday: 5
        case .friday: 6
        case .saturday: 7
        }
    }
}

public enum ScheduleDstPolicy: String, Codable, CaseIterable, Sendable {
    case skipInvalid = "SkipInvalid"
    case shiftForward = "ShiftForward"
    case runOnce = "RunOnce"
}

public struct LocalTimeOfDay: Codable, Equatable, Hashable, Sendable {
    public let hour: Int
    public let minute: Int
    public let second: Int

    public init(hour: Int, minute: Int = 0, second: Int = 0) throws {
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
            throw DomainError.invalid("Local time is outside 00:00:00 to 23:59:59")
        }
        self.hour = hour
        self.minute = minute
        self.second = second
    }
}

public struct FocusSchedule: Codable, Equatable, Sendable {
    public let id: UUID
    public let profileID: ProfileID
    public let timeZoneID: String
    public let dstPolicy: ScheduleDstPolicy
    public let weekdays: Set<ScheduleWeekday>
    public let startLocal: LocalTimeOfDay
    public let endLocal: LocalTimeOfDay
    public let isEnabled: Bool

    public init(
        id: UUID = UUID(),
        profileID: ProfileID,
        timeZoneID: String,
        dstPolicy: ScheduleDstPolicy,
        weekdays: Set<ScheduleWeekday>,
        startLocal: LocalTimeOfDay,
        endLocal: LocalTimeOfDay,
        isEnabled: Bool = true
    ) throws {
        guard TimeZone(identifier: timeZoneID) != nil else {
            throw DomainError.invalid("Schedule time zone must be a valid IANA identifier")
        }
        guard !weekdays.isEmpty else {
            throw DomainError.invalid("Schedule must contain at least one weekday")
        }
        let startSeconds = startLocal.hour * 3_600 + startLocal.minute * 60 + startLocal.second
        let endSeconds = endLocal.hour * 3_600 + endLocal.minute * 60 + endLocal.second
        guard startSeconds < endSeconds else {
            throw DomainError.invalid("Schedule end must be after its start on the same local day")
        }
        self.id = id
        self.profileID = profileID
        self.timeZoneID = timeZoneID
        self.dstPolicy = dstPolicy
        self.weekdays = weekdays
        self.startLocal = startLocal
        self.endLocal = endLocal
        self.isEnabled = isEnabled
    }

    /// Returns the current or next same-day occurrence after `after`.
    /// Invalid spring-forward local times are skipped or shifted according to
    /// `dstPolicy`; repeated fall-back times run once using the first instance.
    public func nextOccurrence(after: Date, searchDays: Int = 14) -> DateInterval? {
        guard isEnabled, searchDays > 0, let timeZone = TimeZone(identifier: timeZoneID) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let firstDay = calendar.startOfDay(for: after)
        for offset in 0..<searchDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay),
                  let weekday = ScheduleWeekday(calendarWeekday: calendar.component(.weekday, from: day)),
                  weekdays.contains(weekday) else {
                continue
            }
            guard let start = resolve(time: startLocal, on: day, calendar: calendar),
                  let end = resolve(time: endLocal, on: day, calendar: calendar),
                  end > start else {
                continue
            }
            let interval = DateInterval(start: start, end: end)
            if interval.end > after { return interval }
        }
        return nil
    }

    private func resolve(time: LocalTimeOfDay, on day: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        switch dstPolicy {
        case .skipInvalid:
            guard let date = calendar.date(from: components) else { return nil }
            let actual = calendar.dateComponents([.hour, .minute, .second], from: date)
            guard actual.hour == time.hour, actual.minute == time.minute, actual.second == time.second else {
                return nil
            }
            return date
        case .shiftForward, .runOnce:
            let beforeDay = calendar.date(byAdding: .second, value: -1, to: day) ?? day
            return calendar.nextDate(
                after: beforeDay,
                matching: components,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward)
        }
    }
}

/// A bounded, deterministic materialization of a recurring schedule. Clients
/// persist the resulting windows locally and can hand the next window to the
/// platform scheduler without requiring network or app execution at trigger
/// time.
public enum FocusScheduleMaterializer {
    public static func materialize(
        schedule: FocusSchedule,
        from start: Date,
        through end: Date,
        maximumOccurrences: Int = 30
    ) -> [DateInterval] {
        guard end > start, maximumOccurrences > 0 else { return [] }

        var occurrences: [DateInterval] = []
        var cursor = start
        let daySpan = Calendar(identifier: .gregorian)
            .dateComponents([.day], from: start, to: end)
            .day ?? 0
        let searchDays = max(14, daySpan + 2)

        while occurrences.count < maximumOccurrences,
              let occurrence = schedule.nextOccurrence(after: cursor, searchDays: searchDays),
              occurrence.start < end {
            if occurrence.end > start {
                occurrences.append(DateInterval(
                    start: max(occurrence.start, start),
                    end: min(occurrence.end, end)))
            }

            // `nextOccurrence(after:)` includes the current interval. Move
            // strictly past its end so a malformed/short window cannot loop.
            cursor = occurrence.end.addingTimeInterval(1)
        }

        return occurrences
    }
}

private extension ScheduleWeekday {
    init?(calendarWeekday: Int) {
        switch calendarWeekday {
        case 1: self = .sunday
        case 2: self = .monday
        case 3: self = .tuesday
        case 4: self = .wednesday
        case 5: self = .thursday
        case 6: self = .friday
        case 7: self = .saturday
        default: return nil
        }
    }
}

public struct FocusCycleConfiguration: Codable, Equatable, Sendable {
    public let focusDuration: TimeInterval
    public let shortBreakDuration: TimeInterval
    public let longBreakDuration: TimeInterval
    public let cyclesBeforeLongBreak: Int
    public let terminationMode: CycleTerminationMode
    public let cycleCount: Int?
    public let totalDuration: TimeInterval?

    public init(focusDuration: TimeInterval, shortBreakDuration: TimeInterval, longBreakDuration: TimeInterval,
                cyclesBeforeLongBreak: Int, terminationMode: CycleTerminationMode,
                cycleCount: Int? = nil, totalDuration: TimeInterval? = nil) throws {
        guard (60...180 * 60).contains(focusDuration), (60...60 * 60).contains(shortBreakDuration),
              (60...120 * 60).contains(longBreakDuration), (2...12).contains(cyclesBeforeLongBreak) else {
            throw DomainError.invalid("Cycle durations or frequency are outside supported bounds")
        }
        switch terminationMode {
        case .cycleCount:
            guard let cycleCount, (1...24).contains(cycleCount), totalDuration == nil else {
                throw DomainError.invalid("Cycle-count configuration is invalid")
            }
        case .totalDuration:
            guard let totalDuration, (60...30 * 24 * 60 * 60).contains(totalDuration), cycleCount == nil else {
                throw DomainError.invalid("Total-duration configuration is invalid")
            }
        }
        self.focusDuration = focusDuration
        self.shortBreakDuration = shortBreakDuration
        self.longBreakDuration = longBreakDuration
        self.cyclesBeforeLongBreak = cyclesBeforeLongBreak
        self.terminationMode = terminationMode
        self.cycleCount = cycleCount
        self.totalDuration = totalDuration
    }
}

public struct SessionPhase: Codable, Equatable, Sendable {
    public let index: Int
    public let kind: SessionPhaseKind
    public let start: Date
    public let end: Date
    public let focusCycleNumber: Int

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct FocusCyclePlan: Codable, Equatable, Sendable {
    public let configuration: FocusCycleConfiguration
    public let phases: [SessionPhase]
    public let end: Date

    public var finalPhase: SessionPhase? { phases.last }
    public var plannedFocusCycles: Int { phases.filter { $0.kind == .focus }.count }
}

public enum FocusCyclePlanBuilder {
    public static func build(configuration: FocusCycleConfiguration, start: Date) -> FocusCyclePlan {
        var phases: [SessionPhase] = []
        var cursor = start
        var cycle = 1
        let finalEnd: Date
        switch configuration.terminationMode {
        case .cycleCount:
            finalEnd = start.addingTimeInterval(totalDuration(configuration, cycles: configuration.cycleCount!))
        case .totalDuration:
            finalEnd = start.addingTimeInterval(configuration.totalDuration!)
        }

        while cursor < finalEnd {
            let focusEnd = minDate(cursor.addingTimeInterval(configuration.focusDuration), finalEnd)
            phases.append(SessionPhase(index: phases.count, kind: .focus, start: cursor, end: focusEnd, focusCycleNumber: cycle))
            cursor = focusEnd
            if cursor >= finalEnd { break }

            let breakKind: SessionPhaseKind = cycle % configuration.cyclesBeforeLongBreak == 0 ? .longBreak : .shortBreak
            let breakDuration = breakKind == .longBreak ? configuration.longBreakDuration : configuration.shortBreakDuration
            let breakEnd = minDate(cursor.addingTimeInterval(breakDuration), finalEnd)
            phases.append(SessionPhase(index: phases.count, kind: breakKind, start: cursor, end: breakEnd, focusCycleNumber: cycle))
            cursor = breakEnd
            cycle += 1
        }
        return FocusCyclePlan(configuration: configuration, phases: phases, end: finalEnd)
    }

    private static func totalDuration(_ configuration: FocusCycleConfiguration, cycles: Int) -> TimeInterval {
        let focus = Double(cycles) * configuration.focusDuration
        let breaks = Double(max(0, cycles - 1))
        let longBreaks = Double(max(0, (cycles - 1) / configuration.cyclesBeforeLongBreak))
        return focus + (breaks - longBreaks) * configuration.shortBreakDuration + longBreaks * configuration.longBreakDuration
    }

    private static func minDate(_ lhs: Date, _ rhs: Date) -> Date { lhs < rhs ? lhs : rhs }
}

public struct FocusSession: Codable, Equatable, Sendable {
    public let id: UUID
    public let profileID: ProfileID
    public let start: Date
    public let end: Date
    public let strict: StrictModeOptions
    public let cyclePlan: FocusCyclePlan?
    public private(set) var state: SessionState

    public init(id: UUID = UUID(), profileID: ProfileID, start: Date, duration: TimeInterval,
                strict: StrictModeOptions, cyclePlan: FocusCyclePlan? = nil) throws {
        guard (60...30 * 24 * 60 * 60).contains(duration) else { throw DomainError.invalid("Session duration is invalid") }
        guard start.timeIntervalSince1970.isFinite else { throw DomainError.invalid("Session start is invalid") }
        self.id = id
        self.profileID = profileID
        self.start = start
        self.end = start.addingTimeInterval(duration)
        self.strict = strict
        self.cyclePlan = cyclePlan
        self.state = .draft
    }

    public var mode: SessionMode { cyclePlan == nil ? .simpleTimer : .focusCycle }

    public mutating func transition(to next: SessionState) throws {
        if state == next { return }
        let valid = switch (state, next) {
        case (.draft, .activating), (.activating, .active), (.activating, .failed), (.activating, .expired): true
        case (.activating, .stopped), (.active, .stopped): !strict.enabled
        case (.active, .expired): true
        case (.active, .recoveryPending): strict.enabled
        case (.recoveryPending, .recovered): true
        default: false
        }
        guard valid else { throw DomainError.invalid("Invalid session transition \(state) -> \(next)") }
        state = next
    }
}

/// The server's session intent without any platform enforcement state. It is
/// safe to transport through sync, but clients must still decide locally how
/// it interacts with an already-running session.
public struct RemoteSessionIntent: Codable, Equatable, Sendable {
    public let id: UUID
    public let profileID: ProfileID
    public let start: Date
    public let end: Date
    public let strict: StrictModeOptions
    public let state: SessionState
    public let revision: Int

    public init(
        id: UUID,
        profileID: ProfileID,
        start: Date,
        end: Date,
        strict: StrictModeOptions,
        state: SessionState,
        revision: Int
    ) throws {
        guard id != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              end > start,
              start.timeIntervalSince1970.isFinite,
              end.timeIntervalSince1970.isFinite,
              revision >= 0 else {
            throw DomainError.invalid("Remote session intent is invalid")
        }
        self.id = id
        self.profileID = profileID
        self.start = start
        self.end = end
        self.strict = strict
        self.state = state
        self.revision = revision
    }
}

public enum SessionReconciliationDisposition: String, Codable, Sendable {
    case adoptRemote
    case keepLocal
    case noOp
    case conflict
    case ignoreExpiredRemote
}

public struct SessionReconciliationDecision: Equatable, Sendable {
    public let disposition: SessionReconciliationDisposition
    public let sessionID: UUID?
    public let reason: String

    public init(
        disposition: SessionReconciliationDisposition,
        sessionID: UUID?,
        reason: String
    ) {
        self.disposition = disposition
        self.sessionID = sessionID
        self.reason = reason
    }
}

/// Resolves remote session events without mutating enforcement. The caller
/// applies an `adoptRemote` decision only after persisting a local snapshot;
/// `keepLocal` is deliberately stronger than eventual cloud convergence for a
/// finite Strict session.
public enum SessionReconciler {
    public static func decide(
        local: FocusSession?,
        remote: RemoteSessionIntent,
        at now: Date
    ) -> SessionReconciliationDecision {
        let remoteIsLive = (remote.state == .activating || remote.state == .active) && remote.end > now
        let remoteIsTerminal = remote.state == .expired || remote.state == .stopped || remote.state == .recovered

        guard let local else {
            return remoteIsLive
                ? SessionReconciliationDecision(
                    disposition: .adoptRemote,
                    sessionID: remote.id,
                    reason: "No local session exists; adopt the still-live remote intent.")
                : SessionReconciliationDecision(
                    disposition: .ignoreExpiredRemote,
                    sessionID: remote.id,
                    reason: "The remote intent is not live at the local reconciliation instant.")
        }

        let localIsLive = (local.state == .activating || local.state == .active) && local.end > now
        if local.id == remote.id {
            if localIsLive && local.strict.enabled && remoteIsTerminal {
                return SessionReconciliationDecision(
                    disposition: .keepLocal,
                    sessionID: local.id,
                    reason: "A remote terminal event cannot cancel a local Strict session before its deadline.")
            }
            if localIsLive && remoteIsLive {
                return SessionReconciliationDecision(
                    disposition: .noOp,
                    sessionID: local.id,
                    reason: "The local snapshot already represents the live remote session.")
            }
            return remoteIsLive
                ? SessionReconciliationDecision(
                    disposition: .adoptRemote,
                    sessionID: remote.id,
                    reason: "The local copy is not live; restore the live remote intent.")
                : SessionReconciliationDecision(
                    disposition: .ignoreExpiredRemote,
                    sessionID: remote.id,
                    reason: "The matching remote session is no longer live.")
        }

        if localIsLive && local.strict.enabled {
            return SessionReconciliationDecision(
                disposition: .keepLocal,
                sessionID: local.id,
                reason: "A different remote session cannot replace a local Strict session in progress.")
        }
        if localIsLive && remoteIsLive {
            return SessionReconciliationDecision(
                disposition: .conflict,
                sessionID: local.id,
                reason: "Two live session IDs overlap; retain local enforcement and surface a conflict.")
        }
        return remoteIsLive
            ? SessionReconciliationDecision(
                disposition: .adoptRemote,
                sessionID: remote.id,
                reason: "The local session is not live; adopt the live remote intent.")
            : SessionReconciliationDecision(
                disposition: .ignoreExpiredRemote,
                sessionID: remote.id,
                reason: "The remote intent is not live at the reconciliation instant.")
    }
}

/// A pure evaluation of a persisted session at an instant. Clients run this
/// locally on resume/tick, so an active lock has a finite outcome even when
/// the network and backend are unavailable.
public struct SessionRuntimeEvaluation: Equatable, Sendable {
    public let effectiveState: SessionState
    public let phase: SessionPhase?
    public let secondsRemaining: TimeInterval

    public init(effectiveState: SessionState, phase: SessionPhase? = nil, secondsRemaining: TimeInterval) {
        self.effectiveState = effectiveState
        self.phase = phase
        self.secondsRemaining = max(0, secondsRemaining)
    }
}

public enum SessionRuntimeEvaluator {
    public static func evaluate(session: FocusSession, at now: Date) -> SessionRuntimeEvaluation {
        switch session.state {
        case .draft:
            return SessionRuntimeEvaluation(
                effectiveState: .draft,
                secondsRemaining: session.start.timeIntervalSince(now))
        case .activating:
            if now < session.start {
                return SessionRuntimeEvaluation(
                    effectiveState: .activating,
                    secondsRemaining: session.start.timeIntervalSince(now))
            }
            return activeEvaluation(session: session, at: now)
        case .active:
            return activeEvaluation(session: session, at: now)
        case .expired, .stopped, .recoveryPending, .recovered, .failed:
            return SessionRuntimeEvaluation(
                effectiveState: session.state,
                secondsRemaining: 0)
        }
    }

    public static func evaluate(
        session: FocusSession,
        localNow: Date,
        using clock: TrustedClockState
    ) -> SessionRuntimeEvaluation {
        evaluate(session: session, at: clock.effectiveNow(localNow: localNow))
    }

    private static func activeEvaluation(session: FocusSession, at now: Date) -> SessionRuntimeEvaluation {
        guard now < session.end else {
            return SessionRuntimeEvaluation(effectiveState: .expired, secondsRemaining: 0)
        }

        let phase = session.cyclePlan?.phases.first {
            $0.start <= now && now < $0.end
        }
        return SessionRuntimeEvaluation(
            effectiveState: .active,
            phase: phase,
            secondsRemaining: session.end.timeIntervalSince(now))
    }
}

/// Persisted clock evidence used by offline clients. A server sample is only
/// a diagnostic/trust anchor; it is never required to keep enforcement alive.
/// When a device clock moves backwards, the latest observed server instant
/// prevents a finite session from being extended indefinitely. A large skew is
/// exposed to UX/telemetry instead of being hidden behind a silent correction.
public struct TrustedClockState: Codable, Equatable, Sendable {
    public enum Trust: String, Codable, Sendable {
        case noSample
        case trusted
        case untrusted
    }

    public let lastObservedUTC: Date?
    public let latestServerUTC: Date?
    public let maximumAllowedSkew: TimeInterval
    public let trust: Trust

    public init(
        lastObservedUTC: Date? = nil,
        latestServerUTC: Date? = nil,
        maximumAllowedSkew: TimeInterval = 5 * 60,
        trust: Trust? = nil
    ) throws {
        guard maximumAllowedSkew > 0, maximumAllowedSkew <= 24 * 60 * 60 else {
            throw DomainError.invalid("Clock skew threshold must be between 1 second and 24 hours")
        }
        self.lastObservedUTC = lastObservedUTC
        self.latestServerUTC = latestServerUTC
        self.maximumAllowedSkew = maximumAllowedSkew
        self.trust = trust ?? Self.computeTrust(
            local: lastObservedUTC,
            server: latestServerUTC,
            threshold: maximumAllowedSkew)
    }

    /// Records a server timestamp returned by a successful request. Samples
    /// are monotonic so a delayed response cannot move the anchor backwards.
    public func recording(localNow: Date, serverNow: Date) -> TrustedClockState {
        let latest = maxDate(latestServerUTC ?? serverNow, serverNow)
        let nextTrust = Self.computeTrust(
            local: localNow,
            server: latest,
            threshold: maximumAllowedSkew)
        return TrustedClockState(
            uncheckedLastObservedUTC: localNow,
            latestServerUTC: latest,
            maximumAllowedSkew: maximumAllowedSkew,
            trust: nextTrust)
    }

    private init(
        uncheckedLastObservedUTC lastObservedUTC: Date?,
        latestServerUTC: Date?,
        maximumAllowedSkew: TimeInterval,
        trust: Trust
    ) {
        self.lastObservedUTC = lastObservedUTC
        self.latestServerUTC = latestServerUTC
        self.maximumAllowedSkew = maximumAllowedSkew
        self.trust = trust
    }

    /// Returns the most conservative known instant. This intentionally does
    /// not extrapolate server time while offline: a client remains finite and
    /// can expire early, but cannot gain extra focus time from a clock rollback.
    public func effectiveNow(localNow: Date) -> Date {
        maxDate(localNow, latestServerUTC ?? localNow)
    }

    private static func computeTrust(local: Date?, server: Date?, threshold: TimeInterval) -> Trust {
        guard let local, let server else { return .noSample }
        return abs(server.timeIntervalSince(local)) <= threshold ? .trusted : .untrusted
    }

    private func maxDate(_ lhs: Date, _ rhs: Date) -> Date { lhs >= rhs ? lhs : rhs }
}

public enum DomainError: Error, Equatable, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}
