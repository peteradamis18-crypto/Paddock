# Overlays screen, delta bar and Rig Doctor end-to-end test (out of the car; no iRacing session needed).
# Drives the same requests the Stream Deck add-on sends (through irdash, which runs irdeck outside the Claude app),
# reads irdashies' real config.json back, checks the focus is never taken, and saves pictures of the top screen,
# the middle race screen and the deck screen (drawn by the real add-on code in headless Chrome) to tests\shots.
# Puts everything back as it found it (overlays, presets, delta bar settings, timing log).
#   powershell -ExecutionPolicy Bypass -File tests\overlays-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = 'http://localhost:8199'
$cfgFile = Join-Path $env:APPDATA 'irdashies\config.json'
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function J($path) { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 8; [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json }
function Api($c, $a) { $u = "$api/api/do?c=$c" + $(if ($a) { "&a=$a" } else { '' }); $null = Invoke-WebRequest -UseBasicParsing $u -TimeoutSec 8 }
function Widgets { (Get-Content $cfgFile -Raw | ConvertFrom-Json).dashboards.default.widgets }
function IsOn($id) { [bool](@(Widgets | Where-Object { $_.id -eq $id })[0].enabled) }
function Ini($key) { $m = Select-String -Path (Join-Path $root 'dash\irdash.ini') -Pattern "^$key=(.*)$" | Select-Object -First 1; if ($m) { $m.Matches[0].Groups[1].Value } else { $null } }
# the VS key goes pb > best > optimal > session (pb is skipped while there is no personal best for the car and track): press until the bar is on the wanted one
function Set-Ref($want) { for ($i = 0; $i -lt 6; $i++) { if ((J '/overlays').delta.ref -eq $want) { return }; Api 'deltaref'; Start-Sleep -Milliseconds 500 } }
# wait until irdash has nothing queued and nothing waiting to be applied
function Settle($max = 30) { Start-Sleep -Milliseconds 400; for ($i = 0; $i -lt $max * 5; $i++) { $j = J '/overlays'; if (-not $j.busy -and -not $j.pending) { Start-Sleep -Milliseconds 300; return $j }; Start-Sleep -Milliseconds 200 }; return J '/overlays' }
function IrdashiesStart { $p = Get-Process irdashies -ErrorAction SilentlyContinue; if ($p) { ($p | Sort-Object StartTime | Select-Object -First 1).StartTime } else { $null } }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class OvT {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static IntPtr Find(string title) { IntPtr found = IntPtr.Zero; EnumWindows(delegate(IntPtr h, IntPtr l) { var t = new StringBuilder(256); GetWindowText(h, t, 256); if (t.ToString() == title) { found = h; return false; } return true; }, IntPtr.Zero); return found; }
  public static int Count(string prefix) { int n = 0; EnumWindows(delegate(IntPtr h, IntPtr l) { var t = new StringBuilder(256); GetWindowText(h, t, 256); if (t.ToString().StartsWith(prefix) && IsWindowVisible(h)) n++; return true; }, IntPtr.Zero); return n; }
  public static string TitleOf(IntPtr h) { var t = new StringBuilder(256); GetWindowText(h, t, 256); return t.ToString(); }
}
'@
function Shot($name, $x, $y, $w, $h, $scaleTo) {
  $bmp = New-Object System.Drawing.Bitmap $w, $h; $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h))
  $path = Join-Path $shots "$name.png"
  if ($scaleTo) { $s = New-Object System.Drawing.Bitmap $bmp, $scaleTo, ([int]($h * $scaleTo / $w)); $s.Save($path); $s.Dispose() } else { $bmp.Save($path) }
  $g.Dispose(); $bmp.Dispose(); return $path
}
$top = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.Y } | Select-Object -First 1
$mid = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.X -eq 0 -and $_.Bounds.Y -eq 0 } | Select-Object -First 1

