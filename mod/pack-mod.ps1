<#
  pack-mod.ps1
  Release packer for a Factorio mod. It reads name and version from info.json,
  stages only distributable files, then creates a Mod Portal-ready ZIP.

  Usage (PowerShell):
    .\pack-mod.ps1 -ModDir ".\telemetry-mod" -OutDir ".\dist"

  The script will create <OutDir> if missing and write <name>_<version>.zip there.
#>

param(
  [string]$ModDir = ".\telemetry-mod",
  [string]$OutDir = ".\dist"
)

function Write-ErrAndExit($msg){ Write-Error $msg; exit 1 }

if (-not (Test-Path -Path $ModDir -PathType Container)) {
  Write-ErrAndExit "Mod directory not found: $ModDir"
}

$infoPath = Join-Path $ModDir 'info.json'
if (-not (Test-Path -Path $infoPath -PathType Leaf)) {
  Write-ErrAndExit "info.json not found in mod directory: $infoPath"
}

try {
  $info = Get-Content -Raw -Path $infoPath | ConvertFrom-Json
} catch {
  Write-ErrAndExit "Failed to read/parse info.json: $_"
}

$name = if ($info.name) { $info.name } else { Split-Path -Path $ModDir -Leaf }
$version = if ($info.version) { $info.version } else { '0.0.0' }

$zipName = "${name}_${version}.zip"

if (-not (Test-Path -Path $OutDir)) {
  New-Item -ItemType Directory -Path $OutDir | Out-Null
}

$dest = Join-Path $OutDir $zipName

if (Test-Path -Path $dest) { Remove-Item -Path $dest -Force }

$sourceRoot = (Resolve-Path -LiteralPath $ModDir).Path
$stageRoot = Join-Path ([IO.Path]::GetTempPath()) ("factorio-mod-package-" + [guid]::NewGuid().ToString('N'))
$packageRoot = "${name}_${version}"
$stageMod = Join-Path $stageRoot $packageRoot

function Test-ExcludedReleaseFile {
  param([string]$RelativePath)

  $normalized = $RelativePath.Replace('\', '/')
  return $normalized -match '(^|/)(?:\.git|\.svn|\.vscode|\.codex|node_modules|tests?|spec|coverage)(/|$)' -or
    $normalized -match '(^|/)(?:mod-list\.json|mod-settings\.dat|player-data\.json|server-settings\.json|factorio-(?:current|previous)\.log)$' -or
    $normalized -match '\.(?:zip|log|tmp|bak|sav|save)$'
}

try {
  New-Item -ItemType Directory -Path $stageMod -Force | Out-Null
  foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File) {
    $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
    if (Test-ExcludedReleaseFile $relative) { continue }

    $stagedFile = Join-Path $stageMod $relative
    $stagedParent = Split-Path -Parent $stagedFile
    if (-not (Test-Path -LiteralPath $stagedParent)) {
      New-Item -ItemType Directory -Path $stagedParent -Force | Out-Null
    }
    Copy-Item -LiteralPath $file.FullName -Destination $stagedFile -Force
  }

  if (-not (Test-Path -LiteralPath (Join-Path $stageMod 'info.json') -PathType Leaf)) {
    throw 'Staging omitted info.json.'
  }

  Compress-Archive -Path $stageMod -DestinationPath $dest -Force
  Write-Host "Created package: $dest"
} catch {
  Write-ErrAndExit "Failed to create zip: $_"
} finally {
  if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
  }
}
