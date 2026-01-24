<#
  pack-mod.ps1
  Simple PowerShell helper to create a ZIP of a Factorio mod folder using name and version from info.json

  Usage (PowerShell):
    .\pack-mod.ps1 -ModDir ".\telemetry-mod_0.1.0" -OutDir ".\dist"

  The script will create <OutDir> if missing and write <name>_<version>.zip there.
#>

param(
  [string]$ModDir = ".\telemetry-mod_0.1.0",
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

# Compress-Archive expects a file/path pattern; include all files/folders inside the mod directory
try {
  # Include the mod folder itself so the zip contains a top-level folder like "telemetry-mod_0.1.0"
  Compress-Archive -Path $ModDir -DestinationPath $dest -Force
  Write-Host "Created package: $dest"
  exit 0
} catch {
  Write-ErrAndExit "Failed to create zip: $_"
}
