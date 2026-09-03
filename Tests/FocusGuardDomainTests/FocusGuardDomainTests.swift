import Foundation
import Testing
@testable import FocusGuardDomain

@Test func buildsExtendedFlowWithoutFinalBreak() throws {
    let configuration = try FocusCycleConfiguration(
        focusDuration: 90 * 60,
        shortBreakDuration: 20 * 60,
        longBreakDuration: 30 * 60,
        cyclesBeforeLongBreak: 2,
        terminationMode: .cycleCount,
        cycleCount: 2)
    let plan = FocusCyclePlanBuilder.build(configuration: configuration, start: Date(timeIntervalSince1970: 0))

    #expect(plan.phases.count == 3)
    #expect(plan.finalPhase?.kind == .focus)
    #expect(plan.end.timeIntervalSince1970 == 200 * 60)
}

@Test func rejectsNormalRecoveryDelay() {
    #expect(throws: DomainError.self) {
        _ = try StrictModeOptions(enabled: false, recoveryDelay: 60)
    }
}

@Test func rejectsWebsiteQueryStrings() {
    #expect(throws: DomainError.self) {
        _ = try WebsiteRule(action: .block, pattern: "example.com/?utm_source=x")
    }
}

@Test func normalizesAndValidatesProfiles() throws {
    let profile = try Profile(
        id: .new(),
        name: "  Deep Work  ",
        description: "  uninterrupted focus  ",
        accentHex: "#aBc123")
    #expect(profile.name == "Deep Work")
    #expect(profile.description == "uninterrupted focus")
    #expect(profile.accentHex == "#ABC123")

    #expect(throws: DomainError.self) {
        _ = try Profile(id: .new(), name: "")
    }
    #expect(throws: DomainError.self) {
        _ = try Profile(id: .new(), name: "Focus", accentHex: "blue")
    }
}

@Test func wireEnumValuesMatchBackendContract() throws {
    let encoder = JSONEncoder()
    #expect(String(data: try encoder.encode(PlatformFamily.appleMobile), encoding: .utf8) == "\"AppleMobile\"")
    #expect(String(data: try encoder.encode(SessionState.recoveryPending), encoding: .utf8) == "\"RecoveryPending\"")
}

@Test func localRuntimeExpiresWithoutBackend() throws {
    let profileID = ProfileID.new()
    let strict = try StrictModeOptions(enabled: true, recoveryDelay: 60)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var session = try FocusSession(
        profileID: profileID,
        start: start,
        duration: 90 * 60,
        strict: strict)
    try session.transition(to: .activating)
    try session.transition(to: .active)

    let evaluation = SessionRuntimeEvaluator.evaluate(
        session: session,
        at: start.addingTimeInterval(91 * 60))
    #expect(evaluation.effectiveState == .expired)
    #expect(evaluation.secondsRemaining == 0)
}

@Test func localRuntimeReportsCyclePhase() throws {
    let profileID = ProfileID.new()
    let strict = try StrictModeOptions(enabled: false)
    let configuration = try FocusCycleConfiguration(
        focusDuration: 25 * 60,
        shortBreakDuration: 5 * 60,
        longBreakDuration: 15 * 60,
        cyclesBeforeLongBreak: 4,
        terminationMode: .cycleCount,
        cycleCount: 2)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let plan = FocusCyclePlanBuilder.build(configuration: configuration, start: start)
    var session = try FocusSession(
        profileID: profileID,
        start: start,
        duration: plan.end.timeIntervalSince(start),
        strict: strict,
        cyclePlan: plan)
    try session.transition(to: .activating)
    try session.transition(to: .active)

    let evaluation = SessionRuntimeEvaluator.evaluate(
        session: session,
        at: start.addingTimeInterval(26 * 60))
    #expect(evaluation.effectiveState == .active)
    #expect(evaluation.phase?.kind == .shortBreak)
}

@Test func scheduleResolvesInItsIanaTimeZone() throws {
    let schedule = try FocusSchedule(
        profileID: .new(),
        timeZoneID: "America/New_York",
        dstPolicy: .skipInvalid,
        weekdays: [.monday, .friday],
        startLocal: try LocalTimeOfDay(hour: 8, minute: 30),
        endLocal: try LocalTimeOfDay(hour: 12))

    let after = Date(timeIntervalSince1970: 1_767_182_400) // 2025-12-31T00:00:00Z
    let occurrence = try #require(schedule.nextOccurrence(after: after))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    #expect(calendar.component(.hour, from: occurrence.start) == 8)
    #expect(calendar.component(.minute, from: occurrence.start) == 30)
    #expect(calendar.component(.weekday, from: occurrence.start) == 6)
}