# ---- deck screen drawn by the real plugin.html code, in headless Chrome (DevTools protocol) ----
function Render-Deck($profile, $extraJs, $outPng) {
  $plugin = [IO.File]::ReadAllText((Join-Path $root 'deck-intro\plugin.html'))
  $stub = "<script>window.__imgs = {}; window.WebSocket = class { constructor() { this.readyState = 1; window.__ws = this; setTimeout(() => this.onopen && this.onopen(), 10); } send(m) { const o = JSON.parse(m); if (o.event === 'setImage') window.__imgs[o.context] = o.payload.image; } };</script>"
  $driver = @'
<script>
window.__run = async function (profile) {
  connectElgatoStreamDeckSocket(1234, 'uuid', 'registerPlugin', JSON.stringify({ devices: [{ id: 'DEV', type: 2 }] }));
  await new Promise(r => setTimeout(r, 50));
  for (let r = 0; r < 4; r++) for (let c = 0; c < 8; c++)
    window.__ws.onmessage({ data: JSON.stringify({ event: 'willAppear', action: 'com.peter.rigintro.tile', context: 'ctx-' + c + '-' + r, payload: { settings: { p: profile }, coordinates: { column: c, row: r } } }) });
  await new Promise(r => setTimeout(r, 1500));
};
window.__compose = async function () {
  const cv = document.getElementById('out'), g = cv.getContext('2d'); g.fillStyle = '#333'; g.fillRect(0, 0, cv.width, cv.height); let n = 0;
  for (let r = 0; r < 4; r++) for (let c = 0; c < 8; c++) {
    const u = window.__imgs['ctx-' + c + '-' + r]; if (!u) continue; n++;
    await new Promise(res => { const im = new Image(); im.onload = () => { g.drawImage(im, c * 150 + 6, r * 150 + 6, 138, 138); res(); }; im.src = u; });
  }
  return n;
};
</script>
<canvas id="out" width="1212" height="612"></canvas>
'@
  $html = $plugin.Replace('<body>', "<body>`n" + $stub).Replace('</body>', $driver + "`n</body>")
  $htmlPath = Join-Path $shots 'deck-harness.html'
  [IO.File]::WriteAllText($htmlPath, $html, (New-Object Text.UTF8Encoding($false)))
  $chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
  if (-not (Test-Path $chrome)) { return -1 }
  $prof = Join-Path $env:TEMP ('deck-harness-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9333
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", '--allow-file-access-from-files', "--remote-debugging-port=$port", 'about:blank') -PassThru -WindowStyle Hidden
  $n = -1
  try {
    $page = $null
    for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
    $script:cid = 0
    function Cdp($method, $params) {
      $script:cid++
      $bytes = [Text.Encoding]::UTF8.GetBytes((@{ id = $script:cid; method = $method; params = $params } | ConvertTo-Json -Depth 8 -Compress))
      $null = $ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [Threading.CancellationToken]::None).Wait()
      while ($true) {
        $buf = New-Object byte[] 65536; $sb = New-Object Text.StringBuilder
        do { $seg = New-Object ArraySegment[byte] -ArgumentList @(, $buf); $r = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None); $null = $r.Wait(); [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Result.Count)) } while (-not $r.Result.EndOfMessage)
        $o = $sb.ToString() | ConvertFrom-Json
        if ($o.id -eq $script:cid) { return $o }
      }
    }
    $null = Cdp 'Page.enable' @{}
    $null = Cdp 'Page.navigate' @{ url = ('file:///' + ($htmlPath -replace '\\', '/')) }
    Start-Sleep -Milliseconds 800
    $expr = "(async()=>{ await __run('$profile'); $extraJs const n = await __compose(); return JSON.stringify({ n, png: document.getElementById('out').toDataURL('image/png') }); })()"
    $res = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }
    if (-not $res.result.exceptionDetails) {
      $o = $res.result.result.value | ConvertFrom-Json
      [IO.File]::WriteAllBytes($outPng, [Convert]::FromBase64String($o.png.Substring($o.png.IndexOf(',') + 1))); $n = $o.n
    }
    $ws.Dispose()
  } finally {
    try { $p | Stop-Process -Force } catch { }
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$prof*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
    Start-Sleep -Milliseconds 300; try { Remove-Item -LiteralPath $prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  }
  return $n
}

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
function Section($title) { Assert-RigFree -Where $title; $title }
$tmp = Join-Path $env:TEMP 'overlays-test-keep'; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory $tmp | Out-Null
Copy-Item $cfgFile "$tmp\config.json"; Copy-Item (Join-Path $root 'overlays') "$tmp\overlays" -Recurse
$iniBefore = @('delta_bar', 'delta_ref', 'delta_pos') | ForEach-Object { "$_=$(Ini $_)" }
$refOrig = Ini 'delta_ref'
$cfg0 = Get-Content $cfgFile -Raw | ConvertFrom-Json
$tsvFile = Join-Path $root 'dash\timings.tsv'; $tsvBefore = if (Test-Path $tsvFile) { [IO.File]::ReadAllText($tsvFile) } else { $null }
'Overlays, delta bar and Rig Doctor test'

