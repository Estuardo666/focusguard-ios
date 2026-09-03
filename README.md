# FocusGuard Apple

Native Apple workspace for iPhone, iPad and macOS. The shared Swift packages contain only platform-neutral domain and synchronization invariants; Screen Time and macOS enforcement belong to separate Xcode targets/extensions once the Mac build environment is available.

The architecture, Windows audit, Apple limitations, Codemagic/Sideloadly workflow and phased roadmap are documented in [`FOCUSGUARD_APPLE_PLAN.md`](FOCUSGUARD_APPLE_PLAN.md).

## Current contents

- `Package.swift` — Swift 6 package manifest for `FocusGuardDomain` and `FocusGuardSync`.
- `Sources/FocusGuardDomain` — profiles, common/platform-specific policies, rules, Strict Mode options, sessions, deterministic focus-cycle plans, local session evaluation/reconciliation (including conservative clock input), IANA-time-zone schedules with explicit DST policy, bounded schedule materialization and clock trust state.
- `Sources/FocusGuardSync` — actor-isolated offline outbox, typed REST client and `SyncCoordinator` with idempotency, server-clock samples, monotonic-cursor invariants and defense-in-depth validation of untrusted pull changes (including rejection of private Screen Time tokens).
- `ScreenTimeLab/App/ScreenTimeLocalModels.swift` — initial SwiftData records and App Group-backed local `ModelContainer` for profiles, sessions, schedules, outbox and sync metadata.
- `ScreenTimeLab/App/ScreenTimeSyncStore.swift` — SwiftData adapter that hydrates/acknowledges the outbox and commits the server cursor only after local materialization.
- `ScreenTimeLab/App/FocusGuardDeviceIdentity.swift` — stable installation identifier in Keychain, separate from account and opaque Screen Time tokens.
- `Tests` — Swift Testing coverage for the platform-neutral slice.
- `project.yml` — XcodeGen definition for the app and three Screen Time extension targets.
- `codemagic.yaml` — package test workflow plus gated signed and unsigned IPA laboratory workflows; the runner generates the Xcode project before building.
- `.github/workflows/ci.yml` — GitHub Actions CI for the platform-neutral Swift tests and static metadata/source checks. It deliberately does not pretend to replace Codemagic/Xcode signing.
- `scripts/codemagic-preflight.ps1` — static gate for required files, bundle IDs, workflows, XML/entitlements and obvious secret patterns before pushing to Codemagic.

## Codemagic → Sideloadly laboratory path

1. Run the Codemagic workflow; it installs XcodeGen and generates `FocusGuardApple.xcodeproj` from `project.yml`.
2. Run `ios-screentime-lab` for the real signed entitlement path. It requires the approved Family Controls capability, App Group, registered device and encrypted Codemagic signing assets.
3. Run `sideload-lab` only for a development IPA that is archived with code signing disabled. Download `build/FocusGuard-unsigned.ipa` and let Sideloadly re-sign it for a registered test device.
4. Inspect the re-signed bundle and every extension before drawing conclusions. Sideloadly re-signing can remove or invalidate Family Controls/App Group entitlements; an IPA installed this way is not evidence that Screen Time enforcement is App-Store-valid.

The signed workflow also exports the effective entitlements for the app and each extension and verifies the signed bundle with `codesign --deep --strict` before publishing artifacts.

For the signed run, configure Codemagic with `CM_DEVELOPMENT_TEAM`, development profiles for `com.focusguard.apple` and all three extension bundle IDs, the registered iPhone/iPad UDID, the approved Family Controls capability and the App Group. The unsigned run needs no signing assets, but Sideloadly must re-sign the IPA before installation and may invalidate those capabilities.

The package tests can run on any macOS runner with the selected Swift toolchain. Xcode project builds, entitlement checks and iPhone behavior cannot be validated from the current Windows workspace.

GitHub Actions provides a fast, signing-free regression gate. Codemagic remains
the authoritative CI for XcodeGen, Xcode archive/export, code signing,
entitlement inspection and the development IPA used by the physical Screen
Time experiment.

Before the first Codemagic run, push this workspace to the configured Apple repository. The audited GitHub repository was empty, so Codemagic cannot build from it until these files (especially `codemagic.yaml`, `project.yml` and `ScreenTimeLab/`) are present.

Run `./scripts/codemagic-preflight.ps1` from PowerShell before that push. It
does not sign or upload anything; it only fails closed on a missing target,
entitlement, protected-file pattern or obvious secret-like value.
