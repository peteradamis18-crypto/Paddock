# C-30 lap analysis engines (docs\DESIGN-analysis.md section 7.1-7.5) and C-34 corner deep-dive engines
# (dash\src\deepdive.cs, /analysis/deep). Offline only: copies of old .ibt files, never the newest, never iRacing's own
# folder. Compiles with dash\build.ps1 -NoDeploy and runs that exe's --analysis command (--deep for C-34), so nothing is
# deployed and no window opens. Out of the car only (tests\guard.ps1).
#   powershell -ExecutionPolicy Bypass -File tests\analysis-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree

$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; Write-Host "  ok    $what" } else { $script:fail++; Write-Host "  FAIL  $what" } }
function Note($what) { Write-Host "  info  $what" }
function Near($a, $b, $tol) { [math]::Abs([double]$a - [double]$b) -le $tol }
# Time over a steady stretch should match distance / speed. A start/finish wrap makes the first or last
# 80 m much quicker than the car was going.
function TimeMatchesSpeed($path, $i0, $i1) {
  $lines = Get-Content -LiteralPath $path
  $p0 = $lines[$i0].Split(',')
  $p1 = $lines[$i1].Split(',')
  $dt = [math]::Abs([double]$p1[0] - [double]$p0[0])
  $spd = ([double]$p0[1] + [double]$p1[1]) / 2
  if ($spd -lt 5) { return $false }
  $expect = [math]::Abs($i1 - $i0) / $spd
  return ([math]::Abs($dt - $expect) / $expect) -le 0.10
}
function Section($title) { Assert-RigFree -Where $title; Write-Host $title }

# Hand check for the lead, once. Road Atlanta, Chevrolet Corvette Z06 GT3.R, file 2026-10-10 00-13-18.
# Lap 7 is the PB, 79.549 s. Lap 8 is 79.878 s. The biggest loss is T1: the corner took 7.850 s, which is
# 0.236 s slower. No cause sentence: he braked 88 m later, got on the throttle 41 m later, and was 9.67 km/h
# slower 100 m after the apex, and the 0.189 s after the apex has two of those at once.
# A sentence that does qualify, file 2026-10-10 15-11-47 lap 1 against that PB: T12,
# "Exit speed 14 km/h lower and lost 0.09 s on the way out." (0.007 s on the way in, throttle unchanged).
$pbName = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt'
$midName = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 13-28-11.ibt'
$shortName = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 15-11-47.ibt'
$want = @($pbName, $midName, $shortName)

$me = Get-Process -Id $PID
$me.PriorityClass = 'BelowNormal'
$cores = [Environment]::ProcessorCount
if ($cores -gt 2) {
  $mask = [int64]0
  for ($i = 0; $i -lt 2; $i++) { $mask = $mask -bor ([int64]1 -shl ($cores - 1 - $i)) }
  $me.ProcessorAffinity = [IntPtr]$mask
}

# L-1: an independent reader of the raw records (nothing of Paddock's code) for "did iRacing count this lap". iRacing's own best lap of the session (LapBestLapTime) is the
# evidence, read at the last record of the lap and 1.5 to 2.5 s after the line: a lap quicker than the best so far that BECAME the best was counted (whatever the off-track
# record says), a quicker lap that left the best unchanged was not; a lap not quicker than the best so far gives no evidence and any off-track record (PlayerTrackSurface 0) decides.
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.IO; using System.Text;
public static class LapRaw {
  static Dictionary<string,int> Vars(byte[] b) {
    int nv = BitConverter.ToInt32(b, 24), vho = BitConverter.ToInt32(b, 28); var v = new Dictionary<string,int>();
    for (int i = 0; i < nv; i++) { int p = vho + 144 * i; v[Encoding.ASCII.GetString(b, p + 16, 32).Trim('\0')] = BitConverter.ToInt32(b, p + 4); }
    return v;
  }
  public static bool Counted(string file, int lap, double time) {
    byte[] b = File.ReadAllBytes(file); var v = Vars(b);
    int bl = BitConverter.ToInt32(b, 36), bo = BitConverter.ToInt32(b, 52), rc = (b.Length - bo) / bl, first = -1; bool off = false;
    for (int r = 0; r < rc; r++) { int s = bo + r * bl; if (BitConverter.ToInt32(b, s + v["Lap"]) == lap && b[s + v["IsOnTrack"]] != 0 && BitConverter.ToInt32(b, s + v["PlayerTrackSurface"]) == 0) { off = true; break; } }
    for (int r = 0; r < rc; r++) { int s = bo + r * bl; if (BitConverter.ToInt32(b, s + v["Lap"]) == lap + 1 && b[s + v["IsOnTrack"]] != 0) { first = r; break; } }
    if (first < 1) return false;
    double before = BitConverter.ToSingle(b, bo + (first - 1) * bl + v["LapBestLapTime"]); if (before <= 1) before = -1;
    double best = -1;
    for (int r = first + 90; r < Math.Min(rc, first + 150); r++) { double x = BitConverter.ToSingle(b, bo + r * bl + v["LapBestLapTime"]); if (x > 1 && (best < 0 || x < best)) best = x; }
    bool faster = before <= 0 || time < before - 0.0015;
    if (faster) return best > 0 && best <= time + 0.0015;
    return !off;
  }
  public static double BestLap(string file) {
    byte[] b = File.ReadAllBytes(file); var v = Vars(b);
    int bl = BitConverter.ToInt32(b, 36), bo = BitConverter.ToInt32(b, 52), rc = (b.Length - bo) / bl; double best = -1;
    for (int r = 0; r < rc; r++) { double x = BitConverter.ToSingle(b, bo + r * bl + v["LapBestLapTime"]); if (x > 15 && (best < 0 || x < best)) best = x; }
    return best;
  }
}
'@

