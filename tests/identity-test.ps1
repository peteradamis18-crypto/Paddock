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
function Cand($id, $track, $car, $type, $startMs, $uid = -1, $sn = -99) {
  $c = New-Object IRDash.RecCand; $c.Id = $id; $c.Track = $track; $c.Car = $car; $c.Type = $type; $c.StartMs = $startMs; $c.UniqueId = $uid; $c.SessionNum = $sn; $c
}
function Pick($list, $uid, $sn, $track, $car, $type, $start) {
  $l = New-Object 'System.Collections.Generic.List[IRDash.RecCand]'; foreach ($x in $list) { $l.Add($x) }
  $a = ''; $p = [IRDash.SessMatch]::Pick($l, $uid, $sn, $track, $car, $type, $start, [ref]$a)
  [pscustomobject]@{ id = $(if ($p) { $p.Id } else { $null }); assoc = $a }
}
$h = 3600000.0; $t0 = 1760000000000.0

Section '1. a moment inside a missing segment has no video (never the next picture)'
# three 10 s segments, the middle one gone: the file holds 0-10 s and 20-30 s of wall time
$st = [double[]]@($t0, ($t0 + 20000)); $en = [double[]]@(($t0 + 10000), ($t0 + 30000))
Check 'a lap starting 5 s in maps to 5.000 s' ([IRDash.SessMatch]::WallToFile($st, $en, $t0 + 5000) -eq 5.0)
Check 'a lap starting 15 s in (inside the gap) maps to NaN' ([double]::IsNaN([IRDash.SessMatch]::WallToFile($st, $en, $t0 + 15000)))
Check 'a lap starting 25 s in maps to 15.000 s (the file has skipped the gap)' ([IRDash.SessMatch]::WallToFile($st, $en, $t0 + 25000) -eq 15.0)
Check 'before the recording -> NaN' ([double]::IsNaN([IRDash.SessMatch]::WallToFile($st, $en, $t0 - 1)))
Check 'after the recording -> NaN' ([double]::IsNaN([IRDash.SessMatch]::WallToFile($st, $en, $t0 + 30001)))
Check 'the segment edges are inside (frame-exact at both ends)' ([IRDash.SessMatch]::WallToFile($st, $en, $t0 + 10000) -eq 10.0 -and [IRDash.SessMatch]::WallToFile($st, $en, $t0 + 20000) -eq 10.0)

Section '2. the holes are listed: recorded but missing segments, merged where they touch'
$as = [double[]]@($t0, ($t0 + 10000), ($t0 + 20000), ($t0 + 30000), ($t0 + 40000))
$ae = [double[]]@(($t0 + 10000), ($t0 + 20000), ($t0 + 30000), ($t0 + 40000), ($t0 + 50000))
$gaps = [IRDash.SessMatch]::MissingSpans($as, $ae, [bool[]]@($true, $false, $false, $true, $false))
Check 'two gaps: 10-30 s (two segments merged) and 40-50 s' ($gaps.Count -eq 2 -and $gaps[0][0] -eq ($t0 + 10000) -and $gaps[0][1] -eq ($t0 + 30000) -and $gaps[1][0] -eq ($t0 + 40000))
Check 'nothing missing -> no gaps' (([IRDash.SessMatch]::MissingSpans($as, $ae, [bool[]]@($true, $true, $true, $true, $true))).Count -eq 0)

