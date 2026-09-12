#Requires -Modules Pester

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:UpdaterPath = Join-Path $script:RepoRoot 'Update-BravePortable.ps1'
    $script:UpdaterSource = Get-Content -LiteralPath $script:UpdaterPath -Raw
    $tokens = $null
    $parseErrors = $null
    $script:UpdaterAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:UpdaterPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count) {
        throw ($parseErrors | ForEach-Object Message | Out-String)
    }

    foreach ($functionName in @('Get-ReleaseAssetSha256', 'Assert-BravePublisherSignature', 'Select-BraveReleaseAsset')) {
        $definition = $script:UpdaterAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
            }, $true)
        if (-not $definition) {
            throw "Required function not found: $functionName"
        }
        $functionScript = [scriptblock]::Create($definition.Extent.Text)
        . $functionScript
    }
}

Describe 'Release asset digest verification' {
    It 'uses the GitHub asset SHA256 digest when present' {
        $asset = [pscustomobject]@{
            name = 'brave-v1.95.101-win32-x64.zip'
            digest = 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        }
        Get-ReleaseAssetSha256 -Asset $asset -ReleaseBody 'ignored' |
            Should -Be 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    }

    It 'falls back to a checksum beside the exact asset name' {
        $asset = [pscustomobject]@{ name = 'brave-v1.95.101-win32-x64.zip'; digest = $null }
        $body = 'brave-v1.95.101-win32-x64.zip bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        Get-ReleaseAssetSha256 -Asset $asset -ReleaseBody $body |
            Should -Be 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
    }

    It 'returns null when GitHub publishes no usable checksum' {
        $asset = [pscustomobject]@{ name = 'brave-v1.95.101-win32-x64.zip'; digest = $null }
        Get-ReleaseAssetSha256 -Asset $asset -ReleaseBody 'No checksums in these notes.' |
            Should -BeNullOrEmpty
    }

    It 'rejects a malformed GitHub digest instead of silently falling back' {
        $asset = [pscustomobject]@{ name = 'brave-v1.95.101-win32-x64.zip'; digest = 'sha256:not-a-hash' }
        { Get-ReleaseAssetSha256 -Asset $asset -ReleaseBody '' } |
            Should -Throw '*unsupported or malformed asset digest*'
    }
}

Describe 'Brave publisher verification' {
    BeforeEach {
        $script:Signature = [pscustomobject]@{
            Status = 'Valid'
            StatusMessage = 'Signature verified.'
            SignerCertificate = [pscustomobject]@{
                Subject = 'CN="Brave Software, Inc.", O="Brave Software, Inc.", L=San Francisco, S=California, C=US'
                Thumbprint = 'F8AC5F11DE7E26383B7A389FC19A2613835799D7'
            }
        }
        Mock Get-AuthenticodeSignature { $script:Signature }
    }

    It 'accepts the current valid Brave certificate' {
        $result = Assert-BravePublisherSignature -Path 'fixture.exe'
        $result.KnownCertificate | Should -BeTrue
        $result.Subject | Should -Match 'Brave Software'
    }

    It 'allows a valid Brave certificate rotation and identifies it for logging' {
        $script:Signature.SignerCertificate.Thumbprint = '1111111111111111111111111111111111111111'
        $result = Assert-BravePublisherSignature -Path 'fixture.exe'
        $result.KnownCertificate | Should -BeFalse
    }

    It 'rejects a valid signature from a different publisher' {
        $script:Signature.SignerCertificate.Subject = 'CN="Example Corp", O="Example Corp", C=US'
        { Assert-BravePublisherSignature -Path 'fixture.exe' } |
            Should -Throw '*unexpected publisher*'
    }

    It 'rejects an invalid Authenticode status' {
        $script:Signature.Status = 'HashMismatch'
        { Assert-BravePublisherSignature -Path 'fixture.exe' } |
            Should -Throw '*Authenticode status is HashMismatch*'
    }

    It 'rejects a signature check that throws' {
        Mock Get-AuthenticodeSignature { throw 'WinVerifyTrust unavailable' }
        { Assert-BravePublisherSignature -Path 'fixture.exe' } |
            Should -Throw '*WinVerifyTrust unavailable*'
    }
}

