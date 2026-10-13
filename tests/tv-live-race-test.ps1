$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
Enter-TestLock 'tv-live-race-test'
$pass = 0; $fail = 0
function Check($name, $ok) { if ($ok) { $script:pass++; "  ok    $name" } else { $script:fail++; "  FAIL  $name" } }
function Section($name) { Assert-RigFree -Where $name; $name }
function Q($s) { [uri]::EscapeDataString([string]$s) }
function Send-RawFrame($values) {
  $query = ($values.GetEnumerator() | ForEach-Object { "$(Q $_.Key)=$(Q $_.Value)" }) -join '&'
  $null = Invoke-WebRequest -UseBasicParsing "http://localhost:8199/api/test/frame?$query" -TimeoutSec 10
}
function Read-TV() { Invoke-RestMethod -UseBasicParsing 'http://localhost:8199/tv/data' -TimeoutSec 10 }
function Set-SampleField($sample, $path) {
  $yaml = "---`r`nWeekendInfo:`r`n TrackName: Road Atlanta`r`n TrackDisplayName: Road Atlanta`r`n TrackConfigName: Full Course`r`n TrackLength: 4.0569 km`r`nSessionInfo:`r`n SessionType: Race`r`nDriverInfo:`r`n DriverCarIdx: $([int]$sample.d.playerIdx)`r`n Drivers:`r`n"
  foreach ($c in $sample.d.cars) { $classId = if ($null -eq $c.classId) { -1 } else { [int]$c.classId }; $yaml += " - CarIdx: $([int]$c.idx)`r`n   UserName: $($c.name)`r`n   CarNumberRaw: $($c.num)`r`n   CarClassID: $classId`r`n   CarClassShortName: $($c.className)`r`n   CarClassColor: $($c.classColor)`r`n" }
  $yaml += "...`r`n"
  [IO.File]::WriteAllText($path, $yaml, [Text.Encoding]::GetEncoding(28591))
  $null = Invoke-WebRequest -UseBasicParsing 'http://localhost:8199/api/test/fieldyaml?name=tv-live-race-test.yaml' -TimeoutSec 10
}
function Send-And-Read($values, $tick) {
  for ($try = 0; $try -lt 40; $try++) {
    Send-RawFrame $values
    for ($poll = 0; $poll -lt 5; $poll++) {
      $d = Read-TV
      if ($null -ne $d.tick -and [math]::Abs([double]$d.tick - [double]$tick) -lt .0005) { return $d }
      Start-Sleep -Milliseconds 20
    }
  }
  throw "TV sampler did not publish raw fixture tick $tick"
}
function Raw-Values($sample) {
  $v = [ordered]@{ SessionTime = [double]$sample.d.tick; IsOnTrack = 1 }
  foreach ($car in $sample.d.cars) {
    $i = [int]$car.idx
    $v["CarIdxLapDistPct_$i"] = [double]$car.pct
    $v["CarIdxLap_$i"] = [int]$car.lap
    $v["CarIdxLapCompleted_$i"] = [int]$car.lap
    $v["CarIdxOnPitRoad_$i"] = [int][bool]$car.pit
    $v["CarIdxLastLapTime_$i"] = [double]$car.last
  }
  return $v
}
function Validate-Snapshot($sample, $d) {
  $raw = @($sample.d.cars); $cars = @($d.cars); $n = $cars.Count
  $positions = @{}; $idxOk = $true
  foreach ($c in $cars) { $positions[[int]$c.idx] = [int]$c.pos; if ([int]$c.pos -lt 1 -or [int]$c.pos -gt $n) { $idxOk = $false } }
  $posOk = $idxOk -and $positions.Count -eq $n
  if ($n -gt 0) { $posOk = $posOk -and ((@($positions.Values | Sort-Object) -join ',') -eq ((1..$n) -join ',')) }
  $gaps = @($cars | ForEach-Object { $_.gap } | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
  $mono = $true
  for ($i = 1; $i -lt $gaps.Count; $i++) { if ($gaps[$i] + .0001 -lt $gaps[$i-1]) { $mono = $false } }
  $outByIdx = @{}; foreach ($c in $cars) { $outByIdx[[int]$c.idx] = $c }
  $battleOk = $d.battles.Count -le [math]::Floor($n / 2); $seen = @{}
  foreach ($b in $d.battles) {
    $a = [int]$b.a; $z = [int]$b.b
    if (-not $positions.ContainsKey($a) -or -not $positions.ContainsKey($z) -or [math]::Abs($positions[$a] - $positions[$z]) -ne 1 -or $seen.ContainsKey($a) -or $seen.ContainsKey($z) -or -not $outByIdx.ContainsKey($a) -or -not $outByIdx.ContainsKey($z) -or $outByIdx[$a].pit -or $outByIdx[$z].pit -or $outByIdx[$a].classId -ne $outByIdx[$z].classId) { $battleOk = $false }
    $seen[$a] = $true; $seen[$z] = $true
  }
  return @{ positions=$posOk; gaps=$mono; battles=$battleOk; n=$n }
}
$api = 'http://localhost:8199'; $hook = Join-Path $root 'dash\test-hook.on'
$testDir = Join-Path $root 'vault-test'; $yamlPath = Join-Path $testDir 'tv-live-race-test.yaml'
$madeHook = $false; $startedDir = $false
try {
  Section '1. guarded pretend race setup'
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/tv" -TimeoutSec 5 } catch { throw 'irdash local server is not running' }
  if (-not (Test-Path $testDir)) { New-Item -ItemType Directory -Force $testDir | Out-Null; $startedDir = $true }
  $samples = @(Get-Content (Join-Path $PSScriptRoot 'fixtures\tv-live-race1.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
  if (-not (Test-Path $hook)) { [IO.File]::WriteAllText($hook, 'tv-live-race-test'); $madeHook = $true }
  Set-SampleField $samples[0] $yamlPath
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/field?on=1&pump=20&ms=0" -TimeoutSec 10
  $null = Invoke-RestMethod -UseBasicParsing "$api/api/test/replaylog?clear=1" -TimeoutSec 10

  Section '2. raw fixture samples are derived by the deployed TV engine'
  $sampleNo = 0; $bad = 0; $lastData = $null; $minCars = [int]::MaxValue; $maxCars = 0; $emptyFrames = 0; $maxBattles = 0; $maxGap = 0.0
  foreach ($s in $samples) {
    if (($sampleNo % 10) -eq 0) { Assert-RigFree -Where "fixture sample $sampleNo" }
    Set-SampleField $s $yamlPath
    $d = Send-And-Read (Raw-Values $s) $s.d.tick
    $v = Validate-Snapshot $s $d
    if ($v.n -lt $minCars) { $minCars = $v.n }; if ($v.n -gt $maxCars) { $maxCars = $v.n }; if ($v.n -eq 0) { $emptyFrames++ }
    if ($d.battles.Count -gt $maxBattles) { $maxBattles = $d.battles.Count }
    foreach ($c in $d.cars) { if ($null -ne $c.gap -and [double]$c.gap -gt $maxGap) { $maxGap = [double]$c.gap } }
    if (-not $v.positions -or -not $v.gaps -or -not $v.battles) { $bad++; "  info  tick $($s.d.tick): positions=$($v.positions), monotonicGaps=$($v.gaps), battles=$($v.battles), cars=$($v.n), got=$($d | ConvertTo-Json -Depth 5 -Compress)" }
    $lastData = $d; $sampleNo++
  }
  Check "$sampleNo fixture frames: /tv/data has positions 1..N, monotonic derived gaps, adjacent/disjoint battles" ($bad -eq 0)
  "  data  cars=$minCars..$maxCars, empty=$emptyFrames, peakBattles=$maxBattles, largestGap=$([math]::Round($maxGap, 3)) s"
  Check 'TV data remains readable with pretend IsOnTrack=1' ($lastData.cars.Count -gt 0 -and [double]$lastData.tick -eq [double]$samples[-1].d.tick)
  Check 'no outgoing SDK commands during raw sample replay' (((Invoke-RestMethod -UseBasicParsing "$api/api/test/replaylog?clear=1" -TimeoutSec 10).msgs.Count) -eq 0)
} finally {
  try { Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 5 | Out-Null } catch { }
  try { Invoke-WebRequest -UseBasicParsing "$api/api/test/field?on=0&pump=33&ms=0" -TimeoutSec 5 | Out-Null } catch { }
  if ($madeHook -and (Test-Path $hook)) { Remove-Item -LiteralPath $hook -Force -ErrorAction SilentlyContinue }
  if (Test-Path $yamlPath) { Remove-Item -LiteralPath $yamlPath -Force -ErrorAction SilentlyContinue }
  if ($startedDir -and (Test-Path $testDir) -and -not (Get-ChildItem $testDir -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $testDir -Force -ErrorAction SilentlyContinue }
  Exit-TestLock
}
"$pass ok, $fail FAIL"
if ($fail -gt 0) { exit 1 }
