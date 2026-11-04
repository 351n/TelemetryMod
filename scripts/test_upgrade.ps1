param(
  [string]$FactorioExe = 'D:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\factorio.exe'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ('telemetry-upgrade-' + [guid]::NewGuid().ToString('N'))
$passed = $false
try {
  if (-not (Test-Path -LiteralPath $FactorioExe -PathType Leaf)) { throw 'Factorio executable not found.' }
  New-Item -ItemType Directory -Path $testRoot | Out-Null
  $archive = Join-Path $testRoot 'legacy.zip'
  & git -C $repoRoot archive --format=zip "--output=$archive" 1f7eda2 mod/telemetry-mod
  if ($LASTEXITCODE -ne 0) { throw 'The 0.1.11 reference commit 1f7eda2 is unavailable; fetch the full repository history.' }
  $legacy = Join-Path $testRoot 'legacy'
  Expand-Archive -LiteralPath $archive -DestinationPath $legacy
  $oldInfo = Get-Content -Raw -LiteralPath (Join-Path $legacy 'mod\telemetry-mod\info.json') | ConvertFrom-Json
  if ($oldInfo.version -ne '0.1.11') { throw 'Reference commit is not the expected 0.1.11 mod.' }
  $oldMods = Join-Path $testRoot 'old-mods'
  $newMods = Join-Path $testRoot 'new-mods'
  New-Item -ItemType Directory -Path $oldMods,$newMods | Out-Null
  Copy-Item -LiteralPath (Join-Path $legacy 'mod\telemetry-mod') -Destination (Join-Path $oldMods 'telemetry-mod') -Recurse
  Copy-Item -LiteralPath (Join-Path $repoRoot 'mod\telemetry-mod') -Destination (Join-Path $newMods 'telemetry-mod') -Recurse
  $modList = '{"mods":[{"name":"base","enabled":true},{"name":"telemetry-mod","enabled":true}]}'
  foreach ($dir in @($oldMods,$newMods)) { $modList | Set-Content -LiteralPath (Join-Path $dir 'mod-list.json') -Encoding utf8NoBOM }
  $gameRoot = Split-Path (Split-Path (Split-Path $FactorioExe -Parent) -Parent) -Parent
  $config = Join-Path $testRoot 'config.ini'
  $dataPath = (Join-Path $gameRoot 'data').Replace('\', '/')
  $writePath = $testRoot.Replace('\', '/')
  @('; version=13', '[path]', "read-data=$dataPath", "write-data=$writePath") | Set-Content -LiteralPath $config -Encoding utf8NoBOM
  $save = Join-Path $testRoot 'legacy-save.zip'
  $create = Start-Process -FilePath $FactorioExe -ArgumentList @('--config', "`"$config`"", '--mod-directory', "`"$oldMods`"", '--create', "`"$save`"") -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $testRoot 'create.log') -RedirectStandardError (Join-Path $testRoot 'create-error.log')
  if ($create.ExitCode -ne 0) { throw 'Could not create a save with TelemetryMod 0.1.11.' }
  $log = Get-Content -Raw -LiteralPath (Join-Path $testRoot 'factorio-current.log')
  if ($log -notmatch 'Factorio 2\.0\.77' -or $log -notmatch 'telemetry-mod 0\.1\.11') { throw 'Unexpected legacy runtime or mod version.' }
  $upgrade = Start-Process -FilePath $FactorioExe -ArgumentList @('--config', "`"$config`"", '--mod-directory', "`"$newMods`"", '--benchmark', "`"$save`"", '--benchmark-ticks', '1') -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $testRoot 'upgrade.log') -RedirectStandardError (Join-Path $testRoot 'upgrade-error.log')
  if ($upgrade.ExitCode -ne 0) { throw 'The legacy save failed to load with the current mod.' }
  $log = Get-Content -Raw -LiteralPath (Join-Path $testRoot 'factorio-current.log')
  if ($log -notmatch 'telemetry-mod 0\.2\.0' -or $log -notmatch 'Checksum for script __telemetry-mod__/control.lua') { throw 'The upgraded mod did not load.' }
  $passed = $true
  Write-Host 'TelemetryMod 0.1.11 save loaded successfully with 0.2.0 on Factorio 2.0.77.'
} finally {
  if ($passed -and (Test-Path -LiteralPath $testRoot)) {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
  } elseif (Test-Path -LiteralPath $testRoot) {
    Write-Warning "Upgrade test artifacts kept for diagnosis: $testRoot"
  }
}
