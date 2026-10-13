# Friends mode, proved. Section 1 always runs (no sim): the driving-line binding, then the top screen
# in headless Chrome at 1920x1080 on a pretend session (map, times, colours, coach).
# Section 2 runs only when Peter has been idle for 10 minutes: a real BMW GT4 Test Drive at Lime Rock.
# The wheel check is what was sent (feel 8 / 14 Nm, max force yours*yours/feel). The sim's max-force
# reading stays at Peter's own wheel, so it is not proof. EXIT must still read that own value back.
# The top-screen picture waits up to 30 s for the map.
#   powershell -ExecutionPolicy Bypass -File tests\friends-live-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = 'http://localhost:8199'
$pass = 0; $fail = 0
$script:ownsSim = $false
$script:live = $false
$script:cdp = $null
$script:liveLog = ''
$script:logAt = 0
# Write-Host so Assert-Wheel can return a value without swallowing ok/FAIL (that hid two failures).
function Check($what, $ok) { if ($ok) { $script:pass++; Write-Host "  ok    $what" } else { $script:fail++; Write-Host "  FAIL  $what" } }
function Guest { (Invoke-WebRequest -UseBasicParsing "$api/guest" -TimeoutSec 5).Content | ConvertFrom-Json }
function Press($c, $a) {
  $u = "$api/api/guest/do?c=$c" + $(if ($a) { "&a=$a" } else { '' })
  $null = Invoke-WebRequest -UseBasicParsing $u -TimeoutSec 8
}
function Q($s) { [uri]::EscapeDataString($s) }
function Fake($q) { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/frame?$q" -TimeoutSec 20 }
function Wait-Until($seconds, [scriptblock]$cond) {
  # Do not watch idle in here. Once the live section has started, its own clicks reset the idle timer,
  # so a check would look like Peter sat down and would abort a session we started on purpose.
  for ($i = 0; $i -lt $seconds * 2; $i++) {
    if (& $cond) { return $true }
    Start-Sleep -Milliseconds 500
  }
  return $false
}

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
function Section($title) {
  Assert-RigFree -Where $title
  if (-not $script:live) {
    $s = & (Join-Path $root 'irdeck-cli.exe') state
    if ($s -match 'telemetry=on|onTrack=True') { throw "a real iRacing session started ($title)" }
  }
  $title
}

# --- Chrome (headless), same idea as tv-test, its own port and profile ---
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('friends-live-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9374
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', '--disable-background-timer-throttling', '--disable-renderer-backgrounding', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', 'about:blank') -PassThru -WindowStyle Hidden
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) {
    Start-Sleep -Milliseconds 200
    try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { }
  }
  if (-not $page) { throw 'Chrome did not open a page' }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0 }
  $null = Cdp 'Page.enable' @{}
  $null = Cdp 'Emulation.setDeviceMetricsOverride' @{ width = $w; height = $h; deviceScaleFactor = 1; mobile = $false }
  $null = Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = "window.__errs=[];addEventListener('error',function(e){__errs.push(String(e.message))});addEventListener('unhandledrejection',function(e){__errs.push(String(e.reason))});" }
  $null = Cdp 'Page.navigate' @{ url = $url }
}
function Cdp($method, $params) {
  $c = $script:cdp; $c.id++
  $bytes = [Text.Encoding]::UTF8.GetBytes((@{ id = $c.id; method = $method; params = $params } | ConvertTo-Json -Depth 8 -Compress))
  $null = $c.ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [Threading.CancellationToken]::None).Wait()
  while ($true) {
    $buf = New-Object byte[] 262144; $sb = New-Object Text.StringBuilder
    do {
      $seg = New-Object ArraySegment[byte] -ArgumentList @(, $buf)
      $r = $c.ws.ReceiveAsync($seg, [Threading.CancellationToken]::None); $null = $r.Wait()
      [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Result.Count))
    } while (-not $r.Result.EndOfMessage)
    $o = $sb.ToString() | ConvertFrom-Json
    if ($o.id -eq $c.id) { return $o }
  }
}
function Cdp-Eval($expr) {
  $r = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }
  if ($r.result.exceptionDetails) { return 'js error: ' + $r.result.exceptionDetails.exception.description }
  return $r.result.result.value
}
function Cdp-Shot($path) { $s = Cdp 'Page.captureScreenshot' @{ format = 'png' }; [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data)) }
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 300; try { [IO.Directory]::Delete($c.prof, $true) } catch { }
}
function Ev([string]$js) { $r = Cdp-Eval $js; if ($r -is [string] -and $r.StartsWith('js error:')) { throw $r }; return $r }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
function Shot-Screen($name, $which) {
  $screens = [System.Windows.Forms.Screen]::AllScreens
  if ($which -eq 'top') { $b = ($screens | Sort-Object { $_.Bounds.Y } | Select-Object -First 1).Bounds }
  else { $hit = $screens | Where-Object { $_.Bounds.X -eq 0 -and $_.Bounds.Y -eq 0 } | Select-Object -First 1; if (-not $hit) { $hit = [System.Windows.Forms.Screen]::PrimaryScreen }; $b = $hit.Bounds }
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $s = New-Object System.Drawing.Bitmap $bmp, 960, 540
  $s.Save((Join-Path $shots $name))
  $g.Dispose(); $bmp.Dispose(); $s.Dispose()
}
function Grab-Top {
  $screens = [System.Windows.Forms.Screen]::AllScreens
  $b = ($screens | Sort-Object { $_.Bounds.Y } | Select-Object -First 1).Bounds
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $g.Dispose()
  return $bmp
}
function Save-Scaled($bmp, $name) {
  $s = New-Object System.Drawing.Bitmap $bmp, 960, 540
  $s.Save((Join-Path $shots $name))
  $s.Dispose()
}
# Regions are the 1920x1080 friends layout (current lap, last, best, the map). Counts scale with the screen.
function Pixel-Count($bmp, $x0, $y0, $x1, $y1, $kind) {
  $sx = $bmp.Width / 1920.0; $sy = $bmp.Height / 1080.0
  $xa = [int]($x0 * $sx); $xb = [Math]::Min($bmp.Width, [int]($x1 * $sx))
  $ya = [int]($y0 * $sy); $yb = [Math]::Min($bmp.Height, [int]($y1 * $sy))
  $n = 0
  for ($y = $ya; $y -lt $yb; $y += 2) {
    for ($x = $xa; $x -lt $xb; $x += 2) {
      $c = $bmp.GetPixel($x, $y)
      $hit = $false
      if ($kind -eq 'white') { $hit = ($c.R -gt 180 -and $c.G -gt 180 -and $c.B -gt 170) }
      elseif ($kind -eq 'ink') { $hit = (($c.R + $c.G + $c.B) -gt 80) }
      else { $hit = ($c.R -gt 140 -and $c.G -gt 100 -and $c.B -lt 120 -and ($c.R - $c.B) -gt 50 -and $c.G -gt $c.B) }
      if ($hit) { $n++ }
    }
  }
  return $n
}

