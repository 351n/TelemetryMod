param(
  [string]$FactorioExe = 'D:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\factorio.exe'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("telemetry-mod-factorio-" + [guid]::NewGuid().ToString('N'))
$mods = Join-Path $testRoot 'mods'
$udpPort = 34199
$udpSourcePort = 34198
$rconPort = 34197
$rconPassword = 'telemetry-smoke-password'
$passed = $false
$receiver = $null
$discordReceiver = $null
$releaseInfo = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'mod\telemetry-mod\info.json') | ConvertFrom-Json

function Read-Exact {
  param([System.IO.Stream]$Stream, [int]$Count)
  $buffer = New-Object byte[] $Count
  $offset = 0
  while ($offset -lt $Count) {
    $read = $Stream.Read($buffer, $offset, $Count - $offset)
    if ($read -le 0) { throw 'Unexpected end of RCON stream.' }
    $offset += $read
  }
  return $buffer
}

function Send-RconPacket {
  param([System.IO.Stream]$Stream, [int]$Id, [int]$Type, [string]$Body)
  $bodyBytes = [Text.Encoding]::ASCII.GetBytes($Body)
  $packetSize = 10 + $bodyBytes.Length
  $packet = New-Object byte[] (4 + $packetSize)
  [BitConverter]::GetBytes($packetSize).CopyTo($packet, 0)
  [BitConverter]::GetBytes($Id).CopyTo($packet, 4)
  [BitConverter]::GetBytes($Type).CopyTo($packet, 8)
  $bodyBytes.CopyTo($packet, 12)
  $Stream.Write($packet, 0, $packet.Length)
  $Stream.Flush()
}

function Read-RconPacket {
  param([System.IO.Stream]$Stream)
  $size = [BitConverter]::ToInt32((Read-Exact $Stream 4), 0)
  $body = Read-Exact $Stream $size
  [pscustomobject]@{
    Id = [BitConverter]::ToInt32($body, 0)
    Type = [BitConverter]::ToInt32($body, 4)
    Body = [Text.Encoding]::ASCII.GetString($body, 8, $size - 10)
  }
}

function Invoke-RconCommand {
  param([string]$Command)
  $client = [Net.Sockets.TcpClient]::new()
  $client.Connect('127.0.0.1', $rconPort)
  try {
    $stream = $client.GetStream()
    Send-RconPacket $stream 1 3 $rconPassword
    $auth = Read-RconPacket $stream
    if ($auth.Id -ne 1 -or $auth.Type -ne 2) { throw 'RCON authentication failed.' }
    Send-RconPacket $stream 2 2 $Command
    return (Read-RconPacket $stream).Body
  } finally {
    $client.Dispose()
  }
}

