# Data tool end-to-end test (out of the car; no iRacing session needed): sessions page, lap analysis, race extras (iRating
# formula), pre-session brief, weekly progress, flag glow, sim priority, Rig Doctor checks, and the OneDrive tool.
# Real telemetry files are only read. Pretend sessions (the test hook) are seen by irdash and the dashboard page only.
# Pictures of the top screen go to tests\shots as d-*.png. Puts everything back as it found it.
#   powershell -ExecutionPolicy Bypass -File tests\data-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = 'http://localhost:8199'
$pass = 0; $fail = 0
function Check($what, $ok, $detail = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what $(if($detail){$detail})" } }
function Near($a, $b, $tol) { [math]::Abs([double]$a - [double]$b) -le $tol }
function J($path) { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 15; [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json }
# status code and body of a request that may fail
function Get-Raw($path) {
  try { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 15; return @{ code = [int]$r.StatusCode; body = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) } }
  catch { $resp = $_.Exception.Response; if (-not $resp) { return @{ code = 0; body = $_.Exception.Message } }
    $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $b = $sr.ReadToEnd(); $sr.Dispose(); return @{ code = [int]$resp.StatusCode; body = $b } }
}
function Fake($q) { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/frame?$q" -TimeoutSec 8 }
function Q($s) { [uri]::EscapeDataString($s) }
function Ini($key) { $m = Select-String -Path (Join-Path $root 'dash\irdash.ini') -Pattern "^$key=(.*)$" | Select-Object -First 1; if ($m) { $m.Matches[0].Groups[1].Value } else { $null } }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$top = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.Y } | Select-Object -First 1
function TopShot($name) {
  $b = $top.Bounds; $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height; $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $path = Join-Path $shots "$name.png"; $s = New-Object System.Drawing.Bitmap $bmp, 1280, 720; $s.Save($path); $s.Dispose(); $g.Dispose()
  return $bmp      # full size, for pixel checks (caller disposes)
}
# the average colour of a patch of the full-size picture
function Patch($bmp, $x, $y, $w, $h) { $r = 0; $g = 0; $b = 0; $n = 0; for ($yy = $y; $yy -lt $y + $h; $yy += 2) { for ($xx = $x; $xx -lt $x + $w; $xx += 2) { $c = $bmp.GetPixel($xx, $yy); $r += $c.R; $g += $c.G; $b += $c.B; $n++ } }; return @{ r = $r / $n; g = $g / $n; b = $b / $n } }

# ---- headless Chrome with the DevTools protocol: runs the real dashboard pages, to look inside them and to picture them ----
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('data-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9355
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', 'about:blank') -PassThru -WindowStyle Hidden
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0 }
  $null = Cdp 'Page.enable' @{}
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
    if ($o.id -eq $c.id) { return $o }
  }
}
function Cdp-Eval($expr) { $r = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }; if ($r.result.exceptionDetails) { return "js error: " + $r.result.exceptionDetails.exception.description }; return $r.result.result.value }
function Cdp-Shot($path) { $s = Cdp 'Page.captureScreenshot' @{ format = 'png' }; [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data)) }
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 300; try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# ---- independent readers (PowerShell, straight from the .ibt) to check the C# numbers against ----
function Ibt-Open($file) {
  $b = [IO.File]::ReadAllBytes($file)
  $o = @{ b = $b; tick = [BitConverter]::ToInt32($b, 8); bl = [BitConverter]::ToInt32($b, 36); bo = [BitConverter]::ToInt32($b, 52); rc = [BitConverter]::ToInt32($b, 140); vars = @{} }
  $nv = [BitConverter]::ToInt32($b, 24); $vho = [BitConverter]::ToInt32($b, 28)
  for ($i = 0; $i -lt $nv; $i++) { $p = $vho + 144 * $i; $o.vars[[Text.Encoding]::ASCII.GetString($b, $p + 16, 32).Trim([char]0)] = [BitConverter]::ToInt32($b, $p + 4) }
  return $o
}
function Ibt-Lap($file) {
  # every lap time iRacing announced while the file was being written (LapLastLapTime changes), at the full 60 records a second
  $f = Ibt-Open $file; $b = $f.b; $oL = $f.vars['LapLastLapTime']; $oOn = $f.vars['IsOnTrack']; $prev = -999.0; $laps = New-Object System.Collections.Generic.List[double]
  for ($r = 0; $r -lt $f.rc; $r++) {
    $base = $f.bo + $r * $f.bl
    if ($b[$base + $oOn] -eq 0) { continue }
    $v = [double][BitConverter]::ToSingle($b, $base + $oL)
    if ($prev -gt -900 -and $v -gt 1 -and [math]::Abs($v - $prev) -gt 0.0005) { $laps.Add($v) }
    $prev = $v
  }
  return $laps
}
function Ibt-Fuel($file) {
  # fuel burnt on each lap that stayed out of the pit lane: the fuel at the line, minus the fuel at the next line
  $f = Ibt-Open $file; $b = $f.b; $oLap = $f.vars['Lap']; $oF = $f.vars['FuelLevel']; $oP = $f.vars['OnPitRoad']; $oOn = $f.vars['IsOnTrack']; $oT = $f.vars['LapLastLapTime']
  $lastLap = -1; $startFuel = 0.0; $dirty = $true; $out = New-Object System.Collections.Generic.List[double]; $have = $false; $prevFuel = 0.0; $times = New-Object System.Collections.Generic.List[double]; $t0 = 0
  for ($r = 0; $r -lt $f.rc; $r++) {
    $base = $f.bo + $r * $f.bl
    if ($b[$base + $oOn] -eq 0) { $lastLap = -1; $have = $false; continue }
    $lap = [BitConverter]::ToInt32($b, $base + $oLap); $fuel = [double][BitConverter]::ToSingle($b, $base + $oF)
    if ($b[$base + $oP] -ne 0 -or ($have -and $fuel -gt $prevFuel + 0.05)) { $dirty = $true }
    if ($lastLap -ge 0 -and $lap -eq $lastLap + 1) {
      if ($have -and -not $dirty) { $out.Add($startFuel - $fuel); $times.Add([double][BitConverter]::ToSingle($b, $base + 90 * $f.bl + $oT)) }
      $startFuel = $fuel; $have = $true; $dirty = ($b[$base + $oP] -ne 0)
    } elseif ($lastLap -ge 0 -and $lap -ne $lastLap) { $have = $false }
    $lastLap = $lap; $prevFuel = $fuel
  }
  return @{ fuel = $out; times = $times }
}
# the community iRating formula, written again here (not the C# code) for the check
function PsChance($ra, $rb) { $br = 1600 / [math]::Log(2); $a = [math]::Exp(-$ra / $br); $b = [math]::Exp(-$rb / $br); return (1 - $a) * $b / ((1 - $a) * $b + $a * (1 - $b)) }
function PsDelta($r, $me, $place) { $e = 0.0; for ($j = 0; $j -lt $r.Count; $j++) { if ($j -ne $me) { $e += PsChance $r[$me] $r[$j] } }; return ($r.Count - $place - $e) * 200 / $r.Count }
function PsSof($r) { $br = 1600 / [math]::Log(2); $s = 0.0; foreach ($x in $r) { $s += [math]::Exp(-$x / $br) }; return -$br * [math]::Log($s / $r.Count) }

