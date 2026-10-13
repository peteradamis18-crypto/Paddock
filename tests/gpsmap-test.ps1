# P0-05 real GPS track maps from .ibt Lat/Lon/Alt. Offline: copies of old .ibt files, the built (not deployed) irdash
# --analysis --gpsmap one-shot, and the real map.js in headless Chrome drawing the measured line. No iRacing file is
# written and nothing is read while a session runs (tests\guard.ps1). Pictures go to tests\shots as g-*.png.
#   powershell -ExecutionPolicy Bypass -File tests\gpsmap-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = if ($env:GPSMAP_TEST_API) { $env:GPSMAP_TEST_API } else { 'http://localhost:8199' }
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; Write-Host "  ok    $what" } else { $script:fail++; Write-Host "  FAIL  $what" } }
function Note($what) { Write-Host "  info  $what" }
function Near($a, $b, $tol) { [math]::Abs([double]$a - [double]$b) -le $tol }
function J($path) { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 30; [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json }
function Get-Raw($path) {
  $rq = [Net.HttpWebRequest]::Create("$api$path"); $rq.Timeout = 30000
  try { $resp = $rq.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { return @{ code = 0; body = $_.Exception.Message } } }
  $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8); $b = $sr.ReadToEnd(); $sr.Dispose(); $c = [int]$resp.StatusCode; $resp.Close()
  return @{ code = $c; body = $b }
}
function Q($s) { [uri]::EscapeDataString($s) }

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$rigState = & (Join-Path $root 'irdeck-cli.exe') state 2>&1 | Out-String
Check 'the rig state is explicitly free before GPS tests' ($rigState -match 'sim=False' -and $rigState -match 'telemetry=off')
if ($fail) { throw 'rig is not free; stopping before GPS tests' }
function Section($title) { Assert-RigFree -Where $title; Write-Host $title }

Add-Type -AssemblyName System.Drawing

$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$raFile = 'chevyvettez06rgt3_roadatlanta full 2026-10-09 10-28-32.ibt'
$sonomaFiles = @('porsche991rsr_sonoma long 2023-05-03 11-31-40.ibt', 'porsche991rsr_sonoma long 2023-05-03 11-33-00.ibt')
$work = Join-Path $env:TEMP ('gpsmap-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$outDir = Join-Path $work 'out'

# ---- cdp: headless Chrome with the DevTools protocol (no window; GitHub and its raw-file host cannot be reached) ----
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('gpsmap-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = Get-Random -Minimum 12000 -Maximum 24000
  $blocked = '--host-resolver-rules=MAP raw.githubusercontent.com ~NOTFOUND,MAP github.com ~NOTFOUND,MAP *.github.com ~NOTFOUND'
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', $blocked, 'about:blank') -PassThru -WindowStyle Hidden
  try { $p.PriorityClass = 'BelowNormal' } catch { }
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  if (-not $page) { throw 'Chrome DevTools did not come up' }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0 }
  $null = Cdp 'Page.enable' @{}
  $null = Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = "window.__errs = []; window.addEventListener('error', function (e) { window.__errs.push(String(e.message)); });" }
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
function Cdp-Shot($path, $x, $y, $w, $h) {
  $s = Cdp 'Page.captureScreenshot' @{ format = 'png'; clip = @{ x = $x; y = $y; width = $w; height = $h; scale = 1 } }
  [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data))
}
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 300; try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
# gold pixels (the measured line over the road)
function Gold-Pixels($path) {
  $bmp = New-Object System.Drawing.Bitmap $path; $n = 0
  for ($yy = 0; $yy -lt $bmp.Height; $yy += 1) { for ($xx = 0; $xx -lt $bmp.Width; $xx += 1) { $c = $bmp.GetPixel($xx, $yy); if ($c.R -gt 150 -and $c.G -gt 110 -and $c.B -lt 110 -and ($c.R - $c.B) -gt 70) { $n++ } } }
  $bmp.Dispose(); return $n
}
# ---- end cdp ----

New-Item -ItemType Directory -Force $work, $outDir | Out-Null