Describe 'Updater safety contracts' {
    It 'does not retain the unsafe ETag-only early-exit path' {
        $script:UpdaterSource | Should -Not -Match '\.etag'
        $script:UpdaterSource | Should -Not -Match 'statusCode -eq 304'
    }

    It 'does not depend on the retired versions.brave.com shortcut' {
        $script:UpdaterSource | Should -Not -Match 'versions\.brave\.com'
    }

    It 'keeps WhatIf output focused on the requested operation' {
        $script:UpdaterSource | Should -Not -Match 'Add-Content'
        $script:UpdaterSource | Should -Match '\[IO\.File\]::AppendAllText'
    }

    It 'requires explicit opt-in for the machine-wide Brave policy' {
        $script:UpdaterSource | Should -Match '\[switch\]\$SuppressUpdateNag'
        $script:UpdaterSource | Should -Match 'if \(\$SuppressUpdateNag\)'
    }

    It 'fails closed when signature verification cannot complete' {
        $catchStart = $script:UpdaterSource.IndexOf('Authenticode verification failed:')
        $exitAfter = $script:UpdaterSource.IndexOf('exit 1', $catchStart)
        $catchStart | Should -BeGreaterThan -1
        $exitAfter | Should -BeGreaterThan $catchStart
    }

    It 'fails closed when a requested profile backup fails' {
        $catchStart = $script:UpdaterSource.IndexOf('Profile backup failed:')
        $exitAfter = $script:UpdaterSource.IndexOf('exit 1', $catchStart)
        $catchStart | Should -BeGreaterThan -1
        $exitAfter | Should -BeGreaterThan $catchStart
    }

    It 'keeps the previous rollback bundle until the new binary passes validation' {
        $signatureCheck = $script:UpdaterSource.LastIndexOf('Assert-BravePublisherSignature -Path $newBraveExe')
        $removeOld = $script:UpdaterSource.IndexOf('Remove-Item $appOld -Recurse -Force -ErrorAction Stop')
        $signatureCheck | Should -BeGreaterThan -1
        $removeOld | Should -BeGreaterThan $signatureCheck
    }

    It 'honors WhatIf for rollback' {
        $script:UpdaterSource | Should -Match 'ShouldProcess\(\$PortableRoot, ''Restore app\.old as the active Brave bundle''\)'
    }

    It 'verifies the rollback bundle before offering to restore it' {
        $rollbackStart = $script:UpdaterSource.IndexOf('if ($Rollback)')
        $signatureCheck = $script:UpdaterSource.IndexOf('Assert-BravePublisherSignature -Path $rollbackBraveExe', $rollbackStart)
        $whatIfGate = $script:UpdaterSource.IndexOf("ShouldProcess(`$PortableRoot, 'Restore app.old as the active Brave bundle')", $rollbackStart)
        $signatureCheck | Should -BeGreaterThan $rollbackStart
        $whatIfGate | Should -BeGreaterThan $signatureCheck
    }
}

Describe 'Release selection' {
    BeforeAll {
        $script:SelectionReleases = @(
            [pscustomobject]@{
                name = 'Release v1.95.101'
                prerelease = $false
                tag_name = 'v1.95.101'
                assets = @([pscustomobject]@{ name = 'brave-v1.95.101-win32-x64.zip' })
            }
            [pscustomobject]@{
                name = 'Beta v1.96.44'
                prerelease = $true
                tag_name = 'v1.96.44'
                assets = @([pscustomobject]@{ name = 'brave-v1.96.44-win32-x64.zip' })
            }
            [pscustomobject]@{
                name = 'Nightly v1.97.27'
                prerelease = $true
                tag_name = 'v1.97.27'
                assets = @([pscustomobject]@{ name = 'brave-v1.97.27-win32-x64.zip' })
            }
        )
    }

    It 'selects the stable channel when requested' {
        $result = Select-BraveReleaseAsset -Releases $script:SelectionReleases -RequestedChannel stable -Architecture x64
        $result.Channel | Should -Be 'stable'
        $result.Version | Should -Be ([Version]'1.95.101')
    }

    It 'selects the highest available version in auto mode' {
        $result = Select-BraveReleaseAsset -Releases $script:SelectionReleases -RequestedChannel auto -Architecture x64
        $result.Channel | Should -Be 'nightly'
        $result.Version | Should -Be ([Version]'1.97.27')
    }

    It 'returns null when the requested architecture is unavailable' {
        Select-BraveReleaseAsset -Releases $script:SelectionReleases -RequestedChannel stable -Architecture arm64 |
            Should -BeNullOrEmpty
    }
}