Section '1. the overlays screen has what it needs'
$o = J '/overlays'
Check '16 overlays on the deck screen, all found in the overlays app' (@($o.widgets).Count -eq 16 -and @($o.widgets | Where-Object { -not $_.known }).Count -eq 0)
Check 'five presets, all saved as files' (@($o.presets).Count -eq 5 -and @($o.presets | Where-Object { -not $_.exists }).Count -eq 0)
Check 'overlays app is running' ($o.running -eq $true)
Check 'irdash and the real config agree on which overlays are on' (@($o.widgets | Where-Object { $_.on }).Count -eq @(Widgets | Where-Object { $_.enabled -and $_.id -in $o.widgets.id }).Count)

Section '2. three quick taps = three overlays changed, one restart, no focus taken'
$ids = @('fuel', 'weather', 'input'); $before = @{}; foreach ($i in $ids) { $before[$i] = IsOn $i }
$fg0 = [OvT]::GetForegroundWindow(); $started0 = IrdashiesStart
$logBefore = (Get-Content (Join-Path $root 'irdeck.log') | Measure-Object).Count
foreach ($i in $ids) { Api 'ovtoggle' $i }
$o = Settle
foreach ($i in $ids) { Check "$i flipped in irdashies' real config" ((IsOn $i) -ne $before[$i]) }
$new = @(Widgets | Where-Object { $_.id -in $ids -and $_.enabled })
$b = $mid.Bounds
Check 'an overlay switched on is placed on the middle race screen' (@($new | Where-Object { $_.layout.x -lt $b.X -or $_.layout.y -lt $b.Y -or ($_.layout.x + $_.layout.width) -gt $b.Right -or ($_.layout.y + $_.layout.height) -gt $b.Bottom }).Count -eq 0)
Check 'the overlays app was restarted once' ((IrdashiesStart) -gt $started0 -and @(Get-Content (Join-Path $root 'irdeck.log') | Select-Object -Skip $logBefore | Where-Object { $_ -match '> ovl apply' }).Count -eq 1)
Check 'the overlay window is back on screen' ([OvT]::Count('irDashies -') -ge 1)
"        overlays were gone for $($o.restartSecs) s while the app restarted"
Check 'the overlays were back within 3 seconds' ($o.restartSecs -ne $null -and [double]$o.restartSecs -le 3.0)
$fg1 = [OvT]::GetForegroundWindow()
Check 'the overlays app did not take the focus' ([OvT]::TitleOf($fg1) -notlike 'irDashies*' -and [OvT]::TitleOf($fg1) -ne 'irdash delta bar')
if ($fg1 -ne $fg0) { "        (the front window changed from '$([OvT]::TitleOf($fg0))' to '$([OvT]::TitleOf($fg1))' - not caused by the overlays app)" }
Check 'the screen shows the new state' ((J '/overlays').onCount -eq @(Widgets | Where-Object { $_.enabled -and $_.id -in $o.widgets.id }).Count)
Check 'a backup of the config was made first' (@(Get-ChildItem (Join-Path $root 'backup\irdashies') -Filter 'config-*.json' | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-5) }).Count -ge 1)
$cfg1 = Get-Content $cfgFile -Raw | ConvertFrom-Json
Check 'the rest of the config (profiles, keys) is untouched' ((($cfg0.keybindings | ConvertTo-Json -Depth 6) -eq ($cfg1.keybindings | ConvertTo-Json -Depth 6)) -and $cfg0.currentProfile -eq $cfg1.currentProfile -and (($cfg0.profiles | ConvertTo-Json -Depth 6) -eq ($cfg1.profiles | ConvertTo-Json -Depth 6)))
Check 'each overlay keeps its own styling (only on/off and place change)' (($cfg0.dashboards.default.widgets | ForEach-Object { $_.id + ':' + ($_.config | ConvertTo-Json -Depth 12 -Compress) }) -join '|' -eq ($cfg1.dashboards.default.widgets | ForEach-Object { $_.id + ':' + ($_.config | ConvertTo-Json -Depth 12 -Compress) }) -join '|')

