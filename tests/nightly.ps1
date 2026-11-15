# nightly.ps1 - the rig's night check (W5-4). irdash's own clock starts it at 03:00 (dash\src\nightly.cs); the lead can start it by hand.
# It CLICKS NOTHING and NEVER starts the sim. It looks at the rig, restarts the Stream Deck app once (the rig is free at night) and
# writes ONE honest line for RIG's screen:
#   tests\nightly.txt                      one line per night, newest last, 60 lines kept:  yyyy-MM-ddTHH:mm <TAB> 1|0 <TAB> text
#   tests\last\nightly-<yyyyMMdd>.txt      the full log, for the lead
# The words (Peter's): "Rig check 03:00: all good" / "...: 2 things: Stream Deck was not running (started it); ..." /
#   "...: skipped, Peter was at the PC" / "...: did not finish (irdash did not answer)". Never a stack trace.
# What the night does: 1 irdeck-cli state (sim off)  2 five dry key runs (keys-test.ps1 section 8: they refuse without a session)
#   3 /health, then the Rig Doctor's own check (/api/doctor/run?quiet=1)  4 Stream Deck restart through irdash (/api/nightly/deck),
#   then the app and the add-on must be back  5 recorder: there is no dry self-test, so "not checked"  6 write the line.
# Needs the sim off, no START key in 10 minutes and 10 minutes without keyboard/mouse input (a locked PC is fine). Exit 0 always,
# except the guard's own exit 3 (irdash turns that into the "skipped" line). Whole run <= 10 minutes, BelowNormal.
# Parameters after -Base are for tests\nightly-test.ps1 only (a pretend irdash, a stand-in irdeck-cli, no waiting).
#   powershell -ExecutionPolicy Bypass -File tests\nightly.ps1
param([string]$Base = 'http://localhost:8199', [string]$Cli = '', [string]$OutDir = '',
      [switch]$Fast, [string]$TestBusy = '', [double]$TestIdle = -1, [switch]$NoLock)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'guard.ps1')
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
if (-not $Cli) { $Cli = Join-Path $root 'irdeck-cli.exe' }
if (-not $OutDir) { $OutDir = $PSScriptRoot }
$lastDir = Join-Path $OutDir 'last'; New-Item -ItemType Directory -Force $lastDir | Out-Null
$lineFile = Join-Path $OutDir 'nightly.txt'
$logFile = Join-Path $lastDir ('nightly-' + (Get-Date -Format 'yyyyMMdd') + '.txt')
$began = Get-Date
$budget = [Diagnostics.Stopwatch]::StartNew()
$maxMinutes = 10          # the whole run; irdash kills it at 12
$script:log = New-Object Collections.Generic.List[string]
function Say($m) { $l = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; $script:log.Add($l); Write-Output $l }
function Nap([double]$sec) { Start-Sleep -Milliseconds ([int]([math]::Max(10, $(if ($Fast) { $sec * 20 } else { $sec * 1000 })))) }
function Over { $budget.Elapsed.TotalMinutes -ge $maxMinutes }
$k = if ($Fast) { 0.05 } else { 1 }     # the waits below shrink in a test; the real ones are 60 s (Doctor), 90 s (app back), 120 s (add-on back)

# one line for RIG, then the full log; keeps the newest 60 lines
function Finish([bool]$good, [string]$words) {
  $text = "Rig check 03:00: $words"
  $row = '{0}{1}{2}{3}' -f $began.ToString('yyyy-MM-ddTHH:mm'), "`t", $(if ($good) { '1' } else { '0' }), "`t$text"
  $keep = @(); if (Test-Path $lineFile) { $keep = @(Get-Content $lineFile | Where-Object { $_.Trim() }) }
  $keep = @($keep + $row); if ($keep.Count -gt 60) { $keep = $keep[($keep.Count - 60)..($keep.Count - 1)] }
  [IO.File]::WriteAllLines($lineFile, [string[]]$keep, (New-Object Text.UTF8Encoding($false)))
  Say "LINE: $text"
  try { [IO.File]::WriteAllLines($logFile, [string[]]$script:log, (New-Object Text.UTF8Encoding($false))) } catch { }
  exit 0
}
function Skipped([string]$why) { Say "skipped: $why"; Finish $false "skipped, $why" }
function NoAnswer([string]$what) { Say "no answer: $what"; Finish $false "did not finish ($what)" }

function Get-Json([string]$path, [int]$timeout = 8, [bool]$mark = $false) {
  $h = @{}; if ($mark) { $h['X-Paddock'] = '1' }
  $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec $timeout -Headers $h -Uri ($Base + $path)
  $t = $r.Content; if ($t -is [byte[]]) { $t = [Text.Encoding]::UTF8.GetString($t) }
  try { return $t | ConvertFrom-Json } catch { return $t }
}
function Get-Apps {
  $h = Get-Json '/health'
  $m = @{}; foreach ($a in @($h.apps)) { $m[[string]$a.id] = [string]$a.state }
  return $m
}

