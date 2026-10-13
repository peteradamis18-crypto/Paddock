# Runs every test that is safe without the real sim, one after the other, and writes a summary.
#   powershell -ExecutionPolicy Bypass -File tests\run-all.ps1            (waits for a free rig, then runs everything)
#   powershell -ExecutionPolicy Bypass -File tests\run-all.ps1 -Only corners,perf
# Waits (up to -WaitMinutes, default 90) while the sim runs, a START was pressed in the last 10 minutes, or another test
# or deploy holds dash\deploy.lock. Tests that need Peter away (gallery live part) run only when he has had no input
# for 10 minutes. friends-live's real Test Drive is in that script and only runs when he is away.
# Left out on purpose: tests that start the real sim (actions-test, mydrive-test live parts,
# replay-test -Live): run those by hand with Peter away.
# Output of each test: tests\last\<name>.txt. Summary: tests\run-all.last.txt (one line per test, FAIL lines listed).
param([string[]]$Only, [int]$WaitMinutes = 90, [switch]$SelfTest)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'guard.ps1')

# The test's own "N passed, M failed" line is the count. ok/FAIL text is not: a Check inside a
# function that returns a value used to vanish from that text while the exit code was still 1.
function Get-TestTally($text, $rc) {
  # "N ok, M FAIL" too: corners-test ends that way and was read as "no summary line" (lead 2026-10-10)
  $rows = @($text | Where-Object { $_ -match '\d+\s+(?:passed|ok),\s+\d+\s+fail(?:ed)?\b' })
  $line = $null
  if ($rows.Count -gt 0) { $line = ("$($rows[$rows.Count - 1])").Trim() }
  $okN = 0; $failN = 0; $have = $false
  if ($line -match '(\d+)\s+(?:passed|ok),\s+(\d+)\s+fail(?:ed)?\b') {
    $okN = [int]$Matches[1]; $failN = [int]$Matches[2]; $have = $true
  }
  $bumped = $false
  if ([int]$rc -ne 0 -and $failN -lt 1) { $failN = 1; $bumped = $true }
  return @{ ok = $okN; fail = $failN; line = $line; have = $have; bumped = $bumped }
}
if ($SelfTest) {
  $bad = 0
  function Expect($name, $text, $rc, $ok, $fail) {
    $t = Get-TestTally $text $rc
    if ($t.ok -ne $ok -or $t.fail -ne $fail) { Write-Host "  FAIL  $name (got $($t.ok) passed, $($t.fail) failed)"; $script:bad++ }
    else { Write-Host "  ok    $name" }
  }
  Expect 'a non-zero exit with 0 failed counts as a failure' @('31 passed, 0 failed') 1 31 1
  Expect 'FAIL text is not the count' @('  FAIL  swallowed', '4 passed, 0 failed') 0 4 0
  Expect 'the script''s own failure count is kept' @('5 passed, 2 failed') 1 5 2
  Expect 'the ok, failed form is kept' @('3 ok, 1 failed') 0 3 1
  Expect 'the ok, FAIL form is kept (corners-test)' @('75 ok, 0 FAIL') 0 75 0
  Expect 'a FAIL line alone is still not a count' @('  FAIL  12 ok, x') 1 0 1
  if ($bad -gt 0) { exit 1 }
  Write-Host 'selftest ok'
  exit 0
}

New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot 'last') | Out-Null
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
$mx = New-Object Threading.Mutex($false, 'Local\paddock-run-all'); if (-not $mx.WaitOne(0)) { 'run-all is already running.'; exit 0 }