Section '3. presets: choose, save, choose again'
Api 'ovpreset' 'quali'; $o = Settle
$q = Get-Content (Join-Path $root 'overlays\presets\quali.json') -Raw | ConvertFrom-Json
$deck = $o.widgets.id
$wantQ = @($q.widgets | Where-Object { $_.enabled -and $_.id -in $deck } | ForEach-Object id | Sort-Object)
$gotQ = @(Widgets | Where-Object { $_.enabled -and $_.id -in $deck } | ForEach-Object id | Sort-Object)
Check 'QUALI switches on exactly its overlays' (($wantQ -join ',') -eq ($gotQ -join ','))
Check 'the QUALI key is gold (its overlays are on now)' ((J '/overlays').presets | Where-Object { $_.id -eq 'quali' }).match
$w = 'weather'; $wasOn = IsOn $w
Api 'ovtoggle' $w; $null = Settle
Check 'one more overlay changes the set; QUALI is no longer exactly on' (-not ((J '/overlays').presets | Where-Object { $_.id -eq 'quali' }).match -and (IsOn $w) -ne $wasOn)
Api 'ovsave' 'friends'; $o = Settle
$fr = Get-Content (Join-Path $root 'overlays\presets\friends.json') -Raw | ConvertFrom-Json
Check 'SAVE AS puts the overlays that are on now into FRIENDS' (@($fr.widgets | Where-Object { $_.id -eq $w })[0].enabled -eq (IsOn $w))
Check 'the old FRIENDS preset was backed up' (@(Get-ChildItem (Join-Path $root 'backup\overlays') -Filter 'friends-*.json' -ErrorAction SilentlyContinue).Count -ge 1)
Api 'ovpreset' 'race'; $null = Settle
Check 'RACE is back to what it says' ((J '/overlays').presets | Where-Object { $_.id -eq 'race' }).match
Api 'ovpreset' 'friends'; $o = Settle
Check 'choosing FRIENDS brings the saved set back (round trip)' ((IsOn $w) -eq (@($fr.widgets | Where-Object { $_.id -eq $w })[0].enabled) -and ((J '/overlays').presets | Where-Object { $_.id -eq 'friends' }).match)
Api 'ovalloff'; $o = Settle
Check 'ALL OFF switches every overlay off' (@(Widgets | Where-Object { $_.enabled }).Count -eq 0 -and $o.onCount -eq 0)
Api 'ovpreset' 'race'; $null = Settle

Section '4. drag mode (EDIT LAYOUT) and focus'
$fgBefore = [OvT]::GetForegroundWindow()
Api 'ovedit'; Start-Sleep -Milliseconds 3500
Check 'the screen says drag mode is on' ((J '/overlays').editing -eq $true)
$p1 = Shot 'o-drag-mode' $b.X $b.Y $b.Width $b.Height 1280
$bmp = New-Object System.Drawing.Bitmap $p1; $blue = 0
for ($yy = 0; $yy -lt $bmp.Height; $yy += 2) { for ($xx = 0; $xx -lt $bmp.Width; $xx += 2) { $c = $bmp.GetPixel($xx, $yy); if ($c.B -gt 200 -and $c.G -gt 120 -and $c.G -lt 190 -and $c.R -lt 60) { $blue++ } } }; $bmp.Dispose()
Check 'the overlays show their drag handles on the race screen' ($blue -gt 200)
Api 'ovedit'; Start-Sleep -Milliseconds 3000
Check 'the screen says it is locked again' ((J '/overlays').editing -eq $false)
Check 'the window that had the focus before gets it back' ([OvT]::GetForegroundWindow() -eq $fgBefore)

Section '5. the overlays app was stopped: the screen says so, one press brings it back'
Get-Process irdashies -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Milliseconds 800
Check 'the screen shows overlays are off' ((J '/overlays').running -eq $false)

