[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GameDirectory,
    [ValidateRange(0, 2147483647)][int]$Revision = 0
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$gameRoot = (Resolve-Path -LiteralPath $GameDirectory).Path
$managedRoot = Join-Path $gameRoot 'Elin_Data/Managed'
$manifestPath = [IO.Path]::GetFullPath((Join-Path $gameRoot '../../appmanifest_2135150.acf'))
$manifest = Get-Content -LiteralPath $manifestPath -Raw
if ($manifest -notmatch '"buildid"\s+"(\d+)"') { throw "Steam build ID missing: $manifestPath" }
$buildId = $Matches[1]
$versionPath = Join-Path $gameRoot 'version.json'
$versionInfo = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
$gameVersion = $null
if ($versionInfo.version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$' -or
    -not [Version]::TryParse($versionInfo.version, [ref]$gameVersion)) {
    throw "Invalid Elin version in $versionPath."
}
# NuGet omits a zero fourth component; preserve nonzero game hotfix versions.
$gameVersion = if ($gameVersion.Revision -gt 0) { $gameVersion.ToString(4) } else { $gameVersion.ToString(3) }

# Framework assemblies come from the consumer's SDK, not from the game snapshot.
$allFiles = @(Get-ChildItem -LiteralPath $managedRoot -File -Filter '*.dll' | Sort-Object Name)
$excluded = @($allFiles | Where-Object { $_.Name -match '^(System(?:\.|$)|mscorlib\.|netstandard\.|Mono\.Security\.)' })
$sources = @($allFiles | Where-Object { $_.Name -notmatch '^(System(?:\.|$)|mscorlib\.|netstandard\.|Mono\.Security\.)' })
if (-not ($sources | Where-Object Name -eq 'Elin.dll')) { throw 'Elin.dll missing.' }

function Get-Sha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}

$sourceHashes = @{}
foreach ($source in $sources) { $sourceHashes[$source.Name] = Get-Sha256 $source.FullName }
$provenancePath = Join-Path $repoRoot 'provenance.json'
$previous = if (Test-Path -LiteralPath $provenancePath) { Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json } else { $null }
if ($previous -and $previous.gameVersion -eq $gameVersion -and -not $PSBoundParameters.ContainsKey('Revision')) {
    $Revision = [int]$previous.revision
}
if ($previous -and $previous.gameVersion -eq $gameVersion -and $Revision -lt [int]$previous.revision) {
    throw "Cannot decrease the package revision for Elin $gameVersion. Current revision: $($previous.revision)."
}
$packageVersion = $gameVersion
if ($Revision -gt 0) { $packageVersion += "-repack.$Revision" }
if ($previous -and $previous.packageVersion -eq $packageVersion) {
    $unchanged = @($previous.assemblies).Count -eq $sources.Count
    foreach ($assembly in $previous.assemblies) {
        if ($sourceHashes[$assembly.name] -ne $assembly.sourceSha256) { $unchanged = $false }
    }
    if (-not $unchanged -or $previous.steamBuildId -ne $buildId) {
        throw "Inputs changed for package $packageVersion. Verify the game installation or use -Revision $($Revision + 1) for an intentional package revision."
    }
    & dotnet pack (Join-Path $repoRoot 'GameLibs.csproj') --configuration Release --output (Join-Path $repoRoot 'artifacts')
    if ($LASTEXITCODE -ne 0) { throw 'Could not pack the existing snapshot.' }
    Write-Output "GameLibs $packageVersion is already up to date; package ready in artifacts/."
    exit 0
}

$referenceDirectory = Join-Path $repoRoot 'references'
New-Item -ItemType Directory -Path $referenceDirectory -Force | Out-Null
foreach ($source in $sources) {
    Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $referenceDirectory $source.Name) -Force
}
# Remove only obsolete files in this repository's fixed references directory.
$resolvedReferences = (Resolve-Path -LiteralPath $referenceDirectory).Path
if ($resolvedReferences -ne [IO.Path]::GetFullPath((Join-Path $repoRoot 'references'))) { throw 'Unexpected references directory.' }
Get-ChildItem -LiteralPath $resolvedReferences -File -Filter '*.dll' |
    Where-Object { $_.Name -notin @($sources | ForEach-Object Name) } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName }

$assemblies = @($sources | ForEach-Object {
    [ordered]@{
        name = $_.Name
        assemblyVersion = [Reflection.AssemblyName]::GetAssemblyName($_.FullName).Version.ToString()
        sourceSha256 = $sourceHashes[$_.Name]
        referenceSha256 = Get-Sha256 (Join-Path $referenceDirectory $_.Name)
    }
})
$provenance = [ordered]@{
    schemaVersion = 2
    steamAppId = 2135150
    steamBuildId = $buildId
    gameVersion = $gameVersion
    revision = $Revision
    packageVersion = $packageVersion
    assemblyFormat = 'Original DLLs; bodies/resources/visibility preserved'
    excludedFrameworkAssemblies = @($excluded | ForEach-Object Name)
    assemblies = $assemblies
}
[IO.File]::WriteAllText($provenancePath, ($provenance | ConvertTo-Json -Depth 5).Replace("`r`n", "`n") + "`n")
$props = @"
<Project>
  <PropertyGroup>
    <SteamBuildId>$buildId</SteamBuildId>
    <GameVersion>$gameVersion</GameVersion>
    <PackageRevision>$Revision</PackageRevision>
    <PackageVersion>`$(GameVersion)</PackageVersion>
    <PackageVersion Condition="'`$(PackageRevision)' != '0'">`$(GameVersion)-repack.`$(PackageRevision)</PackageVersion>
  </PropertyGroup>
</Project>
"@
[IO.File]::WriteAllText((Join-Path $repoRoot 'GameLibs.props'), $props.Replace("`r`n", "`n") + "`n")
& dotnet pack (Join-Path $repoRoot 'GameLibs.csproj') --configuration Release --output (Join-Path $repoRoot 'artifacts')
if ($LASTEXITCODE -ne 0) { throw 'Could not pack GameLibs.' }
Write-Output "GameLibs $packageVersion ready. Commit references/, provenance.json, GameLibs.props and README.md, then push tag v$packageVersion."