if ((& (Join-Path $root 'irdeck-cli.exe') state) -match 'telemetry=on') { 'iRacing is in a session - run this out of the car.'; exit 1 }
# If a real iRacing session starts while this test runs (the pretend one would mix with it), stop at once; the finally block puts everything back.
function Guard($where) {
  $s = & (Join-Path $root 'irdeck-cli.exe') state
  if ($s -match 'telemetry=on|onTrack=True') { throw "a real iRacing session started ($where): stopping the test here and putting everything back" }
}
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
function Section($title) { Assert-RigFree -Where $title; Guard $title; $title }

# the deploy lock: nobody else rebuilds irdash while this test needs it
Enter-TestLock 'data'   # one live test at a time (tests\guard.ps1); released in finally
$lock = Join-Path $root 'dash\deploy.lock'
for ($i = 0; $i -lt 20 -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15; $i++) { 'waiting for the deploy lock (' + (Get-Content $lock) + ')'; Start-Sleep -Seconds 60 }
Set-Content $lock ('data ' + (Get-Date).ToString('HH:mm:ss'))

$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$big = 'chevyvettez06rgt3_roadatlanta full 2026-10-09 10-28-32.ibt'        # 11 laps at Road Atlanta
$race = 'chevyvettez06rgt3_roadatlanta full 2026-10-04 22-13-50.ibt'       # an AI race: its YAML has a Race session (number 2)
$hook = Join-Path $root 'dash\test-hook.on'
$tsvFile = Join-Path $root 'dash\timings.tsv'; $tsvBefore = if (Test-Path $tsvFile) { [IO.File]::ReadAllText($tsvFile) } else { $null }
$logN = (Get-Content (Join-Path $root 'dash\irdash.log') | Measure-Object).Count
$testProcs = @()
'Data tool test'
try {

Section '1. career cache (format 2) and the weekly progress numbers'
$cacheFile = Join-Path $root 'dash\career-cache.tsv'
$rows = @(Get-Content $cacheFile | Where-Object { $_.Trim() }); $cols = @($rows | ForEach-Object { , ($_.Split("`t")) })
Check 'every row is format 2 (older rows were read again in the background)' (@($cols | Where-Object { $_.Count -ge 20 -and $_[12] -eq '2' }).Count -eq $rows.Count)
Check 'telemetry files and cache rows match one to one' ((@(Get-ChildItem $tel -Filter *.ibt | Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-1) }).Count) -le $rows.Count + 1)
Check 'many rows have a best lap, and some have fuel per lap' (@($cols | Where-Object { [double]$_[13] -gt 15 }).Count -ge 20 -and @($cols | Where-Object { [double]$_[14] -gt 0.1 }).Count -ge 5)
Check 'the layout (e.g. "Full Course") is stored, never the next line of the file' (@($cols | Where-Object { $_[16] -match ':' -and $_[16] -notmatch 'Course|Grand|Full|Long|International|Circuit' }).Count -eq 0)
$log = Get-Content (Join-Path $root 'dash\irdash.log')
$c = J '/career'
Check 'career exposes its cache status without a stale upgrade counter' ($c.PSObject.Properties.Name -contains 'hours' -and $c.PSObject.Properties.Name -contains 'laps')
Check 'the intro numbers are still there (hours, laps, km, races, last outing)' ($c.hours -gt 0 -and $c.laps -gt 0 -and $c.km -gt 0 -and $c.lastTrack -and $c.PSObject.Properties.Name -contains 'topCar')
Check 'nothing is left to read again' ($c.upgrading -eq 0)
# The hand count leaves out a short run exactly as Rec.Short does (dash\src\irdash.cs): under 30 s in the car, no lap and never
# off pit road (cache column 22, Left == 0), or a session a test started (dash\test-sessions.txt, 3 min before to 1 min after, 3 h open max).
$tRuns = @(); $tFile = Join-Path $root 'dash\test-sessions.txt'
if (Test-Path $tFile) { foreach ($ln in Get-Content $tFile) { $pp = $ln.Split("`t"); $s1 = 0L; if ($pp.Count -lt 1 -or -not [long]::TryParse($pp[0], [ref]$s1)) { continue }; $e1 = 0L; if ($pp.Count -lt 2 -or -not [long]::TryParse($pp[1], [ref]$e1) -or $e1 -lt $s1 -or ($e1 - $s1) -gt 108000000000) { $e1 = $s1 + 108000000000 }; $tRuns += , @($s1, $e1) } }
$monday = (Get-Date).Date.AddDays(-(([int](Get-Date).DayOfWeek + 6) % 7)); $wk = 0.0; $wl = 0
foreach ($f in $cols) {
  if ([double]$f[2] -lt 30) { continue }                                                                        # under 30 s in the car
  $left = if ($f.Count -ge 22 -and $f[21] -ne '') { [int]$f[21] } else { -1 }
  if ([int]$f[4] -eq 0 -and $left -eq 0) { continue }                                                           # no lap and never off pit road
  $utc = if ($f[18]) { [int64]$f[18] } else { [int64]$f[1] }
  $byTest = $false; foreach ($r in $tRuns) { if ($utc -ge $r[0] - 1800000000 -and $utc -le $r[1] + 600000000) { $byTest = $true; break } }
  if ($byTest) { continue }                                                                                     # a test started this session
  if (([DateTime]::new($utc, 'Utc')).ToLocalTime() -ge $monday) { $wk += [double]$f[2]; $wl += [int]$f[4] }
}
Check "this week from the cache by hand: $([math]::Round($wk / 3600, 1)) h, $wl laps - the idle screen's week figures say the same" (Near $c.week.hours ($wk / 3600) 0.06 -and $c.week.laps -eq $wl)
$pbCombos = @{}; foreach ($f in $cols) { if ([double]$f[2] -lt 30 -or [double]$f[13] -le 0) { continue }; $k = $f[6] + '|' + $f[7] + '|' + $f[16]; $when = ([DateTime]::new([int64]$f[18], 'Utc')).ToLocalTime(); if (-not $pbCombos.ContainsKey($k) -or [double]$f[13] -lt $pbCombos[$k].t - 0.0005) { $pbCombos[$k] = @{ t = [double]$f[13]; when = $when } } }
$pbWeek = @($pbCombos.Values | Where-Object { $_.when -ge $monday }).Count
Check "personal bests set this week by hand: $pbWeek" (($c.week.pbs + $c.week.fresh) -eq $pbWeek)