Section '3. the recording of THIS session, by iRacing session identity'
$vault = @(
  (Cand 'a-gt3'   'Road America' 'BMW M4 GT3'      'Practice'   ($t0)          9001 0),
  (Cand 'a-mx5'   'Road America' 'Mazda MX-5'      'Practice'   ($t0 + 0.5*$h) 9002 0),   # two cars, same track, one hour
  (Cand 'w-p'     'Spa'          'BMW M4 GT3'      'Practice'   ($t0 + 2*$h)   7000 0),   # one weekend: practice, qualifying, race
  (Cand 'w-q'     'Spa'          'BMW M4 GT3'      'Qualifying' ($t0 + 3*$h)   7000 1),
  (Cand 'w-r'     'Spa'          'BMW M4 GT3'      'Race'       ($t0 + 3.5*$h) 7000 2),
  (Cand 'nurb-gp' 'Nurburgring GP' 'BMW M4 GT3'    'Practice'   ($t0 + 5*$h)   8000 0),   # two configs of one venue
  (Cand 'nurb-ns' 'Nurburgring Nordschleife' 'BMW M4 GT3' 'Practice' ($t0 + 6*$h) 8100 0)
)
$r = Pick $vault 9001 0 'Road America' 'BMW M4 GT3' 'Practice' ($t0 + 0.4*$h)
Check 'two cars at one track in one hour: the GT3 session gets the GT3 recording (verified)' ($r.id -eq 'a-gt3' -and $r.assoc -eq 'verified')
$r = Pick $vault 7000 1 'Spa' '' 'Qualifying' ($t0 + 2*$h)
Check 'same weekend: SessionNum 1 gets qualifying, not the newer race' ($r.id -eq 'w-q' -and $r.assoc -eq 'verified')
$r = Pick $vault 7000 2 'Spa' '' 'Race' ($t0 + 2*$h)
Check 'SessionNum 2 gets the race' ($r.id -eq 'w-r')
$r = Pick $vault 8000 0 'Nurburgring' '' 'Practice' ($t0 + 6*$h)
Check 'two configurations: the GP session gets the GP recording even when the Nordschleife one is nearer in time' ($r.id -eq 'nurb-gp')
$r = Pick $vault 9002 0 'Road America' '' 'Practice' ($t0 + 0.5*$h)
Check 'a historical review after newer drives still gets its own recording' ($r.id -eq 'a-mx5')
$r = Pick $vault 5555 0 'Spa' '' 'Practice' ($t0 + 2*$h)
Check 'a session with no recording -> none (never the newest, never a same-track neighbour that knows its own identity)' ($null -eq $r.id -and $r.assoc -eq 'none')

$days = @((Cand 'mon' 'Spa' 'BMW M4 GT3' 'Practice' ($t0) 2 1), (Cand 'tue' 'Spa' 'BMW M4 GT3' 'Practice' ($t0 + 24*$h) 2 1), (Cand 'tue-lime' 'Lime Rock' 'BMW M4 GT3' 'Practice' ($t0 + 24.2*$h) 2 1))
$r = Pick $days 2 1 'Spa' '' 'Practice' ($t0 + 24.1*$h)
Check 'SessionUniqueID repeats across sim launches (2 / 1 on Monday and Tuesday): Tuesday''s telemetry gets Tuesday''s recording' ($r.id -eq 'tue' -and $r.assoc -eq 'verified')
$r = Pick $days 2 1 'Spa' '' 'Practice' ($t0 + 72*$h)
Check 'the same ids three days later match nothing' ($null -eq $r.id)
$r = Pick $days 2 1 'Lime Rock' '' 'Practice' ($t0 + 24.1*$h)
Check 'the same ids at another track the same day do not cross over' ($r.id -eq 'tue-lime')
$r = Pick $days 2 1 'Spa' '' 'Practice' 0
Check 'ids without a start time are not enough' ($null -eq $r.id)

Section '4. old sidecars without identity: probable at best, never newest-wins'
$legacy = @(
  (Cand 'old-1' 'Spa' 'BMW M4 GT3' 'Practice' ($t0)),
  (Cand 'old-2' 'Spa' 'BMW M4 GT3' 'Practice' ($t0 + 4*$h)),
  (Cand 'old-3' 'Spa' 'Porsche 911 GT3 R' 'Practice' ($t0 + 0.1*$h))
)
$r = Pick $legacy 7000 0 'Spa' 'BMW M4 GT3' 'Practice' ($t0 + 0.2*$h)
Check 'nearest same track/car/type within 2 h -> probable (old-1), not the newer old-2, not the other car' ($r.id -eq 'old-1' -and $r.assoc -eq 'probable')
$r = Pick $legacy 7000 0 'Spa' 'BMW M4 GT3' 'Race' ($t0 + 0.2*$h)
Check 'a different session type never matches a legacy sidecar' ($null -eq $r.id)
$r = Pick $legacy 7000 0 'Spa' 'BMW M4 GT3' 'Practice' ($t0 + 10*$h)
Check 'more than 2 h away -> none' ($null -eq $r.id -and $r.assoc -eq 'none')
$r = Pick $legacy -1 -1 'Spa' 'BMW M4 GT3' 'Practice' 0
Check 'no identity and no start time -> none (the old code picked the newest here)' ($null -eq $r.id)

"$($script:pass) passed, $($script:fail) failed."
if ($script:fail -gt 0) { exit 1 }