# name, script, extra arguments, needs Peter away (10 min without input)
$all = @(
  @{ n = 'corners';   f = 'corners-test.ps1';   a = @();                  away = $false },
  @{ n = 'gpsmap';    f = 'gpsmap-test.ps1';    a = @();                  away = $false },   # P0-05: real GPS track maps from .ibt Lat/Lon/Alt (offline copies + the measured line in map.js headless; needs the deployed irdash for its live route check)
  @{ n = 'perf';      f = 'perf-test.ps1';      a = @();                  away = $false },
  @{ n = 'pbdelta';   f = 'pbdelta-test.ps1';   a = @();                  away = $false },
  @{ n = 'bench';     f = 'bench-test.ps1';     a = @();                  away = $false },
  @{ n = 'data';      f = 'data-test.ps1';      a = @();                  away = $false },
  @{ n = 'overlays';  f = 'overlays-test.ps1';  a = @();                  away = $false },
  @{ n = 'dialog';    f = 'dialog-links-test.ps1'; a = @();               away = $false },
  @{ n = 'friends';   f = 'friends-test.ps1';   a = @();                  away = $false },
  @{ n = 'tow-wait';  f = 'tow-wait-test.ps1';  a = @();                  away = $false },
  @{ n = 'harness';   f = 'harness-check-test.ps1'; a = @();               away = $false },
  @{ n = 'guard-lock'; f = 'guard-lock-test.ps1'; a = @();                 away = $false },   # the cross-test lock (guard.ps1 Enter-TestLock): child copies take turns on a private mutex, no rig
  @{ n = 'friends-live'; f = 'friends-live-test.ps1'; a = @();             away = $true },
  @{ n = 'replay';    f = 'replay-test.ps1';    a = @();                  away = $false },
  @{ n = 'mydrive';   f = 'mydrive-test.ps1';   a = @('-DeckOnly');       away = $false },
  @{ n = 'deckspeed'; f = 'deck-speed-test.ps1'; a = @();                 away = $false },
  # added by the lead 2026-10-10: these tests existed but were never in the sweep
  @{ n = 'doctor';    f = 'doctor-test.ps1';    a = @();                  away = $false },
  @{ n = 'official';  f = 'official-test.ps1';  a = @();                  away = $false },
  @{ n = 'tv';        f = 'tv-test.ps1';        a = @();                  away = $false },
  @{ n = 'vault';     f = 'vault-test.ps1';     a = @();                  away = $false },
  @{ n = 'recorder';  f = 'recorder-test.ps1';  a = @();                  away = $false },   # C-06: made-up screen through the real recorder; its real-screen section skips itself unless Peter has been away 10 min
  @{ n = 'review';    f = 'review-test.ps1';    a = @();                  away = $false },
  @{ n = 'quickwins'; f = 'quickwins-test.ps1';  a = @();                  away = $false },
  @{ n = 'analysis';  f = 'analysis-test.ps1';  a = @();                  away = $false },   # C-30/C-34: analysis engines on real .ibt copies
  @{ n = 'workbench'; f = 'workbench-test.ps1';  a = @();                  away = $false },   # W1: channel endpoint on copies + the page headless
  @{ n = 'video-page'; f = 'video-page-test.ps1'; a = @();                  away = $false },   # W5: the workbench's VIDEO page + small video, a pretend clip tied to a real lap in the scratch vault (needs the deployed irdash)
  @{ n = 'race-field'; f = 'race-field-test.ps1'; a = @();                  away = $false },   # W6: the race field log (a pretend 20-car race through the test hook, every number against the simulation), /analysis/race, the RACE page headless (needs the deployed irdash)
  @{ n = 'career';    f = 'career-test.ps1';    a = @();                  away = $false },   # W6c: the CAREER page - every session of a car + track (copies of real Corvette files, checked against iRacing's own lap times and the Session Review engine), the cache, 503 while driving, the page headless (the live part needs the deployed irdash)
  @{ n = 'pro-tools'; f = 'pro-tools-test.ps1'; a = @();                  away = $false },   # P3: the PRO page - X/Y scatter + fit, histogram, maths channels (the server's parser), CSV / .xlsx export, each against an independent calculation on copies of real Corvette files (the live part needs the deployed irdash)
  @{ n = 'keys';      f = 'keys-test.ps1';     a = @();                  away = $false },   # C-32: every deck key answers (its output is tests\last\keys.txt, the key table)
  @{ n = 'session-review'; f = 'session-review-test.ps1'; a = @();         away = $false },   # C-40: Session Review data on copies + the page headless + the dashboard against a pretend irdash
  @{ n = 'deckscreens'; f = 'deck-screens-test.ps1'; a = @();              away = $false },   # C-42: ANALYSIS, SOUND, RACE SETUP deck screens + irdeck sound + irdash side (all pretend, offline)
  @{ n = 'home';      f = 'home-test.ps1';      a = @();                  away = $false },   # P1: Paddock HOME on the top screen (real data, headless 1920x1080, hidden while a pretend session runs; needs the deployed irdash)
  @{ n = 'phone';     f = 'phone-test.ps1';     a = @();                  away = $false },   # P1: the iPhone app (pairing gate, QR decode, the app headless at 393x852, driving mode; needs the deployed irdash)
  @{ n = 'share';     f = 'share-test.ps1';     a = @();                  away = $false },   # P2: SHARE STUDIO - a pretend clip tied to real lap 7 gets the broadcast overlay (ffmpeg + NVENC), every number read back from the video against the .ibt, queue / driving refusal, the workbench chip and the phone clip screen headless (needs the deployed irdash)
  @{ n = 'copy-audit'; f = 'copy-audit-test.ps1'; a = @();                  away = $false },   # AU-1: every screen's visible text and every served text string against the banned patterns of docs\COPY-RULES.md (headless Chrome, real data; needs the deployed irdash)
  @{ n = 'replay-jump'; f = 'replay-jump-test.ps1'; a = @();              away = $false },   # P2: SEE IN iRACING - the replay jump through the pretend SDK path (exact broadcast messages, refusals), the workbench buttons headless (needs the deployed irdash)
  @{ n = 'rig-leftovers'; f = 'rig-leftovers-test.ps1'; a = @();            away = $false },   # P5: the Simucube Tuner's blank box hidden (stand-in programs), MOST TO GAIN (scratch copies vs an independent computation), the iRacing UI window finder (the live part needs the deployed irdash)
  @{ n = 'cars';      f = 'cars-test.ps1';      a = @();                  away = $false },   # CP-1: iRacing's own car pictures (paddock\cars): the files and manifest, his cars' mapping from his .ibt files, served by irdash, the on-demand fetch refused during a session (sandbox), the pictures in a browser (needs the deployed irdash)
  @{ n = 'actions';   f = 'actions-test.ps1';   a = @();                  away = $true },
  @{ n = 'gallery';   f = 'gallery-test.ps1';   a = @('-PeterIsAway');    away = $true }
)
if ($Only) { $Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }); $all = @($all | Where-Object { $Only -contains $_.n }) }   # -File passes 'a,b' as one string