try {
  if (-not (Test-Path -LiteralPath $FactorioExe -PathType Leaf)) { throw "Factorio executable not found: $FactorioExe" }
  foreach ($requiredMetadata in @('name', 'version', 'author', 'homepage', 'contact', 'factorio_version')) {
    if ([string]::IsNullOrWhiteSpace([string]$releaseInfo.$requiredMetadata)) { throw "Release metadata is missing $requiredMetadata." }
  }
  New-Item -ItemType Directory -Force $mods | Out-Null

  $modDestination = Join-Path $mods 'telemetry-mod'
  Copy-Item -LiteralPath (Join-Path $repoRoot 'mod\telemetry-mod') -Destination $modDestination -Recurse -Force
  $settingsPath = Join-Path $modDestination 'settings.lua'
  $settings = Get-Content -Raw -LiteralPath $settingsPath
  $settings = [regex]::Replace($settings, '(name = "telemetry-output-udp-enabled",\s+setting_type = "runtime-global",\s+default_value = )false', '${1}true')
  $settings = [regex]::Replace($settings, '(name = "telemetry-output-rcon-enabled",\s+setting_type = "runtime-global",\s+default_value = )false', '${1}true')
  Set-Content -LiteralPath $settingsPath -Value $settings -Encoding utf8NoBOM
  # Runtime-global settings may only be changed by their owning mod. This test-only
  # command is appended to the isolated copy, never to the distributable source.
  $testControl = Join-Path $modDestination 'control.lua'
  @'

commands.add_command("telemetry-smoke-setting", nil, function(command)
  settings.global["telemetry-output-jsonl-enabled"] = {value = command.parameter == "true"}
end)
'@ | Add-Content -LiteralPath $testControl -Encoding utf8NoBOM

  $smokeDestination = Join-Path $mods 'telemetry-smoke_0.1.0'
  Copy-Item -LiteralPath (Join-Path $repoRoot 'tests\factorio-smoke') -Destination $smokeDestination -Recurse -Force
  '{"mods":[{"name":"base","enabled":true},{"name":"telemetry-mod","enabled":true},{"name":"telemetry-smoke","enabled":true}]}' | Set-Content -LiteralPath (Join-Path $mods 'mod-list.json') -Encoding utf8NoBOM

  $gameRoot = Split-Path (Split-Path (Split-Path $FactorioExe -Parent) -Parent) -Parent
  $dataPath = (Join-Path $gameRoot 'data').Replace('\', '/')
  $writePath = $testRoot.Replace('\', '/')
  $configPath = Join-Path $testRoot 'config.ini'
  @('; version=13', '[path]', "read-data=$dataPath", "write-data=$writePath") | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM

  $save = Join-Path $testRoot 'smoke.zip'
  $createLog = Join-Path $testRoot 'create.log'
  $createArgs = @('--config', "`"$configPath`"", '--mod-directory', "`"$mods`"", "--enable-lua-udp=$udpSourcePort", '--create', "`"$save`"")
  $create = Start-Process -FilePath $FactorioExe -ArgumentList $createArgs -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $createLog -RedirectStandardError (Join-Path $testRoot 'create-error.log')
  if ($create.ExitCode -ne 0) { throw 'Factorio smoke-save creation failed.' }

  $log = Get-Content -Raw -LiteralPath (Join-Path $testRoot 'factorio-current.log')
  if ($log -notmatch 'Factorio 2\.0\.77') { throw 'The test runtime is not Factorio 2.0.77.' }
  if ($log -notmatch 'TELEMETRY_SMOKE PASS') { throw 'Lua output smoke checks did not complete.' }
  $jsonl = Get-Content -LiteralPath (Join-Path $testRoot 'script-output\telemetry.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.source -eq 'smoke' }
  if ($jsonl.Count -ne 1 -or $jsonl[0].type -ne 'notify') { throw 'JSONL output contract check failed.' }

  # The mod must remain playable and JSONL must keep working without Lua UDP enabled.
  $withoutUdpSave = Join-Path $testRoot 'smoke-without-udp.zip'
  $withoutUdpArgs = @('--config', "`"$configPath`"", '--mod-directory', "`"$mods`"", '--create', "`"$withoutUdpSave`"")
  $withoutUdp = Start-Process -FilePath $FactorioExe -ArgumentList $withoutUdpArgs -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $testRoot 'without-udp.log') -RedirectStandardError (Join-Path $testRoot 'without-udp-error.log')
  if ($withoutUdp.ExitCode -ne 0) { throw 'Factorio map creation without the Lua UDP flag failed.' }
  $withoutUdpLog = Get-Content -Raw -LiteralPath (Join-Path $testRoot 'factorio-current.log')
  if ($withoutUdpLog -notmatch 'TELEMETRY_SMOKE PASS') { throw 'Smoke checks without the Lua UDP flag did not complete.' }
  $withoutUdpJsonl = @(Get-Content -LiteralPath (Join-Path $testRoot 'script-output\telemetry.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.source -eq 'smoke' })
  if ($withoutUdpJsonl.Count -ne 1 -or $withoutUdpJsonl[0].type -ne 'notify') { throw 'JSONL failed without the Lua UDP flag.' }

  $receiver = [Net.Sockets.UdpClient]::new($udpPort)
  $udpTask = $receiver.ReceiveAsync()

  $server = Start-Process -FilePath $FactorioExe -ArgumentList @('--config', "`"$configPath`"", '--mod-directory', "`"$mods`"", "--enable-lua-udp=$udpSourcePort", '--rcon-port', $rconPort, '--rcon-password', $rconPassword, '--start-server', "`"$save`"") -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $testRoot 'server.log') -RedirectStandardError (Join-Path $testRoot 'server-error.log')
  try {
    $deadline = (Get-Date).AddSeconds(30)
    do {
      try {
        $emit = '/c remote.call("telemetry_mod", "notify", {source="smoke-rcon", severity="warning", message="rcon smoke"})'
        Invoke-RconCommand $emit | Out-Null
        Invoke-RconCommand $emit | Out-Null
        $response = Invoke-RconCommand '/telemetry-export 1'
        break
      } catch {
        if ($server.HasExited) { throw 'Factorio server exited before the RCON test; inspect server.log.' }
        Start-Sleep -Milliseconds 500
      }
    } while ((Get-Date) -lt $deadline)
    if (-not $response) { throw 'RCON server did not become available.' }
    $rconJson = $response | ConvertFrom-Json
    if ($rconJson.schema -ne 'telemetry-rcon/v1' -or $rconJson.events.Count -gt 1 -or $rconJson.events[0].source -ne 'smoke-rcon') { throw 'RCON export contract check failed.' }
    if (-not $udpTask.Wait(30000)) { throw 'UDP datagram was not received within 30 seconds.' }
    $udpJson = [Text.Encoding]::UTF8.GetString($udpTask.Result.Buffer) | ConvertFrom-Json
    $receiver.Dispose()
    $receiver = $null
    if ($udpJson.type -ne 'notify' -or $udpJson.source -ne 'smoke-rcon') { throw 'UDP output contract check failed.' }

    $node = Get-Command node -ErrorAction Stop
    $discordScript = Join-Path $repoRoot 'tests\factorio-discord-receiver.js'
    $discordReceiver = Start-Process -FilePath $node.Source -ArgumentList @("`"$discordScript`"", "`"$testRoot`"") -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $testRoot 'discord-receiver.log') -RedirectStandardError (Join-Path $testRoot 'discord-receiver-error.log')
    $readyPath = Join-Path $testRoot 'discord-receiver-ready'
    $readyDeadline = (Get-Date).AddSeconds(10)
    while (-not (Test-Path -LiteralPath $readyPath)) {
      if ($discordReceiver.HasExited) { throw 'Discord UDP test receiver exited before becoming ready.' }
      if ((Get-Date) -gt $readyDeadline) { throw 'Discord UDP test receiver did not become ready.' }
      Start-Sleep -Milliseconds 100
    }
    Invoke-RconCommand '/c remote.call("telemetry_mod", "notify", {source="smoke-discord", severity="critical", message="factorio discord smoke"})' | Out-Null
    if (-not $discordReceiver.WaitForExit(30000) -or $discordReceiver.ExitCode -ne 0) { throw 'Factorio-to-Discord UDP integration failed; inspect discord-receiver logs.' }
    $discordReceiver = $null

    # Exercise a real runtime-global change on the loaded save.
    $jsonlPath = Join-Path $testRoot 'script-output\telemetry.jsonl'
    Invoke-RconCommand '/telemetry-smoke-setting false' | Out-Null
    $beforeDisabled = Get-FileHash -LiteralPath $jsonlPath -Algorithm SHA256
    Invoke-RconCommand '/c remote.call("telemetry_mod", "notify", {source="runtime-off", message="jsonl disabled"})' | Out-Null
    $afterDisabled = Get-FileHash -LiteralPath $jsonlPath -Algorithm SHA256
    if ($beforeDisabled.Hash -ne $afterDisabled.Hash) { throw 'JSONL changed while disabled at runtime.' }
    $disabledExport = Invoke-RconCommand '/telemetry-export 1' | ConvertFrom-Json
    if ($disabledExport.events.Count -ne 1 -or $disabledExport.events[0].source -ne 'runtime-off') { throw 'RCON did not retain an event after disabling JSONL.' }
    Invoke-RconCommand '/telemetry-smoke-setting true' | Out-Null
    Invoke-RconCommand '/c remote.call("telemetry_mod", "notify", {source="runtime-on", message="jsonl enabled"})' | Out-Null
    $enabledEvents = @(Get-Content -LiteralPath $jsonlPath | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.source -eq 'runtime-on' })
    if ($enabledEvents.Count -ne 1) { throw 'JSONL did not resume after being re-enabled at runtime.' }
  } finally {
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
  }

  & (Join-Path $repoRoot 'mod\pack-mod.ps1') -ModDir (Join-Path $repoRoot 'mod\telemetry-mod') -OutDir (Join-Path $testRoot 'dist')
  $packageRoot = "$($releaseInfo.name)_$($releaseInfo.version)"
  $zip = Join-Path $testRoot ("dist\$packageRoot.zip")
  if (-not (Test-Path -LiteralPath $zip)) { throw 'Package was not created.' }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [IO.Compression.ZipFile]::OpenRead($zip)
  try {
    $entries = @($archive.Entries.FullName)
    foreach ($required in @("$packageRoot/info.json", "$packageRoot/control.lua", "$packageRoot/changelog.txt", "$packageRoot/LICENSE", "$packageRoot/thumbnail.png", "$packageRoot/locale/en/telemetry.cfg", "$packageRoot/locale/pl/telemetry.cfg")) {
      if (-not ($archive.Entries.FullName -contains $required)) { throw "Package is missing $required" }
    }
    if (($entries | Where-Object { $_ -notmatch "^$([regex]::Escape($packageRoot))/" }).Count -gt 0) { throw 'Package has files outside its versioned root directory.' }
    if (($entries | Where-Object { $_ -match '(^|/)(?:\.git|\.vscode|\.codex|node_modules|tests?|spec|coverage)(/|$)|\.(?:zip|log|sav|save)$' }).Count -gt 0) { throw 'Package contains a development or state file.' }
    $rootLicense = Get-FileHash -LiteralPath (Join-Path $repoRoot 'LICENSE') -Algorithm SHA256
    $modLicense = Get-FileHash -LiteralPath (Join-Path $repoRoot 'mod\telemetry-mod\LICENSE') -Algorithm SHA256
    if ($rootLicense.Hash -ne $modLicense.Hash) { throw 'Repository and packaged mod licenses differ.' }
    $settingsSource = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'mod\telemetry-mod\settings.lua')
    $settingNames = @([regex]::Matches($settingsSource, 'name\s*=\s*"(telemetry-[^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    foreach ($locale in @('en', 'pl')) {
      $localeSource = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "mod\telemetry-mod\locale\$locale\telemetry.cfg")
      foreach ($section in @('mod-setting-name', 'mod-setting-description')) {
        $pattern = '(?ms)^\[' + [regex]::Escape($section) + '\][ \t]*\r?\n(?<body>.*?)(?=^\[|\z)'
        $match = [regex]::Match($localeSource, $pattern)
        if (-not $match.Success) { throw "$locale locale is missing [$section]." }
        foreach ($settingName in $settingNames) {
          if ($match.Groups['body'].Value -notmatch "(?m)^$([regex]::Escape($settingName))=.+$") { throw "$locale locale is missing [$section] $settingName." }
        }
      }
    }
  } finally { $archive.Dispose() }
  $passed = $true
  Write-Host 'TelemetryMod Factorio 2.0.77 smoke test passed.'
} finally {
  if ($receiver) { $receiver.Dispose() }
  if ($discordReceiver -and -not $discordReceiver.HasExited) { Stop-Process -Id $discordReceiver.Id -Force }
  if ($passed -and (Test-Path -LiteralPath $testRoot)) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
  } elseif (Test-Path -LiteralPath $testRoot) {
    Write-Warning "Test artifacts kept for diagnosis: $testRoot"
  }
}
