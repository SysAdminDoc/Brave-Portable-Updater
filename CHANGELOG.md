# Changelog

All notable changes to Brave-Portable-Updater are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v1.0.1 - 2026-05-19

### Fixed
- **Critical: `portapp.json` written with UTF-8 BOM**, breaking `brave-portable.exe`'s Go JSON parser (`cannot unmarshal portapps.json: invalid character ...`). PS 5.1's `Set-Content -Encoding UTF8` always emits a BOM. Rewrote the save to use `[System.Text.UTF8Encoding]::new($false)` via `[IO.File]::WriteAllText`, which produces BOM-less UTF-8 as Go requires.

If you already ran v1.0.0 and your wrapper won't launch, fix in one line:

```powershell
$p='C:\brave-portable-work\portapp.json'; [IO.File]::WriteAllText($p, [IO.File]::ReadAllText($p).TrimStart([char]0xFEFF), (New-Object System.Text.UTF8Encoding $false))
```

## v1.0.0 - 2026-05-19

Initial release. Ground-up rewrite of the popular `download_brave.ps1` updater pattern, fixing the two issues that bite Portapps users hardest.

### Added
- `Update-BravePortable.ps1` - the main updater.
  - Reads installed version from `app\brave.exe`'s `VersionInfo.ProductVersion`, strips the Chromium-major prefix, and compares against GitHub release tags as `[Version]` objects.
  - Queries `github.com/brave/brave-browser/releases` for `stable` / `beta` / `nightly` channels.
  - Downloads via BITS with `Invoke-WebRequest` fallback.
  - Best-effort SHA256 verification when the release notes publish a hash.
  - Path-scoped process termination: only stops `brave.exe` / `brave-portable.exe` whose `.Path` is under the portable root. The system-wide Brave install is never touched.
  - Atomic swap: extracts to `app.new\`, renames `app` to `app.old`, promotes `app.new` to `app`, then deletes `app.old`. Failed extracts leave the previous install intact.
  - Auto-flattens zips containing a single top-level folder.
  - Updates `version` and `date` fields in `portapp.json`.
  - Refuses to run if the target dir doesn't look like a Portapps install.
  - Per-run log at `<root>\log\update.log` in ISO timestamp format.
- `Update-BravePortable.bat` - foreground shim that forwards arguments and pauses on non-zero exit.
- `update.bat` - one-click default run (stable channel).
- `update_then_run_brave.bat` - update, then launch `brave-portable.exe`.
- `run_at_boot.ps1` - registers a Scheduled Task with `Highest` privilege, hidden window, `-Quiet`, and a 15-minute time limit.