Describe 'Version parsing' {
    It 'strips Chromium-major from 4-segment version' {
        $raw = '148.1.90.122'
        $parts = $raw.Split('.')
        $parts.Length | Should -Be 4
        $version = [Version]($parts[1..3] -join '.')
        $version | Should -Be ([Version]'1.90.122')
    }

    It 'passes through 3-segment version unchanged' {
        $raw = '1.90.122'
        $parts = $raw.Split('.')
        $parts.Length | Should -Be 3
        $version = [Version]$raw
        $version | Should -Be ([Version]'1.90.122')
    }

    It 'handles 2-segment version' {
        $raw = '1.90'
        $version = [Version]$raw
        $version.Major | Should -Be 1
        $version.Minor | Should -Be 90
    }

    It 'strips leading v from tag names' {
        $tag = 'v1.91.175'
        $version = [Version]($tag.TrimStart('v'))
        $version | Should -Be ([Version]'1.91.175')
    }

    It 'compares versions correctly (newer > older)' {
        [Version]'1.91.175' -gt [Version]'1.90.122' | Should -Be $true
    }

    It 'compares versions correctly (same)' {
        [Version]'1.90.122' -ge [Version]'1.90.122' | Should -Be $true
    }

    It 'compares versions correctly (older < newer)' {
        [Version]'1.89.0' -ge [Version]'1.90.122' | Should -Be $false
    }
}

Describe 'Channel keyword mapping' {
    BeforeAll {
        $script:channelMap = @{
            'stable'  = 'Release'
            'beta'    = 'Beta'
            'nightly' = 'Nightly'
        }
    }

    It 'maps stable to Release' {
        $script:channelMap['stable'] | Should -Be 'Release'
    }

    It 'maps beta to Beta' {
        $script:channelMap['beta'] | Should -Be 'Beta'
    }

    It 'maps nightly to Nightly' {
        $script:channelMap['nightly'] | Should -Be 'Nightly'
    }
}

Describe 'Asset pattern matching' {
    It 'matches x64 stable asset name' {
        $arch = 'x64'
        $pattern = "^brave-v.*-win32-$arch\.zip$"
        'brave-v1.90.122-win32-x64.zip' | Should -Match $pattern
    }

    It 'matches ARM64 asset name' {
        $arch = 'arm64'
        $pattern = "^brave-v.*-win32-$arch\.zip$"
        'brave-v1.90.122-win32-arm64.zip' | Should -Match $pattern
    }

    It 'rejects wrong architecture' {
        $arch = 'x64'
        $pattern = "^brave-v.*-win32-$arch\.zip$"
        'brave-v1.90.122-win32-arm64.zip' | Should -Not -Match $pattern
    }

    It 'rejects non-zip assets' {
        $arch = 'x64'
        $pattern = "^brave-v.*-win32-$arch\.zip$"
        'brave-v1.90.122-win32-x64.exe' | Should -Not -Match $pattern
    }

    It 'rejects linux assets' {
        $arch = 'x64'
        $pattern = "^brave-v.*-win32-$arch\.zip$"
        'brave-v1.90.122-linux-x64.zip' | Should -Not -Match $pattern
    }

    It 'matches nightly-style tag versions' {
        $arch = 'x64'
        $pattern = "^brave-v.*-win32-$arch\.zip$"
        'brave-v1.93.85-win32-x64.zip' | Should -Match $pattern
    }
}