@Test func scheduleRejectsInvalidTimeZoneAndEmptyDays() throws {
    let time = try LocalTimeOfDay(hour: 8)
    #expect(throws: DomainError.self) {
        _ = try FocusSchedule(
            profileID: .new(),
            timeZoneID: "Not/AZone",
            dstPolicy: .skipInvalid,
            weekdays: [.monday],
            startLocal: time,
            endLocal: try LocalTimeOfDay(hour: 9))
    }
    #expect(throws: DomainError.self) {
        _ = try FocusSchedule(
            profileID: .new(),
            timeZoneID: "UTC",
            dstPolicy: .skipInvalid,
            weekdays: [],
            startLocal: time,
            endLocal: try LocalTimeOfDay(hour: 9))
    }
}

@Test func scheduleAppliesDstPolicyToInvalidSpringForwardTime() throws {
    let start = Date(timeIntervalSince1970: 1_772_884_800) // 2026-03-07T12:00:00Z
    let endTime = try LocalTimeOfDay(hour: 4)
    let invalidStart = try LocalTimeOfDay(hour: 2, minute: 30)
    let skip = try FocusSchedule(
        profileID: .new(),
        timeZoneID: "America/New_York",
        dstPolicy: .skipInvalid,
        weekdays: [.sunday],
        startLocal: invalidStart,
        endLocal: endTime)
    #expect(skip.nextOccurrence(after: start, searchDays: 2) == nil)

    let shift = try FocusSchedule(
        profileID: .new(),
        timeZoneID: "America/New_York",
        dstPolicy: .shiftForward,
        weekdays: [.sunday],
        startLocal: invalidStart,
        endLocal: endTime)
    let occurrence = try #require(shift.nextOccurrence(after: start, searchDays: 2))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    #expect(calendar.component(.hour, from: occurrence.start) == 3)
    #expect(calendar.component(.minute, from: occurrence.start) == 0)
}

@Test func materializerReturnsBoundedLocalWindows() throws {
    let schedule = try FocusSchedule(
        profileID: .new(),
        timeZoneID: "UTC",
        dstPolicy: .runOnce,
        weekdays: [.monday, .wednesday],
        startLocal: try LocalTimeOfDay(hour: 8),
        endLocal: try LocalTimeOfDay(hour: 9))
    let from = Date(timeIntervalSince1970: 1_767_312_000) // 2026-01-01T12:00:00Z
    let through = from.addingTimeInterval(8 * 24 * 60 * 60)

    let windows = FocusScheduleMaterializer.materialize(
        schedule: schedule,
        from: from,
        through: through,
        maximumOccurrences: 2)

    #expect(windows.count == 2)
    #expect(windows.allSatisfy { $0.duration == 60 * 60 })
    #expect(windows[0].start < windows[1].start)
}

@Test func materializerClipsWindowToRequestedRange() throws {
    let schedule = try FocusSchedule(
        profileID: .new(),
        timeZoneID: "UTC",
        dstPolicy: .runOnce,
        weekdays: [.thursday],
        startLocal: try LocalTimeOfDay(hour: 8),
        endLocal: try LocalTimeOfDay(hour: 10))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let fullWindowStart = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 1,
        day: 1,
        hour: 8)))
    let from = fullWindowStart.addingTimeInterval(30 * 60)
    let through = fullWindowStart.addingTimeInterval(90 * 60)

    let windows = FocusScheduleMaterializer.materialize(
        schedule: schedule,
        from: from,
        through: through)

    let window = try #require(windows.first)
    #expect(window.start == from)
    #expect(window.end == through)
}

@Test func trustedClockPreventsBackwardRollbackFromExtendingADeadline() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let serverSample = start.addingTimeInterval(120)
    var clock = try TrustedClockState()

    clock = clock.recording(localNow: start, serverNow: serverSample)

    #expect(clock.trust == .trusted)
    #expect(clock.effectiveNow(localNow: start.addingTimeInterval(-600)) == serverSample)
    #expect(clock.effectiveNow(localNow: start.addingTimeInterval(600)) == start.addingTimeInterval(600))
}

@Test func trustedClockMarksLargeSkewWithoutHidingIt() throws {
    let local = Date(timeIntervalSince1970: 1_700_000_000)
    let server = local.addingTimeInterval(10 * 60)
    let clock = try TrustedClockState().recording(localNow: local, serverNow: server)

    #expect(clock.trust == .untrusted)
    #expect(clock.effectiveNow(localNow: local) == server)
    #expect(throws: DomainError.self) {
        _ = try TrustedClockState(maximumAllowedSkew: 0)
    }
}

