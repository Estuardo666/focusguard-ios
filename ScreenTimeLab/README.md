# Screen Time laboratory target

This directory is the source for the first Apple enforcement experiment described in `FOCUSGUARD_APPLE_PLAN.md`. It intentionally does not belong to the platform-neutral Swift Package target: an Xcode project must include these files in one iOS app target and three extensions.

## Targets to create on macOS

| Target | Type | Principal class |
| --- | --- | --- |
| `FocusGuardMobile` | iOS/iPadOS application | `FocusGuardScreenTimeLabApp` |
| `FocusGuardDeviceActivityMonitor` | Device Activity Monitor extension | `FocusGuardDeviceActivityMonitor` |
| `FocusGuardShieldConfiguration` | Shield Configuration extension | `FocusGuardShieldConfigurationExtension` |
| `FocusGuardShieldAction` | Shield Action extension | `FocusGuardShieldActionExtension` |

All four targets need the Family Controls capability and the same App Group. The app target also needs the Swift package products `FocusGuardDomain` and `FocusGuardSync` once the UI is connected to the shared session model.

The source uses only public FamilyControls, ManagedSettings, ManagedSettingsUI and DeviceActivity APIs. It stores the `FamilyActivitySelection` only in the App Group container; no token or derived app name is sent to the backend.

The lab also initializes a SwiftData `ModelContainer` in the same App Group using `FocusGuardSchemaV1`. It persists the local session deadline/state and the first outbox/sync records; Screen Time tokens remain in the separate App Group `UserDefaults` selection blob.

The shared domain package now materializes recurring schedules into bounded UTC
windows before a platform scheduler is configured. The lab does not treat
`DeviceActivity` as a general-purpose scheduler or promise immediate callback
delivery.

The lab UI persists the selected weekdays, local time range and DST policy in
`LocalScheduleRecord`, and shows the next materialized window. It intentionally
does not label that preview as a completed enforcement test until the signed
Codemagic build is exercised on a real device.

The Strict Mode toggle only removes the normal in-app stop path while the finite session is active. It is deliberately not described as protection against Settings, authorization revocation, uninstall, reset or administrator control.

The lab fails closed before starting when the App Group container is
unavailable. On relaunch it keeps the local session identifier and records a
normal stop separately from an expiry, so diagnostics do not confuse a crash
or a deadline with a user cancellation.

`ScreenTimeSyncEngine` is the integration seam for the next MVP increment. It
reads a bounded outbox batch, marks attempts, pushes with stable idempotency
keys, acknowledges only accepted/non-conflicting results, pulls from the last
durable cursor, invokes a caller-owned materializer, and commits the cursor
only after that materializer succeeds. Enforcement does not call this engine
and therefore remains available while the account or network is offline. Before
materialization it also validates the pull batch ordering and rejects unknown
aggregate operations or private Screen Time token fields; a rejected batch does
not advance the durable cursor.

Build this experiment first with the signed Codemagic workflow. The unsigned IPA workflow is only a packaging/UI aid for Sideloadly and is not evidence that the Family Controls entitlement survived re-signing.
