# journey-check.ps1 - after a REAL session: drive -> recording -> the review of THAT session -> coach -> matching video.
# Read-only against the running irdash and the files on disk; changes nothing, saves nothing. Run it when the sim is
# closed (it refuses otherwise). Pictures of the WATCH cue frames: tests\shots\journey-*.jpg (look at them).
#   powershell -ExecutionPolicy Bypass -File tests\journey-check.ps1 [-Ibt "<file name>"]
param([string]$Ibt = '')
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot; $api = 'http://localhost:8199'; $shots = Join-Path $PSScriptRoot 'shots'
$pass = 0; $fail = 0
function Check($what, $ok, $detail = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what"; if ($detail) { "        $detail" } } }
function J($p) { Invoke-RestMethod ($api + $p) -TimeoutSec 120 }
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'

'1. the session: the newest telemetry file with laps'
if (-not $Ibt) { try { $Ibt = [string](J '/home').lastOuting.file } catch { } }   # the session HOME shows as the last outing
if (-not $Ibt) {
  foreach ($f in (Get-ChildItem $tel -Filter '*.ibt' | Sort-Object LastWriteTime -Descending | Select-Object -First 6)) {
    try { $c = J ('/analysis/coach?id=' + [uri]::EscapeDataString($f.Name)); if ($c.ok -and $c.clean -gt 0) { $Ibt = $f.Name; break } } catch { }
  }
}
Check "a recent session with clean laps: $Ibt" ($Ibt.Length -gt 0)
if (-not $Ibt) { "$pass passed, $fail failed."; exit 1 }
$e = [uri]::EscapeDataString($Ibt)

'2. its recording: the new sidecar, matched by session identity'
$rf = J "/api/rec/for?id=$e"
Check "the recording is VERIFIED for this telemetry file ($($rf.association), $($rf.id))" ($rf.ok -and $rf.association -eq 'verified' -and $rf.id)
if ($rf.id) {
  $sc = Get-ChildItem (Join-Path $root 'vault') -Recurse -Filter "$($rf.id).json" | Select-Object -First 1
  $j = Get-Content $sc.FullName -Raw | ConvertFrom-Json
  Check "sidecar schema 2 with session identity (uid $($j.uniqueId), session $($j.sessionNum)), length measured ($($j.durationSource)), state $($j.state), $(@($j.gaps).Count) gaps" ($j.schema -eq 2 -and $j.uniqueId -gt 0 -and $null -ne $j.sessionNum -and $j.durationSource -eq 'probe' -and $j.state -in @('ready', 'partial'))
  Check "every lap has a place in the video or an honest null ($(@($j.laps).Count) laps)" (@($j.laps | Where-Object { $_.offset -ne $null -and [double]$_.offset -lt 0 }).Count -eq 0)
}

'3. the review names the same session'
$d = J "/debrief?id=$e"
Check "the review answers for it ($(if ($d.race) { 'race' } else { 'practice' }))" ($d.ok -eq $true)
if ($rf.id -and $d.session) { Check "the review's session identity equals the recording's (uid $($d.session.uniqueId) / $($j.uniqueId), session $($d.session.sessionNum) / $($j.sessionNum))" ($d.session.uniqueId -eq $j.uniqueId -and $d.session.sessionNum -eq $j.sessionNum) }
Check "the review's SAVE target is this recording ($($d.bar.recId))" ($d.bar.recId -eq $rf.id)

'4. the coach and the matching footage'
$c = J "/analysis/coach?id=$e"
Check "the coach answers ($($c.clean) clean laps; $(if ($c.ready) { "$(@($c.focus).Count) things to fix" } else { $c.reason }))" ($c.ok)
$ff = Join-Path $root 'vault\bin\ffmpeg.exe'
if ($c.ready -and @($c.focus).Count -and $rf.id) {
  $mp4 = (Get-ChildItem (Join-Path $root 'vault') -Recurse -Filter "$($rf.id).mp4" | Select-Object -First 1).FullName
  $f0 = $c.focus[0]
  $offA = @($rf.laps | Where-Object { $_.n -eq $f0.example.lap })[0].offset; $offB = @($rf.laps | Where-Object { $_.n -eq $f0.best.lap })[0].offset
  Check "both laps of the first card have a place in the video (lap $($f0.example.lap) at $offA s, lap $($f0.best.lap) at $offB s)" ($null -ne $offA -and $null -ne $offB)
  if ($null -ne $offA -and $null -ne $offB) {
    $ta = [math]::Max(0, [double]$offA + [double]$f0.example.at); $tb = [math]::Max(0, [double]$offB + [double]$f0.best.at)
    & $ff -hide_banner -loglevel error -y -ss $ta -i $mp4 -frames:v 1 -vf "scale=960:-1" (Join-Path $shots 'journey-this-lap.jpg')
    & $ff -hide_banner -loglevel error -y -ss $tb -i $mp4 -frames:v 1 -vf "scale=960:-1" (Join-Path $shots 'journey-best-lap.jpg')
    Check "the WATCH cue frames come out of the video ($([math]::Round($ta,1)) s and $([math]::Round($tb,1)) s): tests\shots\journey-this-lap.jpg / journey-best-lap.jpg" ((Test-Path (Join-Path $shots 'journey-this-lap.jpg')) -and (Test-Path (Join-Path $shots 'journey-best-lap.jpg')))
    "        LOOK: both pictures should show the same place on track, 3 s before $($f0.label)."
  }
}

'5. HOME shows it as the last outing'
$h = J '/home'
Check "HOME's last outing is this file ($($h.lastOuting.file))" ($h.lastOuting.file -eq $Ibt)

"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
