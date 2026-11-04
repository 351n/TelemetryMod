param(
  [Parameter(Mandatory)] [string]$LegacySave,
  [string]$ExpectedSource = '',
  [string]$FactorioExe = 'D:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\factorio.exe'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ('telemetry-upgrade-' + [guid]::NewGuid().ToString('N'))
$passed = $false
try {
  if (-not (Test-Path -LiteralPath $FactorioExe -PathType Leaf)) { throw 'Factorio executable not found.' }
  if (-not (Test-Path -LiteralPath $LegacySave -PathType Leaf)) { throw 'Legacy save not found.' }
  if ($ExpectedSource -and $ExpectedSource -notmatch '^[A-Za-z0-9_.-]+$') { throw 'ExpectedSource must contain only letters, digits, underscore, hyphen or dot.' }
  New-Item -ItemType Directory -Path $testRoot | Out-Null
  $newMods = Join-Path $testRoot 'mods'
  New-Item -ItemType Directory -Path $newMods | Out-Null
  Copy-Item -LiteralPath (Join-Path $repoRoot 'mod\telemetry-mod') -Destination (Join-Path $newMods 'telemetry-mod') -Recurse
  if ($ExpectedSource) {
    # Instrument only the isolated test copy. Check saved state before migration runs.
    $lifecycle = Join-Path $newMods 'telemetry-mod\runtime\lifecycle.lua'
    $source = Get-Content -Raw -LiteralPath $lifecycle
    $marker = '  local function on_configuration_changed(data)'
    if (-not $source.Contains($marker)) { throw 'Cannot instrument lifecycle for saved-state verification.' }
    $guard = @"
    local found = false
    for _, entry in ipairs((storage and storage.telemetry_buffer and storage.telemetry_buffer.entries) or {}) do
      if entry.line and string.find(entry.line, '"source":"$ExpectedSource"', 1, true) then found = true end
    end
    if not found then error('Legacy telemetry event was not retained') end
    local outputs = telemetry_upgrade_outputs.new({
      write_file_safe = function() return true end,
      send_udp_safe = function() return true end,
      get_config = function() return {rcon_enabled = true, rcon_window_events = 100, max_age_seconds = 86400, max_bytes = 51200} end,
      get_tick = function() return game.tick end
    })
    if not string.find(outputs.rcon_response(100), '"source":"$ExpectedSource"', 1, true) then
      error('Migrated telemetry is not accessible through the RCON adapter')
    end
    log('TELEMETRY_LEGACY_STATE_PASS')
"@
    $source = "local telemetry_upgrade_outputs = require('runtime.telemetry_outputs')`n" + $source.Replace($marker, $marker + "`n" + $guard)
    Set-Content -LiteralPath $lifecycle -Value $source -Encoding utf8NoBOM
  }
  '{"mods":[{"name":"base","enabled":true},{"name":"telemetry-mod","enabled":true}]}' | Set-Content -LiteralPath (Join-Path $newMods 'mod-list.json') -Encoding utf8NoBOM
  $gameRoot = Split-Path (Split-Path (Split-Path $FactorioExe -Parent) -Parent) -Parent
  $config = Join-Path $testRoot 'config.ini'
  $dataPath = (Join-Path $gameRoot 'data').Replace('\', '/')
  $writePath = $testRoot.Replace('\', '/')
  @('; version=13', '[path]', "read-data=$dataPath", "write-data=$writePath") | Set-Content -LiteralPath $config -Encoding utf8NoBOM
  # Benchmark a copy to ensure the supplied save is never modified.
  $save = Join-Path $testRoot 'legacy-save.zip'
  Copy-Item -LiteralPath $LegacySave -Destination $save
  $upgrade = Start-Process -FilePath $FactorioExe -ArgumentList @('--config', "`"$config`"", '--mod-directory', "`"$newMods`"", '--benchmark', "`"$save`"", '--benchmark-ticks', '1') -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $testRoot 'upgrade.log') -RedirectStandardError (Join-Path $testRoot 'upgrade-error.log')
  if ($upgrade.ExitCode -ne 0) { throw 'The legacy save failed to load with the current mod.' }
  $log = Get-Content -Raw -LiteralPath (Join-Path $testRoot 'factorio-current.log')
  if ($log -notmatch 'Factorio 2\.1\.24' -or $log -notmatch 'telemetry-mod 0\.3\.0' -or $log -notmatch 'Checksum for script __telemetry-mod__/control.lua') { throw 'Unexpected runtime or upgraded mod did not load.' }
  if ($log -notmatch 'Map version 2\.0\.') { throw 'The supplied save was not created with Factorio 2.0.' }
  if ($ExpectedSource -and $log -notmatch 'TELEMETRY_LEGACY_STATE_PASS') { throw 'Legacy telemetry buffer was not verified.' }
  $passed = $true
  Write-Host 'Factorio 2.0 save loaded successfully with TelemetryMod 0.3.0 on Factorio 2.1.24.'
  if ($ExpectedSource) { Write-Host "Verified retained legacy telemetry source: $ExpectedSource" }
} finally {
  if ($passed -and (Test-Path -LiteralPath $testRoot)) {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
  } elseif (Test-Path -LiteralPath $testRoot) {
    Write-Warning "Upgrade test artifacts kept for diagnosis: $testRoot"
  }
}