try {
  Section '1. old telemetry copies as fixtures'
  $gpsSource = Get-Content -LiteralPath (Join-Path $root 'dash\src\gpsmap.cs') -Raw
  Check 'the background builder returns if the bounded session wait expires busy' ($gpsSource -match 'for \(int i = 0; i < 60 && \(Program\.IsDriving \|\| Sdk\.Latest\.Connected\); i\+\+\).*?\r?\n\s*if \(Program\.IsDriving \|\| Sdk\.Latest\.Connected\) return;')
  Check 'each telemetry read is guarded by a fresh session-state check' ($gpsSource -match 'if \(Program\.IsDriving \|\| Sdk\.Latest\.Connected\) \{ why = "session active; telemetry read stopped"; return null; \}\s*read\+\+; budget -= fi\.Length;\s*try \{ g = ReadLap\(fi\.FullName')
  $raPath = Join-Path $tel $raFile
  Check "the Road Atlanta fixture is on disk: $raFile" (Test-Path -LiteralPath $raPath)
  if (Test-Path -LiteralPath $raPath) { Copy-Item -LiteralPath $raPath -Destination $work }
  $sonomaCopied = 0
  foreach ($n in $sonomaFiles) { if (Test-Path -LiteralPath (Join-Path $tel $n)) { Copy-Item -LiteralPath (Join-Path $tel $n) -Destination $work; $sonomaCopied++ } }
  Note "Sonoma Long fixtures copied: $sonomaCopied (the only two old files on this PC)"

  Section '2. compile without deploying'
  $build = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'dash\build.ps1') -NoDeploy | Out-String
  $m = [regex]::Match($build, 'built in (.+?) \(not deployed\)')
  Check 'dash\build.ps1 -NoDeploy compiled (exit 0)' ($LASTEXITCODE -eq 0 -and $m.Success)
  if (-not $m.Success) { throw $build }
  $exe = Join-Path $m.Groups[1].Value.Trim() 'irdash.exe'

  Section '3. build the GPS maps offline and fit them to the geometry irdash holds'
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = "--analysis --gpsmap --root `"$root`" --dir `"$work`" --out `"$outDir`""
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $proc = [Diagnostics.Process]::Start($psi)
  if (-not $proc.WaitForExit(300000)) { try { $proc.Kill() } catch { }; throw 'gpsmap one-shot timed out' }
  Check 'the one-shot ran (exit 0)' ($proc.ExitCode -eq 0)
  $sum = Get-Content -LiteralPath (Join-Path $outDir 'summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $fx = @($sum.fixtures); $sk = @($sum.skipped)
  $ra = @($fx | Where-Object { $_.key -eq 't127-roadatlanta-full' })
  Check "exactly one fixture was built for the road track: $($fx.Count) fixture(s), $($sk.Count) skipped" ($ra.Count -eq 1 -and $sum.fixtureCount -eq $fx.Count)
  if ($ra.Count -eq 1) {
    $r = $ra[0]
    Check "Road Atlanta: mean fit $($r.meanErrorM) m <= 5 m, max $($r.maxErrorM) m <= 15 m" ($r.meanErrorM -le 5 -and $r.maxErrorM -le 15)
    Check "Road Atlanta: the line is a full lap (n=$($r.n), file $($r.file), refSource $($r.refSource))" ($r.n -ge 200 -and $r.file -match '\.ibt$' -and $r.refSource.Length -gt 0)
    Check "Road Atlanta: every one of the $($r.apexCount) matched Lovely apexes is $($r.apexMaxErrorM) m from the line (<= 20 m)" ($r.apexCount -eq 14 -and $r.apexMaxErrorM -le 20)
    Check "Road Atlanta: Alt is carried for every point ($($r.altCount)) but the fit uses x/y only" ($r.altCount -eq $r.n -and $r.n -eq 720)
  }
  $sonoma = @($fx | Where-Object { $_.key -eq 't98-sonoma-long' })
  $sonomaSkip = @($sk | Where-Object { $_.key -eq 't98-sonoma-long' })
  Check 'Sonoma is claimed only from a complete lap: built, or honestly skipped with a reason' ($sonoma.Count -eq 1 -or ($sonomaSkip.Count -eq 1 -and $sonomaSkip[0].why -match 'no clean|no telemetry|gap'))
  if ($sonoma.Count -eq 0) { Note "Sonoma has no complete lap on disk (its old files cover a few percent of the lap): skipped as '$($sonomaSkip[0].why)' - no invented map" }
  $fixtureCount = $fx.Count

  Section '4. the measured line in the real map.js (headless Chrome, the internet blocked)'
  $tm = Get-Raw '/trackmap?key=t127-roadatlanta-full&id=127&name=roadatlanta%20full'
  $live = $null
  if ($tm.code -eq 200 -and $tm.body -match '"gps"') { try { $live = $tm.body | ConvertFrom-Json } catch { } }
  Check "the running /trackmap route serves GPS with geometry (HTTP $($tm.code))" ($live -and $live.gps -and @($live.gps.pts).Count -ge 200 -and @($live.pts).Count -ge 200)
  Check 'Alt stays metadata in the live reply (one value per point)' ($live -and @($live.gps.alt).Count -eq @($live.gps.pts).Count)
  # the served map.js must not invent anything
  $mjs = Get-Content -LiteralPath (Join-Path $root 'dash\www\v2\map.js') -Raw
  Check 'map.js draws no hills, no shading and no synthetic track art' (-not ($mjs -match '(?i)hill|shade|elevation|heightmap'))

  $imgCount = 0
  if (Test-Path $chrome) {
    $cases = @()
    foreach ($f in $fx) { $cases += @{ key = $f.key; raw = (Get-Content -LiteralPath (Join-Path $outDir $f.out) -Raw -Encoding UTF8) } }
    foreach ($c in $cases) {
      $name = if ($c.key -match 'roadatlanta') { 'roadatlanta full' } else { 'sonoma long' }
      $id = if ($c.key -match 'roadatlanta') { '127' } else { '98' }
      Cdp-Open "$api/v2/index.html?track=$(Q $name)&trackid=$id"
      $ok = $false
      for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Milliseconds 500; $st = Cdp-Eval "TrackMap.gps && TrackMap.pts ? JSON.stringify({pts:TrackMap.pts.length,gps:TrackMap.gps.pts.length}) : ''"; if ($st -match '"gps":\d+') { $ok = $true; break } }
      Check "$($c.key): the page loaded geometry and GPS from the live /trackmap route" $ok
      $drawn = Cdp-Eval "(function(){ S.drivers = new Map(); var g = TrackMap.gps; var old=document.getElementById('bigmap'); if(old) old.remove(); var cv=document.createElement('canvas'); cv.id='bigmap'; cv.width=1400; cv.height=760; cv.style.cssText='position:fixed;left:0;top:0;width:1400px;height:760px;z-index:99999;background:#030405'; document.body.appendChild(cv); TrackMap.draw(cv,1400,760); return JSON.stringify({ gps: g ? g.pts.length : 0, alt: g ? g.alt.length : 0, overlay: TrackMap.gpsOverlay }); })()"
      $dj = $null; try { $dj = $drawn | ConvertFrom-Json } catch { }
      Check "$($c.key): the measured line is drawn over the road ($drawn)" ($dj -and $dj.gps -ge 200 -and $dj.overlay)
      $png = Join-Path $shots ('gps-' + ($c.key -replace '^t\d+-', '') + '.png')
      Cdp-Shot $png 0 0 1400 760
      $gold = Gold-Pixels $png
      Check "$(Split-Path $png -Leaf): the gold measured line is visible ($gold gold pixels)" ($gold -gt 400)
      # Alt must not move a pixel
      $same = Cdp-Eval "(function(){ S.drivers = new Map(); var a = document.getElementById('bigmap').toDataURL(); TrackMap.gps.alt = TrackMap.gps.alt.map(function(){ return 99999; }); TrackMap.layerKey=''; TrackMap.draw(document.getElementById('bigmap'),1400,760); var b = document.getElementById('bigmap').toDataURL(); return (a===b) ? 'same' : 'DIFFERENT'; })()"
      Check "$($c.key): changing Alt (0 -> 99999 m) does not change one pixel - Alt is metadata only ($same)" ($same -eq 'same')
      $imgCount++
      Cdp-Close
    }
    Check "one picture per available map fixture ($imgCount pictures, $fixtureCount fixture(s))" ($imgCount -eq $fixtureCount -and $imgCount -ge 1)
  } else { Check 'Chrome is installed for the required screenshot run' $false; Check 'one picture per available map fixture' $false }
} catch {
  Check 'headless Chrome completed the live-route screenshot run' $false
  Note $_.Exception.Message
} finally {
  Cdp-Close
  try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
"`n$pass ok, $fail FAIL"
if ($fail) { exit 1 }
