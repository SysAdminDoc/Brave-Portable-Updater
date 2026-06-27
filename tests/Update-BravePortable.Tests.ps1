#Requires -Modules Pester

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

Describe 'Brave API channel mapping' {
    BeforeAll {
        $script:braveApiMap = @{ 'stable' = 'release'; 'beta' = 'beta'; 'nightly' = 'nightly' }
    }

    It 'maps stable to release endpoint' {
        $script:braveApiMap['stable'] | Should -Be 'release'
    }

    It 'maps beta to beta endpoint' {
        $script:braveApiMap['beta'] | Should -Be 'beta'
    }

    It 'maps nightly to nightly endpoint' {
        $script:braveApiMap['nightly'] | Should -Be 'nightly'
    }
}
