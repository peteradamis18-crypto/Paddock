. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree -NeedAway -Where 'airace live start'

$ErrorActionPreference = 'Stop'
$cli = Join-Path $PSScriptRoot '..\irdeck-cli.exe'
$timingFile = Join-Path $PSScriptRoot 'last\airace-live-timings.txt'
$timings = New-Object System.Collections.Generic.List[string]
$pass = 0; $fail = 0
function Section([string]$name) { "Section $name" }
function Check([string]$name, [bool]$good) {
  if ($good) { $script:pass++; "  ok    $name" } else { $script:fail++; "  FAIL  $name" }
}
function Invoke-Cli([string[]]$arguments) {
  $output = & $script:cli @arguments 2>&1
  $code = $LASTEXITCODE
  # this command may have typed or clicked: mark it so the guard does not mistake it for Peter
  if ($arguments[0] -ne 'state') { Set-Content (Join-Path $PSScriptRoot 'last\own-input.txt') (Get-Date -Format s) }
  return [pscustomobject]@{ Code = $code; Text = ($output -join "`n") }
}
function Wait-State([scriptblock]$condition, [int]$timeoutSeconds, [string]$what) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $last = ''
  while ($watch.Elapsed.TotalSeconds -lt $timeoutSeconds) {
    $state = Invoke-Cli @('state')
    $last = $state.Text
    if (& $condition $last) { $watch.Stop(); return [pscustomobject]@{ Ok = $true; Ms = $watch.ElapsedMilliseconds; State = $last } }
    Start-Sleep -Milliseconds 1000
  }
  $watch.Stop()
  return [pscustomobject]@{ Ok = $false; Ms = $watch.ElapsedMilliseconds; State = $last; What = $what }
}

try {
  Enter-TestLock 'AI race live loop'
  # Mark only this test's own start so the second round's guard ignores its recent START mark.
  $env:RIG_TEST_OWNS_SIM = '1'
  $rounds = @(
    @{ Car = 'BMW Z4 GT3'; Track = 'Road Atlanta'; Layout = 'Full Course' },
    @{ Car = 'Ferrari 296 GT3'; Track = 'Road Atlanta'; Layout = 'Full Course' }
  )
  for ($i = 0; $i -lt $rounds.Count; $i++) {
    $round = $rounds[$i]
    # the previous round's own typing/quit clicks count as input for the idle check: let it settle first
    if ($i -gt 0) { Start-Sleep -Seconds 35 }
    Assert-RigFree -NeedAway -Where ("AI race round {0}" -f ($i + 1))
    Section ("round {0}: {1} / {2} {3}" -f ($i + 1), $round.Car, $round.Track, $round.Layout)
    $start = [Diagnostics.Stopwatch]::StartNew()
    $set = Invoke-Cli @('mydrive', 'set', $round.Car, $round.Track, $round.Layout)
    Check 'MY DRIVE choice accepted' ($set.Code -eq 0)
    if ($set.Code -ne 0) { throw $set.Text }

    $race = Invoke-Cli @('airace', 'start')
    Check 'airace start completed' ($race.Code -eq 0)
    if ($race.Code -ne 0) { throw $race.Text }
    $sim = Wait-State { param($s) $s -match 'sim=True' -and $s -match 'telemetry=on' } 120 'sim process and session'
    Check 'sim process and session appeared' $sim.Ok
    if (-not $sim.Ok) { throw 'UI CHANGED: sim process timeout' }
    $timings.Add(("round {0} sim/session wait: {1} ms" -f ($i + 1), $sim.Ms))

    $getin = Invoke-Cli @('go')
    Check 'existing get-in path returned success' ($getin.Code -eq 0)
    if ($getin.Code -ne 0) { throw $getin.Text }
    $onTrack = Wait-State { param($s) $s -match 'onTrack=True' } 120 'IsOnTrack'
    Check 'IsOnTrack became true within 120 seconds' $onTrack.Ok
    $timings.Add(("round {0} on-track wait: {1} ms" -f ($i + 1), $onTrack.Ms))
    if (-not $onTrack.Ok) { throw 'UI CHANGED: IsOnTrack timeout' }
    # out of the car (garage), the smart key must offer GET IN; then back in with go
    $out = Invoke-Cli @('getout'); $inGarage = Wait-State { param($x) $x -match 'onTrack=False' } 60 'out of the car'
    Check 'GET OUT leaves the car' $inGarage.Ok
    $sm = Invoke-Cli @('smart', '--dry')
    Check ("the smart key offers GET IN in the garage (got: " + (($sm.Text -split "`n" | Select-Object -Last 1).Trim()) + ")") ($sm.Text -match 'GETIN|GET IN')
    $back2 = Invoke-Cli @('go'); $again = Wait-State { param($x) $x -match 'onTrack=True' } 90 'back in the car'
    Check 'GET IN puts him back in the car' $again.Ok

    $quitWatch = [Diagnostics.Stopwatch]::StartNew()
    $quit = Invoke-Cli @('quitmain')
    Check 'quitmain returned success' ($quit.Code -eq 0)
    if ($quit.Code -ne 0) { throw $quit.Text }
    $back = Wait-State { param($s) $s -match 'sim=False ui=True telemetry=off' } 90 'iRacing UI home'
    Check 'returned to iRacing UI' $back.Ok
    $quitWatch.Stop()
    $timings.Add(("round {0} quit and UI return: {1} ms" -f ($i + 1), $quitWatch.ElapsedMilliseconds))
    if (-not $back.Ok) { throw 'UI CHANGED: iRacing UI did not return' }
    $start.Stop()
    $timings.Add(("round {0} total: {1} ms" -f ($i + 1), $start.ElapsedMilliseconds))
  }
}
finally {
  $env:RIG_TEST_OWNS_SIM = $null
  Exit-TestLock
  $dir = Split-Path -Parent $timingFile
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $timings | Set-Content -Path $timingFile -Encoding UTF8
  "Timings: $timingFile"
  "SUMMARY: $pass ok, $fail FAIL"
}
if ($fail) { exit 1 }
