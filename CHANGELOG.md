# Changelog

Notable changes to Brave Portable Updater are recorded here. Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v1.2.0 (2026-09-12)

### Added

- Added a verified release package, SHA256 checksum file, and release manifest.
- Added real PowerShell 5.1 screenshots for WhatIf, fresh install, and rollback runs.
- Added a new shield-and-recovery identity, a README hero, icon sizes, and the full concept archive.
- Added coverage for release selection, GitHub asset digests, publisher validation, rollback checks, and side-effect boundaries.

### Changed

- Channel selection now uses the official GitHub release feed for stable, beta, Nightly, and automatic selection.
- Brave's machine-wide update-prompt policy is unchanged by default. It now requires `-SuppressUpdateNag`.
- Requested profile backups now stop the update if the copy cannot be completed.
- The previous rollback bundle is kept until the new archive has passed extraction and verification.

### Fixed

- Signature checks now fail closed when Authenticode cannot validate the executable or the signer is not Brave Software, Inc.
- Rollback now verifies the retained executable publisher and honors `-WhatIf`.
- GitHub's SHA256 asset digest is used when available. Malformed digest metadata is treated as a failure.
- Removed ETag behavior that could skip a retry after an incomplete update.
- Removed the unavailable `versions.brave.com` shortcut that could make release checks fail before reaching GitHub.
- Logging no longer adds unrelated WhatIf noise when it creates or rotates its own log files.
- Renamed the logging helper so it no longer shadows a PowerShell command name during static analysis.

## v1.1.1 (2026-06-27)

### Fixed

- Replaced silent toast, access-control, and metered-connection catches with visible warnings and log entries.
- Renamed the metered-connection profile variable to avoid PowerShell's automatic `$PROFILE` variable.
- Switched interactive status output from `Write-Host` to `Write-Information`.
- Made shared Pester fixtures script-scoped so local analysis runs cleanly.

## v1.0.1 (2026-05-19)

### Fixed

- Wrote `portapp.json` as UTF-8 without a byte-order mark. PowerShell 5.1's default UTF-8 encoding added a marker that the Portapps wrapper could not parse.

If an older run left a marked `portapp.json`, this repairs it:

```powershell
$p='C:\brave-portable-work\portapp.json'; [IO.File]::WriteAllText($p, [IO.File]::ReadAllText($p).TrimStart([char]0xFEFF), (New-Object System.Text.UTF8Encoding $false))
```

## v1.0.0 (2026-05-19)

Initial public release with path-scoped process handling, Portapps version detection, release downloads, bundle swaps, file logging, and scheduled startup support.