$shipped = Join-Path $root 'dash\irdash.exe'
$shippedStamp = (Get-Item -LiteralPath $shipped).LastWriteTimeUtc.Ticks
$srcDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$work = Join-Path $env:TEMP ('analysis-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$outDir = Join-Path $work 'out'
try {
  Section 'copies of three old laps'
  New-Item -ItemType Directory -Force $work, $outDir | Out-Null
  $newest = Get-ChildItem -LiteralPath $srcDir -Filter '*.ibt' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  Check 'the newest telemetry file is not one of the three copies' ($want -notcontains $newest.Name)
  foreach ($n in $want) {
    $from = Join-Path $srcDir $n
    Check "the old file is still there: $n" (Test-Path -LiteralPath $from)
    if ((Test-Path -LiteralPath $from) -and $n -ne $newest.Name) { Copy-Item -LiteralPath $from -Destination (Join-Path $work $n) }
  }

  Section 'compile without deploying'
  $build = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'dash\build.ps1') -NoDeploy | Out-String
  $m = [regex]::Match($build, 'built in (.+?) \(not deployed\)')
  Check 'dash\build.ps1 -NoDeploy compiled' ($LASTEXITCODE -eq 0 -and $m.Success)
  if (-not $m.Success) { throw $build }
  $exe = Join-Path $m.Groups[1].Value.Trim() 'irdash.exe'

  function Invoke-Analysis($id, $lap, $ref, $tag) {
    $out = Join-Path $outDir "$tag.json"
    $dump = Join-Path $outDir "$tag.txt"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = "--analysis --root `"$root`" --dir `"$work`" --id `"$id`" --lap $lap --ref `"$ref`" --out `"$out`" --dump `"$dump`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit(240000)) { try { $proc.Kill() } catch { }; throw "analysis $tag timed out" }
    if ($proc.ExitCode -ne 0) { throw "analysis $tag failed: $(Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue)" }
    Write-Host "  ok    analysis $tag ran"
    $script:pass++
    return ,@(Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json)
  }

  Section 'lap 8 against the PB'
  $a = Invoke-Analysis $pbName 8 'pb' 'lap8a'
  $b = Invoke-Analysis $pbName 8 'pb' 'lap8b'
  Check 'the lap is the Corvette at Road Atlanta' ($a.car -eq 'Chevrolet Corvette Z06 GT3.R' -and $a.track -eq 'Road Atlanta' -and $a.config -eq 'Full Course')
  Check 'lap 8 is clean and 79.878 s' ($a.clean -eq $true -and (Near $a.official 79.878 0.001) -and (Near $a.time 79.878 0.001))
  Check 'the reference is the PB lap 7 at 79.549 s, not lap 8' ($a.ref.kind -eq 'pb' -and $a.ref.same -eq $false -and $a.ref.lap -eq 7 -and $a.ref.file -eq $pbName -and (Near $a.ref.time 79.549 0.001))
  $sum = 0.0
  foreach ($c in $a.corners) { $sum += [double]$c.time }
  foreach ($s in $a.straights) { $sum += [double]$s }
  Check 'corner times plus straights equal the lap time within 0.05 s' (Near $sum $a.time 0.05)
  $mini = 0.0; foreach ($x in $a.mini) { $mini += [double]$x }
  Check '24 mini-sectors add up to the lap' ($a.mini.Count -eq 24 -and (Near $mini $a.time 0.05))
  $sec = 0.0; foreach ($x in $a.sectors) { $sec += [double]$x }
  $at = @($a.sectorAt)
  Check 'sectors come from the session YAML, not equal thirds' ($a.sectorFrom -eq 'yaml' -and $at.Count -eq 4 -and (Near $at[1] 0.167875 0.0001) -and (Near $at[2] 0.442307 0.0001) -and (Near $at[3] 0.787105 0.0001) -and (Near $sec $a.time 0.05))
  $h1 = (Get-FileHash -LiteralPath (Join-Path $outDir 'lap8a.txt') -Algorithm SHA256).Hash
  $h2 = (Get-FileHash -LiteralPath (Join-Path $outDir 'lap8b.txt') -Algorithm SHA256).Hash
  Check 'resampling the same lap twice is identical' ($h1 -eq $h2 -and $h1.ToLower() -eq $a.sig -and $a.sig -eq $b.sig -and $a.metres -eq $b.metres)
  Check 'the distance drift of this lap is within half a percent' ($a.driftOk -eq $true)
  Check 'corner names keep the Lovely credit' ($a.credit -like '*Lovely Track Data*')
  $top = $a.corners | Sort-Object { [double]$_.dTime } -Descending | Select-Object -First 1
  Note "HAND CHECK lap 8 vs PB 79.549: biggest loss $($top.label), corner $($top.time) s, lost $($top.dTime) s, cause: $(if ($top.cause) { $top.cause } else { '(none)' })"
  Check 'the biggest loss is T1, 7.850 s, lost 0.236 s' ($top.label -eq 'T1' -and (Near $top.time 7.850 0.001) -and (Near $top.dTime 0.236 0.001))
  Check 'T1 has no cause sentence (brake, throttle and exit all moved)' ($top.cause -eq '' -and $top.causeCode -eq 'ambiguous' -and (Near $top.dBrakeM 88 0.01) -and (Near $top.dPickupM 41 0.01) -and (Near $top.dExitKmh -9.67 0.01))
  $quiet = @($a.corners | Where-Object { -not $_.cause })
  Check 'at least one corner produces no sentence' ($quiet.Count -ge 1)
  $smallTalk = @($a.corners | Where-Object { [math]::Abs([double]$_.dTime) -lt 0.05 -and $_.cause })
  Check 'a corner under 0.05 s has no sentence' ($smallTalk.Count -eq 0)
  # L-1: the pool the statistics are counted from is the laps iRacing counted (4 in these 3 files: 79.549, 79.575, 79.878, 79.931). Before, it was every timed lap (18 clean laps).
  Check 'the optimal lap is 78.704 s (the 24 mini-sectors joined over the counted laps), which is at or under the PB' ((Near $a.store.optimal 78.704 0.001) -and ([double]$a.store.optimal -le [double]$a.store.pb.time + 0.001) -and (Near $a.store.pb.time 79.549 0.001))
  Check 'the best equal thirds are 79.269, the lead check against the 79.549 PB' ((Near $a.store.thirdBest 79.269 0.001) -and ([double]$a.store.thirdBest -le [double]$a.store.pb.time + 0.001))
  Check 'the best iRacing sectors are 79.162, and the mini-sector optimal is not above them' ((Near $a.store.sectorBest 79.162 0.001) -and ([double]$a.store.optimal -le [double]$a.store.sectorBest + 0.001))
  Check 'the quickest mini-sector is still a speed the car can reach' ([double]$a.store.miniMin -ge 2.1)
  $dump8 = Join-Path $outDir 'lap8a.txt'
  $n8 = @(Get-Content -LiteralPath $dump8).Count
  Check 'the first and last 80 m are not shortened by the start/finish wrap' ((TimeMatchesSpeed $dump8 0 80) -and (TimeMatchesSpeed $dump8 ($n8 - 81) ($n8 - 1)))
  Check 'the goal line is produced' ($a.store.goal -eq 'Next: 1:19.1 in best corners (T7 0.21, T10b 0.20, T6 0.05)')
  Check 'consistency is the best against the average of the counted laps (4: 79.549, 79.575, 79.878, 79.931 = 79.733, spread 0.382)' ($a.store.consistency.n -eq 4 -and (Near $a.store.consistency.best 79.549 0.001) -and ([double]$a.store.consistency.avg5 -ge [double]$a.store.consistency.best) -and ([double]$a.store.consistency.spread -ge 0) -and (Near $a.store.consistency.avg5 ((79.549 + 79.575 + 79.878 + 79.931) / 4) 0.001) -and (Near $a.store.consistency.spread (79.931 - 79.549) 0.001))
  Check 'the store read all three files and counted 4 laps iRacing counted' ($a.store.files -eq 3 -and $a.store.cleanLaps -eq 4)
  $skips = @($a.laps | Where-Object { -not $_.clean } | ForEach-Object { $_.skip })
  Check 'pit, in, off and partial laps are skipped' (($skips -contains 'pit') -and ($skips -contains 'in') -and ($skips -contains 'off') -and ($skips -contains 'partial'))

  Section 'the lap against itself, and the PB against the next best'
  $self = Invoke-Analysis $pbName 8 ($pbName + ':8') 'self'
  $max = 0.0
  foreach ($c in $self.corners) {
    foreach ($k in @('dTime', 'dIn', 'dOut', 'dBrakeM', 'dEntryKmh', 'dMinKmh', 'dPickupM', 'dExitKmh')) {
      if ($null -ne $c.$k -and [math]::Abs([double]$c.$k) -gt $max) { $max = [math]::Abs([double]$c.$k) }
    }
  }
  Check 'the lap versus itself is 0.00 everywhere and says nothing' ($self.ref.same -eq $true -and $max -lt 0.001 -and @($self.corners | Where-Object { $_.cause }).Count -eq 0)
  $p7 = Invoke-Analysis $pbName 7 'pb' 'lap7'
  Check 'the PB is not compared with itself' ($p7.official -and (Near $p7.official 79.549 0.001) -and $p7.ref.same -eq $false -and -not ($p7.ref.file -eq $pbName -and $p7.ref.lap -eq 7))
  Check 'the next best is the afternoon file lap 7 at 79.575 s' ($p7.ref.file -eq $midName -and $p7.ref.lap -eq 7 -and (Near $p7.ref.time 79.575 0.001))

  Section 'session best, optimal, and one real cause sentence'
  $mid = Invoke-Analysis $midName 1 'session' 'mid'
  Check 'session best stays in that file and is not the lap itself' ($mid.ref.kind -eq 'session' -and $mid.ref.same -eq $false -and $mid.ref.file -eq $midName -and $mid.store.sessionBest.file -eq $midName -and (Near $mid.store.sessionBest.time 79.575 0.001))
  Check 'the PB of the car and track is still the morning 79.549' ($mid.store.pb.file -eq $pbName -and $mid.store.pb.lap -eq 7 -and (Near $mid.store.pb.time 79.549 0.001))
  $opt = Invoke-Analysis $pbName 8 'optimal' 'opt'
  Check 'ref=optimal is the joined mini-sectors' ($opt.ref.kind -eq 'optimal' -and (Near $opt.ref.time $a.store.optimal 0.001) -and $opt.ref.same -eq $false)
  $short = Invoke-Analysis $shortName 1 'pb' 'short'
  $t12 = $short.corners | Where-Object { $_.label -eq 'T12' }
  Note "HAND CHECK 15-11-47 lap 1 vs PB: T12 $($t12.cause)"
  Check 'T12 says the exit speed, and only that' ($t12.cause -eq 'Exit speed 14 km/h lower and lost 0.09 s on the way out.' -and $t12.causeCode -eq 'exit' -and (Near $t12.dTime 0.099 0.001) -and (Near $t12.dIn 0.007 0.001) -and (Near $t12.dOut 0.092 0.001) -and (Near $t12.dExitKmh -14.14 0.01) -and (Near $t12.dPickupM 0 0.01))
  Check 'that file still has a corner with no sentence' (@($short.corners | Where-Object { -not $_.cause }).Count -ge 1)

  # ================= C-34 corner deep-dive engines (dash\src\deepdive.cs) =================
  # Every number below was checked once by hand on 2026-10-11 against the file's raw 60 Hz records (a separate script that
  # reads the records itself, with no code from the engine); the raw figure is in each comment. The engine works on a 1 m grid,
  # so the tolerances are the grid's, not slack. Copies come from vault\telemetry (older than any file iRacing is writing).
  # Corvette Z06 GT3.R, Road Atlanta, file 2026-10-10 00-13-18: lap 8 (79.878 s) against the PB lap 7 (79.549 s).
  Section 'deep dive: copies of two vault files'
  $vault = Join-Path $root 'vault\telemetry'
  $vid = '2026-10-10 00-13-18.ibt'; $fid = '2026-10-10 22-29-06.ibt'; $wid = '2026-10-06 21-26-58.ibt'
  $vetteDir = Join-Path $vault 'chevrolet-corvette-z06-gt3-r\road-atlanta-full-course'
  $ferSrc = Join-Path $vault 'ferrari-296-gt3\sebring-international-raceway-international'
  # L-1: the Vault keeps copies only of laps iRacing counted, so a copy can disappear (21-26-58's only keeper was an uncounted lap); the same untouched file then comes from the telemetry folder
  function Fix($dir, $stamp, $prefix) { $v = Join-Path $dir $stamp; if (Test-Path -LiteralPath $v) { return $v }; return (Join-Path $srcDir ($prefix + $stamp)) }
  $pVid = Fix $vetteDir $vid 'chevyvettez06rgt3_roadatlanta full '; $pWid = Fix $vetteDir $wid 'chevyvettez06rgt3_roadatlanta full '; $pFid = Fix $ferSrc $fid 'ferrari296gt3_sebring international '
  Check 'the three real files are there (the vault''s copy, else the original in the telemetry folder)' ((Test-Path -LiteralPath $pVid) -and (Test-Path -LiteralPath $pWid) -and (Test-Path -LiteralPath $pFid))
  $d1 = Join-Path $work 'deep-corvette'; $dF = Join-Path $work 'deep-ferrari'; $dW = Join-Path $work 'deep-wear'; $dP = Join-Path $work 'deep-patched'
  New-Item -ItemType Directory -Force $d1, $dF, $dW, $dP | Out-Null
  Copy-Item -LiteralPath $pVid -Destination (Join-Path $d1 $vid)
  Copy-Item -LiteralPath $pFid -Destination (Join-Path $dF $fid)
  Copy-Item -LiteralPath $pWid -Destination (Join-Path $dW $wid)

  # ================= L-1: the PB / session reference is a lap iRacing COUNTED (analysis.cs LapRules) =================
  # 2026-10-06 21-26-58: iRacing timed 10 laps; lap 3 (79.897) and lap 15 (80.161) have an off-track record, so iRacing did not count them (its own best lap of the
  # file stays 80.228, lap 14). Before the rule the "PB" reference of that file was the uncounted 79.897 lap.
  Section 'L-1: the reference is a lap iRacing counted'
  $wLaps = @{}
  foreach ($ln in 3, 6, 8, 14, 15) {
    $o = Join-Path $outDir "wl$ln.json"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe; $psi.Arguments = "--analysis --root `"$root`" --dir `"$dW`" --id `"$wid`" --lap $ln --ref `"pb`" --out `"$o`""; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::Start($psi); if (-not $proc.WaitForExit(240000)) { try { $proc.Kill() } catch { }; throw "analysis lap $ln timed out" }
    $wLaps[$ln] = Get-Content -LiteralPath $o -Raw -Encoding UTF8 | ConvertFrom-Json
  }
  $wp = Join-Path $dW $wid
  Check 'the raw records agree: lap 3 (79.897) and lap 15 (80.161) have an off-track record and iRacing did not count them; laps 6, 8 and 14 it counted' (-not [LapRaw]::Counted($wp, 3, 79.897) -and -not [LapRaw]::Counted($wp, 15, 80.161) -and [LapRaw]::Counted($wp, 6, 80.589) -and [LapRaw]::Counted($wp, 8, 80.842) -and [LapRaw]::Counted($wp, 14, 80.228) -and (Near ([LapRaw]::BestLap($wp)) 80.228 0.001))
  Check 'an uncounted lap is still real data: lap 3 can be analysed (clean, 79.897) - it is only never "the PB"' ($wLaps[3].clean -eq $true -and (Near $wLaps[3].time 79.897 0.001) -and (Near $wLaps[3].official 79.897 0.001))
  Check 'the PB reference of lap 6 is lap 14 (80.228, counted), not the quicker lap 3 (79.897) that iRacing did not count' ($wLaps[6].ref.kind -eq 'pb' -and $wLaps[6].ref.lap -eq 14 -and (Near $wLaps[6].ref.time 80.228 0.001) -and $wLaps[6].store.pb.lap -eq 14 -and (Near $wLaps[6].store.pb.time 80.228 0.001))
  Check 'the session best is lap 14 too, and the best-5 average counts only the 3 counted laps (80.228, 80.589, 80.842)' ($wLaps[6].store.sessionBest.lap -eq 14 -and $wLaps[6].store.cleanLaps -eq 3 -and $wLaps[6].store.consistency.n -eq 3 -and (Near $wLaps[6].store.consistency.avg5 ((80.228 + 80.589 + 80.842) / 3) 0.001) -and (Near $wLaps[6].store.consistency.spread (80.842 - 80.228) 0.001))
  Check 'the counted lap 14 itself is compared with the next best counted lap (6), never with the uncounted lap 3 or 15' ($wLaps[14].ref.lap -eq 6 -and (Near $wLaps[14].ref.time 80.589 0.001))
  $o = Join-Path $outDir 'wl-named.json'
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe; $psi.Arguments = "--analysis --root `"$root`" --dir `"$dW`" --id `"$wid`" --lap 6 --ref `"$($wid):3`" --out `"$o`""; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $proc = [Diagnostics.Process]::Start($psi); if (-not $proc.WaitForExit(240000)) { try { $proc.Kill() } catch { }; throw 'analysis named ref timed out' }
  $named = Get-Content -LiteralPath $o -Raw -Encoding UTF8 | ConvertFrom-Json
  # L-1b: the optimal / sector / third / mini bests and the goal are joined only from counted laps with no off-track record. Ferrari practice 17-45-41: every counted lap has
  # hundreds of records (best lap 1:44.133, lap 4), so there is nothing to join - no optimal at all (before: 1:30.279 from sectors across the grass); the best lap is still iRacing's.
  $fer = 'ferrari296gt3_roadatlanta full 2026-10-10 17-45-41.ibt'
  $dFer = Join-Path $work 'fer'; New-Item -ItemType Directory -Force $dFer | Out-Null
  Copy-Item -LiteralPath (Join-Path $srcDir $fer) -Destination (Join-Path $dFer $fer)
  $oF = Join-Path $outDir 'fer.json'
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe; $psi.Arguments = "--analysis --root `"$root`" --dir `"$dFer`" --id `"$fer`" --lap 4 --ref `"optimal`" --out `"$oF`""; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $proc = [Diagnostics.Process]::Start($psi); if (-not $proc.WaitForExit(240000)) { try { $proc.Kill() } catch { }; throw 'analysis ferrari timed out' }
  $fj = Get-Content -LiteralPath $oF -Raw -Encoding UTF8 | ConvertFrom-Json
  Check 'Ferrari practice: the best lap is 1:44.133 (lap 4, counted by iRacing) but no optimal, sector best, third best or mini best exists (null), and ref=optimal gives no reference (lap 4 itself is not a clean lap: 686 records)' ((Near $fj.store.pb.time 104.133 0.001) -and $fj.store.pb.lap -eq 4 -and $null -eq $fj.store.optimal -and $null -eq $fj.store.sectorBest -and $null -eq $fj.store.thirdBest -and $null -eq $fj.store.miniMin -and $fj.store.cleanLaps -eq 4 -and $null -eq $fj.ref)
  Check 'asking for an uncounted lap by name still works: ref=<file>:3 compares lap 6 with lap 3 (a real lap, just never chosen as the PB)' ($named.ref.kind -eq 'lap' -and $named.ref.lap -eq 3 -and (Near $named.ref.time 79.897 0.001))

  function Invoke-Deep($dir, $id, $lap, $ref, $tag, $extra = '') {
    $out = Join-Path $outDir "$tag.json"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = "--analysis --deep --root `"$root`" --dir `"$dir`" --id `"$id`" --lap $lap --ref `"$ref`" --out `"$out`" $extra"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit(240000)) { try { $proc.Kill() } catch { }; throw "deep $tag timed out" }
    if ($proc.ExitCode -ne 0) { throw "deep $tag failed: $(Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue)" }
    Write-Host "  ok    deep $tag ran"
    $script:pass++
    # the object itself, not an array holding it: an empty JSON list inside a wrapped array reads back as $null
    $obj = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
    return $obj
  }
  function Corner($j, $label) { @($j.corners | Where-Object { $_.label -eq $label })[0] }

  Section 'deep 1+2: lock-ups, wheelspin and ABS'
  $a = Invoke-Deep $d1 $vid 8 'pb' 'deepA'
  Check 'lap 8 against the PB lap 7: 79.878 s against 79.549 s, 14 corners' ($a.lap -eq 8 -and (Near $a.time 79.878 0.001) -and $a.ref.lap -eq 7 -and (Near $a.ref.time 79.549 0.001) -and $a.corners.Count -eq 14)
  $lk = @($a.events.me.lock)
  Check 'lap 8 has 6 lock-ups and 3 wheelspin events; the PB lap has 2 lock-ups and 8 wheelspin events' ($lk.Count -eq 6 -and @($a.events.me.spin).Count -eq 3 -and @($a.events.ref.lock).Count -eq 2 -and @($a.events.ref.spin).Count -eq 8)
  # raw: right-front 812.2 to 816.6 m, 0.133 s, 8.7 % slower than the car, brake 29 %; the grid counts one more cell (0.160 s)
  Check 'the first lock-up is the right front at 812 m in T3: 8.7 % under the car, about 0.15 s' ($lk[0].wheel -eq 'RF' -and (Near $lk[0].m 812.0 3) -and (Near $lk[0].secs 0.160 0.04) -and (Near $lk[0].worstPct 8.7 0.7) -and $lk[0].label -eq 'T3')
  Check 'every lock-up has a wheel, a distance and a duration' (@($lk | Where-Object { $_.wheel -and $_.secs -ge 0.05 -and $_.m -gt 0 }).Count -eq 6)
  $c = Corner $a 'T3'; Check 'T3 counts its 2 lock-ups' ($c.me.lock.n -eq 2 -and (Near $c.me.lock.secs 0.240 0.05))
  $c = Corner $a 'T7'
  Check 'T7 (braking from 2052 m) has 4 lock-ups and 1 wheelspin, the rear right' ($c.me.lock.n -eq 4 -and $c.me.spin.n -eq 1 -and $c.me.spin.wheel -eq 'RR')
  $c = Corner $a 'T5'; Check 'T5 has 2 left-rear wheelspin events of about 22 % (raw 20.6 and 22.4 %)' ($c.me.spin.n -eq 2 -and $c.me.spin.wheel -eq 'LR' -and (Near $c.me.spin.worstPct 22.0 2.5))
  Check 'T1 and T2 have none' ((Corner $a 'T1').me.lock.n -eq 0 -and (Corner $a 'T2').me.lock.n -eq 0 -and (Corner $a 'T1').me.spin.n -eq 0)
  # raw: ABS on for 45 of 85 braking samples = 0.529, deepest cut 41.6 %
  $c = Corner $a 'T7'; Check 'T7: ABS on 53 % of the braking time, deepest cut 41.5 %, one ABS zone' ((Near $c.me.abs.share 0.530 0.012) -and (Near $c.me.abs.peakCutPct 41.5 1.5) -and $c.me.abs.zones -eq 1)
  # raw: 24 of 76 = 0.316, deepest cut 26.9 % (the grid shaves a one-sample peak)
  $c = Corner $a 'T1'; Check 'T1: ABS on 31 % of the braking time, deepest cut 25.7 %' ((Near $c.me.abs.share 0.314 0.012) -and (Near $c.me.abs.peakCutPct 25.7 1.5))
  Check 'ABS zones are merged: 6 on lap 8, none closer than 30 m' (@($a.events.me.abs).Count -eq 6 -and (@($a.events.me.abs | Where-Object { $_.peakCutPct -gt 0 }).Count -eq 6))
  Check 'corners that never brake have no ABS block' ($null -eq (Corner $a 'T2').me.abs -and $null -eq (Corner $a 'T8').me.abs)

  Section 'deep 3: braking profile'
  # raw T1 on lap 8: starts 284.9 m, peak 100 %, 0.250 s to the peak, release 0.933 s, 0.617 s of it with the wheel turned,
  # 0.850 s from brake off to throttle on, 1.100 s with neither pedal
  $b = (Corner $a 'T1').me.brake
  Check 'T1 lap 8: braking starts at 284 m, peak 100 %, 0.25 s to the peak' ((Near $b.startM 284.0 1.5) -and (Near $b.peakPct 100.0 0.5) -and (Near $b.toPeakS 0.250 0.02))
  Check 'T1 lap 8: release 0.95 s, 0.63 s of it trailing with the wheel turned' ((Near $b.releaseS 0.946 0.03) -and (Near $b.trailS 0.630 0.03) -and $b.trailS -le $b.releaseS)
  Check 'T1 lap 8: 0.84 s from brake off to throttle on, 1.08 s with neither pedal' ((Near $b.coastGapS 0.842 0.03) -and (Near $b.coastS 1.078 0.04))
  Check 'the PB lap brakes lighter in T1 (peak 94.6 %) and releases longer' ((Near (Corner $a 'T1').ref.brake.peakPct 94.6 0.5) -and (Corner $a 'T1').ref.brake.releaseS -gt $b.releaseS)
  Check 'T4 shares the braking of T3, so it has no braking block of its own' ($null -eq (Corner $a 'T4').me.brake -and (Corner $a 'T3').me.brake.startM -lt (Corner $a 'T3').p0 * 4056.9)

  Section 'deep 4: wheel clipping'
  # raw T1: 5 of 471 records at 98 % or more = 0.0106 of the corner, peak 100 %. Setting 46.19 Nm.
  $k = (Corner $a 'T1').me.clip
  Check 'T1 lap 8: 1.1 % of the corner clipped, peak 100 % = 46.19 Nm of a 46.19 Nm setting' ((Near $k.share 0.011 0.002) -and (Near $k.peakPct 100.0 0.2) -and (Near $k.peakNm 46.19 0.05) -and (Near $k.maxForceNm 46.19 0.01))
  Check 'the PB lap never clips in T1 (peak 65 %)' ((Corner $a 'T1').ref.clip.share -eq 0 -and (Near (Corner $a 'T1').ref.clip.peakPct 65.1 1.0))
  Check 'lap 8 also clips a little in T6 and The Esses, not in T2' ((Corner $a 'T6').me.clip.share -gt 0 -and (Corner $a 'The Esses').me.clip.share -gt 0 -and (Corner $a 'T2').me.clip.share -eq 0)

  Section 'deep 5: racing line'
  # raw (Lat/Lon of the two laps interpolated by distance, left of travel positive): T1 turn-in 442 m -1.31 m, apex 474 m -0.09 m,
  # exit 628.8 m +1.66 m; T7 2093.9 m -0.55, 2117.9 m -1.59, exit 2211 m +1.85. Lap 8 position at 442.0 m: 347.76 east, -261.00 north.
  $l = (Corner $a 'T1').me.line
  Check 'T1 lap 8 turns in at 442 m and its apex is at 474 m; the PB turned in at 387 m' ((Near $l.turnInM 442.0 0.6) -and (Near $l.apexM 474.0 0.6) -and (Near (Corner $a 'T1').ref.line.turnInM 387.0 0.6))
  Check 'T1 lap 8 is 1.31 m right of the PB line at turn-in, 0.09 m right at the apex, 1.66 m left at the exit' ((Near $l.offsetTurnInM -1.31 0.04) -and (Near $l.offsetApexM -0.09 0.04) -and (Near $l.offsetExitM 1.66 0.04))
  Check 'T1 turn-in is at 347.76 m east, 260.99 m south of the lap start' ((Near $l.turnInXY[0] 347.76 0.05) -and (Near $l.turnInXY[1] -260.99 0.05))
  $l = (Corner $a 'T7').me.line
  Check 'T7: offsets -0.55 m at turn-in, -1.59 m at the apex, +1.85 m at the exit' ((Near $l.turnInM 2093.9 0.6) -and (Near $l.offsetTurnInM -0.55 0.04) -and (Near $l.offsetApexM -1.59 0.04) -and (Near $l.offsetExitM 1.85 0.04))
  Check 'the reference line has no offset against itself' ($null -eq (Corner $a 'T1').ref.line.offsetApexM)
  Check 'the line is drawn every 5 m: 812 points for the lap, the PB and the offset' ((Near $a.line.stepM 5.0 0.01) -and @($a.line.me.x).Count -eq 812 -and @($a.line.ref.x).Count -eq 812 -and @($a.line.offset).Count -eq 812)
  $sw = Invoke-Deep $d1 $vid 7 ($vid + ':8') 'deepSwap'
  $worst = 0.0
  for ($i = 0; $i -lt 812; $i++) { $s = [math]::Abs([double]$a.line.offset[$i] + [double]$sw.line.offset[$i]); if ($s -gt $worst) { $worst = $s } }
  Check 'swapping the two laps flips every offset (within 0.25 m)' ($worst -lt 0.25 -and $sw.ref.lap -eq 8)
  Note "largest mismatch when the two laps swap: $([math]::Round($worst, 3)) m"

  Section 'deep 6: g-g'
  # grid recomputed by hand (raw records onto the 1 m grid, median of 9, T1 284 to 628.8 m): lat 2.347, brake 2.169, accel 0.358.
  # Raw peaks are 3.2 g because a kerb at 470 m spikes LatAccel to 4.4 g; the median keeps that out.
  $g = (Corner $a 'T1').me.gg
  Check 'T1 lap 8: peak 2.35 g lateral, 2.17 g braking, 0.36 g accelerating, G total 2.35 g' ((Near $g.peakLatG 2.347 0.01) -and (Near $g.peakBrakeG 2.169 0.01) -and (Near $g.peakAccelG 0.358 0.01) -and (Near $g.peakTotalG 2.347 0.01))
  Check 'T10a lap 8: G total 2.47 g, all of it braking' ((Near (Corner $a 'T10a').me.gg.peakTotalG 2.465 0.01) -and (Near (Corner $a 'T10a').me.gg.peakBrakeG 2.465 0.01))
  Check 'T1 g-g has a point every 4 m of its 345 m zone' (@($g.pts).Count -ge 85 -and @($g.pts).Count -le 88 -and @($g.pts[0]).Count -eq 2)
  Check 'the PB lap pulls 2.76 g sideways in T1 against 2.35 g' ((Near (Corner $a 'T1').ref.gg.peakLatG 2.764 0.02) -and (Corner $a 'T1').ref.gg.peakLatG -gt $g.peakLatG)

  Section 'deep 9: car balance (entry / mid / exit against the PB lap)'
  # raw T1 lap 8: mid (451.6 to 496.4 m) 0.917 s, 56.15 deg of steering at 100 m radius, rear slip 2.24 deg; exit 2.633 s, 37.30 deg, 1.85 deg.
  # raw T1 PB: mid 45.45, exit 33.95. Entry of lap 8 is 0.2 s, under the 0.25 s a phase needs, so it is left out.
  $bm = (Corner $a 'T1').me.balance
  Check 'T1 lap 8 mid-corner: 56.0 deg of wheel for a 100 m radius, 47.8 deg at the wheel, 1.77 g' ((Near $bm.mid.need100Deg 56.02 0.3) -and (Near $bm.mid.steerDeg 47.8 0.5) -and (Near $bm.mid.latG 1.77 0.06))
  Check 'T1 lap 8 exit: 37.3 deg for a 100 m radius' (Near $bm.exit.need100Deg 37.32 0.2)
  Check 'T1 lap 8 entry is left out (0.2 s)' ($null -eq $bm.entry)
  Check 'T1 PB lap: 45.3 deg mid-corner, 33.9 deg at the exit, and it has an entry phase' ((Near (Corner $a 'T1').ref.balance.mid.need100Deg 45.28 0.3) -and (Near (Corner $a 'T1').ref.balance.exit.need100Deg 33.90 0.2) -and $null -ne (Corner $a 'T1').ref.balance.entry)
  $d = (Corner $a 'T1').d
  Check 'T1 lap 8 against the PB: +10.8 deg (+23.7 %) of steering mid-corner, +3.4 deg (+10.1 %) at the exit' ((Near $d.mid.need100Deg 10.75 0.5) -and (Near $d.mid.need100Pct 23.7 1.5) -and (Near $d.exit.need100Deg 3.42 0.3) -and (Near $d.exit.need100Pct 10.1 1.0))
  Check 'the Corvette has a wheelbase (2.723 m) and a front weight (44.3 %) but no steering ratio, so rear slip shows and the understeer angle is hidden' ((Near $a.carConst.wheelbaseM 2.723 0.0005) -and (Near $a.carConst.frontWeight 0.443 0.0005) -and $null -eq $a.carConst.steerRatio -and $a.carConst.known -eq $true -and ($a.carConst.hidden -contains 'understeerDeg') -and ($a.carConst.hidden -contains 'balanceFlags') -and -not ($a.carConst.hidden -contains 'rearSlipDeg') -and $a.carConst.source -like '*2,723 mm*')
  Check 'rear slip 2.24 deg mid-corner and 1.85 deg at the exit of T1; understeer angle and flags are null' ((Near $bm.mid.rearSlipDeg 2.24 0.06) -and (Near $bm.exit.rearSlipDeg 1.85 0.06) -and $null -eq $bm.mid.understeerDeg -and $null -eq $bm.mid.oversteerShare)
  Check 'chassis slip angle 1.65 deg mid-corner and 1.46 deg at the exit of T1' ((Near $bm.mid.slipDeg 1.65 0.06) -and (Near $bm.exit.slipDeg 1.46 0.06))
  # test-only steering ratio 14: raw mid 2.09 deg understeer angle, front slip 4.33, understeer flag 40 % of the time; exit 0.62 deg, 2.47
  $r14 = Invoke-Deep $d1 $vid 8 'pb' 'deepR' '--ratio 14'
  $bm = (Corner $r14 'T1').me.balance
  Check 'with a ratio of 14 the road-wheel understeer angle is 2.1 deg mid-corner and 0.6 deg at the exit (Cosworth: wheel angle / ratio - wheelbase x yaw rate / speed)' ((Near $bm.mid.understeerDeg 2.08 0.1) -and (Near $bm.exit.understeerDeg 0.62 0.06) -and (Near $bm.mid.frontSlipDeg 4.32 0.12) -and (Near $bm.exit.frontSlipDeg 2.47 0.08))
  Check 'with a ratio of 14 the understeer flag is on for about 38 % of the mid-corner, the oversteer flag never, nothing is hidden' ((Near $bm.mid.understeerShare 0.380 0.03) -and $bm.mid.oversteerShare -eq 0 -and @($r14.carConst.hidden).Count -eq 0 -and (Near $r14.carConst.steerRatio 14.0 0.001))
  Check 'the ratio does not change the numbers that need no ratio' ((Near $bm.mid.need100Deg 56.02 0.01) -and (Near $bm.mid.rearSlipDeg 2.24 0.01))

  Section 'deep 7: tyres per stint'
  # raw lap 10 (the stint's last clean lap), 4804 records: left-front middle 67.52 mean / 86.86 peak, left-front left 65.66,
  # right-rear right 55.18 / 89.40, right-front pressure 177.95 mean / 178.33 peak. Wear 100 %, carcass 39.4 C all file long (iRacing
  # only refreshes those two in the pits).
  Check 'the Corvette file is one stint: laps 0 to 11, 9 clean, best 79.549, last clean lap 10, 16.1 minutes' (@($a.stints).Count -eq 1 -and $a.stints[0].lapFirst -eq 0 -and $a.stints[0].lapLast -eq 11 -and $a.stints[0].cleanLaps -eq 9 -and (Near $a.stints[0].best 79.549 0.001) -and $a.stints[0].statLap -eq 10 -and (Near $a.stints[0].minutes 16.1 0.15))
  $ty = $a.stints[0].tyres
  Check 'left front surface, middle: 67.5 C mean and 86.9 C peak over lap 10; left edge 65.7 C' ((Near $ty.LF.surface.M.mean 67.52 0.2) -and (Near $ty.LF.surface.M.peak 86.86 0.2) -and (Near $ty.LF.surface.L.mean 65.66 0.2))
  Check 'right rear surface, right edge: 55.2 C mean and 89.4 C peak' ((Near $ty.RR.surface.R.mean 55.18 0.2) -and (Near $ty.RR.surface.R.peak 89.40 0.2))
  Check 'right front pressure: 177.9 kPa on the last clean lap, peak 178.3, set cold at 158.6' ((Near $ty.RF.pressure.endKpa 177.95 0.2) -and (Near $ty.RF.pressure.peakKpa 178.33 0.2) -and (Near $ty.RF.pressure.coldKpa 158.58 0.1))
  Check 'wear is 100 % and the carcass 39.4 C on every tyre, marked as not live' ((Near $ty.LF.wear.M 100.0 0.05) -and (Near $ty.RR.carcass.M 39.4 0.05) -and $ty.LF.wear.live -eq $false -and $ty.LF.carcass.live -eq $false)
  # the 2026-10-06 file starts on a used set: raw wear 97.5 / 95.3 / 95.2 %, carcass 84.2 / 96.3 / 101.6 C, both constant all file
  $w = Invoke-Deep $dW $wid 3 'pb' 'deepW'
  $wt = $w.stints[0].tyres.LF
  Check 'a used set shows its wear at the stint end: left front 97.5 / 95.3 / 95.2 %, carcass 84.2 / 96.3 / 101.6 C' ((Near $wt.wear.L 97.5 0.05) -and (Near $wt.wear.M 95.3 0.05) -and (Near $wt.wear.R 95.2 0.05) -and (Near $wt.carcass.L 84.2 0.05) -and (Near $wt.carcass.M 96.3 0.05) -and (Near $wt.carcass.R 101.6 0.05))
  Check 'that file is one stint of 13 clean laps, last clean lap 15' (@($w.stints).Count -eq 1 -and $w.stints[0].cleanLaps -eq 13 -and $w.stints[0].statLap -eq 15)

  Section 'deep 8 + stints: a real file with edits (a COPY: setting changes, a pit stop and new tyres written in)'
  # No real file in the vault has a setting change or a mid-session stop, so the copy gets them written into its records:
  #   brake bias +0.5 at record 24500 and +1.0 more at 24530 (lap 5; 0.5 s apart = ONE change, 55.9646 -> 57.4646),
  #   traction control 2 -> 3 at 39000 (lap 8), ABS 2 -> 1 at 44000 (lap 9),
  #   on pit road from 26000 to 33000 (lap 5 becomes IN, lap 6 PIT, lap 7 OUT), left-front wear 97 % from record 30000,
  #   right-front middle wear 99.5 % from 15000 (a live change inside stint 1), and the car name changed to one that is not in the table.
  Add-Type -TypeDefinition @'
