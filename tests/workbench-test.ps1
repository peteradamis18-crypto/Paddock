# W1 Analysis Workbench core (docs\DESIGN-workbench.md 4-5): the channel endpoint on COPIES of two old .ibt files (the
# vault's own copies, never Documents\iRacing, never the newest file) and the page in headless Chrome at 1920x1080 against
# a fixture made from a real lap by that same endpoint. The live part (a running irdash) only runs when the lead has
# deployed a build newer than dash\src\workbench.cs; otherwise it says so and is skipped. Out of the car only (guard.ps1).
#   powershell -ExecutionPolicy Bypass -File tests\workbench-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree

$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; Write-Host "  ok    $what" } else { $script:fail++; Write-Host "  FAIL  $what" } }
function Note($what) { Write-Host "  info  $what" }
function Near($a, $b, $tol) { [math]::Abs([double]$a - [double]$b) -le $tol }
function Section($title) { Assert-RigFree -Where $title; Write-Host $title }

$me = Get-Process -Id $PID
$me.PriorityClass = 'BelowNormal'
$cores = [Environment]::ProcessorCount
if ($cores -gt 2) { $mask = [int64]0; for ($i = 0; $i -lt 2; $i++) { $mask = $mask -bor ([int64]1 -shl ($cores - 1 - $i)) }; $me.ProcessorAffinity = [IntPtr]$mask }

$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$shipped = Join-Path $root 'dash\irdash.exe'
$shippedStamp = (Get-Item -LiteralPath $shipped).LastWriteTimeUtc.Ticks
$vaultDir = Join-Path $root 'vault\telemetry\chevrolet-corvette-z06-gt3-r\road-atlanta-full-course'
# the PB session (lap 7 = 79.549) and the afternoon session whose lap 7 (79.575) is the next best, both already known to analysis-test
$pbName = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt'
$midName = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 13-28-11.ibt'
$copies = @(@{ from = '2026-10-10 00-13-18.ibt'; to = $pbName }, @{ from = '2026-10-10 13-28-11.ibt'; to = $midName })
$CH = 'Speed,Throttle,Brake,BrakeABSactive,SteeringWheelAngle,SteeringWheelPctTorque,Gear,RPM,LatAccel,LongAccel,VelocityX,VelocityY,YawRate,Lat,Lon,LFspeed,RFspeed,LRspeed,RRspeed,dcBrakeBias'
$work = Join-Path $env:TEMP ('workbench-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

# ---- the binary reply: "PWB1", int32 header length, JSON header, Float32 arrays in the header's order ----
function Read-Wb($path) {
  $b = [IO.File]::ReadAllBytes($path)
  if ($b.Length -lt 8 -or [Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'PWB1') { return @{ ok = $false; text = [Text.Encoding]::UTF8.GetString($b) } }
  $hl = [BitConverter]::ToInt32($b, 4); $head = [Text.Encoding]::UTF8.GetString($b, 8, $hl) | ConvertFrom-Json
  $arr = @{}; $pos = 8 + $hl; $n = [int]$head.n
  foreach ($k in $head.arrays) { $a = [Array]::CreateInstance([single], $n); [Buffer]::BlockCopy($b, $pos, $a, 0, $n * 4); $arr[$k] = $a; $pos += $n * 4 }
  return @{ ok = $true; head = $head; arr = $arr; bytes = $b.Length; used = $pos }
}
# an independent reader (PowerShell, straight from the .ibt) for the hand checks
function Ibt-Raw($file, $lap, $names) {
  $b = [IO.File]::ReadAllBytes($file)
  $bl = [BitConverter]::ToInt32($b, 36); $bo = [BitConverter]::ToInt32($b, 52); $rc = [BitConverter]::ToInt32($b, 140)
  $nv = [BitConverter]::ToInt32($b, 24); $vho = [BitConverter]::ToInt32($b, 28); $vars = @{}
  for ($i = 0; $i -lt $nv; $i++) { $p = $vho + 144 * $i; $vars[[Text.Encoding]::ASCII.GetString($b, $p + 16, 32).Trim([char]0)] = @{ t = [BitConverter]::ToInt32($b, $p); o = [BitConverter]::ToInt32($b, $p + 4) } }
  $cols = @{}; foreach ($k in $names) { $cols[$k] = New-Object System.Collections.Generic.List[double] }
  $oLap = $vars['Lap'].o; $oOn = $vars['IsOnTrack'].o
  for ($r = 0; $r -lt $rc; $r++) {
    $base = $bo + $r * $bl
    if ($b[$base + $oOn] -eq 0 -or [BitConverter]::ToInt32($b, $base + $oLap) -ne $lap) { continue }
    foreach ($k in $names) { $v = $vars[$k]; $x = switch ($v.t) { 1 { [double]$b[$base + $v.o] } 2 { [double][BitConverter]::ToInt32($b, $base + $v.o) } 3 { [double][BitConverter]::ToInt32($b, $base + $v.o) } 4 { [double][BitConverter]::ToSingle($b, $base + $v.o) } 5 { [BitConverter]::ToDouble($b, $base + $v.o) } default { 0 } }; $cols[$k].Add($x) }
  }
  return $cols
}

# every record of a .ibt as double columns (for the C-41 hand checks: a second, independent reader, never Paddock's own code)
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.IO; using System.Text;
public static class WbRaw {
  public static Dictionary<string,double[]> All(string file, string[] names) {
    byte[] b = File.ReadAllBytes(file);
    int bl = BitConverter.ToInt32(b, 36), bo = BitConverter.ToInt32(b, 52), rc = BitConverter.ToInt32(b, 140), nv = BitConverter.ToInt32(b, 24), vho = BitConverter.ToInt32(b, 28);
    var vars = new Dictionary<string,int[]>();
    for (int i = 0; i < nv; i++) { int p = vho + 144 * i; vars[Encoding.ASCII.GetString(b, p + 16, 32).Trim('\0')] = new int[] { BitConverter.ToInt32(b, p), BitConverter.ToInt32(b, p + 4) }; }
    var want = new List<string>(names); if (!want.Contains("Lap")) want.Add("Lap"); if (!want.Contains("IsOnTrack")) want.Add("IsOnTrack");
    var cols = new Dictionary<string,double[]>(); foreach (var k in want) cols[k] = new double[rc];
    for (int r = 0; r < rc; r++) {
      int bs = bo + r * bl;
      foreach (var k in want) { var v = vars[k]; double x = 0; switch (v[0]) { case 0: case 1: x = b[bs + v[1]]; break; case 2: case 3: x = BitConverter.ToInt32(b, bs + v[1]); break; case 4: x = BitConverter.ToSingle(b, bs + v[1]); break; case 5: x = BitConverter.ToDouble(b, bs + v[1]); break; } cols[k][r] = x; }
    }
    return cols;
  }
}
'@
function Lap-Idx($raw, $lap) {
  $a = $raw['Lap']; $o = $raw['IsOnTrack']; $ix = New-Object System.Collections.Generic.List[int]
  for ($i = 0; $i -lt $a.Length; $i++) { if ($o[$i] -ne 0 -and [int]$a[$i] -eq $lap) { $ix.Add($i) } }
  return , $ix.ToArray()
}
# the time at which LapDistPct reaches $target, between the two records of the lap around it
function Time-At($raw, $ix, $target) {
  $p = $raw['LapDistPct']; $t = $raw['SessionTime']
  for ($k = 1; $k -lt $ix.Length; $k++) { $a = $ix[$k - 1]; $b = $ix[$k]; if ($p[$a] -lt $target -and $p[$b] -ge $target) { return $t[$a] + ($t[$b] - $t[$a]) * ($target - $p[$a]) / ($p[$b] - $p[$a]) } }
  return $null
}
# every distance (m) where the pedal rises through $level, from the raw records
function Brake-Rises($raw, $ix, $L, $level) {
  $p = $raw['LapDistPct']; $br = $raw['Brake']; $out = New-Object System.Collections.Generic.List[double]
  for ($k = 1; $k -lt $ix.Length; $k++) { $a = $ix[$k - 1]; $b = $ix[$k]; if ($br[$a] -le $level -and $br[$b] -gt $level) { $out.Add($L * ($p[$a] + ($level - $br[$a]) / ($br[$b] - $br[$a]) * ($p[$b] - $p[$a]))) } }
  return , $out.ToArray()
}

# ---- headless Chrome with the DevTools protocol (the same harness as data-test) ----
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('wb-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9361
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', '--allow-file-access-from-files', 'about:blank') -PassThru -WindowStyle Hidden
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  if (-not $page) { throw 'headless Chrome did not start' }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0; errors = New-Object System.Collections.Generic.List[string] }
  $null = Cdp 'Page.enable' @{}
  $null = Cdp 'Runtime.enable' @{}
  $null = Cdp 'Emulation.setDeviceMetricsOverride' @{ width = $w; height = $h; deviceScaleFactor = 1; mobile = $false }
  $null = Cdp 'Page.navigate' @{ url = $url }
}
function Cdp($method, $params) {
  $c = $script:cdp; $c.id++
  $bytes = [Text.Encoding]::UTF8.GetBytes((@{ id = $c.id; method = $method; params = $params } | ConvertTo-Json -Depth 8 -Compress))
  $null = $c.ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [Threading.CancellationToken]::None).Wait()
  while ($true) {
    $buf = New-Object byte[] 262144; $sb = New-Object Text.StringBuilder
    do { $seg = New-Object ArraySegment[byte] -ArgumentList @(, $buf); $r = $c.ws.ReceiveAsync($seg, [Threading.CancellationToken]::None); $null = $r.Wait(); [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Result.Count)) } while (-not $r.Result.EndOfMessage)
    $o = $sb.ToString() | ConvertFrom-Json
    if ($o.method -eq 'Runtime.exceptionThrown') { $c.errors.Add($o.params.exceptionDetails.exception.description) }
    if ($o.id -eq $c.id) { return $o }
  }
}
function Cdp-Eval($expr) { $r = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }; if ($r.result.exceptionDetails) { return "js error: " + $r.result.exceptionDetails.exception.description }; return $r.result.result.value }
function Cdp-Json($expr) { return (Cdp-Eval "JSON.stringify($expr)") | ConvertFrom-Json }
function Cdp-Key($key, $code, $text) { $null = Cdp 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = $key; code = $code; text = $text; windowsVirtualKeyCode = 0 }; $null = Cdp 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = $key; code = $code } }
function Cdp-Shot($path) { $s = Cdp 'Page.captureScreenshot' @{ format = 'png' }; [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data)) }
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 300; try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
# the colour of one pixel of a display's overlay canvas (page-level helper: kind, x, y)
$pixelJs = '(function(k,x,y){var d=WB.displays().filter(function(q){return q.kind===k})[0];var r=devicePixelRatio||1;var p=d.co.getImageData(Math.round(x*r),Math.round(y*r),1,1).data;return [p[0],p[1],p[2],p[3]]})'
function Gold($p) { return ($p[0] -gt 200 -and $p[1] -gt 150 -and $p[1] -lt 230 -and $p[2] -lt 110 -and $p[3] -gt 200) }

