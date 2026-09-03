[CmdletBinding()]
param(
    [string]$Workspace = (Join-Path $PSScriptRoot "..")
)

$ErrorActionPreference = "Stop"
$workspacePath = (Resolve-Path -LiteralPath $Workspace).Path

function Assert-Condition {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "Preflight failed: $Message"
    }
}

Write-Host "FocusGuard Apple Codemagic preflight: $workspacePath"

$requiredFiles = @(
    "Package.swift",
    "project.yml",
    "codemagic.yaml",
    "ScreenTimeLab/FocusGuardMobile.entitlements",
    "ScreenTimeLab/FocusGuardDeviceActivityMonitor.entitlements",
    "ScreenTimeLab/FocusGuardShieldConfiguration.entitlements",
    "ScreenTimeLab/FocusGuardShieldAction.entitlements",
    "ScreenTimeLab/Info-App.plist",
    "ScreenTimeLab/Info-DeviceActivityMonitor.plist",
    "ScreenTimeLab/Info-ShieldConfiguration.plist",
    "ScreenTimeLab/Info-ShieldAction.plist"
)

foreach ($relativePath in $requiredFiles) {
    $absolutePath = Join-Path $workspacePath $relativePath
    Assert-Condition (Test-Path -LiteralPath $absolutePath -PathType Leaf) "missing required file '$relativePath'"
}

$projectSpec = Get-Content -LiteralPath (Join-Path $workspacePath "project.yml") -Raw
$codemagic = Get-Content -LiteralPath (Join-Path $workspacePath "codemagic.yaml") -Raw
$gitignore = Get-Content -LiteralPath (Join-Path $workspacePath ".gitignore") -Raw

foreach ($requiredText in @(
    "com.focusguard.apple",
    "com.focusguard.apple.deviceactivity-monitor",
    "com.focusguard.apple.shield-configuration",
    "com.focusguard.apple.shield-action",
    "FocusGuardMobile",
    "FocusGuardDeviceActivityMonitor",
    "FocusGuardShieldConfiguration",
    "FocusGuardShieldAction"
)) {
    Assert-Condition ($projectSpec.Contains($requiredText)) "project.yml does not contain '$requiredText'"
}

foreach ($requiredText in @(
    "ios-screentime-lab",
    "sideload-lab",
    "ios_signing:",
    "xcode-project use-profiles",
    "CODE_SIGNING_ALLOWED=NO"
)) {
    Assert-Condition ($codemagic.Contains($requiredText)) "codemagic.yaml does not contain '$requiredText'"
}

foreach ($requiredPattern in @(
    "*.ipa",
    "*.p12",
    "*.mobileprovision",
    ".env",
    "Secrets*.xcconfig"
)) {
    Assert-Condition ($gitignore.Contains($requiredPattern)) ".gitignore does not protect '$requiredPattern'"
}

$xmlFiles = Get-ChildItem -LiteralPath (Join-Path $workspacePath "ScreenTimeLab") -File |
    Where-Object { $_.Extension -in @(".plist", ".entitlements") }
foreach ($xmlFile in $xmlFiles) {
    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($xmlFile.FullName)
    Assert-Condition ($null -ne $xml.DocumentElement) "$($xmlFile.Name) has no XML document element"
}

$entitlementFiles = Get-ChildItem -LiteralPath (Join-Path $workspacePath "ScreenTimeLab") -Filter "*.entitlements" -File
foreach ($entitlementFile in $entitlementFiles) {
    $content = Get-Content -LiteralPath $entitlementFile.FullName -Raw
    Assert-Condition ($content.Contains("com.apple.developer.family-controls")) "$($entitlementFile.Name) is missing Family Controls"
    Assert-Condition ($content.Contains("group.com.focusguard.apple")) "$($entitlementFile.Name) is missing the FocusGuard App Group"
}

$secretPattern = '(?i)(BEGIN\s+(RSA|EC|OPENSSH)\s+PRIVATE\s+KEY|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|Bearer\s+[A-Za-z0-9._-]{20,})'
$sourceFiles = Get-ChildItem -LiteralPath $workspacePath -Recurse -File |
    Where-Object {
        $_.FullName -notmatch '\\(\.build|DerivedData|build|\.git)\\' -and
        $_.Extension -in @(".swift", ".yml", ".yaml", ".plist", ".entitlements", ".json", ".md", ".xcconfig")
    }
$secretMatches = foreach ($sourceFile in $sourceFiles) {
    Select-String -LiteralPath $sourceFile.FullName -Pattern $secretPattern
}
Assert-Condition ($null -eq $secretMatches) "a secret-like pattern was found; inspect files before pushing"

Write-Host "Static preflight passed: files, project targets, Codemagic workflows, XML, entitlements and secret scan."
Write-Host "Manual gate remains: run on macOS/Codemagic with approved Family Controls profiles and test on a real iPhone/iPad."