Section '2. sessions page data'
$s = J '/sessions'
Check 'every session in the cache is listed' ($s.sessions.Count -eq $rows.Count)
Check 'each has a date, car, track, type, laps, best lap and seat time' (@($s.sessions | Where-Object { $_.ts -gt 0 -and $_.secs -ge 0 -and $_.laps -ge 0 -and $_.PSObject.Properties.Name -contains 'best' -and $_.PSObject.Properties.Name -contains 'type' }).Count -eq $s.sessions.Count)
$row = @($s.sessions | Where-Object { $_.file -eq $big })[0]
$paced = Ibt-Lap (Join-Path $tel $big)
$handBest = ($paced | Where-Object { $_ -gt 15 } | Measure-Object -Minimum).Minimum
Check "the 11-lap file: best lap by hand from the .ibt is $handBest, the list says $($row.best)" (Near $row.best $handBest 0.0015)
$sameCombo = @($s.sessions | Where-Object { $_.car -eq $row.car -and $_.track -eq $row.track -and $_.config -eq $row.config -and $_.best -gt 0 -and -not $_.short })
$minBest = ($sameCombo | Measure-Object best -Minimum).Minimum
$pb = @($s.pbs | Where-Object { $_.car -eq $row.car -and $_.track -eq $row.track -and $_.config -eq $row.config })[0]
Check "the PB table has the best per car and track ($minBest) with the file it came from" ($pb -and (Near $pb.best $minBest 0.0006) -and (@($s.sessions | Where-Object { $_.file -eq $pb.file }).Count -eq 1))
Check 'no car+track appears twice in the PB table' (@($s.pbs | Group-Object { $_.car + '|' + $_.track + '|' + $_.config } | Where-Object { $_.Count -gt 1 }).Count -eq 0)
$fuelRow = $row.fuel
$fl = Ibt-Fuel (Join-Path $tel $big); $fast = ($fl.times | Where-Object { $_ -gt 15 } | Measure-Object -Minimum).Minimum
$ok = @(); for ($i = 0; $i -lt $fl.fuel.Count; $i++) { if ($fl.times[$i] -le $fast * 1.07) { $ok += $fl.fuel[$i] } }; $sorted = @($ok | Sort-Object); $handFuel = if ($sorted.Count % 2) { $sorted[($sorted.Count - 1) / 2] } else { ($sorted[$sorted.Count / 2 - 1] + $sorted[$sorted.Count / 2]) / 2 }
Check "fuel per lap by hand from the file ($([math]::Round($handFuel, 3)) L) matches the cache ($fuelRow L)" (Near $fuelRow $handFuel 0.04)
$page = Get-Raw '/v2/sessions.html'
Check 'the sessions page is served' ($page.code -eq 200 -and $page.body -match 'sessions.js' -and $page.body -match '<title>Paddock Sessions')
$homeHtml = (Get-Raw '/v2/index.html').body
Check 'HOME has the Sessions link (id idleSessions, text "Sessions") and no THIS WEEK block' ($homeHtml -match 'id="idleSessions"[^>]*>\s*Sessions' -and $homeHtml -notmatch 'idleWeek' -and $homeHtml -notmatch 'This week')

Section '3. lap analysis: the lap list, one lap, and refusing anything that is not a telemetry file'
$laps = J ("/ibt/laps?file=" + (Q $big))
Check 'the lap list names the track, car and type' ($laps.track -eq 'Road Atlanta' -and $laps.car -match 'Corvette' -and $laps.type -eq 'Race' -and $laps.lengthM -gt 4000)
Check 'it has the full laps (11) and not the partial ones around them' (@($laps.laps).Count -eq 11 -and $laps.partial -ge 1)
$bestLap = @($laps.laps | Where-Object { -not $_.pit } | Sort-Object time)[0]
Check "the best lap is lap $($bestLap.n) at $($bestLap.time) and matches the .ibt by hand ($handBest)" ($laps.best -eq $bestLap.n -and (Near $bestLap.time $handBest 0.002))
Check 'the pit lap is marked, and the clean laps are not' ((@($laps.laps | Where-Object { $_.pit }).Count -ge 1) -and ($laps.laps[8].pit -eq 0))
$ta = J ("/ibt/lap?file=" + (Q $big) + "&lap=" + $bestLap.n); $other = @($laps.laps | Where-Object { -not $_.pit -and $_.n -ne $bestLap.n })[1]
$tb = J ("/ibt/lap?file=" + (Q $big) + "&lap=" + $other.n)
Check 'a lap comes back as about 1000 points of speed, throttle, brake, gear, steering and time' ($ta.points -eq 1001 -and $ta.spd.Count -eq 1001 -and $ta.thr.Count -eq 1001 -and $ta.brk.Count -eq 1001 -and $ta.gear.Count -eq 1001 -and $ta.steer.Count -eq 1001 -and $ta.t.Count -eq 1001)
$mono = $true; for ($i = 1; $i -le 1000; $i++) { if ($ta.t[$i] -lt $ta.t[$i - 1]) { $mono = $false } }
Check 'time only moves forward along the lap, from 0 to the lap time' ($mono -and $ta.t[0] -eq 0 -and (Near $ta.t[1000] $ta.time 0.001))
$vmax = ($ta.spd | Measure-Object -Maximum).Maximum; $vmin = ($ta.spd | Measure-Object -Minimum).Minimum
Check "speed looks like a GT3 car at Road Atlanta (top $([math]::Round($vmax * 3.6)) km/h, slowest $([math]::Round($vmin * 3.6)) km/h)" ($vmax * 3.6 -gt 230 -and $vmax * 3.6 -lt 330 -and $vmin * 3.6 -gt 40 -and $vmin * 3.6 -lt 140)
Check 'the pedals are 0 to 100 and the gear is 0 (a gear change) to 6' ((($ta.thr | Measure-Object -Maximum).Maximum -le 100) -and (($ta.brk | Measure-Object -Maximum).Maximum -ge 50) -and (($ta.gear | Measure-Object -Maximum).Maximum -le 6) -and (($ta.gear | Measure-Object -Minimum).Minimum -ge 0) -and (@($ta.gear | Where-Object { $_ -ge 1 }).Count -gt 900))
Check "the difference between two laps ends at the difference of their lap times ($([math]::Round($tb.time - $ta.time, 3)) s)" (Near ($tb.t[1000] - $ta.t[1000]) ($tb.time - $ta.time) 0.002)
$maxDiff = 0; for ($i = 0; $i -le 1000; $i++) { $d = [math]::Abs($tb.t[$i] - $ta.t[$i]); if ($d -gt $maxDiff) { $maxDiff = $d } }
Check 'the two laps line up point for point (the biggest gap on the way is under 2 s)' ($maxDiff -lt 2)
foreach ($bad in @('..\..\Windows\win.ini', '../x.ibt', 'C:\Windows\System32\config\SAM', 'a/b.ibt', 'nope.ibt', '', 'x.txt', (($big -replace ' ', '%20') + '%00'), ('A' * 300 + '.ibt'))) {
  $r = Get-Raw ('/ibt/laps?file=' + $(if ($bad -match '%') { $bad } else { Q $bad }))
  Check ("refused: file=" + $(if ($bad.Length -gt 40) { $bad.Substring(0, 12) + '...(' + $bad.Length + ' characters)' } elseif ($bad) { $bad } else { '(empty)' })) ($r.code -eq 404)
}
Check 'a missing file name is refused too' ((Get-Raw '/ibt/laps').code -eq 404)
Check 'a name on its own is not enough: it must be a file the telemetry folder holds' ((Get-Raw '/ibt/lap?file=nothing-here.ibt&lap=1').code -eq 404)
Check 'a lap number that is not a number is refused' ((Get-Raw ('/ibt/lap?file=' + (Q $big) + '&lap=abc')).code -eq 400)
Check 'a lap that is not in the file is not found' ((Get-Raw ('/ibt/lap?file=' + (Q $big) + '&lap=99')).code -eq 404)
Cdp-Open "$api/v2/sessions.html#a=$(Q $big)"; Start-Sleep -Seconds 8
$info = Cdp-Eval "(function(){var f=document.querySelector('#wbHost iframe'),d=f&&f.contentDocument,u=f&&new URL(f.src),p=d&&d.getElementById('page');return JSON.stringify({title:d&&d.title,src:f&&f.src,lap:u&&u.searchParams.get('lap'),file:u&&u.searchParams.get('id'),loaded:!!(p&&p.innerText.trim()),page:p&&p.innerText})})()"
$info = $info | ConvertFrom-Json
Check "a selected session opens the shared Workbench at its best lap ($($info.lap))" ($info.title -eq 'Paddock Analysis' -and $info.file -eq $big -and $info.lap -eq "$($bestLap.n)" -and $info.loaded) ($info | ConvertTo-Json -Compress)
Check 'the Workbench has rendered its analysis page' ($info.page -and $info.page -notmatch 'Not connected|Loading')
Cdp-Shot (Join-Path $shots 'd-analysis.png')
$null = Cdp-Eval "document.querySelector('#wbHost iframe').contentWindow.WB.cmd('lap-next'); true"; Start-Sleep -Milliseconds 500
# the next lap reloads the Workbench page: wait for its data instead of trusting a fixed half second
for ($w = 0; $w -lt 30; $w++) { if ((Cdp-Eval "(function(){ try { var wb = document.querySelector('#wbHost iframe').contentWindow.WB; return !!(wb && wb.data() && wb.data().head); } catch (e) { return false; } })()") -eq $true) { break }; Start-Sleep -Milliseconds 500 }
$nextLap = Cdp-Eval "document.querySelector('#wbHost iframe').contentWindow.WB.data().head.lap.lap"
Check 'the selected Workbench can step to the next clean lap' ([int]$nextLap -gt [int]$bestLap.n)
$null = Cdp-Eval "document.getElementById('wbBack').click(); 1"; Start-Sleep -Seconds 2
Check 'Back to Sessions closes the shared Workbench and returns to the session list' ((Cdp-Eval "!document.getElementById('wbHost') && location.hash === '' && document.querySelectorAll('#sessList .row').length > 0") -eq $true)
Cdp-Shot (Join-Path $shots 'd-sessions.png')
$rowsOnPage = Cdp-Eval "document.querySelectorAll('#sessList .row').length"
Check 'the list on the page has every session (short runs too, quieter, never hidden: Peter 2026-10-18)' ($rowsOnPage -eq @($s.sessions).Count -and -not (Cdp-Eval "/short runs/i.test(document.getElementById('fMore').textContent)"))
$null = Cdp-Eval "document.querySelectorAll('#fCar .chip')[1].click(); 1"; Start-Sleep -Milliseconds 600
$filtered = Cdp-Eval "JSON.stringify({ rows: document.querySelectorAll('#sessList .row').length, pbs: document.querySelectorAll('#pbList .row').length, on: document.querySelector('#fCar .chip.on').textContent })" | ConvertFrom-Json
Check 'choosing a car filters the sessions and the personal bests together' ($filtered.rows -lt $rowsOnPage -and $filtered.rows -ge 1 -and $filtered.pbs -ge 1)
Cdp-Close