try {
  New-Item -ItemType Directory -Force $work | Out-Null
Section '1. copies of two old sessions (the vault''s own copies)'
$sessionJs = Get-Content -LiteralPath (Join-Path $root 'dash\www\v2\sessions.js') -Raw
Check 'Sessions keeps its session rows and no longer declares the old trace view or render helpers' ($sessionJs -match 'data-file=' -and $sessionJs -notmatch 'function\s+(showTraces|getTrace|drawMap|renderRight|pointer|stepCompare)\s*\(' -and $sessionJs -notmatch 'id="plotBox"|id="anRight"|/ibt/lap\?file=')
  $newestDoc = $null
  $docTel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
  if (Test-Path -LiteralPath $docTel) { $newestDoc = Get-ChildItem -LiteralPath $docTel -Filter '*.ibt' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
  Check 'neither copy is the newest telemetry file' (-not $newestDoc -or ($newestDoc.Name -ne $pbName -and $newestDoc.Name -ne $midName))
  foreach ($c in $copies) {
    $from = Join-Path $vaultDir $c.from
    Check "the vault copy is there: $($c.from)" (Test-Path -LiteralPath $from)
    Copy-Item -LiteralPath $from -Destination (Join-Path $work $c.to)
  }

  Section '2. compile without deploying'
  $build = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'dash\build.ps1') -NoDeploy | Out-String
  $m = [regex]::Match($build, 'built in (.+?) \(not deployed\)')
  Check 'dash\build.ps1 -NoDeploy compiled' ($LASTEXITCODE -eq 0 -and $m.Success)
  if (-not $m.Success) { throw $build }
  $exe = Join-Path $m.Groups[1].Value.Trim() 'irdash.exe'

  function Invoke-Channels($id, $lap, $ref, $ch, $tag, $laps = '') {
    $out = Join-Path $work "$tag.bin"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $multiArg = if ($laps) { "--laps `"$laps`" " } else { '' }
    $psi.Arguments = "--analysis --channels --root `"$root`" --dir `"$work`" --id `"$id`" --lap $lap --ref `"$ref`" --ch `"$ch`" $multiArg--out `"$out`""
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $proc = [Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit(240000)) { try { $proc.Kill() } catch { }; throw "channels $tag timed out" }
    $r = Read-Wb $out; $r.exit = $proc.ExitCode; $r.ms = $sw.ElapsedMilliseconds; $r.path = $out
    return $r
  }

  Section '3. the channel endpoint: two laps x 20 channels, aligned, time pinned to the official lap time'
  $w1 = Invoke-Channels $pbName 7 'pb' $CH 'lap7'
  $w2 = Invoke-Channels $pbName 7 'pb' $CH 'lap7b'
  Check 'the reply is a PWB1 binary and the exit code is 0' ($w1.ok -and $w1.exit -eq 0 -and $w2.ok)
  if (-not $w1.ok) { throw "channels failed: $($w1.text)" }
  $h = $w1.head; $n = [int]$h.n
  Note "lap 7 of $($h.lap.file): $($h.lap.time) s, reference $($h.ref.kind) $($h.ref.file) lap $($h.ref.lap) $($h.ref.time) s; $n samples x $($h.arrays.Count) arrays = $($w1.bytes) bytes"
  Note "endpoint time including process start: $($w1.ms) ms first, $($w2.ms) ms second (both files read each time)"
  Check 'two laps x 20 channels (plus the time axes) in well under a second, process start included' ($w2.ms -lt 1000 -and $h.arrays.Count -eq 42)
  Check 'the lap is the Corvette at Road Atlanta, lap 7, official 79.549 to the 1/1000' ($h.car -eq 'Chevrolet Corvette Z06 GT3.R' -and $h.track -eq 'Road Atlanta' -and $h.lap.lap -eq 7 -and (Near $h.lap.official 79.549 0.0005) -and (Near $h.lap.time 79.549 0.0005))
  Check 'the reference is the next best lap of the car and track (afternoon lap 7, 79.575), never the lap itself' ($h.ref.kind -eq 'pb' -and $h.ref.file -eq $midName -and $h.ref.lap -eq 7 -and (Near $h.ref.time 79.575 0.0005) -and (Near $h.ref.official 79.575 0.0005))
  Check 'the grid is metres + 1 samples about 1 m apart over the whole lap' ($n -eq [int]$h.metres + 1 -and (Near $h.step 1 0.01) -and [double]$h.lengthM -gt 4000 -and [double]$h.lengthM -lt 4100)
  Check 'every array has n samples and the file holds exactly them' ($w1.used -eq $w1.bytes)
  $t = $w1.arr['lap.t']; $tr = $w1.arr['ref.t']
  Check 'the time axis starts at 0 and ends exactly on the official lap time (both laps)' ($t[0] -eq 0 -and (Near $t[$n - 1] 79.549 0.001) -and $tr[0] -eq 0 -and (Near $tr[$n - 1] 79.575 0.001))
  $mono = $true; for ($i = 1; $i -lt $n; $i++) { if ($t[$i] -lt $t[$i - 1] -or $tr[$i] -lt $tr[$i - 1]) { $mono = $false; break } }
  Check 'time never runs backwards' $mono
  $chans = @($h.channels); $okAll = $true; foreach ($c in $chans) { if (-not $c.ok) { $okAll = $false } }
  Check 'all 20 channels were found in the file, with units from the file (Speed m/s, SteeringWheelAngle rad)' ($chans.Count -eq 20 -and $okAll -and ($chans | Where-Object { $_.key -eq 'Speed' }).unit -eq 'm/s' -and ($chans | Where-Object { $_.key -eq 'SteeringWheelAngle' }).unit -eq 'rad')
  $gear = $w1.arr['lap.Gear']; $whole = $true; foreach ($g in $gear) { if ($g -ne [math]::Round($g)) { $whole = $false; break } }
  Check 'gear (a whole-number channel) holds its value between samples instead of interpolating' $whole
  $lat = $w1.arr['lap.Lat']; $lon = $w1.arr['lap.Lon']; $kmh = $w1.arr['lap.Speed'] | ForEach-Object { $_ * 3.6 } | Measure-Object -Maximum -Minimum
  Check 'Lat/Lon sit at Road Atlanta and the speeds are a GT3 lap' ((Near $lat[0] 34.15 0.05) -and (Near $lon[0] -83.81 0.05) -and $kmh.Maximum -gt 200 -and $kmh.Maximum -lt 300 -and $kmh.Minimum -gt 40)
  # hand checks against an independent read of the raw records: the value at the line and the speed 1000 m in
  $raw = Ibt-Raw (Join-Path $work $pbName) 7 @('LapDistPct', 'Speed', 'Throttle')
  $spd = $w1.arr['lap.Speed']; $L = [double]$h.lengthM
  Check 'the first sample is the first record of the lap (speed at the line, raw vs endpoint)' (Near $spd[0] $raw['Speed'][0] 0.001)
  $target = 1000.0; $j = -1; for ($i = 1; $i -lt $raw['LapDistPct'].Count; $i++) { if ($raw['LapDistPct'][$i] * $L -ge $target) { $j = $i; break } }
  $d0 = $raw['LapDistPct'][$j - 1] * $L; $d1 = $raw['LapDistPct'][$j] * $L; $f = ($target - $d0) / ($d1 - $d0)
  $hand = $raw['Speed'][$j - 1] + ($raw['Speed'][$j] - $raw['Speed'][$j - 1]) * $f
  $k1000 = [int][math]::Round(1000 / [double]$h.step)
  Note "HAND CHECK speed 1000 m into lap 7: raw records give $([math]::Round($hand, 3)) m/s, the endpoint $([math]::Round($spd[$k1000], 3)) m/s"
  Check 'the speed 1000 m into the lap matches the raw records within 0.05 m/s' (Near $spd[$k1000] $hand 0.05)
  Check '14 named corners come with the lap (Lovely Track Data, credit kept)' (@($h.corners).Count -eq 14 -and $h.credit -like '*Lovely*' -and (@($h.corners | Where-Object { $_.label -eq 'T10a' }).Count -eq 1))
  Check 'the session lap list is there for the navigator (14 laps, lap 7 official 79.549)' (@($h.laps).Count -eq 14 -and (@($h.laps | Where-Object { $_.n -eq 7 -and (Near $_.official 79.549 0.0005) }).Count -eq 1))
  $w3 = Invoke-Channels $pbName 7 ($pbName + ':8') 'Speed,Gear' 'ref8'
  Check 'ref=<file>:<lap> picks that lap (lap 8, 79.878) and a short channel list gives a short reply' ($w3.ok -and $w3.head.ref.kind -eq 'lap' -and $w3.head.ref.lap -eq 8 -and (Near $w3.head.ref.time 79.878 0.0005) -and $w3.head.arrays.Count -eq 6)
  $w4 = Invoke-Channels $pbName 99 'pb' 'Speed' 'nolap'
  Check 'a lap that is not in the file is a JSON error and exit 1' (-not $w4.ok -and $w4.exit -eq 1 -and $w4.text -like '*"error"*')
  $w5 = Invoke-Channels $pbName 7 'pb' 'Speed,NoSuchChannel,Speed' 'unknown'
  Check 'an unknown channel comes back flagged (ok=false, zeros), repeats are dropped' ($w5.ok -and @($w5.head.channels).Count -eq 2 -and (@($w5.head.channels | Where-Object { $_.key -eq 'NoSuchChannel' })[0].ok -eq $false))
  Section '3b. 3, 4 and 6 real laps with differing source grids return active-grid arrays'
  $channelsSource = Get-Content -LiteralPath (Join-Path $root 'dash\src\workbench.cs') -Raw
  Check 'a selected lap is not rejected only because its source metre grid differs from the active grid' ($channelsSource -notmatch 'found\.Metres\s*!=\s*me\.Metres')
  $cleanOtherLaps = @(8,9,10,4,5)
  foreach ($count in 2,3,5) {
    $selected = $cleanOtherLaps[0..($count - 1)] | ForEach-Object { $pbName + ':' + $_ }
    $spec = $selected -join ','
    $mr = Invoke-Channels $pbName 7 'pb' 'Speed,Gear' ('multi' + ($count + 1)) $spec
    $wantLaps = $count + 1
    Check "$wantLaps real laps return one time and two channel arrays resampled to the active grid" ($mr.ok -and $mr.exit -eq 0 -and $mr.head.multi.Count -eq $count -and $mr.head.n -eq $w1.head.n -and $mr.head.arrays.Count -eq $wantLaps * 3 -and $mr.used -eq $mr.bytes)
    $infoOk = $true; for ($mi = 0; $mi -lt $count; $mi++) { $ln = $cleanOtherLaps[$mi]; $info = @($mr.head.multi | Where-Object { $_.lap -eq $ln })[0]; if (-not $info -or $info.time -le 0 -or $mr.arr[('m' + $mi + '.Speed')].Count -ne $mr.head.n) { $infoOk = $false } }
    Check "$wantLaps laps expose their actual lap numbers, times and $($mr.head.n)-sample Speed arrays" $infoOk
  }
  $dup = Invoke-Channels $pbName 7 'pb' 'Speed' 'multidup' ($pbName + ':8,' + $pbName + ':8')
  Check 'duplicate lap keys fail closed with an error reply' (-not $dup.ok -and $dup.exit -eq 1 -and $dup.text -like '*duplicate lap*')

  Section '4. the page in headless Chrome against the fixtures (shared cursor, linked zoom, playback, keys, pictures)'
  function FxUrl($f) { return 'file:///' + ($f -replace '\\', '/') }
  function Invoke-Mode($mode, $tag, $extra, $id = $null) {
    if (-not $id) { $id = $pbName }
    $out = Join-Path $work "$tag.json"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = "--analysis --$mode $extra --root `"$root`" --dir `"$work`" --id `"$id`" --lap 7 --ref pb --out `"$out`""
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $sw = [Diagnostics.Stopwatch]::StartNew(); $proc = [Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit(240000)) { try { $proc.Kill() } catch { }; throw "$mode $tag timed out" }
    $txt = [IO.File]::ReadAllText($out)
    return @{ path = $out; json = ($txt | ConvertFrom-Json); exit = $proc.ExitCode; ms = $sw.ElapsedMilliseconds }
  }
  # the channels the page itself asks for (workbench.js CHANS), the C-34 deep-dive reply and the session reply with every lap's corner times
  $chp = ([regex]::Match((Get-Content (Join-Path $root 'dash\www\v2\workbench.js') -Raw), 'var CHANS = \[(.*?)\];', 'Singleline').Groups[1].Value -replace "[\s']", '')
  $wf = Invoke-Channels $pbName 7 'pb' $chp 'lap7full'
  $wMultiPage = Invoke-Channels $pbName 7 'pb' $chp 'multilap-page' (($cleanOtherLaps | ForEach-Object { $pbName + ':' + $_ }) -join ',')
  Check 'the six-lap Chrome fixture is a real PWB1 reply with five selected clean laps' ($wMultiPage.ok -and $wMultiPage.head.multi.Count -eq 5 -and $wMultiPage.head.ref -eq $null)
  $dp = Invoke-Mode 'deep' 'deep7' ''
  $se = Invoke-Mode 'session' 'sess7' '--corners'
  $null = Invoke-Channels $pbName 7 'pb' 'Pitch' 'x-Pitch'
  $null = Invoke-Channels $pbName 7 'pb' 'dcThrottleShape' 'x-dcThrottleShape'
  $wMid = Invoke-Channels $midName 7 'pb' $chp 'mid7full'
  $seMid = Invoke-Mode 'session' 'sess-mid' '--corners' $midName
  Section '3a. conditions use the selected lap records in two real telemetry copies'
  foreach ($sample in @(@{ file = $pbName; head = $w1.head }, @{ file = $midName; head = $wMid.head })) {
    $rawC = Ibt-Raw (Join-Path $work $sample.file) 7 @('AirTemp', 'TrackTempCrew', 'WindVel', 'WindDir', 'Skies', 'TrackWetness')
    $cond = $sample.head.conditions
    foreach ($pair in @(@('AirTemp','airC'), @('TrackTempCrew','trackC'), @('WindVel','windMs'))) {
      $vals = @($rawC[$pair[0]] | Sort-Object); $nval = $vals.Count; $median = if ($nval % 2) { $vals[[int]($nval / 2)] } else { ($vals[$nval / 2 - 1] + $vals[$nval / 2]) / 2 }
      Check "$($sample.file) lap 7 $($pair[1]) median matches raw records ($([math]::Round($median,2)))" (Near $cond.PSObject.Properties[$pair[1]].Value $median 0.011)
    }
    $dirVals = @($rawC['WindDir'] | ForEach-Object { $_ * 180 / [math]::PI } | Sort-Object); $dn = $dirVals.Count; $dmedian = if ($dn % 2) { $dirVals[[int]($dn / 2)] } else { ($dirVals[$dn / 2 - 1] + $dirVals[$dn / 2]) / 2 }
    Check "$($sample.file) lap 7 windDirDeg matches converted raw radians ($([math]::Round($dmedian,1)))" (Near $cond.windDirDeg $dmedian 0.11)
    foreach ($pair in @(@('Skies','skies'), @('TrackWetness','wetness'))) {
      $mode = $rawC[$pair[0]] | Group-Object | Sort-Object Count -Descending | Select-Object -First 1
      Check "$($sample.file) lap 7 $($pair[1]) matches raw mode $($mode.Name)" ($cond.PSObject.Properties[$pair[1]].Value -eq [double]$mode.Name)
    }
    Note "$($sample.file) conditions: air $($cond.airC) °C, track $($cond.trackC) °C, wind $($cond.windMs) m/s / $($cond.windDirDeg)°, skies $($cond.skies), wetness $($cond.wetness)"
  }
  Check "the page's own channel list ($(@($chp.Split(',')).Count) channels, workbench.js CHANS) is complete in the Corvette file" ($wf.ok -and @($wf.head.channels | Where-Object { -not $_.ok }).Count -eq 0 -and @($wf.head.channels).Count -eq @($chp.Split(',')).Count)
  Check 'the deep-dive reply and the session reply (with corners=1) come out of the same files, exit 0' ($dp.exit -eq 0 -and $se.exit -eq 0 -and @($dp.json.laps).Count -ge 10 -and @($se.json.turns).Count -eq 14 -and $se.json.laps[1].cornerT.Count -eq 14)
  Note "deep reply $([math]::Round((Get-Item $dp.path).Length / 1KB)) KB in $($dp.ms) ms, session reply with corners $([math]::Round((Get-Item $se.path).Length / 1KB, 1)) KB in $($se.ms) ms (process start and both files included)"
  $fixture = $wf.path
  $fxBase = 'file:///' + ($root -replace '\\', '/') + '/dash/www/v2/workbench.html?data=' + (FxUrl $fixture)
  $url = $fxBase + '&page=driver&deep=' + (FxUrl $dp.path) + '&session=' + (FxUrl $se.path) + '&xdata=' + (FxUrl (Join-Path $work 'x-{ch}.bin'))
  Cdp-Open $url
  $ready = $false
  for ($i = 0; $i -lt 80 -and -not $ready; $i++) { Start-Sleep -Milliseconds 250; $ready = (Cdp-Eval 'window.WB && (WB.extras || WB.error) ? 1 : 0') -eq 1 }
  Start-Sleep -Milliseconds 500
  Check 'the DRIVER page loaded the fixture without a JavaScript error' ($ready -and -not (Cdp-Eval 'WB.error || ""') -and $script:cdp.errors.Count -eq 0)
  Section '4a. reference offset controls and brake auto-align'
  $offsetChecks = Cdp-Json '(function(){var d=WB.data(),step=d.step,origA=d.A.c.Brake.slice(),origR=d.R.c.Brake.slice(),corners=d.corners,old=[WB.state.z0,WB.state.z1];WB.cmd("zoom-reset");WB.cmd("offset","reset");WB.cmd("offset",12);var speed=0,n=0;for(var i=0;i<d.n;i++)if(d.A.c.Speed[i]>0){speed+=d.A.c.Speed[i];n++}var tr=WB.displays().filter(function(x){return x.kind==="traces"})[0],x0=tr.xOf(100),x1=tr.xOf(100+12/step),expected=12/step*tr.W/(WB.state.z1-WB.state.z0),manual=Math.abs(WB.state.offsetM-12)<0.001&&Math.abs(WB.state.offsetS-12/(speed/n))<0.02&&Math.abs((x1-x0)-expected)<0.01&&document.getElementById("mode").textContent.indexOf("12 m")>=0&&document.getElementById("mode").textContent.indexOf(" s")>=0;WB.cmd("offset");var mode=document.getElementById("mode").textContent.indexOf("OFFSET MODE")>=0;WB.cmd("offset");var c=d.cstat.filter(function(x){return x.c.i0<d.n-30&&x.c.i1>d.n/4})[0],off=WB.state.offsetM/step,vals=[];for(i=c.c.i0;i<=c.c.i1;i++)if(i-off>=0&&i-off<d.n){var j=Math.floor(i-off),f=i-off-j;vals.push(d.R.c.kmh[j]+(j+1<d.n?(d.R.c.kmh[j+1]-d.R.c.kmh[j])*f:0))}var want=Math.min.apply(null,vals),corner=Math.abs(c.r.vmin-want)<0.2;for(i=0;i<d.n;i++){d.A.c.Brake[i]=0;d.R.c.Brake[i]=0}for(i=500;i<d.n;i++){d.A.c.Brake[i]=i<520?0:0.2;d.R.c.Brake[i]=i<550?0:0.2}WB.state.z0=100;WB.state.z1=900;d.corners=[];WB.cmd("offset-auto");var auto=Math.abs(WB.state.offsetM+30*step)<=2*step,action=WB.cmd("offset-auto")===true;for(i=0;i<d.n;i++){d.A.c.Brake[i]=0;d.R.c.Brake[i]=0}var before=WB.state.offsetM;WB.cmd("offset-auto");var unavailable=WB.state.offsetM===before&&document.getElementById("mode").textContent.indexOf("AUTO UNAVAILABLE")>=0;d.A.c.Brake.set(origA);d.R.c.Brake.set(origR);d.corners=corners;WB.state.z0=old[0];WB.state.z1=old[1];WB.cmd("offset","reset");return {manual:manual,auto:auto,action:action,mode:mode,corner:corner,unavailable:unavailable,seconds:WB.state.offsetS}})()'
  Note "offset regression measured manual=$($offsetChecks.manual), auto=$($offsetChecks.auto); final seconds=$($offsetChecks.seconds)"
  Check 'manual offset advances the reference exactly 12 m and reports metres and seconds' $offsetChecks.manual
  Check 'offset mode visibly announces that arrow keys move the reference' $offsetChecks.mode
  Check 'the corner reference summary follows the shifted reference samples' $offsetChecks.corner
  $buttonOffset = Cdp-Eval '(function(){var b=document.querySelector(".offbtn[data-off=\"1\"]");if(!b)return false;b.click();var ok=WB.state.offsetM===1&&document.getElementById("mode").textContent.indexOf("+1 m")>=0;WB.cmd("offset","reset");return ok})()'
  Check 'the visible plus control moves the reference by one metre' ($buttonOffset -eq $true)
  Check 'AUTO aligns synthetic brake onsets separated by 30 m within 2 m' $offsetChecks.auto
  Check 'AUTO with no brake event reports unavailable and leaves the prior offset intact' $offsetChecks.unavailable
  Check 'the workbench auto-align command is callable from the deck action' $offsetChecks.action
  Check 'the deck auto-align action runs through the same command and changes measured offset' ($offsetChecks.action -and $offsetChecks.auto)
  $hdr = Cdp-Eval 'document.getElementById("vs").textContent'
  Check 'the header shows this lap 1:19.549, the reference 1:19.575 and the gap' ($hdr -like '*1:19.549*' -and $hdr -like '*1:19.575*' -and $hdr -like '*GAP*')
  Check 'the Workbench header shows the conditions from the selected lap, including wind direction' ((Cdp-Eval 'document.getElementById("mode").textContent') -like '*Air*°C*Track*°C*Wind*m/s*°*Skies*Wet*')
  Check 'the conditions line fits above the lap navigator without clipping or overlap' (Cdp-Eval '(function(){var m=document.getElementById("mode"),n=document.getElementById("nav"),a=m.getBoundingClientRect(),b=n.getBoundingClientRect();return m.scrollWidth<=m.clientWidth&&a.bottom<=b.top})()')
  $st = Cdp-Json 'WB.state'
  Check 'the page opens on the apex of the corner that cost the most (the cursor is inside a corner)' ($st.cur -gt 0 -and (Cdp-Eval 'document.querySelector(".ph b") ? document.querySelector(".ph b").textContent : ""') -match '^T\d|Esses')
  $kinds = Cdp-Json 'WB.displays().map(function(d){return d.kind})'
  Check 'DRIVER has map, readouts, pedals, trace stack and events list' (($kinds -contains 'map') -and ($kinds -contains 'readouts') -and ($kinds -contains 'pedals') -and ($kinds -contains 'traces') -and ($kinds -contains 'events'))
  $ov = Cdp-Json 'WB.overlaps()'
  Note "DRIVER text boxes measured: $($ov.boxes)" ; if ($ov.bad.Count) { Note ('overlapping: ' + ($ov.bad -join '; ')) }
  Check 'no text overlaps another on DRIVER (canvas and DOM boxes measured)' ($ov.boxes -gt 100 -and $ov.bad.Count -eq 0)
  $small = Cdp-Json '(function(){var out=[];WB.textBoxes().forEach(function(b){if(b.h<12)out.push(b.s)});return out})()'
  Check 'canvas labels are 14 px or larger (the only exception: the corner numbers inside the map circles)' (@($small | Where-Object { $_ -notmatch '^[0-9A-Za-z]{1,3}$' }).Count -eq 0)
  # shared cursor: one command moves the trace cursor, the map dot and the readouts together
  $null = Cdp-Eval 'WB.cmd("cursor", 1500)'; Start-Sleep -Milliseconds 120
  $sync = Cdp-Json ('(function(){var tr=WB.displays().filter(function(d){return d.kind==="traces"})[0],mp=WB.displays().filter(function(d){return d.kind==="map"})[0];var x=tr.xOf(WB.state.cur),p=mp.pt(WB.state.cur);var px=' + $pixelJs + ';return {cur:WB.state.cur,trace:px("traces",x,100),map:px("map",p[0],p[1]),speed:document.querySelector("table.ro td.a").textContent,kmh:WB.data().A.c.kmh[1500].toFixed(0)}})()')
  Check 'cursor 1500: the trace cursor line is drawn gold where the engine says it is' ($sync.cur -eq 1500 -and (Gold $sync.trace))
  Check 'cursor 1500: the map dot is gold at the same sample' (Gold $sync.map)
  Check 'cursor 1500: the readouts show the speed of that sample' ($sync.speed -eq $sync.kmh)
  # linked zoom: every trace display and the map share the window; zoom-out restores
  $null = Cdp-Eval 'WB.cmd("zoom-in"); WB.cmd("zoom-in")'; Start-Sleep -Milliseconds 120
  $z = Cdp-Json 'WB.state'
  Check 'zoom-in twice: the window is a quarter of the lap around the cursor' (($z.z1 - $z.z0) -lt ($n / 4 + 2) -and $z.z0 -le 1500 -and $z.z1 -ge 1500)
  $null = Cdp-Eval 'WB.cmd("zoom-out"); WB.cmd("zoom-out")'; Start-Sleep -Milliseconds 120
  $z = Cdp-Json 'WB.state'
  Check 'zoom-out twice (Backspace) brings the whole lap back' ($z.z0 -eq 0 -and $z.z1 -eq $n - 1)
  # playback: the cursor and the map dot move together, smoothly, at the frame rate
  $null = Cdp-Eval 'WB.cmd("cursor", 200); WB.perf(); WB.cmd("speed", "1"); WB.cmd("play")'
  $before = Cdp-Json ('(function(){var mp=WB.displays().filter(function(d){return d.kind==="map"})[0];var p=mp.pt(WB.state.cur);return {cur:WB.state.cur,x:p[0],y:p[1],frames:WB.perf().frames,t:WB.data().A.t[Math.round(WB.state.cur)]}})()')
  Start-Sleep -Milliseconds 1000
  $after = Cdp-Json ('(function(){var mp=WB.displays().filter(function(d){return d.kind==="map"})[0];var p=mp.pt(WB.state.cur);var px=' + $pixelJs + ';return {cur:WB.state.cur,playing:WB.state.playing,x:p[0],y:p[1],now:px("map",p[0],p[1]),old:px("map",' + $before.x + ',' + $before.y + '),frames:WB.perf().frames,t:WB.data().A.t[Math.round(WB.state.cur)]}})()')
  $null = Cdp-Eval 'WB.cmd("pause")'
  $moved = [math]::Sqrt(($after.x - $before.x) * ($after.x - $before.x) + ($after.y - $before.y) * ($after.y - $before.y))
  $framesIn1s = $after.frames - $before.frames
  $played = $after.t - $before.t
  Note "playback 1 s at 1x: cursor $($before.cur) -> $([math]::Round($after.cur, 1)) ($([math]::Round($played, 2)) s of lap time), map dot moved $([math]::Round($moved, 1)) px, $framesIn1s frames rendered"
  Check 'playback moves the cursor about one real second along the lap' ($after.playing -eq $true -and $played -gt 0.8 -and $played -lt 1.4 -and $after.cur -gt $before.cur)
  Check 'the map dot moved with it (gold at the new place, not at the old)' ($moved -gt 8 -and (Gold $after.now) -and -not (Gold $after.old))
  Check 'playback rendered at least 30 frames in that second (headless Chrome, software rendering)' ($framesIn1s -ge 30)
  # Exercise the production frame loop against the real telemetry-derived fixture, not a source-text check.
  foreach ($rate in @(0.5, 1, 2, 4, 8)) {
    $null = Cdp-Eval ('WB.cmd("pause"); WB.cmd("reverse", "0"); WB.cmd("speed", "' + $rate + '"); WB.cmd("cursor", 1000); WB.cmd("play")')
    $rateBefore = [double](Cdp-Eval 'WB.data().A.t[Math.round(WB.state.cur)]')
    $clock = [Diagnostics.Stopwatch]::StartNew(); Start-Sleep -Milliseconds 1400; $clock.Stop()
    $rateAfter = [double](Cdp-Eval 'WB.data().A.t[Math.round(WB.state.cur)]'); $null = Cdp-Eval 'WB.cmd("pause")'
    $measured = ($rateAfter - $rateBefore) / $clock.Elapsed.TotalSeconds
    Note ("cursor rate {0}x: {1:N3} s/s" -f $rate, $measured)
    Check "cursor advances at $rate`x within 5 percent on the fixture data" ([math]::Abs($measured - $rate) -le $rate * 0.05)
  }
  $null = Cdp-Eval 'WB.cmd("speed", "0.5"); WB.cmd("reverse", "1"); WB.cmd("cursor", 2500); WB.cmd("play")'
  $revBefore = [double](Cdp-Eval 'WB.data().A.t[Math.round(WB.state.cur)]')
  $revClock = [Diagnostics.Stopwatch]::StartNew(); Start-Sleep -Milliseconds 1600; $revClock.Stop()
  $revAfter = [double](Cdp-Eval 'WB.data().A.t[Math.round(WB.state.cur)]'); $null = Cdp-Eval 'WB.cmd("pause")'
  $revRate = ($revBefore - $revAfter) / $revClock.Elapsed.TotalSeconds
  Note ("reverse cursor rate 0.5x: {0:N3} s/s" -f $revRate)
  Check 'reverse cursor moves backward at 0.5 seconds per second within 5 percent' ([math]::Abs($revRate - 0.5) -le 0.025)
  $null = Cdp-Eval 'WB.cmd("cursor", 2200); WB.cmd("play")'
  for ($revCheck = 1; $revCheck -le 3; $revCheck++) {
    Start-Sleep -Milliseconds 180
    $revVisual = Cdp-Json ('(function(){var tr=WB.displays().filter(function(d){return d.kind==="traces"})[0],mp=WB.displays().filter(function(d){return d.kind==="map"})[0],p=mp.pt(WB.state.cur),px=' + $pixelJs + ';return {cur:WB.state.cur,trace:px("traces",tr.xOf(WB.state.cur),100),map:px("map",p[0],p[1])}})()')
    Check "reverse checkpoint $revCheck draws the trace cursor and map dot at the same cursor" ((Gold $revVisual.trace) -and (Gold $revVisual.map))
  }
  $null = Cdp-Eval 'WB.cmd("pause")'
  $null = Cdp-Eval 'WB.cmd("reverse", "0"); WB.cmd("speed", "1"); WB.cmd("cursor", 200); WB.cmd("play")'
  # frame time, synchronous: overlay-only frames (cursor moves / playback) and full redraws (zoom changes)
  $ms = Cdp-Json '(function(){return {overlay:WB.bench(120), full:WB.bench(30, true), perf:WB.perf()}})()'
  Note ("FRAME TIME DRIVER: cursor/playback frame {0:N2} ms, full redraw (zoom) {1:N2} ms; live frames so far avg {2:N2} ms, p95 {3:N2} ms, max {4:N2} ms" -f $ms.overlay, $ms.full, $ms.perf.avgMs, $ms.perf.p95Ms, $ms.perf.maxMs)
  Check 'a cursor frame with the full DRIVER page takes under 8 ms (60 fps needs 16.7)' ($ms.overlay -lt 8)
  Check 'a full redraw of every display (zoom change) takes under 16 ms' ($ms.full -lt 16)
  # keyboard like Pi: T tile, ] next corner, [ previous, space play/pause, S rate, Shift+S reverse, Backspace zoom out, R reference cursor, O offset
  # stop the playback the frame-time check started: a moving cursor fails "] lands on the apex", and space would pause, not play
  $null = Cdp-Eval 'WB.cmd("pause"); WB.cmd("cursor", 100)'
  Cdp-Key 't' 'KeyT' 't'; Start-Sleep -Milliseconds 80
  Check 'T toggles tile / overlay' ((Cdp-Json 'WB.state').tile -eq $true)
  Cdp-Key 't' 'KeyT' 't'
  Cdp-Key ']' 'BracketRight' ']'; Start-Sleep -Milliseconds 80
  $st = Cdp-Json 'WB.state'; $apex = Cdp-Json 'WB.data().corners.map(function(c){return c.ia}).sort(function(a,b){return a-b})'
  Check '] jumps the cursor to the next corner apex' ($st.cur -eq ($apex | Where-Object { $_ -gt 102 } | Select-Object -First 1))
  Cdp-Key 'z' 'KeyZ' 'z'; Start-Sleep -Milliseconds 80
  Check 'Z zooms in at the cursor' ((Cdp-Json 'WB.state').z1 - (Cdp-Json 'WB.state').z0 -lt $n / 2 + 2)
  Cdp-Key 'Backspace' 'Backspace' ''; Start-Sleep -Milliseconds 80
  Check 'Backspace zooms back out' ((Cdp-Json 'WB.state').z1 -eq $n - 1)
  Cdp-Key 'r' 'KeyR' 'r'; Start-Sleep -Milliseconds 80
  Check 'R sets the reference cursor (differences from a fixed point)' ((Cdp-Json 'WB.state').refCur -ne $null)
  Cdp-Key 'r' 'KeyR' 'r'
  Cdp-Key 'S' 'KeyS' 'S'; Start-Sleep -Milliseconds 80
  Check 'Shift+S toggles reverse playback direction' ((Cdp-Json 'WB.state').reverse -eq $true)
  Cdp-Key 'S' 'KeyS' 'S'
  Cdp-Key 'o' 'KeyO' 'o'; Cdp-Key 'ArrowRight' 'ArrowRight' ''; Cdp-Key 'ArrowRight' 'ArrowRight' ''; Start-Sleep -Milliseconds 80
  Check 'O then arrows slide the reference lap by metres' ((Cdp-Json 'WB.state').offsetM -eq 2)
  $null = Cdp-Eval 'WB.cmd("offset", "0")'
  Cdp-Key ' ' 'Space' ' '; Start-Sleep -Milliseconds 80
  Check 'space starts playback' ((Cdp-Json 'WB.state').playing -eq $true)
  Cdp-Key ' ' 'Space' ' '
  Cdp-Key '.' 'Period' '.'; Start-Sleep -Milliseconds 80
  $st = Cdp-Json 'WB.state'; $evAt = Cdp-Json 'WB.data().events.map(function(e){return e.i})'
  Check '. jumps to the next event' ($evAt -contains [int]$st.cur)
  Check 'the deck command API answers every listed command and refuses an unknown one' ((Cdp-Eval '["page-next","page-prev","next-corner","prev-corner","next-event","prev-event","zoom-in","zoom-out","zoom-reset","zoom-corner","tile","tile","offset-auto","axis","axis","map-colour","map-colour","speed","speed","speed","speed","pause"].every(function(c){return WB.cmd(c)}) && !WB.cmd("bogus")') -eq $true)
  $auto = (Cdp-Json 'WB.state').offsetM
  Note "offset-auto lined the laps up at the first braking point: $auto m"
  $null = Cdp-Eval 'WB.cmd("offset", "0"); WB.cmd("zoom-reset"); WB.cmd("cursor", WB.data().worst.c.ia); WB.cmd("page", "driver")'; Start-Sleep -Milliseconds 400
  Cdp-Shot (Join-Path $shots 'wb-driver.png')
  Check 'picture tests\shots\wb-driver.png written' ((Get-Item (Join-Path $shots 'wb-driver.png')).Length -gt 50000)
  # GRIP & BALANCE
  $null = Cdp-Eval 'WB.cmd("page", "grip")'; Start-Sleep -Milliseconds 500
  $kinds = Cdp-Json 'WB.displays().map(function(d){return d.kind})'
  Check 'GRIP & BALANCE has g-g, corner table, slip-angle trace, wheel-slip traces and time in gear' (($kinds -contains 'gg') -and ($kinds -contains 'corners') -and (@($kinds | Where-Object { $_ -eq 'traces' }).Count -eq 2) -and ($kinds -contains 'gears'))
  $null = Cdp-Eval 'WB.cmd("cursor", 2000); WB.cmd("zoom-in")'; Start-Sleep -Milliseconds 150
  $link = Cdp-Json '(function(){var t=WB.displays().filter(function(d){return d.kind==="traces"});return t.map(function(d){return (d.xOf(WB.state.cur)-d.X0)/d.W})})()'
  Check 'the zoom is linked: both trace displays put the cursor at the same fraction of their width' ($link.Count -eq 2 -and (Near $link[0] $link[1] 0.001) -and $link[0] -gt 0.4 -and $link[0] -lt 0.6)
  $gg = Cdp-Json ('(function(){var g=WB.displays().filter(function(d){return d.kind==="gg"})[0],p=g.xy(WB.data().A,Math.round(WB.state.cur));var px=' + $pixelJs + ';return px("gg",p[0],p[1])})()')
  Check 'the g-g skidpad shows the cursor as the gold dot' (Gold $gg)
  $null = Cdp-Eval 'WB.cmd("zoom-reset")'; Start-Sleep -Milliseconds 300
  $ov = Cdp-Json 'WB.overlaps()'
  Note "GRIP text boxes measured: $($ov.boxes)"; if ($ov.bad.Count) { Note ('overlapping: ' + ($ov.bad -join '; ')) }
  Check 'no text overlaps another on GRIP & BALANCE' ($ov.boxes -gt 150 -and $ov.bad.Count -eq 0)
  $gaps = Cdp-Json 'Array.prototype.slice.call(document.querySelectorAll("table.ct tr")).slice(1).map(function(r){return parseFloat(r.children[1].textContent.replace(String.fromCharCode(8722),"-").replace(String.fromCharCode(177),""))})'
  $sorted = $true; for ($i = 1; $i -lt $gaps.Count; $i++) { if ($gaps[$i] -gt $gaps[$i - 1] + 1e-9) { $sorted = $false } }
  Check 'the corner table lists all 14 corners sorted by time lost' ($gaps.Count -eq 14 -and $sorted -and $gaps[0] -gt 0)
  $ms2 = Cdp-Json '(function(){return {overlay:WB.bench(120), full:WB.bench(30, true)}})()'
  Note ("FRAME TIME GRIP: cursor/playback frame {0:N2} ms, full redraw {1:N2} ms" -f $ms2.overlay, $ms2.full)
  Check 'GRIP cursor frames under 8 ms, full redraws under 16 ms' ($ms2.overlay -lt 8 -and $ms2.full -lt 16)
  Cdp-Shot (Join-Path $shots 'wb-grip.png')
  Check 'picture tests\shots\wb-grip.png written' ((Get-Item (Join-Path $shots 'wb-grip.png')).Length -gt 50000)
  # ---------------------------------------------------------------------------------------------------------------
  # C-41: BRAKING, TYRES & STINT, SUSPENSION, SPLITS and the channel picker. Same fixtures (one real lap + its reference, the C-34 deep
  # reply and the session reply with every lap's corner times), same rules: each page renders from a real lap, one number per page is
  # checked against an independent read of the raw .ibt records, nothing overlaps, the cursor and zoom are one state.
  # ---------------------------------------------------------------------------------------------------------------
  function Check-Layout($name) {
    $ov = Cdp-Json 'WB.overlaps()'
    Note "$name text boxes measured: $($ov.boxes)"; if ($ov.bad.Count) { Note ('overlapping: ' + ($ov.bad -join '; ')) }
    Check "no text overlaps another on $name (canvas and DOM boxes measured)" ($ov.boxes -gt 60 -and $ov.bad.Count -eq 0)
    $off = Cdp-Json '(function(){var o=[];WB.textBoxes().concat(WB.domBoxes()).forEach(function(q){if(q.x<-0.5||q.x+q.w>1920.5||q.y<-0.5||q.y+q.h>1080.5)o.push(q.s+"@"+Math.round(q.x)+","+Math.round(q.y))});return o})()'
    if (@($off | Where-Object { $_ }).Count) { Note ('off screen: ' + (@($off) -join ' | ')) }
    Check "nothing on $name sits outside the 1920x1080 screen" (@($off | Where-Object { $_ }).Count -eq 0)
    $small = Cdp-Json '(function(){var o=[];WB.textBoxes().forEach(function(b){if(b.h<12)o.push(b.s)});return o})()'
    Check "canvas labels on $name are 14 px or larger" (@($small | Where-Object { $_ -and $_ -notmatch '^[0-9A-Za-z]{1,3}$' }).Count -eq 0)
  }
  function Cdp-List($expr) { $r = Cdp-Json $expr; return $r }
  function Cdp-Goto($url) {
    $null = Cdp-Eval 'window.__old = 1'
    $null = Cdp 'Page.navigate' @{ url = $url }
    for ($i = 0; $i -lt 100; $i++) { Start-Sleep -Milliseconds 250; if ((Cdp-Eval 'window.__old ? 0 : (window.WB && (WB.extras || WB.error) ? 1 : 0)') -eq 1) { break } }
    Start-Sleep -Milliseconds 500
  }
  function Row-Cells($label) { return @(Cdp-List ('(function(l){var r=[].filter.call(document.querySelectorAll("table.ct tr"),function(r){return r.children[0].textContent===l})[0];return r?[].map.call(r.children,function(c){return c.textContent}):null})(' + (ConvertTo-Json $label -Compress) + ')')) }
  $dpj = $dp.json; $ssj = $se.json
  $rawNames = @('SessionTime', 'LapDistPct', 'Brake', 'Speed', 'FuelLevel', 'LFtempL', 'LFshockVel', 'LFrideHeight', 'RFrideHeight', 'LRrideHeight', 'RRrideHeight', 'Pitch')
  $raw = [WbRaw]::All((Join-Path $work $pbName), $rawNames)
  $ix7 = Lap-Idx $raw 7
  $L = [double]$wf.head.lengthM

  Section '4b. tabs: a tab exists only for a page that works; the cursor and the zoom are one state for every page'
  $pg = @(Cdp-List 'WB.pages()')
  Check 'six pages are offered: DRIVER, GRIP, BRAKING, TYRES, SUSPENSION, SPLITS (each one has its data)' (($pg -join ',') -eq 'driver,grip,braking,tyres,suspension,splits')
  $tabs = @(Cdp-List 'Array.prototype.map.call(document.querySelectorAll("#tabs span"),function(s){return s.getAttribute("data-p")})')
  Check 'the tab row shows exactly those pages and nothing else (no dead tab)' (($tabs -join ',') -eq ($pg -join ','))
  Check 'the deck is told the same page list (what the ANALYSIS screen offers)' ((Cdp-Eval 'WB.deck()') -like '*pgs=driver%2Cgrip%2Cbraking%2Ctyres%2Csuspension%2Csplits*')
  $null = Cdp-Eval 'WB.cmd("page","driver"); WB.cmd("zoom-reset"); WB.cmd("cursor", 3400); WB.cmd("zoom-in"); WB.cmd("zoom-in")'; Start-Sleep -Milliseconds 300
  $keep = Cdp-Json 'WB.state'; $same = $true
  foreach ($p in 'braking', 'tyres', 'suspension', 'splits', 'driver') {
    $null = Cdp-Eval "WB.cmd('page','$p')"; Start-Sleep -Milliseconds 250
    $s2 = Cdp-Json 'WB.state'; if ($s2.cur -ne $keep.cur -or $s2.z0 -ne $keep.z0 -or $s2.z1 -ne $keep.z1) { $same = $false; Note "the shared state moved on $p : cursor $($s2.cur) window $($s2.z0)..$($s2.z1)" }
  }
  Check 'cursor and zoom window are identical after going through all six pages and back' ($same -and $keep.cur -eq 3400)
  Cdp-Key '3' 'Digit3' '3'; Start-Sleep -Milliseconds 250
  Check 'the key 3 opens the third tab (BRAKING)' ((Cdp-Json 'WB.state').page -eq 'braking')

  Section '4c. BRAKING'
  $null = Cdp-Eval 'WB.cmd("page","driver"); WB.cmd("zoom-reset"); WB.cmd("cursor", WB.data().worst.c.ia); WB.cmd("page","braking")'; Start-Sleep -Milliseconds 700
  $kinds = Cdp-Json 'WB.displays().map(function(d){return d.kind})'
  Check 'BRAKING has the corner table, a linked trace stack and the brake / steering cells' (($kinds -contains 'braketable') -and ($kinds -contains 'traces') -and ($kinds -contains 'brakecells'))
  $z = Cdp-Json 'WB.state'
  Check 'entering BRAKING zooms the linked traces onto one braking zone (never a whole lap of flat lines)' (($z.z1 - $z.z0) -lt ($n / 4))
  $bc = @($dpj.corners | Where-Object { $_.me.brake -or ($_.ref -and $_.ref.brake) })
  $nRows = [int](Cdp-Eval '[].filter.call(document.querySelectorAll("table.ct tr"),function(r){return r.children[0].tagName==="TD"}).length')
  $nCells = [int](Cdp-Eval 'WB.displays().filter(function(d){return d.kind==="brakecells"})[0].cells.length')
  Note "braking corners in the engine reply: $($bc.Count) ($((($bc | ForEach-Object { $_.label }) -join ' ')))"
  Check 'one table row and one cell per braking corner of the engine reply (no corner without braking listed, none missed)' ($nRows -eq $bc.Count -and $nCells -eq $bc.Count -and $bc.Count -ge 6)
  $t1 = $dpj.corners | Where-Object { $_.label -eq 'T1' }
  $c1 = Row-Cells 'T1'
  Note "T1 row on screen: $($c1 -join ' | ')"
  Check 'the T1 row shows the engine numbers: brake point 287 m, peak 95 %, time to peak 0.34 s, ABS 24 %' ($c1[1] -like '287*' -and $c1[3] -like '95*' -and $c1[4] -like '0.34*' -and $c1[7] -like '24*' -and [math]::Round($t1.me.brake.startM) -eq 287)
  # HAND CHECK, raw records: the pedal rises through 10 % within 1.5 m of the engine's brake point, and the peak of that application is the engine's peak
  $rises = Brake-Rises $raw $ix7 $L 0.10
  $near = ($rises | Sort-Object { [math]::Abs($_ - $t1.me.brake.startM) } | Select-Object -First 1)
  $pk = 0.0; $a = $t1.me.brake.startM; $b = $a + $t1.me.brake.lenM
  foreach ($i in $ix7) { $d = $raw['LapDistPct'][$i] * $L; if ($d -ge $a -and $d -le $b -and $raw['Brake'][$i] -gt $pk) { $pk = $raw['Brake'][$i] } }
  Note "HAND CHECK T1 braking: raw records cross 10 % at $([math]::Round($near, 1)) m (engine/page 287), raw peak $([math]::Round($pk * 100, 1)) % (engine/page $($t1.me.brake.peakPct) %)"
  Check 'the brake point of T1 is within 1.5 m of where the raw pedal channel crosses 10 %' (Near $near $t1.me.brake.startM 1.5)
  Check 'the peak pressure of T1 is the raw peak of that application within 0.7 %' (Near ($pk * 100) $t1.me.brake.peakPct 0.7)
  $t10 = $dpj.corners | Where-Object { $_.label -eq 'T10a' }
  $c10 = Row-Cells 'T10A'
  Check 'T10A: 100 % pedal and the reference brakes 11 m earlier is said in plain words' ($c10[3] -like '100*' -and $c10[2] -like '*later*' -and [math]::Abs(($t10.me.brake.startM - $t10.ref.brake.startM) - 11) -lt 1.5)
  $c10b = Row-Cells 'T10B'
  Check 'T10B: this lap did not brake there, the reference did: dashes for the lap, the reference small' ($c10b[1] -like '–*' -and $c10b[3] -like '–*')
  Check 'a lock-up is shown with its wheel (T7: 2 RF) and nowhere else' ((Row-Cells 'T7')[9] -like '2 RF*' -and ((Row-Cells 'T1')[9] -like '–*'))
  $null = Cdp-Eval '[].filter.call(document.querySelectorAll("table.ct tr"),function(r){return r.children[0].textContent==="T6"})[0].click()'; Start-Sleep -Milliseconds 250
  $st = Cdp-Json 'WB.state'; $t6 = Cdp-Json 'WB.data().corners.filter(function(c){return c.label==="T6"})[0].ia'
  Check 'a click on the T6 row zooms the linked traces there and puts the cursor on its apex' ($st.cur -eq $t6 -and $st.z0 -le $t6 -and $st.z1 -ge $t6 -and ($st.z1 - $st.z0) -lt ($n / 4))
  $fr = Cdp-Json ('(function(){var d=WB.displays().filter(function(k){return k.kind==="brakecells"})[0],q=d.cells.filter(function(q){return q.c.label==="T6"})[0],o=d.cells.filter(function(q){return q.c.label==="T1"})[0];var r=devicePixelRatio||1;function any(c){var p=d.co.getImageData(Math.round(c.x*r),Math.round((c.y+c.h/2)*r),4,1).data,g=0;for(var i=0;i<4;i++){if(p[i*4]>200&&p[i*4+1]>150&&p[i*4+1]<230&&p[i*4+2]<110&&p[i*4+3]>200)g++}return g}return {on:any(q),off:any(o)}})()')
  Check 'the cell of the corner at the cursor is framed in gold, the others are not (shared cursor)' ($fr.on -ge 1 -and $fr.off -eq 0)
  $tx = Cdp-Json ('(function(){var tr=WB.displays().filter(function(d){return d.kind==="traces"})[0];var x=tr.xOf(WB.state.cur);var px=' + $pixelJs + ';return {x:x,p:px("traces",x,60),w:tr.box.w}})()')
  Check 'the trace stack draws its cursor line where the shared cursor is' ((Gold $tx.p) -and $tx.x -gt 0 -and $tx.x -lt $tx.w)
  $ms = Cdp-Json '(function(){return {overlay:WB.bench(120), full:WB.bench(30, true)}})()'
  Note ("FRAME TIME BRAKING: cursor frame {0:N2} ms, full redraw {1:N2} ms" -f $ms.overlay, $ms.full)
  Check 'BRAKING: cursor frames under 8 ms, full redraws under 16 ms' ($ms.overlay -lt 8 -and $ms.full -lt 16)
  $null = Cdp-Eval 'WB.cmd("zoom-reset"); WB.cmd("cursor", WB.data().worst.c.ia); WB.cmd("page","driver"); WB.cmd("page","braking")'; Start-Sleep -Milliseconds 600
  Check-Layout 'BRAKING'
  Cdp-Shot (Join-Path $shots 'wb-braking.png')
  Check 'picture tests\shots\wb-braking.png written' ((Get-Item (Join-Path $shots 'wb-braking.png')).Length -gt 50000)

  Section '4d. TYRES & STINT'
  $null = Cdp-Eval 'WB.cmd("zoom-reset"); WB.cmd("page","tyres")'; Start-Sleep -Milliseconds 700
  $kinds = Cdp-Json 'WB.displays().map(function(d){return d.kind})'
  Check 'TYRES & STINT has the four tyre cards, the lap-time, fuel and temperature charts and the setting changes' (($kinds -contains 'tyres') -and (@($kinds | Where-Object { $_ -eq 'stintchart' }).Count -eq 3) -and ($kinds -contains 'settings') -and ([int](Cdp-Eval 'document.querySelectorAll(".tc").length') -eq 4))
  $body = Cdp-Eval 'document.getElementById("page").innerText'
  Check 'wear and carcass say they are "as at the last pit stop" (iRacing refreshes them only in the pits)' ($body -like '*as at the last pit stop*')
  $lf = $dpj.stints[0].tyres.LF
  $page66 = Cdp-Eval 'document.querySelectorAll(".tc")[0].querySelector("td.a").textContent'
  $ix10 = Lap-Idx $raw 10; $sum = 0.0; foreach ($i in $ix10) { $sum += $raw['LFtempL'][$i] }; $rawMean = $sum / $ix10.Length
  Note "HAND CHECK LF left surface temperature over lap $($dpj.stints[0].statLap): raw records mean $([math]::Round($rawMean, 2)) C, engine $($lf.surface.L.mean) C, page shows $page66"
  Check 'the LF left surface temperature on the card is the mean of the raw records of the last full lap (lap 10) within 0.3 C' ((Near $rawMean $lf.surface.L.mean 0.3) -and $page66 -eq ([string][math]::Round([double]$lf.surface.L.mean)))
  $wearTxt = Cdp-Eval '[].map.call(document.querySelectorAll(".tc")[0].querySelectorAll("tr"),function(r){return r.children[0].textContent+"="+[].slice.call(r.children,1).map(function(c){return c.textContent}).join("/")}).join(" ; ")'
  Note "LF card: $wearTxt"
  Check 'the LF card shows tread 100 / 100 / 100 % and carcass 39 / 39 / 39 C, as the engine says (constant in this file)' ($wearTxt -like '*TREAD LEFT %=100/100/100*' -and $wearTxt -like '*CARCASS °C=39/39/39*')
  # L-1: the stint charts draw every lap iRacing TIMED (fuel and tyres of a lap with a short off-track are real); only "the best" is a lap it counted (3 of the 7)
  $validN = @($ssj.laps | Where-Object { $_.timed } | ForEach-Object { $_.n })
  $fuelRows = @($dpj.laps | Where-Object { $validN -contains $_.lap -and $_.fuelUsed -ne $null })
  $avgFuel = ($fuelRows | Measure-Object -Property fuelUsed -Average).Average
  $l7 = $dpj.laps | Where-Object { $_.lap -eq 7 }
  $rawFuel = $raw['FuelLevel'][$ix7[0]] - $raw['FuelLevel'][$ix7[$ix7.Length - 1]]
  Note "HAND CHECK fuel lap 7: raw records $([math]::Round($rawFuel, 3)) l, engine $($l7.fuelUsed) l; average over the $($fuelRows.Count) valid laps $([math]::Round($avgFuel, 3)) l"
  Check 'the fuel used on lap 7 is the raw fuel level at the start minus the end of the lap within 0.02 l' (Near $rawFuel $l7.fuelUsed 0.02)
  $avgTxt = Cdp-Eval 'WB.textBoxes().filter(function(b){return /^average /.test(b.s)}).map(function(b){return b.s})[0] || ""'
  Check 'the fuel chart says the average litres per lap, equal to the mean of the timed laps' ($avgTxt -match '^average ([0-9.]+) l per lap' -and (Near ([double]$Matches[1]) $avgFuel 0.006))
  $bestTxt = Cdp-Eval 'WB.textBoxes().filter(function(b){return /^1:19\./.test(b.s)}).map(function(b){return b.s}).join(",")'
  Check 'the lap-time chart marks the best lap 1:19.549 and draws the 7 timed laps (a chart only with 5 or more); the 4 timed laps iRacing did not count are grey dots, never the best' ($bestTxt -like '*1:19.549*' -and @($validN).Count -eq 7 -and @($ssj.laps | Where-Object { $_.timed -and -not $_.valid }).Count -eq 4)
  Check 'with no change in this session the list says so and shows the settings at the start (brake bias 55.96 %)' ($body -like '*Setting changes*No changes*' -and $body -like '*brake bias 55.96 %*' -and @($dpj.changes).Count -eq 0)
  # C-41b: carcass and tread are only refreshed in the pits, so they are drawn in the secondary grey (the colour of the note under the cards), not like the live rows
  $cc = Cdp-Json '(function(){var g=function(e){return getComputedStyle(e).color},rows=[].filter.call(document.querySelectorAll(".tc"),function(c,i){return i<4}).map(function(c){return [].filter.call(c.querySelectorAll("tr"),function(r){return r.children[1]&&r.children[1].tagName==="TD"}).map(function(r){return {n:r.children[0].textContent,c:g(r.children[1])}})});return {cards:rows,note:g(document.querySelector(".tnote"))}})()'
  $cardsOk = (@($cc.cards).Count -eq 4)
  foreach ($cd in $cc.cards) {
    $car = @($cd | Where-Object { $_.n -like 'CARCASS*' })[0].c; $tre = @($cd | Where-Object { $_.n -like 'TREAD*' })[0].c; $sur = @($cd | Where-Object { $_.n -like 'SURFACE °C*' -or $_.n -like 'SURFACE ?C*' })[0].c
    if ($car -ne $cc.note -or $tre -ne $cc.note -or $car -eq $sur) { $cardsOk = $false; Note "card colours: carcass $car, tread $tre, surface $sur, note $($cc.note)" }
  }
  Check 'CARCASS and TREAD LEFT are drawn in the secondary grey (same as the note under the cards) on all four cards, not in the colour of the live surface rows' $cardsOk
  Check-Layout 'TYRES & STINT'
  Cdp-Shot (Join-Path $shots 'wb-tyres.png')
  Check 'picture tests\shots\wb-tyres.png written' ((Get-Item (Join-Path $shots 'wb-tyres.png')).Length -gt 50000)

  Section '4e. SUSPENSION'
  $null = Cdp-Eval 'WB.cmd("zoom-reset"); WB.cmd("cursor", 1500); WB.cmd("zoom-in"); WB.cmd("page","suspension")'; Start-Sleep -Milliseconds 700
  $kinds = Cdp-Json 'WB.displays().map(function(d){return d.kind})'
  Check 'SUSPENSION has the ride-height trace stack, eight histograms (position and speed at each corner of the car) and the ride-height table' (($kinds -contains 'traces') -and (@($kinds | Where-Object { $_ -eq 'histo' }).Count -eq 8) -and ($kinds -contains 'ridestrip'))
  $sums = Cdp-Json 'WB.displays().filter(function(d){return d.kind==="histo"}).map(function(d){var a=0,r=0;for(var i=0;i<d.H.nb;i++){a+=d.H.a[i];r+=d.H.r?d.H.r[i]:100}return [a,r]})'
  $okSum = $true; foreach ($s in $sums) { if (-not (Near $s[0] 100 0.05) -or -not (Near $s[1] 100 0.05)) { $okSum = $false } }
  Check 'every histogram holds the whole lap: bins add up to 100 % (this lap and the reference)' $okSum
  # HAND CHECK, raw records: average LF ride height over the lap (distance-weighted = speed-weighted for time samples) and rake
  $sw = 0.0; $sh = @{ LF = 0.0; RF = 0.0; LR = 0.0; RR = 0.0 }
  foreach ($i in $ix7) { $v = $raw['Speed'][$i]; $sw += $v; foreach ($w in 'LF', 'RF', 'LR', 'RR') { $sh[$w] += $raw[$w + 'rideHeight'][$i] * $v } }
  $avgRaw = @{}; foreach ($w in 'LF', 'RF', 'LR', 'RR') { $avgRaw[$w] = $sh[$w] / $sw * 1000 }
  $rakeRaw = ($avgRaw.LR + $avgRaw.RR) / 2 - ($avgRaw.LF + $avgRaw.RF) / 2
  $cellLF = [double](Cdp-Eval 'document.querySelectorAll("table.rs tr")[1].children[1].childNodes[0].nodeValue')
  $cellRake = [double](Cdp-Eval 'document.querySelectorAll("table.rs tr")[1].children[5].childNodes[0].nodeValue')
  Note "HAND CHECK ride height lap 7 (raw records, weighted by distance): LF $([math]::Round($avgRaw.LF, 2)) mm, rake $([math]::Round($rakeRaw, 2)) mm; page shows LF $cellLF, rake $cellRake"
  Check 'the average LF ride height on the page is the raw average within 0.3 mm' (Near $cellLF $avgRaw.LF 0.3)
  Check 'the rake on the page (rear minus front) is the raw figure within 0.3 mm' (Near $cellRake $rakeRaw 0.3)
  $rawPeak = ($raw['LFshockVel'][$ix7] | Measure-Object -Maximum).Maximum * 1000
  $keysTxt = Cdp-Eval 'WB.displays().filter(function(d){return d.kind==="histo"&&d.hk==="vel"&&d.wheel==="LF"})[0].keys.textContent'
  Note "HAND CHECK LF damper speed: raw 60 Hz peak $([math]::Round($rawPeak, 0)) mm/s; page: $keysTxt"
  Check 'the LF bump peak on the page is the raw peak within 3 % (the 1 m grid cannot be higher than a raw record)' ($keysTxt -match 'bump peak (\d+)' -and [double]$Matches[1] -le $rawPeak + 0.5 -and [double]$Matches[1] -ge $rawPeak * 0.97)
  $frac = Cdp-Json '(function(){var tr=WB.displays().filter(function(d){return d.kind==="traces"})[0],s=WB.state;return {f:(tr.xOf(s.cur)-tr.X0)/tr.W,e:(s.cur-s.z0)/(s.z1-s.z0)}})()'
  Check 'the trace stack puts the shared cursor at the shared window position (linked zoom with the other pages)' (Near $frac.f $frac.e 0.001)
  $ms = Cdp-Json '(function(){return {overlay:WB.bench(120), full:WB.bench(30, true)}})()'
  Note ("FRAME TIME SUSPENSION: cursor frame {0:N2} ms, full redraw {1:N2} ms" -f $ms.overlay, $ms.full)
  Check 'SUSPENSION: cursor frames under 8 ms, full redraws under 16 ms' ($ms.overlay -lt 8 -and $ms.full -lt 16)
  # ---- C-41b: LOWEST AT replaces "on the ground" (an interpretation: the ride-height channel's zero is not proven to be the floor; the reference lap goes to -7 mm) ----
  $rs = Cdp-Json '(function(){var t=document.querySelector("table.rs"),p=t.parentNode.parentNode,rows=[].map.call(t.querySelectorAll("tr"),function(r){return r.children[0].textContent}),at=[].filter.call(t.querySelectorAll("tr"),function(r){return r.children[0].textContent==="LOWEST AT"})[0];return {rows:rows,loss:t.querySelectorAll(".loss,.gain").length,red:(p.innerHTML.match(/e5534b/gi)||[]).length,title:p.querySelector(".ph").textContent,txt:document.getElementById("page").innerText,at:at?[].slice.call(at.children,1,5).map(function(c){return {a:c.childNodes[0].nodeValue,r:c.querySelector("small")?c.querySelector("small").textContent:null}}):null}})()'
  Note ("SUSPENSION table rows: " + (($rs.rows | Where-Object { $_ }) -join ' | ') + "; LOWEST AT: " + (($rs.at | ForEach-Object { $_.a + ' (ref ' + $_.r + ')' }) -join ', '))
  Check 'the table rows are AVERAGE mm, LOWEST mm and LOWEST AT; the old "on the ground" row, its 1 mm threshold and its red counts are gone' ((($rs.rows | Where-Object { $_ }) -join ',') -eq 'AVERAGE mm,LOWEST mm,LOWEST AT' -and $rs.loss -eq 0 -and $rs.red -eq 0)
  Check 'no word "ground" anywhere on the SUSPENSION page, title line included' ($rs.txt -notmatch '(?i)ground' -and $rs.title -notmatch '(?i)ground' -and $rs.title -like 'Ride height*')
  # ---- C-41c: LOWEST mm and LOWEST AT are the raw 60 Hz minimums and the places they happened (the engine sends them in /analysis/deep: laps[].lowRide and refLowRide).
  # The 1 m grid misses a dip one record wide: lap 7 RF is -1.09 mm in the file and 1.01 mm on the grid. Every number below is worked out here from the .ibt records. ----
  $step = [double]$wf.head.step; $gn = [int]$wf.head.n; $inv = [Globalization.CultureInfo]::InvariantCulture
  function Corner-Word($i) {
    foreach ($c in $wf.head.corners) {
      $d0 = [double]$c.p0 * $L; $d1 = $(if ([double]$c.p1 -gt [double]$c.p0) { [double]$c.p1 } else { 1.0 }) * $L
      $i0 = [math]::Floor($d0 / $step + 0.5); $i1 = [math]::Min($gn - 1, [math]::Floor($d1 / $step + 0.5))
      if ($i -ge $i0 - 20 -and $i -le $i1 + 20) { if ($c.official) { return 'T' + ([string]$c.official).ToUpper() } else { $nm = ([string]$c.name) -replace '^The ', ''; if ($nm) { return $nm } else { return 'T' + $c.n } } }
    }
    return ($i * $step / 1000).ToString('0.00', $inv) + ' km'
  }
  function Low-Index($a) { $at = 0; for ($i = 1; $i -lt $gn; $i++) { if ($a[$i] -lt $a[$at]) { $at = $i } }; return $at }
  # the lowest raw record of the lap for one wheel: mm and distance (m); a tie takes the first record, like the engine
  function Raw-Low($rw, $ix, $w) { $rv = $rw[$w + 'rideHeight']; $b = $ix[0]; foreach ($i in $ix) { if ($rv[$i] -lt $rv[$b]) { $b = $i } }; return @{ mm = $rv[$b] * 1000; at = $rw['LapDistPct'][$b] * $L } }
  $rawMid = [WbRaw]::All((Join-Path $work $midName), @('SessionTime', 'LapDistPct', 'LFrideHeight', 'RFrideHeight', 'LRrideHeight', 'RRrideHeight'))
  $ixMid = Lap-Idx $rawMid 7
  $lowJs = '(function(){var t=document.querySelector("table.rs"),lm=[].filter.call(t.querySelectorAll("tr"),function(r){return r.children[0].textContent==="LOWEST mm"})[0];return [].slice.call(lm.children,1,5).map(function(c){return {a:c.childNodes[0].nodeValue,r:c.querySelector("small")?c.querySelector("small").textContent:null}})})()'
  $lowCells = @(Cdp-List $lowJs)
  $r7 = ($dpj.laps | Where-Object { $_.lap -eq 7 }).lowRide
  Check 'the deep reply has lowRide on every lap row (4 wheels, mm and metres) and refLowRide for the reference lap' (@($dpj.laps | Where-Object { $_.lowRide -and $_.lowRide.LF -and $_.lowRide.RR }).Count -eq @($dpj.laps).Count -and $dpj.refLowRide.LF -and $dpj.refLowRide.RR)
  $engBad = @(); $pgBad = @(); $atBad = @(); $gridBad = @(); $wantAt = @(); $k = 0
  foreach ($w in 'LF', 'RF', 'LR', 'RR') {
    $ra = Raw-Low $raw $ix7 $w; $rr = Raw-Low $rawMid $ixMid $w
    $ea = $r7.$w; $er = $dpj.refLowRide.$w
    $gridA = ($wf.arr["lap.${w}rideHeight"] | Measure-Object -Minimum).Minimum * 1000; $gridR = ($wf.arr["ref.${w}rideHeight"] | Measure-Object -Minimum).Minimum * 1000
    Note ("HAND CHECK lowest ride height $w lap 7: raw records {0:N2} mm at {1:N1} m (engine {2:N3} mm at {3:N1} m; 1 m grid {4:N2} mm); reference raw {5:N2} mm at {6:N1} m (engine {7:N3} at {8:N1}; grid {9:N2}); page '{10}' / '{11}'" -f $ra.mm, $ra.at, $ea.mm, $ea.atM, $gridA, $rr.mm, $rr.at, $er.mm, $er.atM, $gridR, $lowCells[$k].a, $lowCells[$k].r)
    if (-not (Near $ea.mm $ra.mm 0.002) -or -not (Near $ea.atM $ra.at 0.2)) { $engBad += "$w lap" }
    if (-not (Near $er.mm $rr.mm 0.002) -or -not (Near $er.atM $rr.at 0.2)) { $engBad += "$w ref" }
    if (-not (Near ([double]$lowCells[$k].a) $ra.mm 0.051) -or -not (Near ([double]$lowCells[$k].r) $rr.mm 0.051)) { $pgBad += "$w page '$($lowCells[$k].a)' / '$($lowCells[$k].r)'" }
    $wa = Corner-Word ([int][math]::Floor($ra.at / $step + 0.5)); $wr = Corner-Word ([int][math]::Floor($rr.at / $step + 0.5)); $wantAt += "$w $wa / $wr"
    if ($rs.at[$k].a -ne $wa -or $rs.at[$k].r -ne $wr) { $atBad += "$w page '$($rs.at[$k].a)' ref '$($rs.at[$k].r)', raw records say '$wa' / '$wr'" }
    if ($gridA -lt $ra.mm - 0.05 -or $gridR -lt $rr.mm - 0.05) { $gridBad += $w }       # the 1 m grid is a resampling: it can miss a dip but never goes below a record
    $k++
  }
  Note ('LOWEST AT worked out from the raw records: ' + ($wantAt -join '; '))
  if ($atBad.Count) { Note ($atBad -join ' ; ') }
  Check 'the engine''s lowRide for lap 7 and refLowRide for the reference are, for all four wheels, the raw records'' lowest ride height (within 0.002 mm) and the distance where it happened (within 0.2 m)' ($engBad.Count -eq 0)
  Check 'lap 7 raw lowest ride heights are RF -1.09 mm, RR -0.32 mm, LF 2.07 mm (the 1 m grid said 1.01, 0.71 and 2.76), and LR is the raw record too' ((Near $r7.RF.mm -1.09 0.006) -and (Near $r7.RR.mm -0.32 0.006) -and (Near $r7.LF.mm 2.07 0.006) -and (Near $r7.LR.mm (Raw-Low $raw $ix7 'LR').mm 0.002))
  if ($pgBad.Count) { Note ($pgBad -join ' ; ') }
  Check 'LOWEST mm on the page is the raw lowest ride height of the lap and of the reference, for all four wheels (1 decimal, within 0.05 mm), not the 1 m grid''s' ($pgBad.Count -eq 0 -and @($lowCells).Count -eq 4)
  Check 'LOWEST AT on the page is, for each wheel and for both laps, the corner containing the lowest raw record of the lap (turn name, or the distance where no corner is near)' ($atBad.Count -eq 0)
  Check 'the 1 m grid is never lower than a raw record (so the raw minimum is the one that can be trusted); it does miss a dip: RF lap 7 grid minimum is at least 1 mm above the raw one' ($gridBad.Count -eq 0 -and ((($wf.arr['lap.RFrideHeight'] | Measure-Object -Minimum).Minimum * 1000) - (Raw-Low $raw $ix7 'RF').mm) -gt 1)
  # an older irdash sends no lowRide / refLowRide: the page falls back to the 1 m grid (minimum and place) exactly as before, then gets the raw ones back
  $null = Cdp-Eval '(function(){var dp=WB.data().deep;window.__lr={laps:dp.laps.map(function(l){return l.lowRide}),ref:dp.refLowRide};dp.laps.forEach(function(l){delete l.lowRide});delete dp.refLowRide;return 1})()'
  $null = Cdp-Eval 'WB.cmd("page","driver"); WB.cmd("page","suspension")'; Start-Sleep -Milliseconds 500
  $oldCells = @(Cdp-List $lowJs)
  $oldAt = Cdp-Json '(function(){var t=document.querySelector("table.rs"),at=[].filter.call(t.querySelectorAll("tr"),function(r){return r.children[0].textContent==="LOWEST AT"})[0];return [].slice.call(at.children,1,5).map(function(c){return {a:c.childNodes[0].nodeValue,r:c.querySelector("small")?c.querySelector("small").textContent:null}})})()'
  $fbBad = @(); $k = 0
  foreach ($w in 'LF', 'RF', 'LR', 'RR') {
    $gridA = ($wf.arr["lap.${w}rideHeight"] | Measure-Object -Minimum).Minimum * 1000; $gridR = ($wf.arr["ref.${w}rideHeight"] | Measure-Object -Minimum).Minimum * 1000
    $ga = Corner-Word (Low-Index $wf.arr["lap.${w}rideHeight"]); $gr = Corner-Word (Low-Index $wf.arr["ref.${w}rideHeight"])
    if (-not (Near ([double]$oldCells[$k].a) $gridA 0.051) -or -not (Near ([double]$oldCells[$k].r) $gridR 0.051) -or $oldAt[$k].a -ne $ga -or $oldAt[$k].r -ne $gr) { $fbBad += "$w '$($oldCells[$k].a)' / '$($oldCells[$k].r)' at '$($oldAt[$k].a)' / '$($oldAt[$k].r)', grid says $([math]::Round($gridA, 1)) / $([math]::Round($gridR, 1)) at '$ga' / '$gr'" }
    $k++
  }
  if ($fbBad.Count) { Note ($fbBad -join ' ; ') }
  Check 'a reply without lowRide (an older irdash) falls back to the 1 m grid for LOWEST mm and LOWEST AT, as before' ($fbBad.Count -eq 0)
  $null = Cdp-Eval '(function(){var dp=WB.data().deep;dp.laps.forEach(function(l,i){l.lowRide=window.__lr.laps[i]});dp.refLowRide=window.__lr.ref;return 1})()'
  $null = Cdp-Eval 'WB.cmd("page","driver"); WB.cmd("page","suspension")'; Start-Sleep -Milliseconds 500
  $backCells = @(Cdp-List $lowJs)
  Check 'with the raw minimums back the page shows them again' ((Near ([double]$backCells[1].a) (Raw-Low $raw $ix7 'RF').mm 0.051))
  $null = Cdp-Eval 'WB.cmd("zoom-reset"); WB.cmd("page","driver"); WB.cmd("page","suspension")'; Start-Sleep -Milliseconds 500
  Check-Layout 'SUSPENSION'
  Cdp-Shot (Join-Path $shots 'wb-suspension.png')
  Check 'picture tests\shots\wb-suspension.png written' ((Get-Item (Join-Path $shots 'wb-suspension.png')).Length -gt 50000)

  Section '4f. SPLITS'
  $null = Cdp-Eval 'WB.cmd("zoom-reset"); WB.cmd("page","splits")'; Start-Sleep -Milliseconds 700
  $kinds = Cdp-Json 'WB.displays().map(function(d){return d.kind})'
  Check 'SPLITS has the lap x sector x corner table and the numbers panel' (($kinds -contains 'splits') -and ($kinds -contains 'splitnums'))
  $timed = @($ssj.laps | Where-Object { $_.time -ne $null -or $_.flag })
  $dom = Cdp-Json '[].filter.call(document.querySelectorAll("table.sp tr"),function(r){return r.children[0].tagName==="TD"&&!/foot/.test(r.className)}).map(function(r){return {n:r.children[0].textContent,c:[].map.call(r.children,function(c){return c.className}),t:[].map.call(r.children,function(c){return c.textContent})}})'
  Check 'one row per lap the session list has (valid, OUT, IN and OFF laps alike)' (@($dom).Count -eq $timed.Count -and $timed.Count -ge 10)
  $ns = @($ssj.sectorAt).Count
  function Sector-Rule($sj, $domRows) {
    $bad = 0; $seen = @{ sp = 0; sn = 0; sy = 0; sg = 0 }
    foreach ($lp in @($sj.laps | Where-Object { $_.time -ne $null -or $_.flag })) {
      $row = @($domRows | Where-Object { $_.n -eq [string]$lp.n })[0]
      for ($k = 0; $k -lt @($sj.sectorAt).Count; $k++) {
        $cls = $row.c[2 + $k]
        if (-not $lp.valid -or $lp.sectors -eq $null) { $want = 'sg' }
        elseif ($lp.offTrack -or $lp.skip -eq 'off') { $want = 'sy' }      # L-1b: a counted lap with an off-track record is never a benchmark
        elseif ($sj.prev -and $sj.ever -and $lp.sectors[$k] -le [math]::Min($sj.ever.sectors[$k], $sj.bestSectors[$k]) + 0.0005) { $want = 'sp' }
        elseif ($lp.sectors[$k] -le $sj.bestSectors[$k] + 0.0005) { $want = 'sn' } else { $want = 'sy' }
        if ($lp.valid) { $seen[$want]++ }
        if ($cls -ne $want) { $bad++; Note "lap $($lp.n) S$($k + 1): class $cls, rule says $want" }
      }
    }
    return @{ bad = $bad; seen = $seen }
  }
  $sr = Sector-Rule $ssj $dom
  Check "the sector cells follow the rule on the PB session (purple = best ever, yellow = slower, grey = not counted): $($sr.seen.sp) purple, $($sr.seen.sy) yellow, $($sr.seen.sg) grey rows' cells not counted" ($sr.bad -eq 0 -and $sr.seen.sp -gt 0 -and $sr.seen.sy -gt 0)  # HAND CHECK, raw records: every sector of every valid lap cut at iRacing's own split points (SplitTimeInfo) from the raw SessionTime, the line
  # crossings interpolated and the lap scaled to iRacing's announced lap time, the way iRacing's figure is (the C-40 method); the four add up to the lap
  function Raw-Sectors($ix, $at, $official) {
    $p = $raw['LapDistPct']; $st = $raw['SessionTime']; $a = $ix[0]; $b = $ix[$ix.Length - 1] + 1
    $cross = { param($i) $p0 = $p[$i - 1]; $f = (1 - $p0) / ((1 - $p0) + $p[$i]); $st[$i - 1] + ($st[$i] - $st[$i - 1]) * $f }
    $t0 = & $cross $a; $t1 = & $cross $b; $comp = $t1 - $t0; $scale = $official / $comp
    $cr = @(0.0); for ($k = 1; $k -lt $at.Count; $k++) { $cr += ((Time-At $raw $ix $at[$k]) - $t0) }; $cr += $comp
    $o = @(); for ($k = 0; $k -lt $at.Count; $k++) { $o += ($cr[$k + 1] - $cr[$k]) * $scale }
    return , $o
  }
  $at = @($ssj.sectorAt); $maxDiff = 0.0; $maxSum = 0.0; $bestSec = @(); for ($k = 0; $k -lt $ns; $k++) { $bestSec += 1e9 }; $cntSec = 0
  foreach ($lp in ($ssj.laps | Where-Object { $_.valid -and $_.sectors })) {
    $ix = Lap-Idx $raw ([int]$lp.n); $rs = Raw-Sectors $ix $at ([double]$lp.time)
    $s = 0.0
    for ($k = 0; $k -lt $ns; $k++) { $maxDiff = [math]::Max($maxDiff, [math]::Abs($rs[$k] - $lp.sectors[$k])); $cntSec++; $s += $lp.sectors[$k]; if ($lp.sectors[$k] -lt $bestSec[$k]) { $bestSec[$k] = $lp.sectors[$k] } }
    $maxSum = [math]::Max($maxSum, [math]::Abs($s - $lp.time))
  }
  $optHand = 0.0; foreach ($v in $bestSec) { $optHand += $v }
  Note "HAND CHECK sectors: $cntSec sector times of the valid laps, largest difference from the raw SessionTime at iRacing's split points $([math]::Round($maxDiff, 4)) s; S1..S4 vs lap time worst $([math]::Round($maxSum, 4)) s; best sectors joined $([math]::Round($optHand, 3))"
  Check 'every sector time (3 counted laps x 4) equals the one worked out from the raw records within 0.002 s, and the sectors of a lap add up to its lap time' ($cntSec -eq 12 -and $maxDiff -lt 0.002 -and $maxSum -lt 0.0015)
  $nums = Cdp-Json '[].map.call(document.querySelectorAll(".nt"),function(t){return {l:t.querySelector(".nl").textContent,v:t.querySelector(".nv").textContent,s:t.querySelector(".ns").textContent}})'
  $tb = @($nums | Where-Object { $_.l -eq 'THEORETICAL BEST' })[0]
  Check 'the theoretical best is the best sectors of the counted laps joined: 1:19.161, 0.388 s under the best lap 1:19.549' ($tb.v -eq '1:19.161' -and (Near $optHand 79.161 0.0015) -and $tb.s -like '*0.388*')
  # rolling best, written again here from the mini-sector times in the reply
  $vl = @($ssj.laps | Where-Object { $_.valid -and $_.mini }); $rb = 1e9; $rbLap = 0
  foreach ($lp in $vl) { $nx = @($vl | Where-Object { $_.n -eq $lp.n + 1 })[0]; if (-not $nx) { continue }
    for ($s = 1; $s -lt 24; $s++) { $t = 0.0; for ($j = $s; $j -lt 24; $j++) { $t += $lp.mini[$j] }; for ($j = 0; $j -lt $s; $j++) { $t += $nx.mini[$j] }; if ($t -lt $rb) { $rb = $t; $rbLap = $lp.n } } }
  $rbTxt = @($nums | Where-Object { $_.l -eq 'ROLLING BEST' })[0].v
  $rbSec = [double]$rbTxt.Split(':')[0] * 60 + [double]$rbTxt.Split(':')[1]
  Check "the rolling best ($rbTxt, laps $rbLap to $($rbLap + 1)) is the quickest 24 mini-sectors in a row over two valid laps, and is not slower than the best lap" ((Near $rbSec $rb 0.0006) -and $rb -le 79.549 + 1e-6 -and $rb -gt 79.0)
  $times = @($ssj.laps | Where-Object { $_.valid } | ForEach-Object { [double]$_.time } | Sort-Object); $top = @($times | Select-Object -First 5); $avg5 = ($top | Measure-Object -Average).Average
  $sd5 = [math]::Sqrt((($top | ForEach-Object { ($_ - $avg5) * ($_ - $avg5) }) | Measure-Object -Sum).Sum / $top.Count)
  $cn = @($nums | Where-Object { $_.l -like 'BEST * AVERAGE' })[0]
  Check "best-3 average $([math]::Round($avg5, 3)) and spread $([math]::Round($sd5, 3)) are shown (page: $($cn.l) $($cn.v), $($cn.s)) as the engine reply says and as computed from the counted lap times" ($cn.l -eq 'BEST 3 AVERAGE' -and $top.Count -eq 3 -and $cn.v -eq '1:19.786' -and (Near $avg5 $ssj.consistency.avg 0.0006) -and (Near $sd5 $ssj.consistency.sd 0.002) -and $cn.s -like ('*' + $ssj.consistency.sd.ToString('0.000') + '*'))
  # lap x corner heat map: T10a on lap 7 from the raw records, and the cell and the spread row on screen
  $ti = -1; for ($k = 0; $k -lt @($ssj.turns).Count; $k++) { if ($ssj.turns[$k].label -eq 'T10a') { $ti = $k } }
  $cn10 = @($wf.head.corners | Where-Object { $_.label -eq 'T10a' })[0]
  $rawT = (Time-At $raw $ix7 ([double]$cn10.p1)) - (Time-At $raw $ix7 ([double]$cn10.p0))
  $lap7 = @($ssj.laps | Where-Object { $_.n -eq 7 })[0]
  Note "HAND CHECK T10a on lap 7: raw records $([math]::Round($rawT, 3)) s between its start and end, the reply says $($lap7.cornerT[$ti]) s"
  Check 'the T10a time of lap 7 in the heat-map data equals the raw records between the corner start and end within 0.004 s' ($ti -ge 0 -and (Near $rawT $lap7.cornerT[$ti] 0.004))
  $col = @($vl | Where-Object { $_.cornerT } | ForEach-Object { [double]$_.cornerT[$ti] }); $cmin = ($col | Measure-Object -Minimum).Minimum
  $mean = ($col | Measure-Object -Average).Average; $sdc = [math]::Sqrt((($col | ForEach-Object { ($_ - $mean) * ($_ - $mean) }) | Measure-Object -Sum).Sum / $col.Count)
  $wantCell = if ($lap7.cornerT[$ti] - $cmin -lt 0.005) { 'best' } else { '+' + ($lap7.cornerT[$ti] - $cmin).ToString('0.00') }
  $row7 = @($dom | Where-Object { $_.n -eq '7' })[0]; $hcCol = 2 + $ns + 1 + $ti
  Check "the heat-map cell for lap 7 in T10a reads $wantCell (seconds lost against the best T10a of the session)" ($row7.t[$hcCol] -eq $wantCell)
  $spreadCell = Cdp-Eval ('[].filter.call(document.querySelectorAll("table.sp tr.foot"),function(r){return /SPREAD/.test(r.textContent)})[0].children[' + (2 + $ti) + '].textContent')
  Note "T10a spread: page $spreadCell, computed $sdc"
  Check "the spread row shows ±$($sdc.ToString('0.00')) for T10a (standard deviation over the valid laps)" ($spreadCell -eq ('±' + $sdc.ToString('0.00')))
  $badRows = @($dom | Where-Object { $lp2 = $_; (@($timed | Where-Object { [string]$_.n -eq $lp2.n -and -not $_.valid }).Count -gt 0) -and (@($lp2.t[($ns + 3)..($lp2.t.Count - 1)] | Where-Object { $_ }).Count -gt 0) })
  Check 'laps that do not count (OUT, IN, OFF, INVALID) have no heat-map cells' ($badRows.Count -eq 0)
  # ---- C-41b: one answer for every lap, on every screen. Lap 4 of this session: iRacing gave it no time (-1) although our off-track rule saw nothing ----
  $l3 = @($ssj.laps | Where-Object { $_.n -eq 3 })[0]; $l4 = @($ssj.laps | Where-Object { $_.n -eq 4 })[0]
  Note "lap 3 in the session reply: time $($l3.time) valid $($l3.valid) flag '$($l3.flag)' skip '$($l3.skip)'; lap 4: time $($l4.time) official $($l4.official) valid $($l4.valid) flag '$($l4.flag)' skip '$($l4.skip)'"
  Check 'lap 4 (no time from iRacing, off-track rule saw nothing) is flagged INVALID, iRacing''s own word, and does not count; a lap where the off-track was seen stays OFF' ($l4.valid -eq $false -and $l4.skip -eq '' -and $l4.flag -eq 'INVALID' -and $l3.valid -eq $false -and $l3.skip -eq 'off' -and $l3.flag -eq 'OFF')
  $strip = @(Cdp-List '[].map.call(document.querySelectorAll("#nav div"),function(d){var m=/^L(\d+)/.exec(d.textContent);return {n:m?+m[1]:0,t:d.textContent,c:d.className,click:!!d.onclick}})')
  $s4 = @($strip | Where-Object { $_.n -eq 4 })[0]
  Note "lap strip: $((($strip | ForEach-Object { $_.t.Trim() + ($(if ($_.c -match '\bout\b') { ' (dim)' } else { '' })) }) -join ' | '))"
  Check 'the workbench lap strip shows lap 4 dim with the word INVALID, not as a normal lap (it was "L4 1:20.322" before)' ($s4 -and $s4.t -match 'L4\s+1:20\.322\s+INVALID$' -and $s4.c -match '\bout\b' -and $s4.c -notmatch '\bpb\b')
  $diff = @()
  foreach ($sp in $strip) {
    $lp = @($ssj.laps | Where-Object { $_.n -eq $sp.n })[0]; if (-not $lp) { continue }
    $dimStrip = $sp.c -match '\bout\b'; $wStrip = if ($sp.t -match '\s([A-Z]+)$') { $Matches[1] } else { '' }
    $row = @($dom | Where-Object { $_.n -eq [string]$sp.n })[0]; $wRow = if ($row -and $row.t[1] -match '\s([A-Z]+)$') { $Matches[1] } else { '' }
    $dimRow = $row -and $row.c[1] -match 'mute'
    if ($dimStrip -ne (-not $lp.valid) -or $dimRow -ne (-not $lp.valid) -or $wStrip -ne $lp.flag -or $wRow -ne $lp.flag) { $diff += "lap $($sp.n): strip dim=$dimStrip '$wStrip', SPLITS dim=$dimRow '$wRow', session reply valid=$($lp.valid) '$($lp.flag)'" }
  }
  if ($diff.Count) { Note ('strip / SPLITS / reply differ: ' + ($diff -join ' ; ')) }
  Check "every lap is shown the same way in the lap strip and in SPLITS (dim when it does not count, the same flag word) and as the session reply says ($($strip.Count) laps)" ($strip.Count -ge 10 -and $diff.Count -eq 0)
  # L-1: a lap iRacing timed but did not count (lap 2: short off-track) is shown dim with the word OFF but is still a real lap - it can be opened and stepped to; only the laps iRacing gave no time stay shut
  $s2 = @($strip | Where-Object { $_.n -eq 2 })[0]
  $wbSrc = Get-Content -LiteralPath (Join-Path $root 'dash\www\v2\workbench.js') -Raw
  Check 'lap 2 (timed, off-track record) is dim with the word OFF in the strip; the strip opens a lap by lapOpen (iRacing timed it), the best marker and the counts use lapCounts (iRacing counted it)' ($s2.t -match 'L2\s+1:20\.590\s+OFF$' -and $s2.c -match '\bout\b' -and $s2.c -notmatch '\bpb\b' -and $wbSrc -match "if \(lapOpen\(l\) && l\.n !== A\.lap\) d\.addEventListener\('click'" -and $wbSrc -match "laps\.filter\(lapCounts\)\.map\(function \(l\) \{ return l\.time; \}\)" -and $wbSrc -match "function lapOpen\(l\) \{ var r = sessLap\(l\); return r \? \(r\.timed != null \? !!r\.timed : !!r\.valid\)")
  $chips = @(Cdp-List '[].map.call(document.querySelectorAll("table.sp td.tm i"),function(i){var r=i.getBoundingClientRect(),c=i.parentNode.getBoundingClientRect(),n=i.parentNode.nextElementSibling.getBoundingClientRect();return {s:i.textContent,h:r.height,right:r.right,cell:c.right,nxt:n.left}})')
  Check 'the flag chips (OUT, IN, OFF, INVALID ...) sit on one line inside the TIME cell and clear of the S1 column' (@($chips).Count -ge 4 -and (@($chips | Where-Object { $_.s -eq 'INVALID' }).Count -eq 1) -and @($chips | Where-Object { $_.h -gt 22 -or $_.right -gt $_.cell + 0.5 -or $_.right -gt $_.nxt + 0.5 }).Count -eq 0)
  $nTxt = Cdp-Eval '[].map.call(document.querySelectorAll(".nt"),function(t){return t.textContent}).filter(function(s){return /^LAPS/.test(s)})[0]'
  Note "LAPS tile: $nTxt"
  Check 'the LAPS tile counts the laps that do not count by the words on the rows (OFF 1 · INVALID 1 ...) and no longer says "off track" for all of them' ($nTxt -match 'INVALID 1' -and $nTxt -notmatch 'off track')
  # the BEST row is coloured by the rule of the rows above: purple when the sector is also the best ever, green when only best this session
  $bestRow = @(Cdp-List '[].map.call([].filter.call(document.querySelectorAll("table.sp tr.foot"),function(r){return r.children[0].textContent==="BEST"})[0].children,function(c){return {c:c.className,t:c.textContent}})')
  $bad = @(); $cls = @()
  for ($k = 0; $k -lt $ns; $k++) {
    $want = if ($ssj.prev -and $ssj.ever -and $ssj.bestSectors[$k] -le $ssj.ever.sectors[$k] + 0.0005) { 'sp' } else { 'sn' }
    $above = $null; foreach ($rw in $dom) { $lq = @($ssj.laps | Where-Object { [string]$_.n -eq $rw.n })[0]; if ($lq.valid -and $lq.sectors -and [math]::Abs($lq.sectors[$k] - $ssj.bestSectors[$k]) -lt 0.0005) { $above = $rw.c[2 + $k]; break } }
    $got = $bestRow[2 + $k].c; $cls += $got
    if ($got -ne $want -or $got -ne $above) { $bad += "S$($k + 1): BEST row $got, rule says $want, the lap cell above with the same number is $above" }
  }
  if ($bad.Count) { Note ($bad -join ' ; ') }
  Check "the BEST row's sectors are coloured by the same rule as the rows above ($($cls -join ', ')): the PB session's best sectors are best-ever, so purple, no longer all green" ($bad.Count -eq 0 -and ($cls -contains 'sp'))
  Check-Layout 'SPLITS'
  Cdp-Shot (Join-Path $shots 'wb-splits.png')
  Check 'picture tests\shots\wb-splits.png written' ((Get-Item (Join-Path $shots 'wb-splits.png')).Length -gt 50000)
  # the afternoon session as the session on screen: its best sectors are slower than the PB session's, so green (best of this session) appears and purple does not
  $fxMid = 'file:///' + ($root -replace '\\', '/') + '/dash/www/v2/workbench.html?data=' + (FxUrl $wMid.path)
  Cdp-Goto ($fxMid + '&page=splits&session=' + (FxUrl $seMid.path))
  $domMid = Cdp-Json '[].filter.call(document.querySelectorAll("table.sp tr"),function(r){return r.children[0].tagName==="TD"&&!/foot/.test(r.className)}).map(function(r){return {n:r.children[0].textContent,c:[].map.call(r.children,function(c){return c.className})}})'
  $srm = Sector-Rule $seMid.json $domMid
  # L-1: iRacing counted only lap 7 of the afternoon (laps 2 to 6 have an off-track record, grey, flag OFF), so its four sectors ARE the session's best: 4 green cells, nothing slower
  Check "the afternoon session on screen: green = best of this session ($($srm.seen.sn) cells = the 4 sectors of its one counted lap), yellow = slower ($($srm.seen.sy)), no purple because the PB session's sectors are faster; the 5 timed laps iRacing did not count are grey" ($srm.bad -eq 0 -and $srm.seen.sn -eq 4 -and $srm.seen.sy -eq 0 -and $srm.seen.sp -eq 0 -and @($seMid.json.laps | Where-Object { $_.timed -and -not $_.valid -and $_.flag -eq 'OFF' }).Count -eq 5)
  Check 'the first lap of a session, joined from the pits (OUT), is shown grey and not counted' ((@($domMid | Where-Object { $_.n -eq '1' })[0]).c[2] -eq 'sg')
  # the BEST row in the afternoon session: not the best ever (the PB session is faster), so green like the cells above, never purple
  $bestMid = @(Cdp-List '[].map.call([].filter.call(document.querySelectorAll("table.sp tr.foot"),function(r){return r.children[0].textContent==="BEST"})[0].children,function(c){return c.className})')
  $mj = $seMid.json; $badMid = @(); $clsMid = @()
  for ($k = 0; $k -lt @($mj.sectorAt).Count; $k++) {
    $want = if ($mj.prev -and $mj.ever -and $mj.bestSectors[$k] -le $mj.ever.sectors[$k] + 0.0005) { 'sp' } else { 'sn' }
    $above = $null; foreach ($rw in $domMid) { $lq = @($mj.laps | Where-Object { [string]$_.n -eq $rw.n })[0]; if ($lq.valid -and $lq.sectors -and [math]::Abs($lq.sectors[$k] - $mj.bestSectors[$k]) -lt 0.0005) { $above = $rw.c[2 + $k]; break } }
    $clsMid += $bestMid[2 + $k]
    if ($bestMid[2 + $k] -ne $want -or $bestMid[2 + $k] -ne $above) { $badMid += "S$($k + 1): BEST row $($bestMid[2 + $k]), rule says $want, the lap cell above is $above" }
  }
  if ($badMid.Count) { Note ($badMid -join ' ; ') }
  Check "afternoon session: the BEST row is green where the sector is only the best of this session ($($clsMid -join ', ')), as the cells above are" ($badMid.Count -eq 0 -and -not ($clsMid -contains 'sp') -and ($clsMid -contains 'sn'))

  Section '4g. TYRES & STINT with two stints and two setting changes (a pretend session: a copy of the real reply with a pit stop and the changes written in)'
  # nothing like it exists in the 12 vault files (C-34 found none), so the real reply is patched: stint 1 = laps 0-4, stint 2 = laps 5-11 with
  # fresh-looking tread and carcass, a brake bias change before lap 8 (best 3 laps before / after) and a traction control change across a stop
  $pj = Get-Content $dp.path -Raw | ConvertFrom-Json
  $s1 = $pj.stints[0]; $s2 = ($s1 | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
  $s1.lapLast = 4; $s1.cleanLaps = 2; $s1.statLap = 2
  $s2.n = 2; $s2.lapFirst = 5; $s2.lapLast = 11; $s2.cleanLaps = 6; $s2.statLap = 10; $s2.minutes = 9.5
  foreach ($w in 'LF', 'RF', 'LR', 'RR') { $s2.tyres.$w.wear.L = 97.0; $s2.tyres.$w.wear.M = 96.5; $s2.tyres.$w.wear.R = 96.0; $s2.tyres.$w.wear.live = $true; $s2.tyres.$w.carcass.L = 62.0; $s2.tyres.$w.carcass.M = 63.0; $s2.tyres.$w.carcass.R = 64.0; $s2.tyres.$w.carcass.live = $true }
  $pj.stints = @($s1, $s2)
  $ch1 = [pscustomobject]@{ channel = 'dcBrakeBias'; from = 55.9646; to = 56.4646; t = 700.0; lap = 7; atM = 2100; before = @([pscustomobject]@{ lap = 5; time = 80.205 }, [pscustomobject]@{ lap = 6; time = 79.931 }); after = @([pscustomobject]@{ lap = 9; time = 80.471 }, [pscustomobject]@{ lap = 10; time = 80.078 }); bestBefore = 79.931; bestAfter = 80.078; delta = 0.147; pitBetween = $false }
  $ch2 = [pscustomobject]@{ channel = 'dcTractionControl'; from = 2; to = 3; t = 800.0; lap = 10; atM = 400; before = @([pscustomobject]@{ lap = 8; time = 79.878 }); after = @([pscustomobject]@{ lap = 12; time = 79.5 }); bestBefore = 79.878; bestAfter = 79.5; delta = -0.378; pitBetween = $true }
  $pj.changes = @($ch1, $ch2)
  $patched = Join-Path $work 'deep-patched.json'; [IO.File]::WriteAllText($patched, ($pj | ConvertTo-Json -Depth 14 -Compress), (New-Object Text.UTF8Encoding($false)))
  Cdp-Goto ($fxBase + '&page=tyres&deep=' + (FxUrl $patched) + '&session=' + (FxUrl $se.path))
  $stt = Cdp-Json 'WB.state'
  Check 'opening with page=tyres works once the engine reply is in, on the stint the lap belongs to (stint 2)' ($stt.page -eq 'tyres' -and ((Cdp-Eval 'document.querySelector(".ph b").textContent') -eq '2'))
  $chips = @(Cdp-List '[].map.call(document.querySelectorAll(".chip"),function(c){return c.textContent+(c.className.indexOf("on")>=0?"*":"")})')
  Check 'two stints give two chips, the shown one lit' (($chips -join ',') -eq 'STINT 1,STINT 2*')
  $body = Cdp-Eval 'document.getElementById("page").innerText'
  Check 'stint 2 shows the new tread (97 / 96 / 96 %), the warm carcass and says carcass and tread are as at the last pit stop' ($body -like '*Carcass and tread: as at the last pit stop*' -and (Cdp-Eval 'document.querySelectorAll(".tc")[0].querySelectorAll("td.v")[3].textContent') -eq '97')
  $sc = @(Cdp-List '[].map.call(document.querySelectorAll(".sc"),function(r){return r.textContent})')
  Note ('changes on screen: ' + ($sc -join ' || '))
  Check 'the brake bias change is listed with its lap, both values, the best before / after and the difference (+0.147 s)' ($sc.Count -eq 2 -and $sc[0] -like '*BRAKE BIAS*lap 7*55.96 % → 56.46 %*1:19.931*1:20.078*+0.147*')
  Check 'the traction control change across a stop says a pit stop was in between and never claims the gain is the setting' ($sc[1] -like '*TRACTION CONTROL*setting 2 → setting 3*pit stop between*')
  Check-Layout 'TYRES & STINT (two stints)'
  $null = Cdp-Eval 'document.querySelectorAll(".chip")[0].click()'; Start-Sleep -Milliseconds 500
  $body = Cdp-Eval 'document.getElementById("page").innerText'
  Check 'the chip of stint 1 shows it: only 2 clean laps there, so the charts say "Under 5 clean laps" and list them instead of drawing' ((Cdp-Eval 'WB.textBoxes().some(function(b){return /^Under 5 clean laps/.test(b.s)})') -eq $true -and (Cdp-Eval 'document.querySelector(".ph b").textContent') -eq '1')
  Check-Layout 'TYRES & STINT (stint 1, short)'

  Section '4h. the channel picker: initials search, any of the 288 channels becomes a trace row'
  $url4h = $fxBase + '&page=driver&deep=' + (FxUrl $dp.path) + '&session=' + (FxUrl $se.path) + '&xdata=' + (FxUrl (Join-Path $work 'x-{ch}.bin'))
  Cdp-Goto $url4h
  Check 'the picker knows all 288 channels of the file' ((Cdp-Eval 'window.WB_CATALOG.length') -eq 288)
  Check '"LG" finds Lateral G first (initials, like Pi Toolbox)' ((@(Cdp-List 'WB.search("LG")'))[0] -eq 'Lateral G')
  Check '"lg" also finds Longitudinal G, and "ride h" finds the ride heights, "pitch" the pitch orientation' ((@(Cdp-List 'WB.search("lg")') -contains 'Longitudinal G') -and ((@(Cdp-List 'WB.search("ride h")'))[0] -like 'Ride height*') -and (@(Cdp-List 'WB.search("pitch")') -contains 'Pitch orientation'))
  Check 'a search that matches nothing finds nothing' ((@(Cdp-List 'WB.search("qqzzqq")') | Where-Object { $_ }).Count -eq 0)
  Check '+ CHANNEL is on DRIVER (it has a trace stack with room) and not on TYRES or SPLITS (no dead button)' (((Cdp-Eval 'document.getElementById("addch").style.display') -ne 'none') -and ((Cdp-Eval 'WB.cmd("page","tyres"); document.getElementById("addch").style.display') -eq 'none') -and ((Cdp-Eval 'WB.cmd("page","splits"); document.getElementById("addch").style.display') -eq 'none'))
  $null = Cdp-Eval 'WB.cmd("page","driver")'; Start-Sleep -Milliseconds 400
  $rows0 = [int](Cdp-Eval 'WB.displays().filter(function(d){return d.kind==="traces"})[0].rows.length')
  $null = Cdp-Eval 'document.getElementById("addch").click()'; Start-Sleep -Milliseconds 200
  Check 'a click on + CHANNEL opens the picker with the cursor in its field' ((Cdp-Eval 'document.querySelector(".picker.on") ? document.activeElement.tagName : "none"') -eq 'INPUT')
  $null = Cdp-Eval '(function(){var i=document.querySelector(".picker input");i.value="LG";i.dispatchEvent(new Event("input"))})()'; Start-Sleep -Milliseconds 150
  $first = Cdp-Eval 'document.querySelector(".picker .pr .p1").textContent'
  $formula = Cdp-Eval 'document.querySelector(".picker .pr .p3").textContent'
  Check 'typing LG lists Lateral G first, with how it is made (LatAccel divided by 9.81)' ($first -eq 'Lateral G' -and $formula -like '*LatAccel*9.81*')
  $povJs = '(function(){var r=document.querySelector(".picker").getBoundingClientRect(),all=WB.domBoxes().filter(function(b){return b.x>=r.left-1&&b.x+b.w<=r.right+1&&b.y>=r.top-1&&b.y+b.h<=r.bottom+1}),bad=[];for(var i=0;i<all.length;i++)for(var j=i+1;j<all.length;j++){var p=all[i],q=all[j];if(p.x+1<q.x+q.w-1&&q.x+1<p.x+p.w-1&&p.y+1<q.y+q.h-1&&q.y+1<p.y+p.h-1)bad.push(p.s+"|"+q.s)}return {n:all.length,bad:bad,inside:r.right<=1920&&r.bottom<=1080}})()'
  $pov = Cdp-Json $povJs
  Note "picker text boxes measured with LG typed: $($pov.n)"; if ($pov.bad.Count) { Note ('picker overlaps: ' + ($pov.bad -join '; ')) }
  Check 'the picker''s own text (title, field, results) does not overlap and the picker is on screen' ($pov.n -ge 6 -and @($pov.bad | Where-Object { $_ }).Count -eq 0 -and $pov.inside)
  Cdp-Shot (Join-Path $shots 'wb-picker.png')
  Check 'picture tests\shots\wb-picker.png written' ((Get-Item (Join-Path $shots 'wb-picker.png')).Length -gt 50000)
  $null = Cdp-Eval '(function(){var i=document.querySelector(".picker input");i.value="";i.dispatchEvent(new Event("input"))})()'; Start-Sleep -Milliseconds 150
  $pov = Cdp-Json $povJs
  Note "picker text boxes measured with the field empty (ten common channels): $($pov.n)"; if ($pov.bad.Count) { Note ('picker overlaps: ' + ($pov.bad -join '; ')) }
  Check 'the full list of ten channels (field empty) does not overlap either' ($pov.n -ge 25 -and @($pov.bad | Where-Object { $_ }).Count -eq 0)
  $null = Cdp-Eval '(function(){var i=document.querySelector(".picker input");i.value="LG";i.dispatchEvent(new Event("input"))})()'; Start-Sleep -Milliseconds 150
  Cdp-Key 'Enter' 'Enter' ''; Start-Sleep -Milliseconds 400
  $rowsLG = Cdp-Json 'WB.displays().filter(function(d){return d.kind==="traces"})[0].rows.map(function(r){return r.key||r.kind})'
  Check 'Enter adds Lateral G as a trace row and closes the picker' (@($rowsLG).Count -eq $rows0 + 1 -and ($rowsLG -contains 'latG') -and -not (Cdp-Eval 'document.querySelector(".picker.on") ? 1 : 0'))
  # Peter 2026-10-15: "channel button can't escape" - every way out must work, with or without the keyboard
  $null = Cdp-Eval 'document.getElementById("addch").click()'; Start-Sleep -Milliseconds 150
  $null = Cdp-Eval '(function(){var b=document.querySelector(".picker .pclose");b.dispatchEvent(new MouseEvent("mousedown",{bubbles:true}))})()'; Start-Sleep -Milliseconds 150
  Check 'the picker has a visible Close button and it closes the picker' (-not (Cdp-Eval 'document.querySelector(".picker.on") ? 1 : 0'))
  $null = Cdp-Eval 'document.getElementById("addch").click()'; Start-Sleep -Milliseconds 150
  $null = Cdp-Eval 'document.querySelector(".picker input").blur(); document.body.focus(); 1'
  Cdp-Key 'Escape' 'Escape' ''; Start-Sleep -Milliseconds 200
  Check 'Esc closes the picker even when the search field has lost focus' (-not (Cdp-Eval 'document.querySelector(".picker.on") ? 1 : 0'))
  $null = Cdp-Eval 'document.getElementById("addch").click()'; Start-Sleep -Milliseconds 150
  $null = Cdp-Eval '(function(){document.body.dispatchEvent(new MouseEvent("mousedown",{bubbles:true}))})()'; Start-Sleep -Milliseconds 150
  Check 'a click outside the picker closes it' (-not (Cdp-Eval 'document.querySelector(".picker.on") ? 1 : 0'))
  $null = Cdp-Eval 'WB.cmd("cursor", 1500)'; Start-Sleep -Milliseconds 200
  $lat = Cdp-Eval 'WB.data().A.c.latG[1500].toFixed(2)'
  Check "the new row shows the lateral g at the cursor ($lat) like every other row" ((Cdp-Eval ('WB.textBoxes().some(function(b){return b.s==="' + $lat + '"})')) -eq $true)
  # a raw channel that is not loaded yet (Pitch): fetched from the endpoint, then a row
  $null = Cdp-Eval 'document.getElementById("addch").click()'; Start-Sleep -Milliseconds 150
  $null = Cdp-Eval '(function(){var i=document.querySelector(".picker input");i.value="pitch orientation";i.dispatchEvent(new Event("input"))})()'; Start-Sleep -Milliseconds 150
  Cdp-Key 'Enter' 'Enter' ''
  $got = $false; for ($i = 0; $i -lt 20 -and -not $got; $i++) { Start-Sleep -Milliseconds 200; $got = (Cdp-Eval '!!(WB.data().A.c.Pitch && WB.state.extra.indexOf("Pitch")>=0)') -eq $true }
  Check 'a channel the page did not load (Pitch) is fetched and becomes a row' $got
  $p0 = [double](Cdp-Eval 'WB.data().A.c.Pitch[0]')
  Check 'its first value is the first record of the lap in the .ibt (raw Pitch)' (Near $p0 $raw['Pitch'][$ix7[0]] 0.0001)
  # a channel this car's file does not have (dcThrottleShape): said in words, no row
  $rowsBefore = [int](Cdp-Eval 'WB.state.extra.length')
  $null = Cdp-Eval 'document.getElementById("addch").click()'; Start-Sleep -Milliseconds 150
  $null = Cdp-Eval '(function(){var i=document.querySelector(".picker input");i.value="throttle shape";i.dispatchEvent(new Event("input"))})()'; Start-Sleep -Milliseconds 150
  Cdp-Key 'Enter' 'Enter' ''; Start-Sleep -Milliseconds 800
  $note = Cdp-Eval 'document.querySelector(".picker .pnote").textContent'
  Check 'a channel the car''s file lacks (dcThrottleShape) is refused in plain words and adds no row' ($note -like '*No "dcThrottleShape"*' -and [int](Cdp-Eval 'WB.state.extra.length') -eq $rowsBefore)
  Cdp-Key 'Escape' 'Escape' ''; Start-Sleep -Milliseconds 150
  Check 'Esc closes the picker' (-not (Cdp-Eval 'document.querySelector(".picker.on") ? 1 : 0'))
  foreach ($q in 'long g', 'ride height rf') {
    $null = Cdp-Eval 'document.getElementById("addch").click()'; Start-Sleep -Milliseconds 120
    $null = Cdp-Eval ('(function(){var i=document.querySelector(".picker input");i.value="' + $q + '";i.dispatchEvent(new Event("input"))})()'); Start-Sleep -Milliseconds 120
    Cdp-Key 'Enter' 'Enter' ''; Start-Sleep -Milliseconds 300
  }
  $info = Cdp-Json '(function(){var t=WB.displays().filter(function(d){return d.kind==="traces"})[0];return {n:t.rows.length,min:Math.min.apply(null,t.rows.map(function(r){return r.h})),bottom:t.bottom,boxH:t.box.h,extra:WB.state.extra.length}})()'
  Note "DRIVER with 4 added channels: $($info.n) rows, the smallest $($info.min) px, bottom at $([math]::Round($info.bottom)) of $($info.boxH)"
  Check 'with 4 added rows (the most the page takes) all 11 rows fit: none under 44 px and the axis stays inside the box' ($info.n -eq 11 -and $info.extra -eq 4 -and $info.min -ge 44 -and $info.bottom -le $info.boxH)
  Check-Layout 'DRIVER with 4 added channels'
  $null = Cdp-Eval 'document.getElementById("addch").click()'; Start-Sleep -Milliseconds 120
  $null = Cdp-Eval '(function(){var i=document.querySelector(".picker input");i.value="rake";i.dispatchEvent(new Event("input"))})()'; Start-Sleep -Milliseconds 120
  Cdp-Key 'Enter' 'Enter' ''; Start-Sleep -Milliseconds 300
  Check 'a fifth added channel is refused ("This page is full") and a picked one can be taken off again' (((Cdp-Eval 'document.querySelector(".picker .pnote").textContent') -like '*Page full*') -and [int](Cdp-Eval 'WB.state.extra.length') -eq 4)
  Cdp-Key 'Escape' 'Escape' ''
  $null = Cdp-Eval 'document.getElementById("addch").click()'; Start-Sleep -Milliseconds 120
  $null = Cdp-Eval '(function(){var i=document.querySelector(".picker input");i.value="lg";i.dispatchEvent(new Event("input"))})()'; Start-Sleep -Milliseconds 120
  Cdp-Key 'Enter' 'Enter' ''; Start-Sleep -Milliseconds 300
  Check 'picking Lateral G again takes it off (3 rows left) and the picker shows ON beside the ones that are on' ([int](Cdp-Eval 'WB.state.extra.length') -eq 3 -and -not (Cdp-Eval 'WB.state.extra.indexOf("latG")>=0'))
  Cdp-Key '/' 'Slash' '/'; Start-Sleep -Milliseconds 200
  Check 'the key / opens the picker as well' ((Cdp-Eval 'document.querySelector(".picker.on") ? 1 : 0') -eq 1)
  Cdp-Key 'Escape' 'Escape' ''
  # the rows he added stay when he opens another lap (the page reloads): Pitch needs fetching again, the others are derived
  $before = Cdp-Json 'WB.state.extra'
  Cdp-Goto $url4h
  $after = Cdp-Json 'WB.state.extra'
  Note ("added rows before the reload: " + ($before -join ', ') + "; after: " + ($after -join ', '))
  Check 'the added rows come back by themselves after the page is reloaded for another lap (the fetched channel included)' ((@($after).Count -eq 3) -and (($after -join ',') -eq ($before -join ',')) -and (Cdp-Eval '!!WB.data().A.c.Pitch'))
  $null = Cdp-Eval 'try { localStorage.removeItem("wbExtra") } catch (e) { }; WB.state.extra.length = 0; WB.cmd("page","driver")'

  Section '4i. no dead tabs when an engine reply is missing'
  Cdp-Goto ($fxBase + '&page=braking')
  $pg0 = (@(Cdp-List 'WB.pages()')) -join ','
  Check 'with no engine reply at all only the pages that work are offered (no BRAKING, TYRES, SPLITS) and a request for BRAKING opens DRIVER' ($pg0 -eq 'driver,grip,suspension' -and (Cdp-Json 'WB.state').page -eq 'driver' -and (@(Cdp-List 'Array.prototype.map.call(document.querySelectorAll("#tabs span"),function(s){return s.getAttribute("data-p")})') -join ',') -eq $pg0)
  Cdp-Goto ($fxBase + '&page=driver&deep=' + (FxUrl $dp.path))
  Check 'with the deep-dive reply but no session reply SPLITS has no tab and the rest do' ((@(Cdp-List 'WB.pages()') -join ',') -eq 'driver,grip,braking,tyres,suspension')
  Cdp-Goto ($fxBase + '&page=driver&deep=' + (FxUrl (Join-Path $work 'does-not-exist.json')))
  Check 'an engine reply that cannot be read leaves no BRAKING or TYRES tab and no error on screen' ((@(Cdp-List 'WB.pages()') -join ',') -eq 'driver,grip,suspension' -and -not (Cdp-Eval 'WB.error || ""'))

Section '4j. Session Review ANALYSIS sends the selected lap, not the session best, to Workbench'
  $reviewFx = 'file:///' + ($root -replace '\\', '/') + '/dash/www/v2/sessionreview.html?data=' + [uri]::EscapeDataString((FxUrl $se.path)) + '&map=' + [uri]::EscapeDataString((FxUrl $wf.path))
  $null = Cdp 'Page.navigate' @{ url = $reviewFx }
  $reviewReady = $false; for ($i = 0; $i -lt 80 -and -not $reviewReady; $i++) { Start-Sleep -Milliseconds 250; $reviewReady = (Cdp-Eval 'document.getElementById("srAnalysis") && !document.getElementById("srAnalysis").hidden') -eq $true }
  Note "Session Review fixture ready: $reviewReady; error: $(Cdp-Eval 'window.SessionReview && SessionReview.error ? SessionReview.error : ""')"
  if ($reviewReady) { $null = Cdp-Eval ('SessionReview.openAnalysis({file:' + (ConvertTo-Json $pbName -Compress) + ',shown:{lap:5,time:80.125}},null)') }
  $reviewSrc = [string](Cdp-Eval 'document.querySelector("#wbHost iframe") ? document.querySelector("#wbHost iframe").src : ""')
  Note "Session Review first URL: $reviewSrc"
  Check 'ANALYSIS opens workbench.html with the real review file and selected lap 5 when best is lap 7' ($reviewReady -and $reviewSrc -match ('workbench\.html\?id=' + [regex]::Escape([uri]::EscapeDataString($pbName)) + '&lap=5'))
  $distinct = Cdp-Eval ('(function(){var h=document.getElementById("wbHost");if(h)h.remove();SessionReview.openAnalysis({file:' + (ConvertTo-Json $pbName -Compress) + ',shown:{lap:5,time:80.125}},"review-id-distinct-from-file");return true})()')
  $distinctSrc = [string](Cdp-Eval 'document.querySelector("#wbHost iframe") ? document.querySelector("#wbHost iframe").src : ""')
  Note "Session Review explicit URL: $distinctSrc"
  Check 'Review preserves an explicit ID distinct from the telemetry filename and keeps selected lap 5' ($distinct -eq $true -and $distinctSrc -match 'workbench\.html\?id=review-id-distinct-from-file&lap=5')

  Section '4k. six real lap overlays, eight channels, cursor readout and headless frame rate'
  $multiUrl = 'file:///' + ($root -replace '\\', '/') + '/dash/www/v2/workbench.html?data=' + (FxUrl $wMultiPage.path)
  $null = Cdp 'Page.navigate' @{ url = $multiUrl }
  $multiReady = $false; for ($i = 0; $i -lt 80 -and -not $multiReady; $i++) { Start-Sleep -Milliseconds 250; $multiReady = (Cdp-Eval 'window.WB && WB.ready && WB.data().M.length===5 ? 1 : 0') -eq 1 }
  $null = Cdp-Eval 'WB.cmd("page","driver"); WB.state.extra=[]; try { localStorage.removeItem("wbExtra") } catch (e) {}; document.getElementById("addch").click()'; Start-Sleep -Milliseconds 150
  $null = Cdp-Eval '(function(){var i=document.querySelector(".picker input");i.value="lg";i.dispatchEvent(new Event("input"))})()'; Start-Sleep -Milliseconds 150
  Cdp-Key 'Enter' 'Enter' ''; Start-Sleep -Milliseconds 300
  $multiState = Cdp-Eval 'JSON.stringify({href:location.href,has:!!window.WB,ready:window.WB?WB.ready:false,error:window.WB?(WB.error||""):"",page:window.WB?WB.state.page:"",hasData:window.WB?!!WB.data():false,displays:window.WB?WB.displays().map(function(d){return d.kind}):[],laps:window.WB&&WB.data()?WB.data().M.length:0,body:document.body.innerText.slice(0,300)})'
  if ($multiState -notlike 'js error:*') { $multiState = $multiState | ConvertFrom-Json; Note ("multi-lap browser state: ready $($multiState.ready), page $($multiState.page), laps $($multiState.laps), displays $($multiState.displays -join ','); $($multiState.error); $($multiState.body)") } else { Note "multi-lap browser evaluation: $multiState" }
  $multiRows = 0; try { $multiRows = [int](Cdp-Eval 'WB.displays().filter(function(d){return d.kind==="traces"})[0].rows.length') } catch { }
  Note "trace fixture extra channels: $(Cdp-Eval 'JSON.stringify(WB.state.extra)'); added Lateral G available: $(Cdp-Eval '!!WB.data().A.c.latG')"
  $multiLegend = Cdp-Json '(function(){return [8,9,10,4,5].map(function(n){var e=document.querySelector("#nav [data-lap=\""+n+"\"]");return e?{t:e.textContent,c:e.style.color,b:e.style.borderColor}:null})})()'
  Note "multi-lap trace rows: $multiRows; legend laps: $(@($multiLegend | ForEach-Object { $_.t }) -join ', ')"
  Check 'six laps load from the real .ibt replies and eight channel rows are drawn on one distance axis' ($multiReady -and $multiRows -eq 8 -and @($multiLegend).Count -eq 5 -and (Cdp-Eval 'document.getElementById("vs").textContent') -like '*6 LAPS*')
  $null = Cdp-Eval 'WB.cmd("cursor",1500)'; Start-Sleep -Milliseconds 200
  $ixCursor = 0; $lap8Km = 0; $readout = $false
  if ($multiReady -and (Cdp-Eval '!!WB.data()') -eq $true) {
    $ixCursor = [int](Cdp-Eval 'Math.round(WB.state.cur)'); $lap8Km = [double](Cdp-Eval ('WB.data().M[0].c.kmh[' + $ixCursor + '].toFixed(2)'))
    $readout = Cdp-Eval ('WB.textBoxes().some(function(b){return b.s==="L8 " + WBX.api.fmt(WB.data().M[0].info.time) + " " + WBX.api.num(WB.data().M[0].c.kmh[' + $ixCursor + '],0)})')
  }
  Check "lap 8 shows its time and cursor speed ($lap8Km km/h) beside the active trace" ($readout -eq $true)
  $activeKm = [double](Cdp-Eval ('WB.data().A.c.kmh[' + $ixCursor + '].toFixed(2)'))
  $activeReadout = Cdp-Eval ('WB.textBoxes().some(function(b){return b.s==="L7 " + WBX.api.fmt(WB.data().A.info.time) + " " + WBX.api.num(WB.data().A.c.kmh[' + $ixCursor + '],0)})')
  Check "active lap 7 cursor readout includes its time and speed ($activeKm km/h)" ($activeReadout -eq $true)
  $gapOk = Cdp-Eval '(function(){var d=WB.displays().filter(function(x){return x.kind==="traces"})[0], seen=0, old=d.plot;d.plot=function(g,a){if(WB.data().M.some(function(l){return l.gap===a}))seen++;return old.apply(this,arguments)};d.drawStatic();d.plot=old;d.drawOverlay();var i=Math.round(WB.state.cur),m=WB.data().M[0];return seen>0 && Math.abs(m.gap[i]-(WB.data().A.t[i]-m.t[i]))<0.001 && WB.textBoxes().some(function(b){return b.s.indexOf("L"+m.info.lap+" "+WBX.api.fmt(m.info.time)+" ")===0})})()'
  Check 'selected laps are drawn on the GAP trace and show each lap time delta at the shared cursor' ($gapOk -eq $true)
  if ($multiReady -and (Cdp-Eval '!!WB.data()') -eq $true) {
    $raw8 = [WbRaw]::All((Join-Path $work $pbName), @('LapDistPct', 'Speed')); $ix8 = Lap-Idx $raw8 8; $dist8 = $ixCursor * [double]$wMultiPage.head.step; $j8 = -1
    for ($k8 = 1; $k8 -lt $ix8.Length; $k8++) { if ($raw8['LapDistPct'][$ix8[$k8]] * [double]$wMultiPage.head.lengthM -ge $dist8) { $j8 = $k8; break } }
    $a8 = $ix8[$j8 - 1]; $b8 = $ix8[$j8]; $f8 = ($dist8 / [double]$wMultiPage.head.lengthM - $raw8['LapDistPct'][$a8]) / ($raw8['LapDistPct'][$b8] - $raw8['LapDistPct'][$a8]); $hand8 = ($raw8['Speed'][$a8] + ($raw8['Speed'][$b8] - $raw8['Speed'][$a8]) * $f8) * 3.6
    Note "HAND CHECK lap 8 cursor speed at $([math]::Round($dist8)) m: raw record interpolation $([math]::Round($hand8,2)) km/h, browser $lap8Km km/h"
    Check 'lap 8 cursor speed readout matches an independent raw-record interpolation within 0.5 km/h' (Near $lap8Km $hand8 0.5)
  }
  $multiFrame = @{fps=0;layout=@{boxes=0;bad=@()}}
  if ($multiReady -and (Cdp-Eval '!!WB.data()') -eq $true) { $frameJson = Cdp-Eval '(function(){return new Promise(function(resolve){var n=0,t=performance.now(),f=function(){n++;WB.cmd("cursor",(n*17)%WB.data().n);if(performance.now()-t>=1000)resolve({fps:n*1000/(performance.now()-t),layout:WB.overlaps()});else requestAnimationFrame(f)};requestAnimationFrame(f)})})().then(function(x){return JSON.stringify(x)})'; $multiFrame = $frameJson | ConvertFrom-Json }
  Note ("six-lap cursor motion: {0:N1} fps; text boxes {1}; overlaps {2}" -f $multiFrame.fps, $multiFrame.layout.boxes, $multiFrame.layout.bad.Count)
  Check 'headless Chrome keeps six laps by eight traces at 50 fps or better with no overlapping labels' ($multiFrame.fps -ge 50 -and $multiFrame.layout.bad.Count -eq 0)
  Cdp-Shot (Join-Path $shots 'wb-multilap.png')
  Check 'picture tests\shots\wb-multilap.png written' ((Get-Item (Join-Path $shots 'wb-multilap.png')).Length -gt 50000)

  Check 'no JavaScript exception during the whole run' ($script:cdp.errors.Count -eq 0)
  if ($script:cdp.errors.Count) { Note ($script:cdp.errors -join ' / ') }
  Cdp-Close

  $liveAllowed = $true
  try { $null = Invoke-WebRequest -UseBasicParsing ('http://localhost:8199/analysis/channels?id=' + [uri]::EscapeDataString($pbName) + '&lap=7&ref=pb&ch=Speed') -TimeoutSec 10 }
  catch { if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -in @(409, 503)) { $liveAllowed = $false } else { throw } }
  if (-not $liveAllowed) { Note 'skipped live API and browser checks: irdash refused the test hook while driving (HTTP 409/503)' }
  else {
  Section '5. against the running irdash (only when the lead has deployed this build)'
  $srcStamp = (@('workbench.cs', 'deepdive.cs', 'sessionreview.cs', 'analysis.cs') | ForEach-Object { (Get-Item -LiteralPath (Join-Path $root ('dash\src\' + $_))).LastWriteTimeUtc } | Sort-Object -Descending | Select-Object -First 1)
  $deployed = (Get-Item -LiteralPath $shipped).LastWriteTimeUtc -gt $srcStamp
  $running = [bool](Get-Process irdash -ErrorAction SilentlyContinue)
  $cmdOk = $false
  if ($deployed -and $running) { try { $r = Invoke-WebRequest -UseBasicParsing 'http://localhost:8199/workbench/cmd' -TimeoutSec 5; $cmdOk = $r.StatusCode -eq 200 } catch { } }
  if (-not $cmdOk) { Note "skipped: irdash.exe $(if ($deployed) { 'is deployed' } else { 'is older than workbench.cs' }), $(if ($running) { 'running' } else { 'not running' }) - the lead deploys with dash\build.ps1 and runs this part" }
  else {
    $docFile = Join-Path $docTel $pbName
    if (Test-Path -LiteralPath $docFile) {
      $r = Invoke-WebRequest -UseBasicParsing ('http://localhost:8199/analysis/channels?id=' + [uri]::EscapeDataString($pbName) + '&lap=7&ref=pb&ch=Speed,Gear') -TimeoutSec 30
      $bytes = $r.RawContentStream.ToArray()
      Check 'GET /analysis/channels answers 200 with a PWB1 binary' ($r.StatusCode -eq 200 -and [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -eq 'PWB1')
      Note "live reply: $($bytes.Length) bytes, content-type $($r.Headers['Content-Type'])"
      Section '5a. multi-lap endpoint returns a shared grid for 3, 4 and 6 real laps'
      # Keep the six-lap live selection inside this file's full laps; 11-14 are pit / part laps.
      foreach ($nums in @(@(8,9), @(8,9,10), @(1,2,4,5,6))) {
        $spec = ($nums | ForEach-Object { $pbName + ':' + $_ }) -join ','
        $mr = Invoke-WebRequest -UseBasicParsing ('http://localhost:8199/analysis/channels?id=' + [uri]::EscapeDataString($pbName) + '&lap=7&ref=pb&ch=Speed,Gear&laps=' + [uri]::EscapeDataString($spec)) -TimeoutSec 60
        $mb = $mr.RawContentStream.ToArray(); $tmp = Join-Path $work ('multi-' + $nums.Count + '.bin'); [IO.File]::WriteAllBytes($tmp, $mb); $parsed = Read-Wb $tmp
        $wantCount = $nums.Count + 1; $arrayCount = $wantCount * 3
        Check "$wantCount real laps have $($parsed.head.n) samples each for time, speed and gear" ($parsed.ok -and $parsed.head.multi.Count -eq $nums.Count -and $parsed.head.n -eq $w1.head.n -and $parsed.head.arrays.Count -eq $arrayCount -and $parsed.used -eq $parsed.bytes)
        $timesOk = $true; foreach ($ln in $nums) { $info = @($parsed.head.multi | Where-Object { $_.lap -eq $ln })[0]; if (-not $info -or $info.time -le 0) { $timesOk = $false } }
        Check "$wantCount real laps carry their own lap numbers and times" $timesOk
      }
      $dupCode = 0; try { $null = Invoke-WebRequest -UseBasicParsing ('http://localhost:8199/analysis/channels?id=' + [uri]::EscapeDataString($pbName) + '&lap=7&ch=Speed&laps=' + [uri]::EscapeDataString($pbName + ':8,' + $pbName + ':8')) -TimeoutSec 60 } catch { $dupCode = [int]$_.Exception.Response.StatusCode }
      Check 'the endpoint refuses a duplicate lap selection with HTTP 400' ($dupCode -eq 400)
      $rd = Invoke-WebRequest -UseBasicParsing ('http://localhost:8199/analysis/deep?id=' + [uri]::EscapeDataString($pbName) + '&lap=7&ref=pb') -TimeoutSec 60
      Check 'GET /analysis/deep answers 200 with the engines and the per-lap fuel and tyre rows (C-41) and the raw lowest ride heights (C-41c)' ($rd.StatusCode -eq 200 -and $rd.Content -like '*"stints":*' -and $rd.Content -like '*"fuelUsed":*' -and $rd.Content -like '*"changes":*' -and $rd.Content -like '*"lowRide":{"LF":{"mm":*' -and $rd.Content -like '*"refLowRide":{"LF":{"mm":*')
      $rs = Invoke-WebRequest -UseBasicParsing ('http://localhost:8199/analysis/session?id=' + [uri]::EscapeDataString($pbName) + '&lap=7&corners=1') -TimeoutSec 60
      Check 'GET /analysis/session?corners=1 answers 200 with every lap''s corner times and the corner list (C-41)' ($rs.StatusCode -eq 200 -and $rs.Content.Contains('"cornerT":[') -and $rs.Content.Contains('"turns":['))
    } else { Note "no $pbName in Documents\iRacing\telemetry - the live endpoint check needs it" }
    $ok1 = (Invoke-WebRequest -UseBasicParsing 'http://localhost:8199/api/do?c=wb-next-corner' -TimeoutSec 5).Content
    $q = (Invoke-WebRequest -UseBasicParsing 'http://localhost:8199/workbench/cmd' -TimeoutSec 5).Content | ConvertFrom-Json
    Check '/api/do?c=wb-next-corner is whitelisted and shows up at /workbench/cmd' ($ok1 -eq 'ok' -and $q.cmd -eq 'next-corner')
    $bad = 0; try { $null = Invoke-WebRequest -UseBasicParsing 'http://localhost:8199/api/do?c=wb-bogus' -TimeoutSec 5 } catch { $bad = [int]$_.Exception.Response.StatusCode }
    Check 'an unknown wb- command is refused (400)' ($bad -eq 400)
    $page = Invoke-WebRequest -UseBasicParsing 'http://localhost:8199/v2/workbench.html' -TimeoutSec 5
    Check 'irdash serves /v2/workbench.html' ($page.StatusCode -eq 200 -and $page.Content -like '*workbench.js*')

    Section '5a. deck OFFSET AUTO dispatch reaches the running Workbench page'
    Cdp-Open ('http://localhost:8199/v2/workbench.html?id=' + [uri]::EscapeDataString($pbName) + '&lap=7')
    $wbReady = $false; for ($i = 0; $i -lt 40 -and -not $wbReady; $i++) { Start-Sleep -Milliseconds 250; $wbReady = (Cdp-Eval 'window.WB && WB.data() ? 1 : 0') -eq 1 }
    if ($wbReady) {
      $null = Cdp-Eval 'window.__deckSeen="";var deckCmd=WB.cmd;WB.cmd=function(c,a){window.__deckSeen=c;return deckCmd(c,a)}'
      Start-Sleep -Milliseconds 900   # the page's first poll (every 0.3 s) only learns the current seq, so a press before it is not replayed
      $deckPost = (Invoke-WebRequest -UseBasicParsing 'http://localhost:8199/api/do?c=wb-offset-auto' -TimeoutSec 5).Content
      for ($i = 0; $i -lt 20 -and (Cdp-Eval 'window.__deckSeen') -ne 'offset-auto'; $i++) { Start-Sleep -Milliseconds 250 }
      Check 'wb-offset-auto is queued by the deck API and polled into WB.cmd("offset-auto")' ($deckPost -eq 'ok' -and (Cdp-Eval 'window.__deckSeen') -eq 'offset-auto')
    } else { Check 'wb-offset-auto is queued by the deck API and polled into WB.cmd("offset-auto")' $false }
    Cdp-Close

    Section '5b. real Sessions and Vault selections open the same Workbench with their lap'
    $liveSessions = (Invoke-WebRequest -UseBasicParsing 'http://localhost:8199/sessions' -TimeoutSec 10).Content | ConvertFrom-Json
    $sessionRow = $liveSessions.sessions | Where-Object { $_.best -ne $null -and -not $_.gone } | Select-Object -First 1
    $lapReply = (Invoke-WebRequest -UseBasicParsing ('http://localhost:8199/ibt/laps?file=' + [uri]::EscapeDataString($sessionRow.file)) -TimeoutSec 20).Content | ConvertFrom-Json
    Cdp-Open ('http://localhost:8199/v2/workbench.html?id=' + [uri]::EscapeDataString($sessionRow.file) + '&lap=' + $lapReply.best)
    $null = Cdp 'Page.navigate' @{ url = 'http://localhost:8199/v2/sessions.html' }
    $rowReady = $false; for ($i = 0; $i -lt 40 -and -not $rowReady; $i++) { Start-Sleep -Milliseconds 250; $rowReady = (Cdp-Eval ('[].some.call(document.querySelectorAll(".row[data-file]"),function(r){return r.dataset.file===' + (ConvertTo-Json $sessionRow.file -Compress) + '})')) -eq $true }
    $clicked = $false; if ($rowReady) { $clicked = (Cdp-Eval ('(function(){var r=[].filter.call(document.querySelectorAll(".row[data-file]"),function(x){return x.dataset.file===' + (ConvertTo-Json $sessionRow.file -Compress) + '})[0];if(!r)return false;r.click();return true})()')) -eq $true }
    $src = ''; for ($i = 0; $i -lt 60 -and -not $src; $i++) { Start-Sleep -Milliseconds 250; $src = [string](Cdp-Eval 'document.querySelector("#wbHost iframe") ? document.querySelector("#wbHost iframe").src : ""') }
    Check 'clicking the real Sessions row opens workbench.html on that file and its best lap' ($clicked -and $src -match ('workbench\.html\?id=' + [regex]::Escape([uri]::EscapeDataString($sessionRow.file)) + '&lap=' + [int]$lapReply.best))

    $list = (Invoke-WebRequest -UseBasicParsing 'http://localhost:8199/vault/list' -TimeoutSec 10).Content | ConvertFrom-Json
    $moment = $null
    foreach ($candidate in $list.moments) {
      if (-not $candidate.ibtSrc -or -not $candidate.lap) { continue }
      try { $item = (Invoke-WebRequest -UseBasicParsing ('http://localhost:8199/vault/item?id=' + [uri]::EscapeDataString($candidate.id)) -TimeoutSec 10).Content | ConvertFrom-Json; if ($item.hasTelemetry) { $moment = $candidate; break } } catch { }
    }
    $vaultOk = $false
    if ($moment) {
      $null = Cdp 'Page.navigate' @{ url = 'http://localhost:8199/v2/vault.html' }
      $cardReady = $false; for ($i = 0; $i -lt 40 -and -not $cardReady; $i++) { Start-Sleep -Milliseconds 250; $cardReady = (Cdp-Eval ('[].some.call(document.querySelectorAll(".card[data-id]"),function(r){return r.dataset.id===' + (ConvertTo-Json $moment.id -Compress) + '})')) -eq $true }
      if ($cardReady) { $null = Cdp-Eval ('(function(){var r=[].filter.call(document.querySelectorAll(".card[data-id]"),function(x){return x.dataset.id===' + (ConvertTo-Json $moment.id -Compress) + '})[0];r.click();return true})()') }
      $vsrc = ''; for ($i = 0; $i -lt 60 -and -not $vsrc; $i++) { Start-Sleep -Milliseconds 250; $vsrc = [string](Cdp-Eval 'document.querySelector("#wbHost iframe") ? document.querySelector("#wbHost iframe").src : ""') }
      $vaultOk = $cardReady -and $vsrc -match ('workbench\.html\?id=' + [regex]::Escape([uri]::EscapeDataString($moment.id)) + '&lap=' + [int]$moment.lap)
    }
    Check 'clicking a real Vault lap card opens workbench.html with its Vault id and lap' $vaultOk

    $reviewData = (Invoke-WebRequest -UseBasicParsing ('http://localhost:8199/analysis/session?id=' + [uri]::EscapeDataString($sessionRow.file)) -TimeoutSec 30).Content | ConvertFrom-Json
    $null = Cdp 'Page.navigate' @{ url = 'http://localhost:8199/v2/sessionreview.html?id=' + [uri]::EscapeDataString($sessionRow.file) }
    $reviewReady = $false; for ($i = 0; $i -lt 100 -and -not $reviewReady; $i++) { Start-Sleep -Milliseconds 250; $reviewReady = (Cdp-Eval 'document.getElementById("srAnalysis") && !document.getElementById("srAnalysis").hidden') -eq $true }
    if ($reviewReady) { $null = Cdp-Eval 'document.getElementById("srAnalysis").click()' }
    $rsrc = ''; for ($i = 0; $i -lt 60 -and -not $rsrc; $i++) { Start-Sleep -Milliseconds 250; $rsrc = [string](Cdp-Eval 'document.querySelector("#wbHost iframe") ? document.querySelector("#wbHost iframe").src : ""') }
    $reviewLap = [int]$reviewData.shown.lap
    Check 'ANALYSIS on the real Session Review opens the same file and its shown best lap in Workbench' ($reviewReady -and $rsrc -match ('workbench\.html\?id=' + [regex]::Escape([uri]::EscapeDataString($sessionRow.file)) + '&lap=' + $reviewLap))

    # 5c (six laps on eight traces, readout, frame rate) is section 4k: it ran on whatever page 5b left open (Session Review)
    # and stopped the test with an error before section 6, so its checks never ran here.
  }
  }

  Section '6. nothing on screen changed'
  Check 'dash\irdash.exe was not replaced by this test' ((Get-Item -LiteralPath $shipped).LastWriteTimeUtc.Ticks -eq $shippedStamp)
}
finally {
  Cdp-Close
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
  Assert-RigFree -Where 'done'
}

Write-Host "`nworkbench-test: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