using System; using System.IO; using System.Text; using System.Collections.Generic;
public static class IbtPatch {
  public static void Apply(string src, string dst, string[] ops) {
    byte[] b = File.ReadAllBytes(src);
    int yamlLen = BitConverter.ToInt32(b, 16), yamlOff = BitConverter.ToInt32(b, 20);
    int numVars = BitConverter.ToInt32(b, 24), varOff = BitConverter.ToInt32(b, 28), bufLen = BitConverter.ToInt32(b, 36), dataOff = BitConverter.ToInt32(b, 52);
    Dictionary<string, int[]> vars = new Dictionary<string, int[]>();
    for (int i = 0; i < numVars; i++) {
      int p = varOff + i * 144; int nl = Array.IndexOf(b, (byte)0, p + 16, 32) - (p + 16);
      vars[Encoding.ASCII.GetString(b, p + 16, nl)] = new int[] { BitConverter.ToInt32(b, p), BitConverter.ToInt32(b, p + 4) };
    }
    long recs = (b.Length - dataOff) / bufLen;
    foreach (string op in ops) {            // "name|first|last|=value", "name|first|last|+delta" or "yaml|old text|new text" (same length)
      string[] f = op.Split('|');
      if (f[0] == "yaml") {
        byte[] o = Encoding.ASCII.GetBytes(f[1]), n = Encoding.ASCII.GetBytes(f[2]);
        if (o.Length != n.Length) throw new Exception("yaml text must keep its length");
        for (int p = yamlOff; p + o.Length <= yamlOff + yamlLen; p++) {
          bool same = true; for (int k = 0; k < o.Length && same; k++) if (b[p + k] != o[k]) same = false;
          if (same) { Buffer.BlockCopy(n, 0, b, p, n.Length); p += o.Length - 1; }
        }
        continue;
      }
      int[] v = vars[f[0]];
      long r0 = long.Parse(f[1]), r1 = Math.Min(long.Parse(f[2]), recs - 1);
      bool add = f[3][0] == '+'; double val = double.Parse(f[3].Substring(1), System.Globalization.CultureInfo.InvariantCulture);
      for (long r = r0; r <= r1; r++) {
        int p = dataOff + (int)(r * bufLen) + v[1];
        if (v[0] == 4) { float cur = BitConverter.ToSingle(b, p); Buffer.BlockCopy(BitConverter.GetBytes((float)(add ? cur + val : val)), 0, b, p, 4); }
        else if (v[0] == 2 || v[0] == 3) { int cur = BitConverter.ToInt32(b, p); Buffer.BlockCopy(BitConverter.GetBytes((int)(add ? cur + val : val)), 0, b, p, 4); }
        else if (v[0] == 0 || v[0] == 1) { b[p] = (byte)(add ? b[p] + val : val); }
        else throw new Exception("type " + v[0] + " not handled for " + f[0]);
      }
    }
    File.WriteAllBytes(dst, b);
  }
}
'@ -ErrorAction SilentlyContinue
  $ops = @('dcBrakeBias|24500|60507|+0.5', 'dcBrakeBias|24530|60507|+1.0', 'dcTractionControl|39000|60507|=3', 'dcABS|44000|60507|=1',
           'OnPitRoad|26000|33000|=1', 'LFwearL|30000|60507|=0.97', 'LFwearM|30000|60507|=0.97', 'LFwearR|30000|60507|=0.97', 'RFwearM|15000|60507|=0.995',
           'yaml|Chevrolet Corvette Z06 GT3.R|Chevrolet Corvette Z06 GT3.X')
  [IbtPatch]::Apply((Join-Path $d1 $vid), (Join-Path $dP $vid), [string[]]$ops)
  $p = Invoke-Deep $dP $vid 9 'pb' 'deepP'
  Check 'the edited copy starts with the file''s own settings: brake bias 55.96, traction control 2, ABS 2' ((Near $p.settings.dcBrakeBias 55.9646 0.001) -and $p.settings.dcTractionControl -eq 2 -and $p.settings.dcABS -eq 2)
  $ch = @($p.changes)
  Check 'three changes are found, in the order they were made (the two bias clicks 0.5 s apart are one change)' ($ch.Count -eq 3 -and $ch[0].channel -eq 'dcBrakeBias' -and $ch[1].channel -eq 'dcTractionControl' -and $ch[2].channel -eq 'dcABS')
  Check 'brake bias 55.9646 -> 57.4646 in lap 5' ((Near $ch[0].from 55.9646 0.001) -and (Near $ch[0].to 57.4646 0.001) -and $ch[0].lap -eq 5)
  # lap times are iRacing's: 1 = 83.664, 2 = 80.590, 4 = 80.322 (lap 3 is off track), 8 = 79.878, 9 = 80.471, 10 = 80.078
  Check 'bias change: laps 1, 2, 4 before (best 80.322), laps 8, 9, 10 after (best 79.878), 0.444 s quicker, a pit stop in between' ((@($ch[0].before | ForEach-Object { $_.lap }) -join ',') -eq '1,2,4' -and (Near $ch[0].bestBefore 80.322 0.001) -and (@($ch[0].after | ForEach-Object { $_.lap }) -join ',') -eq '8,9,10' -and (Near $ch[0].bestAfter 79.878 0.001) -and (Near $ch[0].delta -0.444 0.001) -and $ch[0].pitBetween -eq $true)
  Check 'traction control 2 -> 3 in lap 8: laps 1, 2, 4 before, laps 9, 10 after (best 80.078), pit stop in between' ($ch[1].from -eq 2 -and $ch[1].to -eq 3 -and $ch[1].lap -eq 8 -and (@($ch[1].before | ForEach-Object { $_.lap }) -join ',') -eq '1,2,4' -and (@($ch[1].after | ForEach-Object { $_.lap }) -join ',') -eq '9,10' -and (Near $ch[1].delta -0.244 0.001) -and $ch[1].pitBetween -eq $true)
  Check 'ABS 2 -> 1 in lap 9: laps 2, 4, 8 before (best 79.878), lap 10 after (80.078, 0.199 s slower), no stop in between' ($ch[2].from -eq 2 -and $ch[2].to -eq 1 -and $ch[2].lap -eq 9 -and (@($ch[2].before | ForEach-Object { $_.lap }) -join ',') -eq '2,4,8' -and (Near $ch[2].bestBefore 79.878 0.001) -and (Near $ch[2].bestAfter 80.078 0.001) -and (Near $ch[2].delta 0.199 0.001) -and $ch[2].pitBetween -eq $false)
  Check 'a file with no setting change reports none (the unedited Corvette and the Ferrari)' (@($a.changes).Count -eq 0)
  $st = @($p.stints)
  Check 'the pit stop splits the file into two stints: laps 0 to 5 (3 clean, best 80.322) and laps 7 to 11 (3 clean, best 79.878)' ($st.Count -eq 2 -and $st[0].lapLast -eq 5 -and $st[0].cleanLaps -eq 3 -and (Near $st[0].best 80.322 0.001) -and $st[0].statLap -eq 4 -and $st[1].lapFirst -eq 7 -and $st[1].lapLast -eq 11 -and $st[1].cleanLaps -eq 3 -and (Near $st[1].best 79.878 0.001) -and $st[1].statLap -eq 10)
  Check 'wear at the end of each stint: left front 100 % then 97 % after the new set; right front 99.5 % (a live change in stint 1, steady in stint 2)' ((Near $st[0].tyres.LF.wear.M 100.0 0.05) -and (Near $st[1].tyres.LF.wear.M 97.0 0.05) -and $st[0].tyres.LF.wear.live -eq $false -and $st[1].tyres.LF.wear.live -eq $false -and (Near $st[0].tyres.RF.wear.M 99.5 0.05) -and $st[0].tyres.RF.wear.live -eq $true -and $st[1].tyres.RF.wear.live -eq $false)
  Check 'surface temperature comes from each stint''s own last clean lap (stint 2 left front middle 67.5 C, the lap 10 figure)' ((Near $st[1].tyres.LF.surface.M.mean 67.52 0.2) -and $st[0].tyres.LF.surface.M.mean -ne $st[1].tyres.LF.surface.M.mean)
  Check 'a car that is not in the table gets no wheelbase, no rear slip, no understeer angle, but still the steering numbers' ($p.carConst.known -eq $false -and $null -eq $p.carConst.wheelbaseM -and ($p.carConst.hidden -contains 'rearSlipDeg') -and ($p.carConst.hidden -contains 'understeerDeg') -and $null -eq (Corner $p 'T1').me.balance.mid.rearSlipDeg -and $null -ne (Corner $p 'T1').me.balance.mid.need100Deg -and $p.carConst.source -like '*not in the table*')

  Section 'deep: a second car (Ferrari 296 GT3, Sebring, lap 1 against the PB lap 2)'
  $f = Invoke-Deep $dF $fid 1 'pb' 'deepF'
  Check 'Ferrari: 17 corners, lap 1 = 130.320 s against lap 2 = 126.639 s' ($f.corners.Count -eq 17 -and (Near $f.time 130.320 0.001) -and $f.ref.lap -eq 2 -and (Near $f.ref.time 126.639 0.001) -and $f.car -eq 'Ferrari 296 GT3')
  Check 'Ferrari constants: wheelbase 2.660 m from the spec sheet, front weight 46.9 % from its own setup, no steering ratio' ((Near $f.carConst.wheelbaseM 2.660 0.0005) -and (Near $f.carConst.frontWeight 0.469 0.0005) -and $null -eq $f.carConst.steerRatio -and $f.carConst.source -like '*2,660 mm*')
  Check 'Ferrari settings are its own: brake bias 50.52, traction control 3, ABS 3, no change' ((Near $f.settings.dcBrakeBias 50.5209 0.001) -and $f.settings.dcTractionControl -eq 3 -and $f.settings.dcABS -eq 3 -and @($f.changes).Count -eq 0)
  Check 'Ferrari: one stint, 2 clean laps, best 126.639, tyres 100 % worn' (@($f.stints).Count -eq 1 -and $f.stints[0].cleanLaps -eq 2 -and (Near $f.stints[0].best 126.639 0.001) -and (Near $f.stints[0].tyres.RR.wear.M 100.0 0.05))
  # raw Sunset Bend corner body 5104.3 to 5631.6 m, lap 1: 3 of 756 records at 98 % or more = 0.004
  Check 'Ferrari: wheel clipping shows in Sunset Bend (0.4 % of the corner, 100 % torque)' ((Near (Corner $f 'Sunset Bend').me.clip.peakPct 100.0 0.5) -and (Near (Corner $f 'Sunset Bend').me.clip.share 0.004 0.002))
  Check 'Ferrari rear slip exists in at least one corner' (@($f.corners | Where-Object { $null -ne $_.me.balance.mid -and $null -ne $_.me.balance.mid.rearSlipDeg }).Count -ge 5)

  # P4 (2026-10-11): wheelbases of the BMW M4 GT3 EVO (2.916 m) and the Toyota GR86 (2.575 m) from iRacing's own manuals (docs\research\car-assets-steering.md B5).
  # His BMW and GR86 files have no complete lap (every BMW lap is off track, in or partial; the GR86 files are one pit lap), so the table is checked on copies of the
  # Corvette file whose car name is changed to the exact CarScreenName his real files carry (same length, patched in the session text only; the data is the Corvette's).
  Section 'deep: the BMW M4 GT3 EVO and the Toyota GR86 are in the car table'
  function Yaml-Of($path) { $fs = [IO.File]::OpenRead($path); try { $h = New-Object byte[] 144; [void]$fs.Read($h, 0, 144); $n = [BitConverter]::ToInt32($h, 16); $fs.Position = [BitConverter]::ToInt32($h, 20); $yb = New-Object byte[] $n; [void]$fs.Read($yb, 0, $n) } finally { $fs.Close() }; return [Text.Encoding]::GetEncoding(1252).GetString($yb) }
  $realBmw = Join-Path $srcDir 'bmwm4gt3_roadatlanta full 2026-10-10 16-40-31.ibt'; $realGr = Join-Path $srcDir 'toyotagr86_limerock 2019 gp 2026-10-09 18-06-45.ibt'
  if ((Test-Path -LiteralPath $realBmw) -and (Test-Path -LiteralPath $realGr)) {
    $nameB = [regex]::Match((Yaml-Of $realBmw), '(?m)^\s*CarScreenName:\s*(.*?)\s*$').Groups[1].Value; $nameG = [regex]::Match((Yaml-Of $realGr), '(?m)^\s*CarScreenName:\s*(.*?)\s*$').Groups[1].Value
    Check "his real files name the cars exactly as the table does: '$nameB' and '$nameG'" ($nameB -ceq 'BMW M4 GT3 EVO' -and $nameG -ceq 'Toyota GR86')
  } else { Note 'the real BMW / GR86 files are not on this PC: only the copies are checked' }
  $dB = Join-Path $work 'deep-bmw'; $dG = Join-Path $work 'deep-gr86'; New-Item -ItemType Directory -Force $dB, $dG | Out-Null
  [IbtPatch]::Apply((Join-Path $d1 $vid), (Join-Path $dB $vid), [string[]]@('yaml|Chevrolet Corvette Z06 GT3.R|BMW M4 GT3 EVO              '))
  [IbtPatch]::Apply((Join-Path $d1 $vid), (Join-Path $dG $vid), [string[]]@('yaml|Chevrolet Corvette Z06 GT3.R|Toyota GR86                 '))
  $bm = Invoke-Deep $dB $vid 8 'pb' 'deepBMW'; $gr = Invoke-Deep $dG $vid 8 'pb' 'deepGR86'
  Check 'the BMW is in the table: car name BMW M4 GT3 EVO, wheelbase 2.916 m, the source names the manual page, no steering ratio' ($bm.car -eq 'BMW M4 GT3 EVO' -and $bm.carConst.known -eq $true -and (Near $bm.carConst.wheelbaseM 2.916 0.0005) -and $bm.carConst.source -like '*2916 mm*' -and $bm.carConst.source -like '*BMW-M4-GT3-Manual*' -and $null -eq $bm.carConst.steerRatio)
  Check 'the GR86 is in the table: car name Toyota GR86, wheelbase 2.575 m, the source names the manual, no steering ratio (the road car''s 2.5 turns are not used)' ($gr.car -eq 'Toyota GR86' -and $gr.carConst.known -eq $true -and (Near $gr.carConst.wheelbaseM 2.575 0.0005) -and $gr.carConst.source -like '*2575 mm*' -and $gr.carConst.source -like '*Toyota_GR86_Manual*' -and $null -eq $gr.carConst.steerRatio -and $gr.carConst.source -like '*not used*')
  $rsB = @($bm.corners | Where-Object { $null -ne $_.me.balance.mid -and $null -ne $_.me.balance.mid.rearSlipDeg }).Count; $rsG = @($gr.corners | Where-Object { $null -ne $_.me.balance.mid -and $null -ne $_.me.balance.mid.rearSlipDeg }).Count
  Check "rear slip angle appears for both cars (the front weight is the file's own 44.3 %): $rsB corners for the BMW, $rsG for the GR86; the understeer angle and the balance flags stay hidden (no steering ratio)" ($rsB -ge 5 -and $rsG -ge 5 -and ($bm.carConst.hidden -contains 'understeerDeg') -and ($gr.carConst.hidden -contains 'understeerDeg') -and -not ($bm.carConst.hidden -contains 'rearSlipDeg') -and $null -eq (Corner $bm 'T1').me.balance.mid.understeerDeg)
  $t1v = (Corner $a 'T1').me.balance.mid.rearSlipDeg; $t1b = (Corner $bm 'T1').me.balance.mid.rearSlipDeg; $t1g = (Corner $gr 'T1').me.balance.mid.rearSlipDeg
  Check "the wheelbase is what changes the rear slip: T1 mid-corner Corvette (2.723 m) $t1v deg, BMW (2.916 m) $t1b deg, GR86 (2.575 m) $t1g deg are three different numbers, and the longer the wheelbase the more the figure moves" (([math]::Abs($t1b - $t1v) -gt 0.005) -and ([math]::Abs($t1g - $t1v) -gt 0.005) -and ([math]::Abs($t1b - $t1g) -gt 0.01) -and ((($t1b - $t1v) * ($t1g - $t1v)) -lt 0))

  Section 'nothing on screen changed'
  Check 'dash\irdash.exe was not replaced' ((Get-Item -LiteralPath $shipped).LastWriteTimeUtc.Ticks -eq $shippedStamp)
}
finally {
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
  Assert-RigFree -Where 'done'
}

Write-Host "`nanalysis-test: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