Section '4. opening the sessions page from a key, and never while driving'
$tsvKeep = $null
Set-Content $hook 'on for the test'
Cdp-Open "$api/v2/"; Start-Sleep -Seconds 4
Check 'the idle screen is up and the Sessions link is on it' ((Cdp-Eval "!!document.getElementById('idleSessions') && getComputedStyle(document.getElementById('overlay')).display") -eq 'block')
$bmp = TopShot 'd-idle'; $bmp.Dispose()
$n0 = (J '/nav').seq
$null = Invoke-WebRequest -UseBasicParsing "$api/api/sessions/open" -TimeoutSec 5
Check 'the key URL (/api/sessions/open) is accepted' ((J '/nav').to -eq 'sessions')
Start-Sleep -Milliseconds 3500
Check 'the dashboard page puts the sessions page over itself' ((Cdp-Eval "!!document.querySelector('#sessHost iframe') && document.querySelector('#sessHost').classList.contains('on')") -eq $true)
Cdp-Shot (Join-Path $shots 'd-sessions-from-key.png')
$bmp = TopShot 'd-top-sessions-open'; $shotW = $bmp.Width; $shotH = $bmp.Height; $bmp.Dispose()
Check "the physical-screen capture was saved for review (${shotW}x${shotH})" ($shotW -ge 1920 -and $shotH -ge 1080)
$null = Invoke-WebRequest -UseBasicParsing "$api/api/sessions/close" -TimeoutSec 5; Start-Sleep -Seconds 3
Check 'the close URL takes it away again' ((Cdp-Eval "!document.getElementById('sessHost')") -eq $true -and (J '/nav').to -eq '')
# driving: pretend session, on track
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/session?file=$(Q $race)" -TimeoutSec 8
Fake 'IsOnTrack=1&OnPitRoad=0&SessionNum=2&PlayerCarIdx=0&PlayerCarPosition=3&PlayerCarClassPosition=3&Lap=4&LapDistPct=0.4&Speed=45&FuelLevel=80&Gear=4&SessionFlags=0'
Start-Sleep -Milliseconds 2600
$r = Get-Raw '/api/sessions/open'
Check 'while you are driving the key is refused and nothing is requested' ($r.code -eq 409 -and (J '/nav').to -eq '')
Check 'the lap analysis refuses to read files while you are driving' ((Get-Raw ('/ibt/laps?file=' + (Q $big))).code -eq 503)
Check 'the sessions list itself still answers (it reads only a small cache)' ((Get-Raw '/sessions').code -eq 200)
Fake 'IsOnTrack=0&Speed=0'; Start-Sleep -Milliseconds 2600
$null = Invoke-WebRequest -UseBasicParsing "$api/api/sessions/open" -TimeoutSec 5; Start-Sleep -Seconds 3
Check 'with the car stopped and out of it, the page opens' ((Cdp-Eval "!!document.querySelector('#sessHost iframe')") -eq $true)
Fake 'IsOnTrack=1&Speed=30'; Start-Sleep -Milliseconds 3500
Check 'it closes by itself the moment you are in the car' ((Cdp-Eval "!document.getElementById('sessHost')") -eq $true -and (J '/nav').to -eq '')
Cdp-Close