Describe 'Channel filtering logic' {
    BeforeAll {
        $script:mockReleases = @(
            @{ name = 'Nightly v1.93.85'; prerelease = $true; tag_name = 'v1.93.85'; assets = @(
                @{ name = 'brave-v1.93.85-win32-x64.zip'; browser_download_url = 'https://example.com/n.zip'; size = 230000000 }
            )}
            @{ name = 'Beta v1.92.125'; prerelease = $true; tag_name = 'v1.92.125'; assets = @(
                @{ name = 'brave-v1.92.125-win32-x64.zip'; browser_download_url = 'https://example.com/b.zip'; size = 225000000 }
            )}
            @{ name = 'Release v1.91.175'; prerelease = $false; tag_name = 'v1.91.175'; assets = @(
                @{ name = 'brave-v1.91.175-win32-x64.zip'; browser_download_url = 'https://example.com/s.zip'; size = 220000000 }
            )}
        )
    }

    It 'finds latest stable release (filters by Release keyword, excludes prerelease)' {
        $channelKeyword = 'Release'
        $arch = 'x64'
        $assetPattern = "^brave-v.*-win32-$arch\.zip$"
        $found = $null
        foreach ($r in $script:mockReleases) {
            if ($r.name -notmatch $channelKeyword) { continue }
            if ($r.prerelease) { continue }
            $a = $r.assets | Where-Object { $_.name -match $assetPattern } | Select-Object -First 1
            if ($a) { $found = $r; break }
        }
        $found | Should -Not -BeNullOrEmpty
        $found.tag_name | Should -Be 'v1.91.175'
    }

    It 'finds latest beta release' {
        $channelKeyword = 'Beta'
        $arch = 'x64'
        $assetPattern = "^brave-v.*-win32-$arch\.zip$"
        $found = $null
        foreach ($r in $script:mockReleases) {
            if ($r.name -notmatch $channelKeyword) { continue }
            $a = $r.assets | Where-Object { $_.name -match $assetPattern } | Select-Object -First 1
            if ($a) { $found = $r; break }
        }
        $found | Should -Not -BeNullOrEmpty
        $found.tag_name | Should -Be 'v1.92.125'
    }

    It 'finds latest nightly release' {
        $channelKeyword = 'Nightly'
        $arch = 'x64'
        $assetPattern = "^brave-v.*-win32-$arch\.zip$"
        $found = $null
        foreach ($r in $script:mockReleases) {
            if ($r.name -notmatch $channelKeyword) { continue }
            $a = $r.assets | Where-Object { $_.name -match $assetPattern } | Select-Object -First 1
            if ($a) { $found = $r; break }
        }
        $found | Should -Not -BeNullOrEmpty
        $found.tag_name | Should -Be 'v1.93.85'
    }

    It 'returns nothing for channel with no matching assets' {
        $channelKeyword = 'Release'
        $arch = 'arm64'
        $assetPattern = "^brave-v.*-win32-$arch\.zip$"
        $found = $null
        foreach ($r in $script:mockReleases) {
            if ($r.name -notmatch $channelKeyword) { continue }
            if ($r.prerelease) { continue }
            $a = $r.assets | Where-Object { $_.name -match $assetPattern } | Select-Object -First 1
            if ($a) { $found = $r; break }
        }
        $found | Should -BeNullOrEmpty
    }
}

