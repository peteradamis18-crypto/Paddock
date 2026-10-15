# identity-test.ps1 - offline: which recording belongs to a telemetry session, and where a moment lands in the video.
# Compiles dash\src\sessmatch.cs on its own (no irdash, no live apps, safe while Peter races).
#   powershell -ExecutionPolicy Bypass -File tests\identity-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
$script:pass = 0; $script:fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Section($t) { $t }     # offline only: reads no telemetry, touches no live app, so no rig guard is needed between sections

$root = Split-Path -Parent $PSScriptRoot
$srcText = [IO.File]::ReadAllText((Join-Path $root 'dash\src\sessmatch.cs')).Replace('    sealed class RecCand', '    public sealed class RecCand').Replace('    static class SessMatch', '    public static class SessMatch')   # the irdash classes are internal; the test needs them public
Add-Type -TypeDefinition $srcText -Language CSharp -IgnoreWarnings -ErrorAction Stop
$h = 3600000.0; $m = 60000.0; $t0 = 1760000000000.0
# a recording: id, track, car, type, start, length in minutes (0 = an old sidecar with no end), identity
function Cand($id, $track, $car, $type, $startMs, $mins, $uid = -1, $sn = -99) {
  $c = New-Object IRDash.RecCand; $c.Id = $id; $c.Track = $track; $c.Car = $car; $c.Type = $type; $c.StartMs = $startMs
  $c.EndMs = $(if ($mins -gt 0) { $startMs + $mins * $m } else { 0 }); $c.UniqueId = $uid; $c.SessionNum = $sn; $c
}
function Pick($list, $uid, $sn, $track, $car, $type, $lapMs) {
  $l = New-Object 'System.Collections.Generic.List[IRDash.RecCand]'; foreach ($x in $list) { $l.Add($x) }
  $a = ''; $p = [IRDash.SessMatch]::Pick($l, $uid, $sn, $track, $car, $type, $lapMs, [ref]$a)
  [pscustomobject]@{ id = $(if ($p) { $p.Id } else { $null }); assoc = $a }
}
function W2F($st, $en, $at) { [IRDash.SessMatch]::WallToFile([double[]]$st, [double[]]$en, $at) }

Section '1. a moment the video does not have is NaN (never a later picture)'
# three 10 s segments, the middle one gone: the file holds 0-10 s and 20-30 s of wall time
$st = @($t0, ($t0 + 20000)); $en = @(($t0 + 10000), ($t0 + 30000))
Check 'a lap starting 5 s in maps to 5.000 s' ((W2F $st $en ($t0 + 5000)) -eq 5.0)
Check 'a lap starting 15 s in (inside the missing segment) maps to NaN' ([double]::IsNaN((W2F $st $en ($t0 + 15000))))
Check 'a lap starting 25 s in maps to 15.000 s (the file has skipped the gap)' ((W2F $st $en ($t0 + 25000)) -eq 15.0)
Check 'the segment edges are inside (frame-exact at both ends)' ((W2F $st $en ($t0 + 10000)) -eq 10.0 -and (W2F $st $en ($t0 + 20000)) -eq 10.0)
Check 'a lap starting 2 s before the first picture (encoder start-up) shows the first picture' ((W2F $st $en ($t0 - 2000)) -eq 0.0)
Check 'a lap starting 18 s in (2 s before the next span) shows that span''s first picture' ((W2F $st $en ($t0 + 18000)) -eq 10.0)
Check 'a lap starting 10 s before the recording -> NaN' ([double]::IsNaN((W2F $st $en ($t0 - 10000))))
Check 'after the recording -> NaN' ([double]::IsNaN((W2F $st $en ($t0 + 30001))))

Section '2. the holes are listed: recorded but missing segments, merged where they touch'
$as = [double[]]@($t0, ($t0 + 10000), ($t0 + 20000), ($t0 + 30000), ($t0 + 40000))
$ae = [double[]]@(($t0 + 10000), ($t0 + 20000), ($t0 + 30000), ($t0 + 40000), ($t0 + 50000))
$gaps = [IRDash.SessMatch]::MissingSpans($as, $ae, [bool[]]@($true, $false, $false, $true, $false))
Check 'two gaps: 10-30 s (two segments merged) and 40-50 s' ($gaps.Count -eq 2 -and $gaps[0][0] -eq ($t0 + 10000) -and $gaps[0][1] -eq ($t0 + 30000) -and $gaps[1][0] -eq ($t0 + 40000))
Check 'nothing missing -> no gaps' (([IRDash.SessMatch]::MissingSpans($as, $ae, [bool[]]@($true, $true, $true, $true, $true))).Count -eq 0)