function Rig-Wait($needAway) {
  $until = (Get-Date).AddMinutes($WaitMinutes)
  while ((Get-Date) -lt $until) {
    $why = Get-RigBusy
    $lock = Join-Path $root 'dash\deploy.lock'
    if (-not $why -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15) { $why = 'a test or deploy holds the lock (' + (Get-Content $lock) + ')' }
    if (-not $why -and (Test-Path (Join-Path $root 'dash\test-hook.on'))) { $why = 'the test hook is on (another test is running)' }
    if (-not $why -and $needAway -and [RigGuard]::IdleMinutes() -lt 10) { $why = 'Peter used the PC less than 10 minutes ago' }
    if (-not $why) { return $null }
    Start-Sleep -Seconds 30
  }
  return $why
}

$env:PADDOCK_RUN_ALL = '1'   # tests that write their own tests\last file (keys-test) leave it to this redirect
$sum = New-Object Collections.Generic.List[string]
$sum.Add("run-all started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
foreach ($t in $all) {
  $skip = Rig-Wait $t.away
  if ($skip) { $sum.Add(('{0,-10} SKIPPED: {1}' -f $t.n, $skip)); continue }
  $out = Join-Path $PSScriptRoot "last\$($t.n).txt"
  $t0 = Get-Date
  $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot $t.f)) + $t.a
  & powershell.exe @args *> $out
  $rc = $LASTEXITCODE
  $text = Get-Content $out -ErrorAction SilentlyContinue
  $tally = Get-TestTally $text $rc
  $secs = ((Get-Date) - $t0).TotalSeconds
  $sum.Add(('{0,-12} {1} passed, {2} failed  (exit {3}, {4:N0} s)' -f $t.n, $tally.ok, $tally.fail, $rc, $secs))
  if ($tally.line) { $sum.Add('             ' + $tally.line) }
  if ($tally.bumped) { $sum.Add('             non-zero exit counted as a failure') }
  if (-not $tally.have) { $sum.Add('             (no "N passed, M failed" line: ' + (($text | Select-Object -First 2) -join ' / ') + ')') }
  if ($tally.fail -gt 0) { foreach ($f in @($text | Where-Object { $_ -match '^\s+FAIL\s' })) { $sum.Add('             ' + $f.Trim()) } }
}
$sum.Add("run-all finished $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$sum | Set-Content (Join-Path $PSScriptRoot 'run-all.last.txt') -Encoding UTF8
$sum