@Test func runtimeEvaluatorUsesConservativeClockForOfflineExpiry() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var session = try FocusSession(
        profileID: .new(),
        start: start,
        duration: 60,
        strict: try StrictModeOptions(enabled: false))
    try session.transition(to: .activating)
    try session.transition(to: .active)
    let clock = try TrustedClockState().recording(
        localNow: start,
        serverNow: start.addingTimeInterval(120))

    let evaluation = SessionRuntimeEvaluator.evaluate(
        session: session,
        localNow: start.addingTimeInterval(-600),
        using: clock)
    #expect(evaluation.effectiveState == .expired)
}

@Test func commonPolicyDoesNotEmbedPlatformTargets() throws {
    let profileID = ProfileID.new()
    let policy = try CommonProfilePolicy(
        profileID: profileID,
        defaultSessionDuration: 90 * 60,
        strictMode: try StrictModeOptions(enabled: true, recoveryDelay: 60),
        breakEnforcement: .allowConfiguredRules)
    let encoded = try JSONEncoder().encode(policy)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    #expect(object["profileID"] != nil)
    #expect(object["applicationRules"] == nil)
    #expect(object["selectionTokens"] == nil)
}

@Test func appleBindingRejectsEmptySelectionAndMacRulesNormalizeTargets() throws {
    let empty = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    #expect(throws: DomainError.self) {
        _ = try AppleMobileDeviceRules(
            bindingID: empty,
            selectionRevision: 0,
            includesApplicationTokens: true,
            includesCategoryTokens: false,
            includesWebDomainTokens: false)
    }
    #expect(throws: DomainError.self) {
        _ = try AppleMobileDeviceRules(
            bindingID: UUID(),
            selectionRevision: 0,
            includesApplicationTokens: false,
            includesCategoryTokens: false,
            includesWebDomainTokens: false)
    }

    let rules = try MacOSDeviceRules(
        applicationBundleIdentifiers: [" com.focusguard.app ", "com.focusguard.app"],
        websiteDomains: ["Example.COM", "example.com"],
        capabilities: ["ScreenTime", "ScreenTime"])
    #expect(rules.applicationBundleIdentifiers == ["com.focusguard.app"])
    #expect(rules.websiteDomains == ["example.com"])
    #expect(rules.capabilities == ["ScreenTime"])
}

@Test func reconcilerAdoptsLiveRemoteSessionWhenLocalIsEmpty() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let remote = try RemoteSessionIntent(
        id: UUID(),
        profileID: .new(),
        start: now,
        end: now.addingTimeInterval(90 * 60),
        strict: try StrictModeOptions(enabled: false),
        state: .active,
        revision: 1)

    let decision = SessionReconciler.decide(local: nil, remote: remote, at: now)
    #expect(decision.disposition == .adoptRemote)
    #expect(decision.sessionID == remote.id)
}

@Test func reconcilerNeverCancelsLocalStrictSessionForRemoteTerminalEvent() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var local = try FocusSession(
        id: UUID(),
        profileID: .new(),
        start: now,
        duration: 90 * 60,
        strict: try StrictModeOptions(enabled: true, recoveryDelay: 60))
    try local.transition(to: .activating)
    try local.transition(to: .active)
    let remote = try RemoteSessionIntent(
        id: local.id,
        profileID: local.profileID,
        start: local.start,
        end: local.end,
        strict: local.strict,
        state: .stopped,
        revision: 2)

    let decision = SessionReconciler.decide(
        local: local,
        remote: remote,
        at: now.addingTimeInterval(5 * 60))
    #expect(decision.disposition == .keepLocal)
    #expect(decision.sessionID == local.id)
}

@Test func reconcilerSurfacesTwoLiveNonStrictSessionsAsConflict() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var local = try FocusSession(
        id: UUID(),
        profileID: .new(),
        start: now,
        duration: 60 * 60,
        strict: try StrictModeOptions(enabled: false))
    try local.transition(to: .activating)
    try local.transition(to: .active)
    let remote = try RemoteSessionIntent(
        id: UUID(),
        profileID: .new(),
        start: now.addingTimeInterval(60),
        end: now.addingTimeInterval(2 * 60 * 60),
        strict: try StrictModeOptions(enabled: false),
        state: .active,
        revision: 1)

    let decision = SessionReconciler.decide(local: local, remote: remote, at: now.addingTimeInterval(5 * 60))
    #expect(decision.disposition == .conflict)
}

@Test func reconcilerIgnoresRemoteSessionThatAlreadyEnded() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let remote = try RemoteSessionIntent(
        id: UUID(),
        profileID: .new(),
        start: now.addingTimeInterval(-2 * 60 * 60),
        end: now.addingTimeInterval(-60),
        strict: try StrictModeOptions(enabled: false),
        state: .active,
        revision: 1)

    #expect(SessionReconciler.decide(local: nil, remote: remote, at: now).disposition == .ignoreExpiredRemote)
}