Section '6. Rig Doctor sees it and says what to press'
# a leftover pretend session makes the doctor refuse to start anything; this check is out of a session
try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 5 } catch { }
Start-Sleep -Milliseconds 500
$null = Invoke-WebRequest -UseBasicParsing "$api/api/doctor/run" -TimeoutSec 8
for ($i = 0; $i -lt 80; $i++) { Start-Sleep -Milliseconds 500; $d = J '/doctor'; if (-not $d.running -and $d.ranAt -and $d.age -le 20) { break } }
$ids6 = @('overlays_visible', 'overlays_running', 'crewchief', 'streamdeck', 'irdash', 'screens', 'graphics', 'disk', 'telemetry', 'sim_priority', 'onedrive', 'timings', 'performance')
Check 'thirteen checks, all of the ones in the spec (and the sim priority, OneDrive and frame rate ones from the data and performance tools)' ((@($d.items | ForEach-Object id | Sort-Object) -join ',') -eq (($ids6 | Sort-Object) -join ','))
Check 'every check is green, amber or red with a plain sentence' (@($d.items | Where-Object { $_.state -notin 'ok', 'warn', 'bad' -or $_.detail.Length -lt 8 }).Count -eq 0)
Check 'every amber or red check says what to press or do' (@($d.items | Where-Object { $_.state -ne 'ok' -and $_.fix.Length -lt 8 }).Count -eq 0)
$ov = $d.items | Where-Object id -eq 'overlays_running'
Check 'with the overlays app stopped, the doctor starts it by itself (out of a session) and says so' ($ov.state -eq 'ok' -and $ov.done -match 'overlays' -and (J '/overlays').running)
$vis = $d.items | Where-Object id -eq 'overlays_visible'
$probe = Join-Path $root 'dash\probe.txt'
Check 'the overlays app is checked by a helper started through Explorer' ($vis.state -eq 'ok' -and (Test-Path $probe) -and (Get-Item $probe).LastWriteTime -gt (Get-Date).AddMinutes(-2) -and (Get-Content $probe -Raw) -match 'overlays_exe=.*irdashies\.exe')
Check 'the list is set to show on the top screen' ($d.show -eq $true)
Start-Sleep -Milliseconds 2500
$null = Shot 'o-doctor-top' $top.Bounds.X $top.Bounds.Y $top.Bounds.Width $top.Bounds.Height 960
Api 'ovapply'; $o = Settle
Check 'one press brings the overlays app back' ((J '/overlays').running -eq $true)