Section '5. race extras: the iRating formula, then the live strength of field'
# worked by hand: two drivers, 3200 and 1600. e^(-R/BR1) is 1/4 and 1/2, so the favourite beats the other 3/4 of the time
$f1 = J '/irating?irs=3200,1600&me=0&pos=1'; $f2 = J '/irating?irs=3200,1600&me=0&pos=2'; $f3 = J '/irating?irs=3200,1600&me=1&pos=1'; $f4 = J '/irating?irs=3200,1600&me=1&pos=2'
Check 'the favourite beats the other driver 3 times in 4 (expected score 0.75)' (Near $f1.expected 0.75 0.0001)
Check 'favourite wins: (2 - 1 - 0.75) x 200 / 2 = +25' (Near $f1.delta 25 0.001)
Check 'favourite is second: (2 - 2 - 0.75) x 100 = -75' (Near $f2.delta -75 0.001)
Check 'the other driver wins: (2 - 1 - 0.25) x 100 = +75, and is second: -25' ((Near $f3.delta 75 0.001) -and (Near $f4.delta -25 0.001))
Check 'strength of field of 3200 and 1600 = -2308.31 x ln((0.25 + 0.5) / 2) = 2264.07' (Near $f1.sof 2264.07 0.05)
$e4 = 1..4 | ForEach-Object { (J "/irating?irs=2000,2000,2000,2000&me=0&pos=$_").delta }
Check 'four equal drivers: first +75, second +25, third -25, last -75' ((Near $e4[0] 75 0.001) -and (Near $e4[1] 25 0.001) -and (Near $e4[2] -25 0.001) -and (Near $e4[3] -75 0.001))
$rt = @(2850, 2600, 2400, 2150, 1900, 1700); $sum = 0.0; for ($i = 0; $i -lt 6; $i++) { $sum += (J ("/irating?irs=" + ($rt -join ',') + "&me=$i&pos=$($i + 1)")).delta }
Check 'nobody gains what nobody loses: all the changes in a race add up to zero' (Near $sum 0 0.001)
$h = J ("/irating?irs=" + ($rt -join ',') + "&me=0&pos=3")
Check "6 drivers, you (2850) in P3: C# says $($h.delta), the same sum written again in PowerShell says $([math]::Round((PsDelta $rt 0 3), 3))" (Near $h.delta (PsDelta $rt 0 3) 0.002)
Check 'bad input is refused' ((Get-Raw '/irating?irs=2000&me=0&pos=1').code -eq 400 -and (Get-Raw '/irating?irs=a,b&me=0&pos=1').code -eq 400 -and (Get-Raw '/irating?irs=2000,2000&me=5&pos=1').code -eq 400)
# the live path: a pretend official race (YAML from a real file, iRatings put in), you in P3
Set-Content $hook 'on for the test'
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/session?file=$(Q $race)&irs=$($rt -join ',')&official=1" -TimeoutSec 8
Fake 'IsOnTrack=1&OnPitRoad=0&SessionNum=2&PlayerCarIdx=0&PlayerCarPosition=3&PlayerCarClassPosition=3&Lap=4&LapDistPct=0.4&Speed=45&FuelLevel=80&Gear=4&SessionFlags=0'
Start-Sleep -Milliseconds 800
$lv = J '/race'
Check "live: an official race, 6 rated drivers in your class, strength of field $($lv.sof) (by hand $([math]::Round((PsSof $rt)))), you 2850" ($lv.on -eq $true -and $lv.official -eq $true -and $lv.n -eq 6 -and $lv.ir -eq 2850 -and (Near $lv.sof (PsSof $rt) 1))
Check "live: your estimated change in P3 is $($lv.delta) (by hand $([math]::Round((PsDelta $rt 0 3), 1)))" (Near $lv.delta (PsDelta $rt 0 3) 0.06)
Fake 'PlayerCarClassPosition=1'; Start-Sleep -Milliseconds 400
Check 'it follows your position: P1 is worth more than P3' ((J '/race').delta -gt $lv.delta -and (Near (J '/race').delta (PsDelta $rt 0 1) 0.06))
Cdp-Open "$api/v2/"; Start-Sleep -Seconds 5
$sof = Cdp-Eval "document.getElementById('sofBox').hidden + '|' + document.getElementById('sofBox').textContent"
$sofTxt = ([math]::Round((PsSof $rt))).ToString('N0', [Globalization.CultureInfo]::GetCultureInfo('en-GB'))
Check "the standings header shows it: $sof" ($sof -match ('^false\|SoF\s*' + $sofTxt + '.*iRating\s*\+'))
$bmp = TopShot 'd-race-extras'; $bmp.Dispose()
Cdp-Shot (Join-Path $shots 'd-race-extras-page.png')
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/session?file=$(Q $race)&irs=$($rt -join ',')&official=0" -TimeoutSec 8; Start-Sleep -Milliseconds 800
$un = J '/race'
Check 'not an official race: strength of field yes, but no iRating change promised' ($un.on -eq $true -and $un.official -eq $false -and $null -eq $un.delta)
Start-Sleep -Milliseconds 2500
Check 'and the page says the race is unrated' ((Cdp-Eval "document.getElementById('sofBox').textContent") -match 'unrated')
Fake 'SessionNum=0'; Start-Sleep -Milliseconds 400
Check 'in practice there is nothing (races only)' ((J '/race').on -eq $false)
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/session?file=$(Q $race)" -TimeoutSec 8; Fake 'SessionNum=2'; Start-Sleep -Milliseconds 400
Check 'an AI race (no real iRatings) has nothing either' ((J '/race').on -eq $false)
Start-Sleep -Milliseconds 2500
Check 'and the header on the page is empty again' ((Cdp-Eval "document.getElementById('sofBox').hidden") -eq $true)
Cdp-Close

