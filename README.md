# Brave-Portable-Updater

[![Version](https://img.shields.io/badge/version-1.1.0-blue?style=flat-square)](CHANGELOG.md)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D4?style=flat-square&logo=windows)](#compatibility)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=flat-square&logo=powershell&logoColor=white)](#usage)

A safe, path-scoped PowerShell updater for the [Portapps](https://github.com/portapps/brave-portable) `brave-portable` distribution. Updates the inner Brave bundle in place while leaving your system-wide Brave install and your portable user profile untouched.

## Why this exists

Most existing updater scripts have one of two problems:

1. They run `Get-Process brave | Stop-Process`, which kills the **installed full version of Brave** along with the portable one, dropping every tab in your main session.
2. They track versions by parsing version-stamped subfolder names under `app\`. Portapps doesn't use a version subfolder - it puts `brave.exe` and the Chromium bundle directly in `app\` - so those scripts re-download on every run.

This updater fixes both, plus a few extras:

- **Path-scoped process termination.** Only stops `brave.exe` / `brave-portable.exe` whose `.Path` lives under the portable root. The full install is provably untouched.
- **Version detection from the binary.** Reads `app\brave.exe`'s `VersionInfo.ProductVersion`, strips the Chromium-major prefix, and compares against [github.com/brave/brave-browser](https://github.com/brave/brave-browser) release tags.
- **Atomic swap.** Extracts to `app.new\`, renames `app` to `app.old`, promotes `app.new` to `app`, then deletes `app.old`. A failed extract leaves the previous install intact.
- **Authenticode signature verification** on the extracted `brave.exe`. Blocks the update if the binary is not signed by Brave Software, Inc.
- **Best-effort SHA256 verification** when the release notes publish a hash.
- **Updates `portapp.json`** so the wrapper UI shows the correct version.
- **Rollback support.** The previous version is retained in `app.old\`. Run with `-Rollback` to swap back instantly.
- **ARM64 auto-detection.** Downloads the correct asset for x64 or ARM64 Windows.
- **GitHub API rate-limit awareness.** Detects 403/429 responses and suggests using `-GitHubToken`.
- **Log rotation** at 1 MB (keeps one backup).
- **Logs to `<root>\log\update.log`** in ISO timestamp format.
- **Refuses to run** if the target dir doesn't look like a Portapps install (no `brave-portable.exe`, no `data\`).

## Files

| File | Purpose |
| --- | --- |
| `Update-BravePortable.ps1` | The updater. |
| `Update-BravePortable.bat` | Forwards args to the PS1, pauses on non-zero exit. |
| `update.bat` | One-click default run (stable channel, pauses at end). |
| `update_then_run_brave.bat` | Update, then launch `brave-portable.exe`. Set `PORTABLE_ROOT` env var to override the default path. |
| `run_at_boot.ps1` | Registers a Scheduled Task that runs the updater at every system startup. |

## Install

Copy the contents of this repo into your Brave-Portable updater dir of choice (it doesn't have to live next to `brave-portable.exe` - the script accepts `-PortableRoot`):

```powershell
git clone https://github.com/SysAdminDoc/Brave-Portable-Updater.git
```

Or download the ZIP and extract anywhere.

## Usage

```powershell
# Default: stable channel, targets C:\brave-portable-work
.\Update-BravePortable.ps1

# Other channels
.\Update-BravePortable.ps1 -Channel beta
.\Update-BravePortable.ps1 -Channel nightly

# Different install location
.\Update-BravePortable.ps1 -PortableRoot "D:\Apps\Brave"

# Reinstall current version (e.g. after corruption)
.\Update-BravePortable.ps1 -Force

# Quiet (file log only) - useful for scheduled tasks
.\Update-BravePortable.ps1 -Quiet

# Roll back to the previous version
.\Update-BravePortable.ps1 -Rollback

# Use a GitHub token to avoid API rate limits
.\Update-BravePortable.ps1 -GitHubToken "ghp_..."
```

Exit codes: `0` already-current or updated successfully, non-zero on failure.

## Autorun at boot

```powershell
# Elevates and registers a Scheduled Task named "BravePortableUpdate"
.\run_at_boot.ps1
```

Manage the task:

```cmd
schtasks /run    /tn BravePortableUpdate
schtasks /query  /tn BravePortableUpdate /v /fo LIST
schtasks /delete /tn BravePortableUpdate /f
```

## How it actually works

1. Sanity-check the target dir: must contain `brave-portable.exe` and `data\`.
2. Read installed version from `app\brave.exe`'s `ProductVersion`. Brave's `ProductVersion` is the Chromium major prefixed onto the Brave version (e.g. `148.1.90.122` = Chromium 148 + Brave 1.90.122). Drop the first segment to get the comparable Brave version (`1.90.122`).
3. Query `api.github.com/repos/brave/brave-browser/releases?per_page=80`. Filter by channel keyword (`Release` / `Beta` / `Nightly`), pick the first release with a `brave-v*-win32-x64.zip` asset.
4. If installed >= remote, exit 0. Otherwise download via BITS (fallback `Invoke-WebRequest`) to `%TEMP%`.
5. If the release notes contain a SHA256 line matching the asset name, verify the hash.
6. Find every `brave.exe` / `brave-portable.exe` process whose `.Path` starts with the portable root. Stop only those. Sleep 2s for file handles to release.
7. Extract zip to `<root>\app.new\`. If the zip has a single top-level folder, flatten it.
8. Sanity-check `app.new\brave.exe` exists. If not, abort.
9. Verify the Authenticode signature on `app.new\brave.exe`. Block the swap if the binary is not validly signed.
10. Rename `app` to `app.old`, `app.new` to `app`. The previous version in `app.old` is retained for rollback.
11. Patch `version` and `date` in `portapp.json` so the wrapper UI is consistent.

## Compatibility

- Windows 10 / 11
- PowerShell 5.1 or later (ships with Windows)
- Targets the official Brave Windows x64 and ARM64 zips from <https://github.com/brave/brave-browser/releases>
- Designed for the [Portapps](https://github.com/portapps/brave-portable) wrapper layout (`<root>\app\`, `<root>\data\`, `<root>\brave-portable.exe`)

## License

[MIT](LICENSE)