Section '7. a pretend session (only irdash sees it; iRacing and the other programs see nothing): start and load times, the delta bar in the car, the restart gate'
$hook = Join-Path $root 'dash\test-hook.on'; $mark = Join-Path $root 'dash\start-mark.txt'
$markBefore = if (Test-Path $mark) { [IO.File]::ReadAllText($mark) } else { $null }
$logN = (Get-Content (Join-Path $root 'dash\irdash.log') | Measure-Object).Count
$minus = [string][char]0x2212
function Fake($q) { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/frame?$q" -TimeoutSec 5 }
function Bar { (J '/overlays').delta.text }
function Count-Hot($bmpPath) {
  $bm = New-Object System.Drawing.Bitmap $bmpPath; $g = 0; $rd = 0
  for ($yy = 0; $yy -lt $bm.Height; $yy += 2) { for ($xx = 0; $xx -lt $bm.Width; $xx += 2) { $c = $bm.GetPixel($xx, $yy); if ($c.R -gt 200 -and $c.G -lt 110 -and $c.B -lt 110) { $rd++ } elseif ($c.G -gt 190 -and $c.R -lt 90 -and $c.B -lt 150) { $g++ } } }
  $bm.Dispose(); return @{ green = $g; red = $rd }
}
$before_battle = $null
Enter-TestLock 'overlays'   # one live test at a time (tests\guard.ps1); released in finally
try {
  # end first: ending deletes the mark, and a session already up never records "session loaded"
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 5 } catch { }
  Start-Sleep -Milliseconds 500
  Set-Content $hook 'on for the test'
  # START was pressed 41 s ago; the session loads, you sit in the pits, then you go out
  [IO.File]::WriteAllText($mark, ([DateTime]::UtcNow.AddSeconds(-41).Ticks.ToString() + "`tTEST"))
  Fake 'IsOnTrack=0&OnPitRoad=1&Lap=1&LapDistPct=0.1&Speed=0'
  Start-Sleep -Milliseconds 3500
  Fake 'IsOnTrack=1&OnPitRoad=0&Speed=0&Lap=3&LapDistPct=0.5&LapBestLapTime=101.2&LapLastLapTime=102.0&LapDeltaToBestLap=-0.214&LapDeltaToBestLap_OK=1&LapDeltaToOptimalLap=0.1&LapDeltaToOptimalLap_OK=1&LapDeltaToSessionBestLap=0.05&LapDeltaToSessionBestLap_OK=1'
  Start-Sleep -Milliseconds 1500
  $tl = if (Test-Path $tsvFile) { @(Get-Content $tsvFile) } else { @() }
  Check 'START to session loaded is timed (41 s since the START press)' (@($tl | Where-Object { $_ -match "`tstart_to_session`t4[1-3]\.\d`t" }).Count -ge 1)
  Check 'START to in the car is timed (about 45 s)' (@($tl | Where-Object { $_ -match "`tstart_to_car`t4[4-7]\.\d`t" }).Count -ge 1)
  Check 'loading to in the car is timed (about 3.5 s)' (@($tl | Where-Object { $_ -match "`tsession_to_car`t[345]\.\d`t" }).Count -ge 1)
  $seq0 = (J '/doctor').showSeq
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/doctor/run?quiet=1" -TimeoutSec 8
  for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Milliseconds 500; $d = J '/doctor'; if (-not $d.running -and $d.age -le 10) { break } }
  Check 'the last values reach Rig Doctor and the idle screen line' ($d.timings -match 'session loaded in 4\d s' -and $d.timings -match 'in the car in 4\d s' -and ($d.items | Where-Object id -eq 'timings').detail -match 'in the car in 4\d s')
  Check 'a quiet check does not ask to put the list on the screen' ($d.showSeq -eq $seq0)
  $page = (Invoke-WebRequest -UseBasicParsing "$api/v2/index.html").Content
  Check 'the idle screen has the rig line' ($page -match 'id="idleRig"')

  # the bar in the car
  $fgDrive = [OvT]::GetForegroundWindow()
  $hb = [OvT]::Find('irdash delta bar')
  Check 'in the car the bar appears by itself' ($hb -ne [IntPtr]::Zero -and [OvT]::IsWindowVisible($hb))
  # the default is VS PB; these checks are the best lap, so select that (a loaded PB would otherwise show dashes)
  Set-Ref 'best'; Start-Sleep -Milliseconds 400
  Check 'it shows -0.214 and the lap it is heading for (best 1:41.200)' ((Bar) -eq "$($minus)0.214 1:40.986")
  $r = New-Object OvT+RECT; [void][OvT]::GetWindowRect($hb, [ref]$r)
  $hot = Count-Hot (Shot 'o-delta-live-ahead' ($r.L - 20) ($r.T - 10) (($r.R - $r.L) + 40) (128 + 20) 0)
  Check 'ahead of the best lap it is green' ($hot.green -gt 150 -and $hot.red -lt 60)
  Fake 'LapDeltaToBestLap=0.18'; Start-Sleep -Milliseconds 700
  Check 'behind it shows +0.180 and 1:41.380' ((Bar) -eq '+0.180 1:41.380')
  $hot = Count-Hot (Shot 'o-delta-live-behind' ($r.L - 20) ($r.T - 10) (($r.R - $r.L) + 40) (128 + 20) 0)
  Check 'behind the best lap it is red' ($hot.red -gt 150 -and $hot.green -lt 60)
  Check 'the bar is not the front window while driving' ([OvT]::GetForegroundWindow() -ne $hb -and [OvT]::GetForegroundWindow() -eq $fgDrive)
  # a pretend session has no personal best, so a bar set to PB shows BEST (the label says which one is really in use)
  Set-Ref 'best'
  Api 'deltaref'; Start-Sleep -Milliseconds 600
  Check 'VS OPTIMAL shows that lap''s delta' ((J '/overlays').delta.ref -eq 'optimal' -and (Bar) -match '^\+0\.100')
  Api 'deltaref'; Start-Sleep -Milliseconds 600
  Check 'VS SESSION shows that lap''s delta' ((J '/overlays').delta.ref -eq 'session' -and (Bar) -match '^\+0\.050')
  Set-Ref 'best'; Start-Sleep -Milliseconds 400
  Fake 'OnPitRoad=1'; Start-Sleep -Milliseconds 1500
  Check 'in the pits the bar fades away' (-not [OvT]::IsWindowVisible($hb))
  Fake 'OnPitRoad=0'; Start-Sleep -Milliseconds 900
  Check 'out of the pits it is back' ([OvT]::IsWindowVisible($hb))
  Fake 'LapDeltaToBestLap_OK=0'; Start-Sleep -Milliseconds 2500
  Check 'with no usable delta (no reference lap yet) the bar steps aside' (-not [OvT]::IsWindowVisible($hb))
  Fake 'LapDeltaToBestLap_OK=1'; Start-Sleep -Milliseconds 700

  # the overlays only restart once the car has stopped
  $started1 = IrdashiesStart; $before_battle = IsOn 'battle'
  Fake 'Speed=35'
  Api 'ovtoggle' 'battle'; Start-Sleep -Milliseconds 6500
  $o = J '/overlays'
  Check 'at 35 m/s the change is saved but the overlays are not restarted' ((IsOn 'battle') -ne $before_battle -and (IrdashiesStart) -eq $started1 -and $o.pending -eq $true)
  Check 'and the deck screen says it is waiting for the car to stop' ($o.waiting -eq $true)
  Fake 'Speed=0'
  $o = Settle 20
  Check 'once the car is stopped the overlays restart by themselves' ((IrdashiesStart) -gt $started1 -and -not $o.pending)
}
finally {
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 5 } catch { }
  Start-Sleep -Milliseconds 600
  Remove-Item -LiteralPath $hook -Force -ErrorAction SilentlyContinue
  Exit-TestLock
  if ($markBefore -ne $null) { [IO.File]::WriteAllText($mark, $markBefore) } else { Remove-Item -LiteralPath $mark -Force -ErrorAction SilentlyContinue }
}
$lg = @(Get-Content (Join-Path $root 'dash\irdash.log') | Select-Object -Skip $logN)
Check 'the focus log says the bar was never the front window' (@($lg | Where-Object { $_ -match 'delta bar focus check: \d+ checks while driving, the bar was the front window 0 times' }).Count -eq 1)
Check 'the test hook is switched off again' (-not (Test-Path $hook))