Section '3. the recording of THIS session: same iRacing ids AND the lap driven while it ran'
$vault = @(
  (Cand 'a-gt3'   'Road America' 'BMW M4 GT3' 'Practice'   ($t0)          25 2 0),   # two launches, same track, one hour, same per-launch ids
  (Cand 'a-mx5'   'Road America' 'Mazda MX-5' 'Practice'   ($t0 + 0.5*$h) 25 2 0),
  (Cand 'w-q'     'Spa'          'BMW M4 GT3' 'Qualifying' ($t0 + 2.6*$h) 15 3 1),   # one weekend: qualifying, race
  (Cand 'w-r'     'Spa'          'BMW M4 GT3' 'Race'       ($t0 + 3*$h)   45 3 2),
  (Cand 'nurb-gp' 'Nurburgring GP' 'BMW M4 GT3' 'Practice' ($t0 + 5*$h)   20 4 0),
  (Cand 'nurb-ns' 'Nurburgring Nordschleife' 'BMW M4 GT3' 'Practice' ($t0 + 5.5*$h) 20 5 0)
)
$r = Pick $vault 2 0 'Road America' '' 'Practice' ($t0 + 10*$m)
Check 'two launches with the same ids (2/0) at one track: the lap at 0:10 gets the first recording (verified)' ($r.id -eq 'a-gt3' -and $r.assoc -eq 'verified')
$r = Pick $vault 2 0 'Road America' '' 'Practice' ($t0 + 40*$m)
Check '... the lap at 0:40 gets the second one' ($r.id -eq 'a-mx5' -and $r.assoc -eq 'verified')
$r = Pick $vault 3 1 'Spa' '' 'Qualifying' ($t0 + 2.7*$h)
Check 'same weekend: SessionNum 1 gets qualifying' ($r.id -eq 'w-q' -and $r.assoc -eq 'verified')
$r = Pick $vault 3 2 'Spa' '' 'Race' ($t0 + 3.5*$h)
Check 'SessionNum 2 gets the race' ($r.id -eq 'w-r')
$r = Pick $vault 3 2 'Spa' '' 'Race' ($t0 + 2.7*$h)
Check 'right ids but a lap outside the race recording -> nothing' ($null -eq $r.id)
$r = Pick $vault 4 0 'Nurburgring' '' 'Practice' ($t0 + 5.2*$h)
Check 'two configurations: the GP lap gets the GP recording' ($r.id -eq 'nurb-gp')
$r = Pick $vault 9 0 'Spa' '' 'Qualifying' ($t0 + 2.7*$h)
Check 'other ids during a recording that knows its own ids -> none (never a same-track neighbour)' ($null -eq $r.id -and $r.assoc -eq 'none')
$r = Pick $vault 3 1 'Spa' '' 'Qualifying' 0
Check 'no lap time -> none' ($null -eq $r.id)
$days = @((Cand 'mon' 'Spa' 'BMW M4 GT3' 'Practice' ($t0) 60 2 1), (Cand 'tue' 'Spa' 'BMW M4 GT3' 'Practice' ($t0 + 24*$h) 60 2 1))
$r = Pick $days 2 1 'Spa' '' 'Practice' ($t0 + 24.5*$h)
Check 'SessionUniqueID repeats across days (2/1 Monday and Tuesday): Tuesday''s lap gets Tuesday''s recording' ($r.id -eq 'tue' -and $r.assoc -eq 'verified')
$r = Pick @($days[0]) 2 1 'Spa' '' 'Practice' ($t0 + 24.5*$h)
Check 'Tuesday''s recording deleted: Monday''s is NOT offered for Tuesday''s lap (the reviewer''s case)' ($null -eq $r.id)
$r = Pick $days 2 1 'Lime Rock' '' 'Practice' ($t0 + 24.5*$h)
Check 'same ids and time but another track -> none' ($null -eq $r.id)

Section '4. old sidecars without identity: probable at best, only for a lap inside them'
$legacy = @(
  (Cand 'old-1' 'Spa' 'BMW M4 GT3' 'Practice' ($t0) 0),
  (Cand 'old-2' 'Spa' 'BMW M4 GT3' 'Practice' ($t0 + 4*$h) 0),
  (Cand 'old-3' 'Spa' 'Porsche 911 GT3 R' 'Practice' ($t0 + 0.1*$h) 0)
)
$r = Pick $legacy 7000 0 'Spa' 'BMW M4 GT3' 'Practice' ($t0 + 0.2*$h)
Check 'same track/car/type with the lap inside it -> probable (old-1), not the newer old-2, not the other car' ($r.id -eq 'old-1' -and $r.assoc -eq 'probable')
$r = Pick $legacy 7000 0 'Spa' 'BMW M4 GT3' 'Race' ($t0 + 0.2*$h)
Check 'a different session type never matches a legacy sidecar' ($null -eq $r.id)
$r = Pick $legacy 7000 0 'Spa' 'BMW M4 GT3' 'Practice' ($t0 + 10*$h)
Check 'a lap long after every recording -> none' ($null -eq $r.id -and $r.assoc -eq 'none')

"$($script:pass) passed, $($script:fail) failed."
if ($script:fail -gt 0) { exit 1 }