function Take-Log {
  $p = Join-Path $root 'irdeck.log'
  if (-not (Test-Path $p)) { return $script:liveLog }
  $fs = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
  try {
    if ($fs.Length -lt $script:logAt) { $script:logAt = 0 }
    [void]$fs.Seek($script:logAt, 'Begin')
    $sr = New-Object IO.StreamReader($fs)
    $script:liveLog += $sr.ReadToEnd()
    $script:logAt = $fs.Length
    $sr.Dispose()
  } finally { $fs.Dispose() }
  return $script:liveLog
}
function Wheel-Hit($step) {
  $all = [regex]::Matches($script:liveLog, ("guest: wheel {0} feel ([0-9.]+) Nm -> max force ([0-9.]+) Nm, sim reads ([0-9.]+|n/a) \(yours ([0-9.]+)" -f $step))
  if ($all.Count -eq 0) { return $null }
  return $all[$all.Count - 1]
}

$lock = Join-Path $root 'dash\deploy.lock'
$hook = Join-Path $root 'dash\test-hook.on'
$stateFile = Join-Path $root 'guest\state.ini'
$stateBytes = [IO.File]::ReadAllBytes($stateFile)
$markFile = Join-Path $root 'dash\start-mark.txt'
$markBefore = Test-Path $markFile
$ir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing'
$cfg = Join-Path $ir 'controls.cfg'
$cfgTime = (Get-Item $cfg).LastWriteTimeUtc
$pendingLive = $false