Section '8. delta bar settings (out of the car the bar shows sample values for a few seconds, so you can see where it sits)'
$fg0 = [OvT]::GetForegroundWindow()
$null = Invoke-WebRequest -UseBasicParsing "$api/api/delta/preview?s=8" -TimeoutSec 5
Start-Sleep -Milliseconds 1200
$hb = [OvT]::Find('irdash delta bar')
Check 'the bar is a window of its own and is showing' ($hb -ne [IntPtr]::Zero -and [OvT]::IsWindowVisible($hb))
$ex = [OvT]::GetWindowLong($hb, -20)
Check 'it cannot take focus, ignores the mouse, stays on top and is see-through' ((($ex -band 0x08000000) -ne 0) -and (($ex -band 0x20) -ne 0) -and (($ex -band 0x8) -ne 0) -and (($ex -band 0x80000) -ne 0))
$r = New-Object OvT+RECT; [void][OvT]::GetWindowRect($hb, [ref]$r)
Check 'it sits top centre of the middle race screen' ([math]::Abs(($r.L + $r.R) / 2 - ($b.X + $b.Width / 2)) -lt 6 -and $r.T -ge $b.Y -and $r.T -lt $b.Y + 400 -and $r.R -le $b.Right)
Check 'it is not the front window' ([OvT]::GetForegroundWindow() -ne $hb -and [OvT]::GetForegroundWindow() -eq $fg0)
$shot = Shot 'o-delta-bar' ($r.L - 20) ($r.T - 10) (($r.R - $r.L) + 40) (128 + 20) 0
$bmp = New-Object System.Drawing.Bitmap $shot; $hot = 0
for ($yy = 0; $yy -lt $bmp.Height; $yy += 2) { for ($xx = 0; $xx -lt $bmp.Width; $xx += 2) { $c = $bmp.GetPixel($xx, $yy); if (($c.R -gt 200 -and $c.G -lt 110 -and $c.B -lt 110) -or ($c.G -gt 190 -and $c.R -lt 90 -and $c.B -lt 150)) { $hot++ } } }; $bmp.Dispose()
Check 'the picture shows the signed delta in green or red' ($hot -gt 150)
Set-Ref 'best'
$ref0 = Ini 'delta_ref'; $pos0 = Ini 'delta_pos'; $on0 = Ini 'delta_bar'
$seen = @()
for ($i = 0; $i -lt 4; $i++) { Api 'deltaref'; Start-Sleep -Milliseconds 500; $seen += (J '/overlays').delta.ref; if ($seen[-1] -eq $ref0) { break } }
Check 'VS cycles best, optimal, session (and pb when there is a personal best) and round again' ($seen[-1] -eq $ref0 -and $seen -contains 'optimal' -and $seen -contains 'session' -and (Ini 'delta_ref') -eq $ref0)
$y0 = [int](J '/overlays').delta.y
Api 'deltaup'; Api 'deltaup'; Start-Sleep -Milliseconds 400; $y1 = [int](J '/overlays').delta.y
Api 'deltadown'; Api 'deltadown'; Api 'deltadown'; Start-Sleep -Milliseconds 400; $y2 = [int](J '/overlays').delta.y
Api 'deltaup'; Start-Sleep -Milliseconds 400
Check 'MOVE up and down nudges 10 px each and saves it in irdash.ini' ($y1 -eq $y0 - 20 -and $y2 -eq $y0 + 10 -and (Ini 'delta_pos') -match ",$y0$")
Api 'deltaon'; Start-Sleep -Milliseconds 400
Check 'DELTA ON/OFF switches it off and writes delta_bar=0' ((J '/overlays').delta.on -eq $false -and (Ini 'delta_bar') -eq '0')
Api 'deltaon'; Start-Sleep -Milliseconds 400
Check 'and back on' ((J '/overlays').delta.on -eq $true -and (Ini 'delta_bar') -eq '1')
Start-Sleep -Milliseconds 7000
Check 'the bar goes away by itself when there is nothing to show' (-not [OvT]::IsWindowVisible($hb))