try {
  Say "nightly check starts (irdash $Base)"
  # ---- 0. is the rig free? the sim off, no START key in 10 minutes, 10 minutes without keyboard/mouse (a locked PC is fine) ----
  $why = if ($TestBusy) { $TestBusy } else { Get-RigBusy }
  if ($why) { Skipped $(if ($why -match 'START key') { 'a START key was pressed lately' } elseif ($why -match 'sim is running') { 'the sim was running' } else { $why }) }
  $idle = if ($TestIdle -ge 0) { $TestIdle } else { [RigGuard]::IdleMinutes() }
  if ($idle -lt 10) { Skipped 'Peter was at the PC' }
  if (-not $NoLock) { Enter-TestLock 'nightly' 0 }     # another live test holds the rig: the guard exits 3 and irdash writes the "skipped" line

  # ---- 1. irdeck-cli state ----
  if (-not (Test-Path $Cli)) { NoAnswer 'irdeck-cli.exe is missing' }
  $st = ((& $Cli state 2>&1 | ForEach-Object { "$_" }) -join ' ')
  Say "state: $st"
  if ($st -notmatch 'sim=') { NoAnswer 'irdeck did not answer' }
  if ($st -notmatch 'sim=False') { Skipped 'the sim was running' }
  if ($st -match 'onTrack=True|telemetry=on') { Skipped 'Peter was driving' }

  $faults = New-Object Collections.Generic.List[string]

  # ---- 2. the five dry key runs: the exact commands and answers of tests\keys-test.ps1 section 8 (they refuse without a session) ----
  $dry = @(
    @{ label = 'pittoggle'; a = @('pittoggle');             rc = @(3); re = 'no sim session running' },
    @{ label = 'getout';    a = @('getout');                rc = @(3); re = 'no sim session running' },
    @{ label = 'skip';      a = @('skip');                  rc = @(3); re = 'no session is running' },
    @{ label = 'chat say';  a = @('chat', 'say', 'GG');     rc = @(3); re = 'no sim session running' },
    @{ label = 'tow';       a = @('tow', '--pretend', '0.4'); rc = @(0); re = 'stationary' })
  $badKeys = @()
  foreach ($d in $dry) {
    if (Over) { break }
    $o = ((& $Cli @($d.a) 2>&1 | ForEach-Object { "$_" }) -join "`n"); $rc = $LASTEXITCODE
    $good = ($o -notmatch 'ERROR |Exception|Unhandled') -and ($d.rc -contains $rc) -and ($o -match $d.re)
    Say ("key {0}: rc {1} {2}" -f $d.label, $rc, $(if ($good) { 'ok' } else { 'WRONG: ' + ($o -replace '\s+', ' ') }))
    if (-not $good) { $badKeys += $d.label }
  }
  if ($badKeys.Count -gt 0) { $faults.Add('deck keys did not answer as expected (' + ($badKeys -join ', ') + ')') }

  # ---- 3. /health, then the Rig Doctor ----
  try { $pre = Get-Apps } catch { NoAnswer 'irdash did not answer' }
  Say ('health before: ' + (($pre.Keys | Sort-Object | ForEach-Object { "$_=$($pre[$_])" }) -join ' '))
  if ($pre['sim'] -eq 'live') { Skipped 'the sim was running' }
  $apps = @(@{ id = 'deck'; words = 'Stream Deck' }, @{ id = 'cc'; words = 'the spotter (CrewChief)' }, @{ id = 'overlays'; words = 'the overlays' })
  $was = @{}; foreach ($a in $apps) { if ($pre.ContainsKey($a.id) -and $pre[$a.id] -ne 'ok') { $was[$a.id] = $true } }
  if ($pre['sim'] -in @('stuck', 'loading', 'starting')) { $faults.Add("iRacing was $($pre['sim']) with no one driving") }

  try { $d0 = Get-Json '/doctor'; $ranBefore = [string]$d0.ranAt } catch { NoAnswer 'irdash did not answer' }
  [void](Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Headers @{ 'X-Paddock' = '1' } -Uri ($Base + '/api/doctor/run?quiet=1'))
  $docDone = $false; $t0 = Get-Date
  while (((Get-Date) - $t0).TotalSeconds -lt (60 * $k) -and -not (Over)) {
    Nap 2
    try { $d = Get-Json '/doctor' } catch { NoAnswer 'irdash did not answer' }
    if (-not $d.running -and [string]$d.ranAt -ne $ranBefore -and $d.ranAt) { $docDone = $true; break }
  }
  if (-not $docDone) { $faults.Add('the rig check did not run') ; Say 'doctor: did not finish within 60 s' }
  else {
    Say "doctor: $($d.headline)"
    $mapped = @{ streamdeck = 'deck'; crewchief = 'cc'; overlays_running = 'overlays' }
    foreach ($it in @($d.items)) {
      # an add-on older than the one on disk is "ok" to the Doctor (it installs itself when Stream Deck restarts) but worth a word
      if ($it.id -eq 'streamdeck' -and $it.state -eq 'ok' -and [string]$it.detail -match 'ready to install') { $faults.Add('the Stream Deck add-on is out of date'); Say "doctor item: $($it.detail)"; continue }
      if ($it.state -eq 'ok') { continue }
      Say "doctor item: $($it.name) [$($it.state)]: $($it.detail) - $($it.fix)"
      if ($it.state -eq 'bad' -and $mapped.ContainsKey([string]$it.id) -and $was.ContainsKey($mapped[[string]$it.id])) { continue }   # "not running" is said already, in its own words
      $faults.Add(("{0}: {1}" -f $it.name, $it.detail).TrimEnd(': '))
    }
  }
  $post = $null; try { $post = Get-Apps } catch { NoAnswer 'irdash did not answer' }
  foreach ($a in $apps) {
    if (-not $was.ContainsKey($a.id)) { if ($post.ContainsKey($a.id) -and $post[$a.id] -ne 'ok') { $faults.Add("$($a.words) stopped during the check") }; continue }
    $faults.Add("$($a.words) was not running (" + $(if ($post[$a.id] -eq 'ok') { 'started it' } else { 'could not start it' }) + ')')
  }

  # ---- 4. a real Stream Deck restart through irdash; then the app and the add-on must be back ----
  if (-not (Over)) {
    try { $r = Get-Json '/api/nightly/deck' 8 $true }
    catch [Net.WebException] {
      # irdash answered with a refusal (409: a session started, 403, 404): read its words; no answer at all is the outer catch's
      $resp = $_.Exception.Response
      if ($null -eq $resp) { throw }
      $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $body = $sr.ReadToEnd(); $sr.Dispose(); $r = if ($body -match '^refused') { $body } else { "refused: $body" }
    }
    Say "deck restart asked: $r"
    if ("$r" -match 'refused') { Say 'deck restart refused by irdash'; $faults.Add("the Stream Deck restart was refused ($($r -replace '^refused:\s*', ''))") }
    else {
      $t1 = Get-Date; Nap 10; $appBack = $false; $addonBack = $false
      while (((Get-Date) - $t1).TotalSeconds -lt (120 * $k) -and -not (Over)) {
        try {
          $ap = Get-Apps
          if ($ap['deck'] -eq 'ok') {
            $appBack = $true
            $age = (Get-Json '/doctor').deckAge          # seconds since the add-on last asked irdash anything; must be after the restart
            if ($null -ne $age -and [double]$age -le (((Get-Date) - $t1).TotalSeconds + 1)) { $addonBack = $true; break }
          }
        } catch { NoAnswer 'irdash did not answer' }
        if (((Get-Date) - $t1).TotalSeconds -ge (90 * $k) -and -not $appBack) { break }
        Nap 3
      }
      Say "deck after the restart: app back=$appBack, add-on back=$addonBack ($([int]((Get-Date) - $t1).TotalSeconds) s)"
      if (-not $appBack) { $faults.Add('Stream Deck did not come back after the restart') }
      elseif (-not $addonBack) { $faults.Add('the Stream Deck add-on did not report back after the restart') }
    }
  }

  # ---- 5. recorder: dash\src\recorder.cs has no dry self-test (its test routes need a pretend session), so it is not checked ----
  Say 'recorder: not checked (no dry self-test)'

  # ---- 6. the line ----
  if (Over) { $faults.Add('the check ran out of time') }
  $notChecked = ' (not checked: recorder, deck start page)'
  if ($faults.Count -eq 0) { Finish $true ('all good' + $notChecked) }
  $n = $faults.Count
  Finish $false ("$n thing" + $(if ($n -eq 1) { '' } else { 's' }) + ': ' + ($faults -join '; ') + $notChecked)
}
catch {
  Say ('crashed: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber)
  $m = $_.Exception.Message
  if ($m -match 'remote server|Unable to connect|timed out|actively refused|No connection|operation has timed') { NoAnswer 'irdash did not answer' }
  NoAnswer 'something unexpected went wrong; the full log is in tests\last'
}
finally { Exit-TestLock }