Section '6. pre-session brief on the top screen'
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/session?file=$(Q $race)" -TimeoutSec 8
Fake 'IsOnTrack=0&OnPitRoad=0&SessionUniqueID=61&SessionNum=2&PlayerCarIdx=0&PlayerCarPosition=3&PlayerCarClassPosition=3&Lap=0&LapDistPct=0.01&Speed=0&FuelLevel=104&AirTemp=25.5&TrackTempCrew=40&WindVel=0.9&WindDir=0&Precipitation=0&TrackWetness=1&SessionFlags=0'
$b = J '/brief'
Check 'the brief data names the car and track from the loaded session' ($b.ready -and $b.track -eq 'Road Atlanta' -and $b.config -eq 'Full Course' -and $b.car -match 'Corvette')
Check "your best here ($($b.pb.time)) is the best of the sessions list ($($pb.best))" (Near $b.pb.time $pb.best 0.0006)
Check 'last time driven here, the number of sessions and the hours are given' ($b.lastCar.ago -and $b.sessionsCar -ge 20 -and $b.hoursCar -gt 1)
$lastHand = ($cols | Where-Object { $_[6] -match 'Corvette' -and $_[7] -eq 'Road Atlanta' -and [double]$_[2] -ge 30 } | ForEach-Object { ([DateTime]::new([int64]$_[18], 'Utc')).ToLocalTime() } | Sort-Object -Descending)[0]
Check "last time here by hand from the cache: $($lastHand.ToString('d MMM HH:mm')) - the brief gives the date '$($b.lastCar.ago)'" ($b.lastCar.ago -eq $lastHand.ToString('ddd d MMM', [Globalization.CultureInfo]::InvariantCulture))
Check "typical fuel per lap from history: $($b.fuel) L over $($b.fuelLaps) clean laps (this file by hand: $([math]::Round($handFuel, 2)))" ($b.fuel -gt 2.2 -and $b.fuel -lt 2.9 -and (Near $b.fuel $handFuel 0.2))
# the brief stays hidden while Rig Doctor's list is on screen; wait it out, then still require the brief
for ($i = 0; $i -lt 150; $i++) { $doc = J '/doctor'; if (-not $doc.show) { break }; if ($i % 10 -eq 0) { Guard 'waiting for the doctor list to leave' }; Start-Sleep -Milliseconds 500 }
Cdp-Open "$api/v2/"; Start-Sleep -Seconds 7
$br = Cdp-Eval "(function(){ var e=document.getElementById('brief'); if(!e) return 'none'; var cs=getComputedStyle(e); return JSON.stringify({on:e.classList.contains('on'), pe:cs.pointerEvents, text:e.innerText.replace(/\s+/g,' ')}); })()"
$bj = if ($br -ne 'none') { $br | ConvertFrom-Json } else { $null }
Check 'with a session loaded and you not in the car, the brief is up' ($bj -and $bj.on)
Check 'it shows the track, your best lap, the fuel per lap and the weather' ($bj -and $bj.text -match 'Road Atlanta' -and $bj.text -match ([regex]::Escape((Get-Date 0).AddSeconds($pb.best).ToString('m:ss.fff')) -replace '^0', '') -and $bj.text -match '2\.5\d' -and $bj.text -match 'Partly Cloudy' -and $bj.text -match 'Dry')
Check 'it ignores the mouse (it can never be in the way)' ($bj -and $bj.pe -eq 'none')
$bmp = TopShot 'd-brief'; $bmp.Dispose()
Cdp-Shot (Join-Path $shots 'd-brief-page.png')
Fake 'IsOnTrack=1&Speed=2'; Start-Sleep -Milliseconds 700
Check 'the moment you are in the car it starts to fade' ((Cdp-Eval "(function(){ var e=document.getElementById('brief'); return !e || !e.classList.contains('on'); })()") -eq $true)
Start-Sleep -Milliseconds 1600
Check 'and it is gone from the page while you drive' ((Cdp-Eval "!document.getElementById('brief')") -eq $true)
Fake 'Speed=40'; Start-Sleep -Seconds 4
Check 'it does not come back while you are driving' ((Cdp-Eval "!document.getElementById('brief')") -eq $true)
Fake 'IsOnTrack=0&Speed=0'; Start-Sleep -Seconds 4
Check 'nor when you stop and get out: that is the debrief''s moment, not the brief''s' ((Cdp-Eval "!document.getElementById('brief')") -eq $true)
$bmp = TopShot 'd-brief-gone'; $bmp.Dispose()
Cdp-Close

Section '7. flag glow'
Set-Content $hook 'on for the test'
$base = 'IsOnTrack=1&OnPitRoad=0&SessionNum=2&PlayerCarIdx=0&PlayerCarPosition=3&PlayerCarClassPosition=3&Lap=4&LapDistPct=0.4&Speed=45&FuelLevel=80&Gear=4&RPM=6200&Throttle=0.8&Brake=0&LapCurrentLapTime=31.2&LapLastLapTime=80.6&LapBestLapTime=79.6&SessionTimeRemain=1500&SessionState=4'
Fake "$base&SessionFlags=0"; Start-Sleep -Seconds 2
Cdp-Open "$api/v2/"; Start-Sleep -Seconds 4
Check 'no flag: no glow' ((Cdp-Eval "document.getElementById('flagGlow').className") -eq '')
$expect = @(@('yellow', 8, 'yellow'), @('yellow', 0x4000, 'yellow'), @('blue', 32, 'blue'), @('white', 2, 'white'), @('red', 16, 'red'), @('black', 65536, 'black'), @('checkered', 1, 'checkered'))
foreach ($e in $expect) {
  Guard 'flag glow'
  Fake "$base&SessionFlags=$($e[1])"; Start-Sleep -Milliseconds 1700
  Check "flag bits $($e[1]) -> $($e[0]) glow" ((Cdp-Eval "document.getElementById('flagGlow').className") -eq ('on ' + $e[2]))
  Cdp-Shot (Join-Path $shots "d-flag-page-$($e[0]).png")
}
Fake "$base&SessionFlags=$(8 + 32)"; Start-Sleep -Milliseconds 1700
Check 'yellow and blue together: yellow wins (it is the bigger deal)' ((Cdp-Eval "document.getElementById('flagGlow').className") -eq 'on yellow')
Fake "$base&SessionFlags=0"; Start-Sleep -Milliseconds 1700
Check 'flag gone: glow gone' ((Cdp-Eval "document.getElementById('flagGlow').className") -eq '')
Fake "$base&SessionFlags=4"; Start-Sleep -Milliseconds 1500
Check 'green flag: a green glow...' ((Cdp-Eval "document.getElementById('flagGlow').className") -eq 'on green')
Start-Sleep -Seconds 8
Check '...that fades by itself after a few seconds' ((Cdp-Eval "document.getElementById('flagGlow').className") -eq '')
Check 'the glow ignores the mouse and sits under every overlay' ((Cdp-Eval "(function(){var s=getComputedStyle(document.getElementById('flagGlow')); return s.pointerEvents+'|'+s.zIndex+'|'+s.position;})()") -eq 'none|800|fixed')
Cdp-Close

Section '8. the sim runs at High priority when a session starts (a harmless stand-in program is used; the real sim is not touched)'
Set-Content $hook 'on for the test'
$ping = Join-Path $env:SystemRoot 'System32\ping.exe'; $stand = Join-Path $env:TEMP 'irdash-test-sim.exe'; $stand2 = Join-Path $env:TEMP 'irdash-test-other.exe'; Copy-Item $ping $stand -Force; Copy-Item $ping $stand2 -Force
$sp = Start-Process -FilePath $stand -ArgumentList '-n 120 127.0.0.1' -PassThru -WindowStyle Hidden; $testProcs += $sp
$sp2 = Start-Process -FilePath $stand2 -ArgumentList '-n 120 127.0.0.1' -PassThru -WindowStyle Hidden; $testProcs += $sp2
Start-Sleep -Milliseconds 700
$sp.PriorityClass = 'Normal'; $sp2.PriorityClass = 'Normal'   # the stand-ins inherit this shell's priority (BelowNormal when helpers run the test)
$aff0 = $sp.ProcessorAffinity; $boost0 = $sp.PriorityBoostEnabled
Check 'before: the stand-in runs at Normal priority' ($sp.PriorityClass -eq 'Normal')
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/simproc?name=irdash-test-sim" -TimeoutSec 5
Check 'the default setting is High (nothing in irdash.ini overrides it)' ((Ini 'sim_priority') -in $null, 'high')
Fake "$base&SessionFlags=0&IsOnTrack=0"; Start-Sleep -Seconds 5
$sp.Refresh()
Check 'a session starts: the stand-in is raised to High' ($sp.PriorityClass -eq 'High')
Check 'only the priority changed: processor affinity and priority boost are as before' ($sp.ProcessorAffinity -eq $aff0 -and $sp.PriorityBoostEnabled -eq $boost0 -and -not $sp.HasExited)
Check 'the log says what happened' (@(Get-Content (Join-Path $root 'dash\irdash.log') | Select-Object -Skip $logN | Where-Object { $_ -match "sim priority: irdash-test-sim \($($sp.Id)\) raised from Normal to High" }).Count -eq 1)
$res = J "/api/test/priority?pid=$($sp2.Id)&mode=normal"
$sp2.Refresh()
Check 'with sim_priority=normal the priority is left alone' ($sp2.PriorityClass -eq 'Normal' -and $res.result -match 'sim_priority=normal')
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/simproc?name=" -TimeoutSec 5
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 5; Start-Sleep -Milliseconds 500