Section '9. the deck screen drawn by the real add-on code'
$shotDeck = Join-Path $shots 'o-deck-overlays.png'
$n = Render-Deck 'overlays' '' $shotDeck
Check 'all 32 keys of the OVERLAYS screen are drawn' ($n -eq 32)
$refBefore = (J '/overlays').delta.ref
$null = Render-Deck 'overlays' "await Overlays.press(3, 3); await new Promise(r => setTimeout(r, 900));" (Join-Path $shots 'o-deck-after-press.png')
$refAfter = (J '/overlays').delta.ref
Check 'pressing VS on that screen reaches irdash (the bar compares with the next lap type)' ($refAfter -ne $refBefore)
Set-Ref $ref0; Start-Sleep -Milliseconds 400
Check 'delta settings are back as they were' ((Ini 'delta_ref') -eq $ref0 -and (Ini 'delta_bar') -eq $on0)
Check 'the friends screen still draws all 32 keys' ((Render-Deck 'friends' '' (Join-Path $shots 'o-deck-friends-still-works.png')) -eq 32)

Section '10. put everything back'
Copy-Item "$tmp\overlays\presets\*" (Join-Path $root 'overlays\presets') -Force
Get-ChildItem (Join-Path $root 'overlays\presets') -Filter '*.json' | Where-Object { -not (Test-Path "$tmp\overlays\presets\$($_.Name)") } | Remove-Item -Force
if (Test-Path "$tmp\overlays\state.ini") { Copy-Item "$tmp\overlays\state.ini" (Join-Path $root 'overlays\state.ini') -Force }
if ($tsvBefore -ne $null) { [IO.File]::WriteAllText($tsvFile, $tsvBefore) } elseif (Test-Path $tsvFile) { Remove-Item $tsvFile -Force }
# the original config goes back through the real tool so irdashies restarts on it
[IO.File]::Copy("$tmp\config.json", $cfgFile, $true)
Api 'ovapply'; $o = Settle
$now = Get-Content $cfgFile -Raw | ConvertFrom-Json
Check 'your overlays are exactly as before the test' ((($cfg0.dashboards.default.widgets | ForEach-Object { "$($_.id):$($_.enabled):$($_.layout.x),$($_.layout.y)" }) -join ';') -eq (($now.dashboards.default.widgets | ForEach-Object { "$($_.id):$($_.enabled):$($_.layout.x),$($_.layout.y)" }) -join ';') -and $o.running)
Set-Ref $refOrig
Check 'no change was left in the delta bar settings' ((Ini 'delta_bar') -eq $on0 -and (Ini 'delta_ref') -eq $refOrig -and ((Ini 'delta_pos') -replace '^.*,', '') -eq ($pos0 -replace '^.*,', '' -replace '^auto$', '160'))
''
"$pass passed, $fail failed. Pictures in $shots"