'Friends live test'
Enter-TestLock 'friends-live'   # one live test at a time (tests\guard.ps1); released in finally
try {
  Section '1. offline: the driving line is already bound' | Out-Null
  '1. offline: the driving line is already bound'
  $b = [IO.File]::ReadAllBytes($cfg)
  $name = [Text.Encoding]::ASCII.GetBytes('ToggleDrivingLine')
  $found = $null
  for ($i = 0; $i -le $b.Length - $name.Length - 20; $i++) {
    $ok = $true
    for ($k = 0; $k -lt $name.Length; $k++) { if ($b[$i + $k] -ne $name[$k]) { $ok = $false; break } }
    if (-not $ok -or $b[$i + $name.Length] -ne 0) { continue }
    $o = $i + $name.Length + 1
    $count = [BitConverter]::ToInt32($b, $o); $o += 4
    if ($count -lt 1) { continue }
    $type = [BitConverter]::ToInt32($b, $o); $o += 4
    $bound = [BitConverter]::ToInt32($b, $o); $o += 4
    $vk = [BitConverter]::ToInt32($b, $o); $o += 4
    $o += 2
    $e2 = [BitConverter]::ToUInt16($b, $o)
    $found = @{ type = $type; bound = $bound; vk = $vk; e2 = [int]$e2 }
    break
  }
  $iniKey = ''
  foreach ($l in Get-Content (Join-Path $root 'guest\guest.ini')) { if ($l -match '^\s*racing_line_key\s*=\s*(\S+)') { $iniKey = $Matches[1] } }
  $ctrlAlt = $found -and ($found.e2 -band 12) -ne 0 -and ($found.e2 -band 48) -ne 0
  Check 'Toggle Driving Line is bound to ctrl+alt+l, matching guest.ini' ($found -and $found.type -eq 6 -and $found.bound -eq 4 -and $found.vk -eq 0x4C -and $ctrlAlt -and $iniKey -eq 'ctrl+alt+l')
  if (-not $found) { '        no ToggleDrivingLine record' } else { "        type=$($found.type) bound=$($found.bound) vk=$($found.vk) mod=$($found.e2) ini=$iniKey" }

  Section '2. offline: top screen with a pretend session' | Out-Null
  '2. offline: top screen with a pretend session'
  for ($i = 0; $i -lt 20 -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15; $i++) { 'waiting for the deploy lock'; Start-Sleep -Seconds 30 }
  Set-Content $lock ('friends-live ' + (Get-Date).ToString('HH:mm:ss'))
  Set-Content $hook 'on for the friends live test'
  $tel = Join-Path $ir 'telemetry'
  $race = 'chevyvettez06rgt3_roadatlanta full 2026-10-04 22-13-50.ibt'
  if (-not (Test-Path (Join-Path $tel $race))) {
    $alt = 'chevyvettez06rgt3_roadatlanta full 2026-10-06 21-26-58.ibt'
    if (Test-Path (Join-Path $tel $alt)) { $race = $alt } else { throw 'no Road Atlanta telemetry file to borrow a session from' }
  }
  $g0 = Guest
  if ($g0.active) { Press 'off'; Start-Sleep -Seconds 2 }
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/session?file=$(Q $race)" -TimeoutSec 30
  Fake 'IsOnTrack=1&OnPitRoad=0&SessionState=4&SessionTime=1000&SessionTimeRemain=604800&LapDistPct=0.05&LapCurrentLapTime=12.4&LapLastLapTime=90.5&LapBestLapTime=90.123&Speed=10&Lap=3&LapCompleted=2&FuelLevel=40&Throttle=0.2&Brake=0'
  Press 'on'
  $on = Wait-Until 8 { (Guest).active -eq $true }
  Check 'friends mode is on for the pretend session' $on
  $gj = Guest
  Check 'the wheel step is still a name, and light feels like 8 Nm' ($gj.wheel -eq 'light' -and $gj.wheelFeel -ne $null -and [math]::Abs([double]$gj.wheelFeel - 8) -lt 0.01)

  Cdp-Open "$api/v2/"
  $up = Wait-Until 25 { (Ev "(typeof TrackMap!=='undefined' && TrackMap.pts && TrackMap.pts.length>100 && document.querySelector('#guest.drive .gd-mapc')) ? 1 : 0") -eq 1 }
  Check 'the pretend session shows the friends drive view and a track outline' $up
  if (-not $up) {
    $why = Ev "(function(){return JSON.stringify({pts:(typeof TrackMap!=='undefined'&&TrackMap.pts)?TrackMap.pts.length:-1,mode:(typeof Guest!=='undefined')?Guest.mode:'',e:(window.__errs||[]).join(' | ')});})()"
    "        $why"
    throw 'the page never showed the drive view'
  }
  $wline = Ev "(function(){var m=Guest.wheelLine({wheel:'medium',wheelFeel:14,wheelRead:46.2,wheelOwn:46.2});var f=Guest.wheelLine({wheel:'full',wheelOwn:46.2,wheelRead:46.2});return m+'|'+f;})()"
  $bits = @("$wline" -split '\|')
  # ASCII only on purpose: PowerShell 5 reads this file as ANSI, so a middle dot here would not match the page.
  $medOk = $bits.Count -eq 2 -and $bits[0] -eq 'Medium'
  $fullOk = $bits.Count -eq 2 -and $bits[1].StartsWith('Full') -and $bits[1].Contains('46') -and $bits[1].Contains('Nm')
  Check 'medium shows the feel name only, not a wheel reading' ($medOk -and $fullOk -and "$wline" -notmatch 'wheel reads|feel')
  "        wheel line: $wline"
  $text = Ev "document.body.innerText"
  Check 'the corner name block is gone' ($text -notmatch 'Next corner' -and (Ev "document.querySelector('.gd-turn')?1:0") -eq 0)
  $box = Ev "(function(){var r=document.querySelector('.gd-map').getBoundingClientRect();return JSON.stringify({l:Math.round(r.left),t:Math.round(r.top),w:Math.round(r.width),h:Math.round(r.height)});})()" | ConvertFrom-Json
  Check 'the map is large on the left of a 1920x1080 screen' ($box.w -ge 900 -and $box.h -ge 400 -and $box.l -lt 120 -and $box.t -gt 400)
  "        map at $($box.l),$($box.t) $($box.w)x$($box.h)"
  $pix = Ev "(function(){var c=document.querySelector('.gd-mapc');var d=Guest.dot;if(!c||!d)return 'no';var x=Math.round(d.x*(c.width/c.clientWidth)),y=Math.round(d.y*(c.height/c.clientHeight));var p=c.getContext('2d').getImageData(x,y,1,1).data;return p[0]+','+p[1]+','+p[2];})()"
  $gold = $false; if ($pix -match '^(\d+),(\d+),(\d+)$') { $gold = [int]$Matches[1] -gt 200 -and [int]$Matches[2] -gt 150 -and [int]$Matches[3] -lt 120 }
  Check "the car is a gold dot ($pix)" $gold
  $d0 = Ev "JSON.stringify(Guest.dot)" | ConvertFrom-Json
  Fake 'LapDistPct=0.42'
  $moved = Wait-Until 4 { $d1 = Ev "JSON.stringify(Guest.dot)" | ConvertFrom-Json; [math]::Abs($d1.x - $d0.x) + [math]::Abs($d1.y - $d0.y) -gt 20 }
  Check 'the dot moves when the car moves around the lap' $moved
  foreach ($p in 0.435, 0.45, 0.465, 0.48) { Fake ("LapDistPct=" + $p); Start-Sleep -Milliseconds 180 }
  $trail = [int](Ev "Guest.trail ? Guest.trail.length : 0")
  Check "a faint trail is kept ($trail points)" ($trail -ge 2)
  Check 'current lap shows tenths' ((Ev "document.querySelector('.gd-cur').textContent") -eq '12.4')
  Check 'a short current lap stays white until the delta says it is ahead' ((Ev "document.querySelector('.gd-cur').className.indexOf('ahead')") -lt 0)
  Check 'last lap is shown' ((Ev "document.querySelector('.gd-last').textContent") -eq '1:30.500')
  Check 'best lap is shown' ((Ev "document.querySelector('.gd-best').textContent") -eq '1:30.123')
  Check 'the session clock is the elapsed time (this session does not count down)' ((Ev "document.querySelector('.gd-clock-l').textContent") -eq 'Session' -and (Ev "document.querySelector('.gd-clock-v').textContent") -match '\d')
  foreach ($p in 0.50, 0.515, 0.53, 0.545) { Fake ("LapDistPct=" + $p); Start-Sleep -Milliseconds 200 }
  Cdp-Shot (Join-Path $shots 'friends-live-map.png')
  Cdp-Shot (Join-Path $shots 'friends-live-times.png')

  Fake 'LapLastLapTime=90.123&LapBestLapTime=90.123&LapCurrentLapTime=80&LapDeltaToBestLap_OK=1&LapDeltaToBestLap=-0.4'
  $coloured = Wait-Until 4 { (Ev "(document.querySelector('.gd-last').className.indexOf('pb')>=0 && document.querySelector('.gd-best').className.indexOf('pb')>=0 && document.querySelector('.gd-cur').className.indexOf('ahead')>=0)?1:0") -eq 1 }
  Check 'a session best is purple and a lap ahead of it is green' $coloured
  Check 'the green lap still shows tenths' ((Ev "document.querySelector('.gd-cur').textContent") -eq '1:20.0')
  Fake 'SessionTimeRemain=125'
  $left = Wait-Until 4 { (Ev "document.querySelector('.gd-clock-l').textContent") -eq 'Time left' }
  Check 'a timed session shows time left' $left

  Fake 'LapCurrentLapTime=-1&SessionTime=2000&LapDistPct=0.02'
  $zero = Wait-Until 4 { (Ev "document.querySelector('.gd-cur').textContent") -eq '0.0' }
  Fake 'SessionTime=2007'
  $grew = Wait-Until 4 { (Ev "document.querySelector('.gd-cur').textContent") -match '^([6-9]|[1-9]\d)' }
  Check 'an outlap with no official time still counts up' ($zero -and $grew)

  Press 'coach'; Start-Sleep -Milliseconds 1800
  $hidden = Wait-Until 4 { (Ev "getComputedStyle(document.querySelector('.gd-map')).display") -eq 'none' }
  Check 'COACH hides the map' $hidden
  Cdp-Shot (Join-Path $shots 'friends-live-coach-off.png')
  Press 'coach'

  Cdp-Close
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8
  Press 'off'; Start-Sleep -Seconds 1
  Check 'friends mode is off again after the pretend session' ((Guest).active -eq $false)

  $idle = [RigGuard]::IdleMinutes()
  if ($idle -lt 10) {
    $pendingLive = $true
    "PENDING live: Peter is not away ($([math]::Round($idle, 1)) min idle)."
    'Run when he has been away 10 minutes: powershell -ExecutionPolicy Bypass -File tests\friends-live-test.ps1'
  } else {
    Section '3. live: BMW GT4 at Lime Rock' | Out-Null
    '3. live: BMW GT4 at Lime Rock'
    Assert-RigFree -NeedAway
    $script:live = $true
    $env:RIG_TEST_OWNS_SIM = '1'
    $script:ownsSim = $true
    $script:logAt = (Get-Item (Join-Path $root 'irdeck.log')).Length
    $script:liveLog = ''
    Start-Sleep -Seconds 18
    Press 'on'; Start-Sleep -Milliseconds 800
    Press 'car' 'gt4'; Start-Sleep -Milliseconds 600
    Press 'track' 'limerock'; Start-Sleep -Milliseconds 600
    Press 'wheel' 'light'; Start-Sleep -Milliseconds 800
    "        starting the Test Drive (this takes a few minutes)"
    Press 'start'
    $loaded = Wait-Until 240 {
      Take-Log | Out-Null
      $script:liveLog -match 'guest: wheel light feel' -or $script:liveLog -match 'did not load|tdsetup: .*stopped|guest: pick a car'
    }
    Take-Log | Out-Null
    $cards = $script:liveLog -match 'tdsetup: BMW M4 G82 GT4 Evo at Lime Rock Park'
    Check 'iRacing cards show the BMW GT4 at Lime Rock Park' $cards
    Check 'the session came up and the light wheel was applied' ($loaded -and $script:liveLog -match 'guest: wheel light feel')
    if ($script:liveLog -notmatch 'guest: wheel light feel') { throw 'the Test Drive did not reach the wheel step' }

    # What was sent, not SteeringWheelMaxForceNm. That reading stays at Peter's own wheel.
    function Assert-Wheel($step, $heavierStep) {
      $m = Wheel-Hit $step
      $ok = $false; $msg = 'no send in the log'
      if ($m) {
        $feel = [double]$m.Groups[1].Value; $sent = [double]$m.Groups[2].Value; $read = $m.Groups[3].Value; $own = [double]$m.Groups[4].Value
        $msg = "feel $feel sent $sent sim-max $read yours $own"
        $feelOk = $false
        if ($step -eq 'light') { $feelOk = [math]::Abs($feel - 8) -lt 0.05 }
        elseif ($step -eq 'medium') { $feelOk = [math]::Abs($feel - 14) -lt 0.05 }
        else { $feelOk = [math]::Abs($feel - $own) -lt 0.05 }
        $expect = $own
        if ($step -ne 'full' -and $feel -gt 0 -and $feel -lt $own) {
          $expect = ($own * $own) / $feel
          if ($expect > 300) { $expect = 300 }
          if ($expect -lt 1) { $expect = 1 }
        }
        $sentOk = [math]::Abs($sent - $expect) -le 0.15
        $orderOk = $true
        if ($heavierStep) {
          $prev = Wheel-Hit $heavierStep
          if (-not $prev) { $orderOk = $false } else { $orderOk = $sent -lt ([double]$prev.Groups[2].Value - 5) }
        }
        $ok = $feelOk -and $sentOk -and $orderOk
      }
      Check "wheel $step sent the right feel ($msg)" $ok
      return $m
    }
    $null = Assert-Wheel 'light' $null
    $nMed = ([regex]::Matches($script:liveLog, 'guest: wheel medium feel')).Count
    Press 'wheel' 'medium'
    $gotM = Wait-Until 25 { Take-Log | Out-Null; ([regex]::Matches($script:liveLog, 'guest: wheel medium feel')).Count -gt $nMed }
    Check 'medium was sent' $gotM
    $null = Assert-Wheel 'medium' 'light'

    $nFull = ([regex]::Matches($script:liveLog, 'guest: wheel full feel')).Count
    Press 'wheel' 'full'
    $gotF = Wait-Until 25 { Take-Log | Out-Null; ([regex]::Matches($script:liveLog, 'guest: wheel full feel')).Count -gt $nFull }
    Check 'full was sent' $gotF
    $null = Assert-Wheel 'full' 'medium'

    $lineSent = $script:liveLog -match 'key ctrl\+alt\+l sent to iRacingSim64DX11'
    Check 'START sent the racing-line key to the sim' $lineSent
    $st = Get-Content $stateFile -Raw
    Check 'the line state is remembered as on' ($st -match 'line_on=1')
    '        The key was sent and the state says on. That does not show the line is on the track.'

    "        waiting up to 30 s for the track map on the top screen"
    $mapOn = $false; $pix = $null; $bmp = $null
    $untilMap = (Get-Date).AddSeconds(30)
    do {
      if ($bmp) { $bmp.Dispose(); $bmp = $null }
      $bmp = Grab-Top
      $pix = @{
        cur = (Pixel-Count $bmp 64 150 620 340 'white')
        last = (Pixel-Count $bmp 64 360 250 470 'ink')
        best = (Pixel-Count $bmp 250 360 560 470 'ink')
        map = (Pixel-Count $bmp 64 498 1044 968 'gold')
      }
      "        map gold $($pix.map), times current $($pix.cur) last $($pix.last) best $($pix.best)"
      if ($pix.map -ge 12) { $mapOn = $true; break }
      Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $untilMap)
    if ($bmp) { Save-Scaled $bmp 'friends-live-top.png'; $bmp.Dispose() }
    Check "the track map showed on the top screen within 30 seconds (gold pixels $($pix.map))" $mapOn
    $timesOn = $pix.cur -ge 40 -and $pix.last -ge 15 -and $pix.best -ge 15
    Check "the three times are on that picture (current $($pix.cur), last $($pix.last), best $($pix.best))" $timesOn
    Shot-Screen 'friends-live-pits.png' 'mid'
    Check 'pictures of the top screen and the sim were saved' ((Test-Path (Join-Path $shots 'friends-live-top.png')) -and (Test-Path (Join-Path $shots 'friends-live-pits.png')))

    "        putting the wheel back and leaving the session"
    $nBack = ([regex]::Matches($script:liveLog, 'wheel back to yours')).Count
    Press 'off'
    $back = Wait-Until 20 { Take-Log | Out-Null; ([regex]::Matches($script:liveLog, 'wheel back to yours')).Count -gt $nBack }
    Take-Log | Out-Null
    $bm = [regex]::Match($script:liveLog, 'wheel back to yours ([0-9.]+) Nm, sim reads ([0-9.]+)')
    $backOk = $back -and $bm.Success -and [math]::Abs([double]$bm.Groups[1].Value - [double]$bm.Groups[2].Value) -le 1.5
    Check "EXIT put your wheel back ($($bm.Value))" $backOk
    Start-Sleep -Seconds 2
    $q = Start-Process -FilePath (Join-Path $root 'irdeck-cli.exe') -ArgumentList 'quitmain' -WorkingDirectory $root -PassThru -NoNewWindow -Wait
    Check 'QUIT TO MAIN returned to the iRacing home screen' ($q.ExitCode -eq 0)
    $script:ownsSim = $false
    Remove-Item Env:\RIG_TEST_OWNS_SIM -ErrorAction SilentlyContinue
    $script:live = $false
  }
}
finally {
  try { if ($script:ownsSim) {
    # a START still clicking the Test Drive window must finish before QUIT touches that same window
    for ($i = 0; $i -lt 90 -and (Get-Process irdeck -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 2 }
    try { Press 'off' } catch { }
    Start-Sleep -Seconds 2
    try { $null = Start-Process -FilePath (Join-Path $root 'irdeck-cli.exe') -ArgumentList 'quitmain' -WorkingDirectory $root -PassThru -NoNewWindow -Wait } catch { }
    for ($i = 0; $i -lt 40 -and (Get-Process iRacingSim64DX11 -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 2 }
    if (Get-Process iRacingSim64DX11 -ErrorAction SilentlyContinue) {
      try { $null = Start-Process -FilePath (Join-Path $root 'irdeck-cli.exe') -ArgumentList 'quit-sim' -WorkingDirectory $root -PassThru -NoNewWindow -Wait } catch { }
      for ($i = 0; $i -lt 20 -and (Get-Process iRacingSim64DX11 -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 2 }
    }
  } } catch { }
  try { Cdp-Close } catch { }
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 5 } catch { }
  try { if ((Guest).active) { Press 'off' } } catch { }
  Remove-Item -LiteralPath $hook -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
  Exit-TestLock
  Remove-Item Env:\RIG_TEST_OWNS_SIM -ErrorAction SilentlyContinue
  if ($markFile -and -not $markBefore -and (Test-Path $markFile)) { Remove-Item -LiteralPath $markFile -Force -ErrorAction SilentlyContinue }
  try { [IO.File]::WriteAllBytes($stateFile, $stateBytes) } catch { }
}
$cfgNow = (Get-Item $cfg).LastWriteTimeUtc
$after = $null
if ($found) {
  $b2 = [IO.File]::ReadAllBytes($cfg)
  $name2 = [Text.Encoding]::ASCII.GetBytes('ToggleDrivingLine')
  for ($i = 0; $i -le $b2.Length - $name2.Length - 20; $i++) {
    $ok = $true
    for ($k = 0; $k -lt $name2.Length; $k++) { if ($b2[$i + $k] -ne $name2[$k]) { $ok = $false; break } }
    if (-not $ok -or $b2[$i + $name2.Length] -ne 0) { continue }
    $o = $i + $name2.Length + 1 + 4
    $type2 = [BitConverter]::ToInt32($b2, $o); $o += 4
    $bound2 = [BitConverter]::ToInt32($b2, $o); $o += 4
    $vk2 = [BitConverter]::ToInt32($b2, $o); $o += 4
    $o += 2
    $e22 = [int][BitConverter]::ToUInt16($b2, $o)
    $after = @{ type = $type2; bound = $bound2; vk = $vk2; e2 = $e22 }
    break
  }
}
$sameBind = $found -and $after -and $after.type -eq $found.type -and $after.bound -eq $found.bound -and $after.vk -eq $found.vk -and $after.e2 -eq $found.e2
Check 'the Toggle Driving Line binding is unchanged' $sameBind
if ($cfgNow -ne $cfgTime) { "        controls.cfg timestamp changed; the driving-line binding itself was compared" }
''
if ($pendingLive) { 'Live Test Drive: PENDING (Peter was not away). Offline section above is the part that ran.' }
"$pass passed, $fail failed. Pictures in $shots"
if ($fail -gt 0) { exit 1 }
