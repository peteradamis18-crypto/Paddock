# coach-test.ps1 - offline: the session coach (dash\src\coach.cs, GET /analysis/coach) on real, OLD telemetry files.
# Loads a freshly compiled irdash.exe as a library (no server, no live app) and runs at BelowNormal priority, so it is
# allowed while Peter races. Never reads a telemetry file written in the last 2 hours.
#   powershell -ExecutionPolicy Bypass -File tests\coach-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Check($what, $ok, $detail = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what"; if ($detail) { "        $detail" } } }
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$old = (Get-Date).AddHours(-2)

'1. compile without deploying and load the engine'
$build = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'dash\build.ps1') -NoDeploy | Out-String
$bm = [regex]::Match($build, 'built in (.+?) \(not deployed\)')
Check 'dash\build.ps1 -NoDeploy compiled (coach.cs is in $src)' $bm.Success
if (-not $bm.Success) { exit 1 }
$asm = [Reflection.Assembly]::LoadFile((Join-Path $bm.Groups[1].Value.Trim() 'irdash.exe'))
$bf = [Reflection.BindingFlags]'Static,Public,NonPublic'
$asm.GetType('IRDash.TrackMaps').GetField('TelemetryDir').SetValue($null, [string]$tel)
$asm.GetType('IRDash.Corners').GetField('DataRoot', $bf).SetValue($null, [string]$root)
$coach = $asm.GetType('IRDash.Analysis').GetMethod('Coach', $bf)
function Run($name) { $j = $coach.Invoke($null, [object[]]@([string](Join-Path $tel $name))); return [pscustomobject]@{ raw = $j; obj = ($j | ConvertFrom-Json) } }

'2. a long session with many clean laps (Corvette at Road Atlanta)'
$long = Get-ChildItem $tel -Filter 'chevyvettez06rgt3_roadatlanta*.ibt' | Where-Object { $_.LastWriteTime -lt $old } | Sort-Object Length -Descending | Select-Object -First 1
$r = Run $long.Name; $o = $r.obj
Check "the coach answers for $($long.Name): $($o.clean) clean laps, reference lap $($o.ref.lap) $($o.ref.time)" ($o.ok -and $o.ready -and $o.clean -ge 3 -and $o.ref.lap -gt 0) ($r.raw.Substring(0, [Math]::Min(400, $r.raw.Length)))
Check "at most three things to fix, biggest typical loss first ($(@($o.focus | ForEach-Object { "$($_.label) $($_.loss)" }) -join ', '))" (@($o.focus).Count -le 3 -and (@($o.focus).Count -lt 2 -or [double]$o.focus[0].loss -ge [double]$o.focus[1].loss))
foreach ($f in @($o.focus)) {
  "     $($f.label): $($f.loss) s typical, lost in $($f.lost) of $($f.laps) laps | $($f.facts -join ' | ') | $($f.say) | example lap $($f.example.lap) cue $($f.example.at) s, best lap cue $($f.best.at) s"
  Check "$($f.label): a repeated loss (>= 0.05 s, lost in at least half the laps and at least 2)" ([double]$f.loss -ge 0.05 -and $f.lost -ge [math]::Max(2, [math]::Ceiling($f.laps / 2)))
  Check "$($f.label): every fact is a measured difference in metres or mph, and there is one instruction" (@($f.facts | Where-Object { $_ -notmatch '^(Braking \d+ m (earlier|later) than the best lap|\d+ mph (slower|faster) (into the turn|at the slowest point|on the exit)|Throttle \d+ m later than the best lap)$' }).Count -eq 0 -and $f.say.Length -gt 0)
  Check "$($f.label): the video cues are inside their laps (or up to 3 s before the line, from the previous lap) (example $($f.example.at) s, best $($f.best.at) s)" ([double]$f.example.at -ge -3 -and [double]$f.example.at -lt [double]$f.example.time -and [double]$f.best.at -ge -3 -and [double]$f.best.at -lt [double]$o.ref.time)
  $first = if (@($f.facts).Count) { [string]$f.facts[0] } else { '' }
  $agree = ($f.code -eq '' -and @($f.facts).Count -eq 0) -or ($f.code -eq 'brake' -and $first -match '^Braking \d+ m earlier') -or ($f.code -eq 'pickup' -and $first -match '^Throttle \d+ m later than the best lap') -or ($f.code -in @('entry', 'min', 'exit') -and $first -match 'slower')
  $onlyLoss = @($f.facts | Where-Object { $_ -match 'faster|later than the best lap|Throttle \d+ m earlier' }).Count -eq 0
  Check "$($f.label): the facts agree with the instruction (its own fact is shown first, and every fact is a loss)" ($agree -and $onlyLoss)
}
$banned = '\b(you|your)\b|!|—'
Check 'the words follow COPY-RULES (no "you", no exclamation, no em dash)' ($r.raw -notmatch $banned)

'3. too few clean laps: never a refusal with nothing behind it (Peter 2026-10-18), and the words say it is only a hint'
Check 'the long session carries the drive summary too' ($o.summary -and [double]$o.summary.onTrackSec -gt 60 -and $o.mode -eq 'habit')
$short = Get-ChildItem $tel -Filter '*.ibt' | Where-Object { $_.LastWriteTime -lt $old -and $_.Length -lt 6MB -and $_.Length -gt 1MB } | Select-Object -First 8
$done = $false
foreach ($s in $short) {
  $q = Run $s.Name
  if ($q.obj.ok -and $q.obj.clean -lt 3) {
    $m = $q.obj.mode
    Check "a short session ($($s.Name), $($q.obj.clean) clean laps) is ready (mode $m) with the drive summary, not 'Not enough laps'" ($q.obj.ready -and $q.obj.summary -and $q.obj.reason -notmatch 'Not enough laps' -and $m -in @('two', 'pb', 'partial', 'drive'))
    if ($m -in @('two', 'pb', 'partial')) { Check "  its one comparison says it is a hint and names its reference ($($q.obj.hint))" ($q.obj.hint -match 'hint' -and $q.obj.ref.time -gt 0 -and @($q.obj.corners).Count -ge 1) }
    else { Check "  nothing comparable: it says why ($($q.obj.reason))" ($q.obj.reason.Length -gt 10) }
    $done = $true; break
  }
}
if (-not $done) { '  info  no short old session found to check the "too few laps" answer' }
$pz = Get-ChildItem $tel -Filter 'porsche718gt4_roadamerica 2026 full 2026-10-18 08-36-50.ibt' | Where-Object { $_.LastWriteTime -lt $old } | Select-Object -First 1
if ($pz) {
  $q = Run $pz.Name; $c = $q.obj
  Check "08-36-50 (no full lap): mode $($c.mode), part of lap $($c.lap.lap) $($c.lap.cover.text), $(@($c.corners).Count) corners against the best lap ever $($c.ref.time)" ($c.ready -and $c.mode -eq 'partial' -and $c.lap.partial -and [double]$c.lap.cover.toPct -gt 0.4 -and @($c.corners).Count -ge 3 -and $c.ref.kind -match 'best ever')
  Check '08-36-50: every fact on its cards is a measured difference (same wording rule as the habits)' (@($c.focus | ForEach-Object { $_.facts } | Where-Object { $_ -notmatch '^(Braking \d+ m (earlier|later) than the best lap|\d+ mph (slower|faster) (into the turn|at the slowest point|on the exit)|Throttle \d+ m later than the best lap)$' }).Count -eq 0)
  Check '08-36-50: the words follow COPY-RULES' ($q.raw -notmatch $banned)
}

"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
