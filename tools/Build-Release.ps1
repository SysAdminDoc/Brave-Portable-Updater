[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version = '1.2.0'
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$distRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'dist'))
$expectedDistRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'dist'))
if ($distRoot -ne $expectedDistRoot -or
    -not $distRoot.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean unexpected release directory: $distRoot"
}

$packageName = "Brave-Portable-Updater-v$Version"
$stageRoot = Join-Path $distRoot $packageName
$zipPath = Join-Path $distRoot "$packageName.zip"
$checksumPath = Join-Path $distRoot 'SHA256SUMS.txt'
$manifestPath = Join-Path $distRoot 'release-manifest.json'

if (Test-Path -LiteralPath $distRoot) {
    Remove-Item -LiteralPath $distRoot -Recurse -Force
}
[void][IO.Directory]::CreateDirectory($stageRoot)

$files = @(
    'Update-BravePortable.ps1',
    'Update-BravePortable.bat',
    'update.bat',
    'update_then_run_brave.bat',
    'run_at_boot.ps1',
    'README.md',
    'CHANGELOG.md',
    'ROADMAP.md',
    'LICENSE',
    'icon.png',
    'icon.ico'
)
foreach ($file in $files) {
    Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination (Join-Path $stageRoot $file)
}

$assetRoot = Join-Path $stageRoot 'assets'
[void][IO.Directory]::CreateDirectory($assetRoot)
foreach ($assetDirectory in @('brand', 'marketing', 'screenshots')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "assets\$assetDirectory") -Destination $assetRoot -Recurse
}
foreach ($supportDirectory in @('tests', 'tools')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot $supportDirectory) -Destination $stageRoot -Recurse
}

Compress-Archive -Path (Join-Path $stageRoot '*') -DestinationPath $zipPath -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(
    $checksumPath,
    "$hash  $($zipPath | Split-Path -Leaf)$([Environment]::NewLine)",
    [Text.Encoding]::ASCII
)

$manifest = [ordered]@{
    name = $packageName
    version = $Version
    file = $zipPath | Split-Path -Leaf
    sha256 = $hash
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
}
$json = $manifest | ConvertTo-Json
[IO.File]::WriteAllText(
    $manifestPath,
    $json + [Environment]::NewLine,
    (New-Object Text.UTF8Encoding $false)
)

Remove-Item -LiteralPath $stageRoot -Recurse -Force
Write-Information "Built $zipPath" -InformationAction Continue
Write-Information "SHA256 $hash" -InformationAction Continue