Section '9. Rig Doctor: the two new checks, and the OneDrive tool'
$null = Invoke-WebRequest -UseBasicParsing "$api/api/doctor/run?quiet=1" -TimeoutSec 8
for ($i = 0; $i -lt 80; $i++) { Start-Sleep -Milliseconds 500; $d = J '/doctor'; if (-not $d.running -and $d.age -le 10) { break } }
$pr = $d.items | Where-Object id -eq 'sim_priority'; $od = $d.items | Where-Object id -eq 'onedrive'
Check "Rig Doctor has a sim priority check: $($pr.state), '$($pr.detail)'" ($pr -and $pr.state -in 'ok', 'warn' -and $pr.detail -match 'High|priority')
Check "Rig Doctor reports whether Documents\iRacing is pinned in OneDrive: $($od.state), '$($od.detail)'" ($od -and $od.state -in 'ok', 'warn' -and $od.detail -match 'always keep|not set|free up|online-only|not in OneDrive|kept on this PC')
$attr = [int](Get-Item (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing')).Attributes
Check 'the check agrees with the folder''s real attributes (pinned = green)' ((($attr -band 0x80000) -ne 0) -eq ($od.state -eq 'ok'))
Check 'when it is not pinned it says what to do: run tools\keep-iracing-local.cmd' ($od.state -eq 'ok' -or $od.fix -match 'keep-iracing-local\.cmd')
Check 'both tools exist' ((Test-Path (Join-Path $root 'tools\keep-iracing-local.cmd')) -and (Test-Path (Join-Path $root 'tools\keep-iracing-local-UNDO.cmd')))
# the tool itself, on a scratch folder (never on your real Documents): pins everything, and the undo takes it off again
$fake = Join-Path $env:TEMP 'data-test-docs'; New-Item -ItemType Directory -Force "$fake\iRacing\telemetry" | Out-Null; Set-Content "$fake\iRacing\app.ini" 'x'; Set-Content "$fake\iRacing\telemetry\a.ibt" 'y'
foreach ($n in 'keep-iracing-local.cmd', 'keep-iracing-local-UNDO.cmd') {
  $t = [IO.File]::ReadAllText((Join-Path $root "tools\$n")); $t2 = [regex]::Replace($t, 'for /f "usebackq delims=" %%D in \(`[^`]+`\) do set "DOCS=%%D"', 'set "DOCS=' + $fake + '"')
  Check "$n sets the Documents folder from Windows' own answer (not a guess)" ($t -match 'GetFolderPath\(.MyDocuments.\)' -and $t2 -ne $t)
  [IO.File]::WriteAllText((Join-Path $env:TEMP "data-test-$n"), $t2, (New-Object Text.ASCIIEncoding))
}
$null = cmd /c "`"$env:TEMP\data-test-keep-iracing-local.cmd`""
$pinned = @(Get-Item "$fake\iRacing" -Force; Get-ChildItem "$fake\iRacing" -Recurse -Force) | Where-Object { [int]$_.Attributes -band 0x80000 }
Check 'the tool pins the folder and everything inside it (4 of 4)' (@($pinned).Count -eq 4)
$null = cmd /c "`"$env:TEMP\data-test-keep-iracing-local-UNDO.cmd`""
$left = @(Get-Item "$fake\iRacing" -Force; Get-ChildItem "$fake\iRacing" -Recurse -Force) | Where-Object { [int]$_.Attributes -band 0x80000 }
Check 'the undo takes it all off again' (@($left).Count -eq 0)

Section '9b. Rig Doctor fixes things itself (safe cases only: it stops the overlays app and the spotter, then lets the doctor bring them back)'
# what the idle screen says: "All good" or one short line, never the list of warnings
Cdp-Open "$api/v2/"; Start-Sleep -Seconds 4
$idle = Cdp-Eval "(function(){ Rig.idle({ ranAt: 'x', bad: 2, warn: 3, headline: '5 things to look at', items: [{ state: 'warn', name: 'Race screens', fix: 'plug the cable in' }, { state: 'warn', name: 'Stream Deck', fix: 'click Install' }], ask: '', timings: '' }); var a = document.getElementById('idleRig').textContent; Rig.idle({ ranAt: 'x', ask: 'Disk nearly full (9 GB left) - free up space', timings: '' }); var b = document.getElementById('idleRig').textContent; return JSON.stringify([a, b]); })()" | ConvertFrom-Json
# HOME v3: the doctor's result lives in the READY panel (#idleRig): no line at all when nothing needs him, one "Rig" row when something does
Check 'warnings that only he could clear (a cable, an add-on update) do not nag: READY shows no Rig row and none of those warnings' ($idle[0] -notmatch 'Rig\s*Disk|cable|Install|Race screens' -and $idle[0] -match '^(Ready|Live|.* off|Recording failed|Disk low)') "READY='$($idle[0])'"
Check 'something that truly needs him is one short Rig row in READY, and READY no longer says Ready' ($idle[1] -match 'Rig\s*Disk nearly full' -and $idle[1] -notmatch '^Ready') "READY='$($idle[1])'"
Cdp-Close
$d = J '/doctor'
Check 'an add-on update waiting to be installed is not a warning' ((($d.items | Where-Object id -eq 'streamdeck').state) -eq 'ok')
Check 'the doctor''s own idle line is "All good" when nothing needs you (ask is empty)' ($d.ask -eq '' -and $d.bad -eq 0)
function Doctor-Now($seconds = 70) { $null = Invoke-WebRequest -UseBasicParsing "$api/api/doctor/run?quiet=1" -TimeoutSec 8; Start-Sleep -Milliseconds 800; for ($i = 0; $i -lt $seconds * 2; $i++) { if ($i % 12 -eq 11) { Guard 'waiting for the doctor' }; Start-Sleep -Milliseconds 500; $x = J '/doctor'; if (-not $x.running -and $x.age -le 8) { return $x } }; return J '/doctor' }
$logAt = (Get-Content (Join-Path $root 'dash\irdash.log') | Measure-Object).Count
function Fixed-Lines { @(Get-Content (Join-Path $root 'dash\irdash.log') | Select-Object -Skip $logAt | Where-Object { $_ -match 'Rig Doctor fixed' }) }
# in a session (pretend) nothing is started
Set-Content $hook 'on for the test'
Fake 'IsOnTrack=0&OnPitRoad=0&SessionNum=2&PlayerCarIdx=0&Speed=0'; Start-Sleep -Milliseconds 800
Guard 'before stopping the overlays app'; Get-Process irdashies -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 1
$x = Doctor-Now 40
Check 'overlays app stopped during a session: the doctor leaves it (nothing is started while a session runs)' (($x.items | Where-Object id -eq 'overlays_running').state -ne 'ok' -and -not (Get-Process irdashies -ErrorAction SilentlyContinue))
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 5; Start-Sleep -Seconds 3
$x = Doctor-Now 80
$ovi = $x.items | Where-Object id -eq 'overlays_running'
Check "session over: the doctor starts the overlays app by itself ($($ovi.done))" ($ovi.state -eq 'ok' -and $ovi.done -match 'overlays' -and [bool](Get-Process irdashies -ErrorAction SilentlyContinue) -and (J '/overlays').running)
Check 'and logs it as "Rig Doctor fixed: ..."' (@(Fixed-Lines | Where-Object { $_ -match 'Overlays running' }).Count -ge 1)
Check 'the overlays come back on their saved layout (some are switched on)' ((J '/overlays').onCount -ge 1)
# CrewChief gone
Guard 'before stopping CrewChief'; Get-Process CrewChiefV4 -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 1
$x = Doctor-Now 80
$cci = $x.items | Where-Object id -eq 'crewchief'
Check "CrewChief stopped: the doctor starts it again ($($cci.done))" ($cci.state -eq 'ok' -and $cci.done -match 'CrewChief' -and [bool](Get-Process CrewChiefV4 -ErrorAction SilentlyContinue))
# CrewChief calling you by a friend's name with friends mode off (a leftover): the doctor puts your own name back
$ccCfg = (Get-ChildItem "$env:LOCALAPPDATA\Britton_IT_Ltd" -Recurse -Filter user.config | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
$stateFile = Join-Path $root 'guest\state.ini'; $stateBefore = [IO.File]::ReadAllText($stateFile); $cfgBefore = [IO.File]::ReadAllText($ccCfg)
$own = [regex]::Match($cfgBefore, 'name="PERSONALISATION_NAME"[^>]*>\s*<value>([^<]*)</value>').Groups[1].Value
if ($stateBefore -match '(?m)^active=0' -and $own) {
  try {
    Guard 'before changing CrewChief'
    $s2 = [regex]::Replace($stateBefore, '(?m)^own_cc_name=.*$', "own_cc_name=$own"); if ($s2 -eq $stateBefore -and $stateBefore -notmatch 'own_cc_name=') { $s2 = $stateBefore.TrimEnd() + "`r`nown_cc_name=$own`r`n" }
    [IO.File]::WriteAllText($stateFile, $s2)
    Get-Process CrewChiefV4 -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 2
    [IO.File]::WriteAllText($ccCfg, [regex]::Replace($cfgBefore, '(name="PERSONALISATION_NAME"[^>]*>\s*<value>)[^<]*(</value>)', '${1}Sam${2}'), (New-Object Text.UTF8Encoding($false)))
    Start-Process 'C:\Program Files (x86)\Britton IT Ltd\CrewChiefV4\CrewChiefV4.exe' -WorkingDirectory 'C:\Program Files (x86)\Britton IT Ltd\CrewChiefV4'; Start-Sleep -Seconds 6
    $x = Doctor-Now 100; $c2 = $x.items | Where-Object id -eq 'crewchief'
    $nameNow = [regex]::Match([IO.File]::ReadAllText($ccCfg), 'name="PERSONALISATION_NAME"[^>]*>\s*<value>([^<]*)</value>').Groups[1].Value
    Check "friends mode off, CrewChief calling you Sam: the doctor puts '$own' back ($($c2.done))" ($nameNow -eq $own -and $c2.state -eq 'ok' -and [bool](Get-Process CrewChiefV4 -ErrorAction SilentlyContinue))
    Check 'and logs it' (@(Fixed-Lines | Where-Object { $_ -match 'Spotter' -and $_ -match 'driver name' }).Count -ge 1)
  } finally {
    [IO.File]::WriteAllText($stateFile, $stateBefore)
    $nameNow = [regex]::Match([IO.File]::ReadAllText($ccCfg), 'name="PERSONALISATION_NAME"[^>]*>\s*<value>([^<]*)</value>').Groups[1].Value
    if ($nameNow -ne $own) { Get-Process CrewChiefV4 -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 1; [IO.File]::WriteAllText($ccCfg, $cfgBefore, (New-Object Text.UTF8Encoding($false))); Start-Process 'C:\Program Files (x86)\Britton IT Ltd\CrewChiefV4\CrewChiefV4.exe' -WorkingDirectory 'C:\Program Files (x86)\Britton IT Ltd\CrewChiefV4' }
  }
} else { Check 'CrewChief name test skipped (friends mode is on, or no name is set)' $true }
# the doctor finds a missing program by itself, without anybody pressing anything (needs irdash to have run 6 minutes)
$age = ((Get-Date) - (Get-Process irdash | Sort-Object StartTime | Select-Object -First 1).StartTime).TotalMinutes
if ($age -ge 6) {
  Guard 'before stopping the overlays app'; Get-Process irdashies -ErrorAction SilentlyContinue | Stop-Process -Force; $t0 = Get-Date; $back = $false
  for ($i = 0; $i -lt 200 -and -not $back; $i++) { Start-Sleep -Milliseconds 750; $back = [bool](Get-Process irdashies -ErrorAction SilentlyContinue) }
  $secs = [math]::Round(((Get-Date) - $t0).TotalSeconds)
  Check "overlays app gone and nobody pressing anything: back by itself after $secs s (not before 45 s, in case it is only restarting)" ($back -and $secs -ge 40 -and $secs -le 140)
  Start-Sleep -Seconds 6
} else { "  (skipped: the automatic 45 s watch needs irdash to have run 6 minutes; it has run $([math]::Round($age, 1)))" }

Section '10. nothing is left behind'
}
finally {
  Cdp-Close
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/simproc?name=" -TimeoutSec 5 } catch { }
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/sessions/close" -TimeoutSec 5 } catch { }
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 5 } catch { }
  Start-Sleep -Milliseconds 600
  Remove-Item -LiteralPath $hook -Force -ErrorAction SilentlyContinue
  foreach ($p in $testProcs) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
  Remove-Item (Join-Path $env:TEMP 'irdash-test-sim.exe') -Force -ErrorAction SilentlyContinue; Remove-Item (Join-Path $env:TEMP 'irdash-test-other.exe') -Force -ErrorAction SilentlyContinue
  if ($tsvBefore -ne $null) { [IO.File]::WriteAllText($tsvFile, $tsvBefore) } elseif (Test-Path $tsvFile) { Remove-Item $tsvFile -Force }
  Remove-Item -LiteralPath (Join-Path $env:TEMP 'data-test-docs') -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
  Exit-TestLock
}
Check 'the test hook is switched off again' (-not (Test-Path $hook))
Check 'the stand-in programs are gone' (@(Get-Process irdash-test-sim, irdash-test-other -ErrorAction SilentlyContinue).Count -eq 0)
Check 'the deploy lock is released' (-not (Test-Path $lock))
Check 'no page request is left open' ((J '/nav').to -eq '')
''
"$pass passed, $fail failed. Pictures in $shots"