Describe 'SHA256 extraction from release notes' {
    It 'finds hash adjacent to asset name' {
        $body = @"
## SHA256 Checksums
brave-v1.91.175-win32-x64.zip  a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2
brave-v1.91.175-linux-x64.zip  ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
"@
        $assetName = 'brave-v1.91.175-win32-x64.zip'
        $hashLine = $body -split "`n" |
            Where-Object { $_ -match [regex]::Escape($assetName) -and $_ -match '[A-Fa-f0-9]{64}' } |
            Select-Object -First 1
        $hashLine | Should -Not -BeNullOrEmpty
        $hashLine -match '([A-Fa-f0-9]{64})' | Should -Be $true
        $matches[1] | Should -Be 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2'
    }

    It 'returns null when no hash is published' {
        $body = "Release notes without checksums."
        $assetName = 'brave-v1.91.175-win32-x64.zip'
        $hashLine = $body -split "`n" |
            Where-Object { $_ -match [regex]::Escape($assetName) -and $_ -match '[A-Fa-f0-9]{64}' } |
            Select-Object -First 1
        $hashLine | Should -BeNullOrEmpty
    }

    It 'does not match partial hex strings (< 64 chars)' {
        $body = "brave-v1.91.175-win32-x64.zip  abcdef1234"
        $assetName = 'brave-v1.91.175-win32-x64.zip'
        $hashLine = $body -split "`n" |
            Where-Object { $_ -match [regex]::Escape($assetName) -and $_ -match '[A-Fa-f0-9]{64}' } |
            Select-Object -First 1
        $hashLine | Should -BeNullOrEmpty
    }
}

Describe 'Architecture detection' {
    It 'detects x64 on AMD64 processor' {
        $testArch = 'AMD64'
        $result = if ($testArch -eq 'ARM64') { 'arm64' } else { 'x64' }
        $result | Should -Be 'x64'
    }

    It 'detects arm64 on ARM64 processor' {
        $testArch = 'ARM64'
        $result = if ($testArch -eq 'ARM64') { 'arm64' } else { 'x64' }
        $result | Should -Be 'arm64'
    }
}

Describe 'Release presentation and packaging' {
    BeforeAll {
        $script:ReadmePath = Join-Path $script:RepoRoot 'README.md'
        $script:ReadmeSource = Get-Content -LiteralPath $script:ReadmePath -Raw
        $script:BuildScriptPath = Join-Path $script:RepoRoot 'tools\Build-Release.ps1'
    }

    It 'puts the generated marketing hero at the top of README' {
        $firstLine = Get-Content -LiteralPath $script:ReadmePath | Select-Object -First 1
        $firstLine | Should -Match 'assets/marketing/hero-1280x640\.png'
        Test-Path -LiteralPath (Join-Path $script:RepoRoot 'assets\marketing\hero-1280x640.png') |
            Should -BeTrue
    }

    It 'references every real product capture from README' {
        foreach ($name in @('01-whatif-preview.png', '02-verified-update.png', '03-verified-rollback.png')) {
            $script:ReadmeSource | Should -Match ([regex]::Escape("assets/screenshots/$name"))
            Test-Path -LiteralPath (Join-Path $script:RepoRoot "assets\screenshots\$name") |
                Should -BeTrue
        }
    }

    It 'ships the selected mark as an RGBA PNG' {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $script:RepoRoot 'assets\brand\logo.png'))
        [Text.Encoding]::ASCII.GetString($bytes, 1, 3) | Should -Be 'PNG'
        $bytes[25] | Should -Be 6
    }

    It 'keeps the release version aligned across public entry points' {
        $version = '1.2.0'
        $script:UpdaterSource | Should -Match ([regex]::Escape("`$ScriptVersion = `"$version`""))
        $script:ReadmeSource | Should -Match "version-$([regex]::Escape($version))-"
        (Get-Content -LiteralPath $script:BuildScriptPath -Raw) |
            Should -Match ([regex]::Escape("[string]`$Version = '$version'"))
        (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'run_at_boot.ps1') -Raw) |
            Should -Match ([regex]::Escape("v$version"))
    }

    It 'guards the release cleanup path before recursive deletion' {
        $buildSource = Get-Content -LiteralPath $script:BuildScriptPath -Raw
        $buildSource | Should -Match 'Refusing to clean unexpected release directory'
        $buildSource | Should -Match 'Remove-Item -LiteralPath \$distRoot -Recurse -Force'
    }
}
