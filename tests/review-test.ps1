# C-07 after-race review and the wheel KEEP button, and C-27 (the strip when he is still in the sim after a race).
# Section 1 compiles the pure wheel logic (no irdash, no device). The later sections need a free rig and the
# current irdash (dash\build.ps1). They use the test hook and a scratch vault. Nothing here clicks, sends keys,
# or opens a window on the rig. Pictures: tests\shots\c07-review.png, tests\shots\c27-strip.png.
#   Section 4: he closes the practice summary first and leaves the session afterwards: the strip comes back.
#   Section 5: the session is over but the sim program is still open (pretended: the test never starts the sim):
#              the newest telemetry file is left alone while the session runs and while it is still growing, and is read
#              (BelowNormal) once the session is over and it has settled; the laps then appear in the strip within 30 s.
#   Section 6: an irdash restart (the stream drops) is not the end of a session: no debrief, no strip.
#   powershell -ExecutionPolicy Bypass -File tests\review-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'
New-Item -ItemType Directory -Force $shots | Out-Null
$api = if ($env:REVIEW_TEST_API) { $env:REVIEW_TEST_API } else { 'http://localhost:8199' }
$ini = Join-Path $root 'dash\irdash.ini'
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; Write-Host "  ok    $what" } else { $script:fail++; Write-Host "  FAIL  $what" } }
function Note($what) { Write-Host "  info  $what" }
function Qs($s) { [uri]::EscapeDataString([string]$s) }

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
function Section($title) { Assert-RigFree -Where $title; Write-Host ''; Write-Host $title }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class C07Fg {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
'@ -ErrorAction SilentlyContinue
function Fg() { [C07Fg]::GetForegroundWindow().ToInt64() }

function Http($path, $secs) {
  $rq = [Net.HttpWebRequest]::Create("$api$path"); $rq.Timeout = $secs * 1000; $rq.ReadWriteTimeout = $secs * 1000
  try { $resp = $rq.GetResponse() } catch [Net.WebException] {
    $resp = $_.Exception.Response
    if (-not $resp) { return @{ code = 0; body = $_.Exception.Message } }
  }
  $ms = New-Object IO.MemoryStream; $resp.GetResponseStream().CopyTo($ms); $b = $ms.ToArray(); $code = [int]$resp.StatusCode; $resp.Close()
  return @{ code = $code; body = [Text.Encoding]::UTF8.GetString($b) }
}
function J($path) {
  $h = Http $path 30
  if ($h.code -ne 200) { throw "HTTP $($h.code) $path $($h.body)" }
  return ($h.body | ConvertFrom-Json)
}
function Events() { (J '/vault/test/events').events }
function Wait-Ev($part, $secs) {
  $until = (Get-Date).AddSeconds($secs); $last = ''
  while ((Get-Date) -lt $until) {
    try { $last = Events } catch { $last = $_.Exception.Message }
    if ("$last" -like "*$part*") { return $true }
    Start-Sleep -Milliseconds 80
  }
  Note "events: $last"
  return $false
}
function Begin-Get($path) {
  $ps = [PowerShell]::Create()
  $null = $ps.AddScript({
    param($u)
    try { $r = Invoke-WebRequest -UseBasicParsing $u -TimeoutSec 20; return [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
    catch { return 'ERR ' + $_.Exception.Message }
  }).AddArgument("$api$path")
  return @{ ps = $ps; h = $ps.BeginInvoke() }
}
function End-Get($g, $secs) {
  $ok = $g.h.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($secs))
  $text = 'ERR timeout'
  if ($ok) { $text = @($g.ps.EndInvoke($g.h)) | Select-Object -Last 1 }
  else { try { $g.ps.Stop() } catch { } }
  $g.ps.Dispose()
  return "$text"
}

# wheel_keep is our line in irdash.ini. Put back only that line (other agents may be writing other keys).
$script:iniBom = $false
$script:iniSeen = $false
$script:wheelLine = $null
$script:hadWheel = $false
function Read-IniLines {
  $bytes = [IO.File]::ReadAllBytes($ini)
  # Remember the file's original encoding. Saving the button rewrites the ini; the restore must not leave a new BOM behind.
  if (-not $script:iniSeen) {
    $script:iniBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $script:iniSeen = $true
  }
  return [IO.File]::ReadAllLines($ini)
}
function Write-IniLines($lines) {
  $enc = New-Object System.Text.UTF8Encoding $script:iniBom
  [IO.File]::WriteAllLines($ini, [string[]]$lines, $enc)
}
function Get-WheelLine {
  if (-not (Test-Path $ini)) { return $null }
  foreach ($l in (Read-IniLines)) { if ($l -match '^\s*wheel_keep\s*=') { return $l } }
  return $null
}
function Restore-WheelLine {
  if (-not (Test-Path $ini)) { return }
  $keep = New-Object System.Collections.Generic.List[string]
  $put = $false
  foreach ($l in (Read-IniLines)) {
    if ($l -match '^\s*wheel_keep\s*=') {
      if ($script:hadWheel -and -not $put) { $keep.Add($script:wheelLine); $put = $true }
    } else { $keep.Add($l) }
  }
  if ($script:hadWheel -and -not $put) { $keep.Add($script:wheelLine) }
  Write-IniLines $keep
}

$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url) {
  $w = 1920; $h = 1080
  $prof = Join-Path $env:TEMP ('c07-review-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $port = 9388
  $p = Start-Process -FilePath $chrome -ArgumentList @(
    '--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof",
    "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', 'about:blank'
  ) -PassThru -WindowStyle Hidden
  try { $p.PriorityClass = 'BelowNormal' } catch { }
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) {
    Start-Sleep -Milliseconds 200
    try {
      $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"
      foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } }
    } catch { }
  }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; port = $port; id = 0 }
  $null = Cdp 'Page.enable' @{}
  $null = Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = "window.__pops=0;window.open=function(){window.__pops++;return null;};window.__errs=[];window.addEventListener('error',function(e){window.__errs.push(String(e.message));});" }
  $null = Cdp 'Emulation.setDeviceMetricsOverride' @{ width = $w; height = $h; deviceScaleFactor = 1; mobile = $false }
  $null = Cdp 'Page.navigate' @{ url = $url }
}
function Cdp($method, $params) {
  $c = $script:cdp; $c.id++
  $bytes = [Text.Encoding]::UTF8.GetBytes((@{ id = $c.id; method = $method; params = $params } | ConvertTo-Json -Depth 8 -Compress))
  $null = $c.ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [Threading.CancellationToken]::None).Wait()
  while ($true) {
    $buf = New-Object byte[] 1048576; $sb = New-Object Text.StringBuilder
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
function Cdp-Shot($path) {
  $s = Cdp 'Page.captureScreenshot' @{ format = 'png' }
  [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data))
}
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 300
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
function Wait-True($expr, $secs) {
  $last = ''
  for ($i = 0; $i -lt ($secs * 4); $i++) {
    $last = Cdp-Eval $expr
    if ($last -eq $true) { return $true }
    Start-Sleep -Milliseconds 250
  }
  Note "last: $last"
  return $false
}
function Frame($q) { $null = Http "/api/test/frame?$q" 8; Start-Sleep -Milliseconds 450 }

# A pretend practice session on track with one clean lap counted (the page keeps it as the stint it summarises when he gets out).
function Practice-Stint {
  $null = J '/vault/test/yaml'
  Frame 'IsOnTrack=1&OnPitRoad=0&PlayerTrackSurface=1&SessionNum=0&SessionUniqueID=4242&SessionState=4&LapCompleted=3&FuelLevel=50&SessionTime=100&LapLastLapTime=80&Speed=30&PlayerCarMyIncidentCount=0&PlayerCarPosition=5&PlayerCarClassPosition=5&Lap=4&LapDistPct=0.3'
  $ready = Wait-True "(!!(L.connected && S.sessions && S.sessions.length>=2 && L.v.IsOnTrack && !isRace()))" 10
  Frame 'LapCompleted=4&SessionTime=160&FuelLevel=48&LapLastLapTime=79.8'
  Frame 'SessionTime=163'
  $laps = Wait-True "(L.laps && L.laps.length>=1 && L.laps[0].time>0)" 8
  return ($ready -and $laps)
}

# The scratch copy of an old telemetry file gets its start time (header bytes 112..119, seconds since 1970) moved so that it ends
# "just now": the strip only lists a session that ended after this irdash saw the session begin. The copy is the test's own.
function Patch-Ibt($path, $secs) {
  $b = [IO.File]::ReadAllBytes($path)
  $start = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$secs - 2
  [BitConverter]::GetBytes([int64]$start).CopyTo($b, 112)
  [IO.File]::WriteAllBytes($path, $b)
}
function Over-Scan { return (J '/vault/test/overscan') }

$hook = Join-Path $root 'dash\test-hook.on'
$lock = Join-Path $root 'dash\deploy.lock'
$script:madeHook = $false
$script:locked = $false
$script:sand = $false
'C-07 review test'
$script:err = $null
Enter-TestLock 'review'   # one live test at a time (tests\guard.ps1); released in finally
try {

Section '1. wheel logic, compiled on its own with a stub device'
$main = Join-Path $env:TEMP 'c07-wheel-main.cs'
$exe = Join-Path $env:TEMP 'c07-wheel-unit.exe'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
@'
using System;
using System.Collections.Generic;
class C07Unit {
  static int pass, fail;
  static void Ok(string name, bool cond) {
    if (cond) { pass++; Console.WriteLine("ok " + name); }
    else { fail++; Console.WriteLine("FAIL " + name); }
  }
  static void Main() {
    Ok("short 79.8 is 1:19.8", IRDash.WheelLogic.Short(79.8) == "1:19.8");
    Ok("teach waits 10 s", IRDash.WheelLogic.TeachMs == 10000);
    Ok("keep all default is 60 s", IRDash.WheelLogic.DefaultMs == 60000);
    Ok("bit 2 is button 3", IRDash.WheelLogic.Edges(new uint[] { 0 }, new uint[] { 4 }) == "0:3");
    Ok("a held button is not a new edge", IRDash.WheelLogic.Edges(new uint[] { 4 }, new uint[] { 4 }) == "");
    Ok("lowest device then lowest button", IRDash.WheelLogic.Edges(new uint[] { 0, 0 }, new uint[] { 1, 1 }) == "0:1,1:1");
    uint[][] held = new uint[][] { new uint[] { 4 }, new uint[] { 4 } };
    Ok("the first sample is only a baseline", IRDash.WheelLogic.FirstPress(held) == "");
    uint[][] rose = new uint[][] { new uint[] { 0 }, new uint[] { 0 }, new uint[] { 4 } };
    Ok("the next rising edge is the press", IRDash.WheelLogic.FirstPress(rose) == "0:3");
    Ok("driving is KEEP", IRDash.WheelLogic.Act("0:3", 0, 3, true, false) == "keep");
    Ok("the review is KEEP ALL", IRDash.WheelLogic.Act("0:3", 0, 3, false, true) == "keepall");
    Ok("driving wins over the review", IRDash.WheelLogic.Act("0:3", 0, 3, true, true) == "keep");
    Ok("a different button does nothing", IRDash.WheelLogic.Act("0:3", 0, 5, true, true) == "");
    Ok("no binding does nothing", IRDash.WheelLogic.Act("", 0, 3, true, true) == "");
    int d, b;
    Ok("button 0 is rejected", !IRDash.WheelLogic.Bind("0:0", out d, out b));
    Ok("device 16 is rejected", !IRDash.WheelLogic.Bind("16:1", out d, out b));
    Ok("a word is rejected", !IRDash.WheelLogic.Bind("x", out d, out b));
    Ok("0:5 is accepted", IRDash.WheelLogic.Bind("0:5", out d, out b) && d == 0 && b == 5);
    string line = IRDash.WheelLogic.Sentence(IRDash.WheelLogic.ParseLaps("14|79.8|PB;9|80.4|top 6%;7|81.2|best 3"));
    Ok("three laps names the PB and the top 6 percent", line.Contains("3 laps saved") && line.Contains("lap 14 1:19.8 (PB)") && line.Contains("lap 9 1:20.4 (top 6%)") && line.Contains("\u2014"));
    string more = IRDash.WheelLogic.Sentence(IRDash.WheelLogic.ParseLaps("1|60|a;2|61|b;3|62|c;4|63|d;5|64|e"));
    Ok("more than four laps shows three and an ellipsis", more.StartsWith("5 laps saved") && more.Contains("lap 3 ") && more.IndexOf("lap 4 ") < 0 && more.EndsWith(" \u2026"));
    Console.WriteLine("UNIT " + pass + " ok, " + fail + " FAIL");
    Environment.Exit(fail > 0 ? 1 : 0);
  }
}
'@ | Set-Content -LiteralPath $main -Encoding ASCII
& $csc /nologo /define:WHEEL_UNIT "/out:$exe" $main (Join-Path $root 'dash\src\wheel.cs')
Check 'the wheel logic compiles on its own' ($LASTEXITCODE -eq 0)
if ($LASTEXITCODE -eq 0) {
  $unit = & $exe
  $unit | ForEach-Object { $_ }
  $uOk = @($unit | Where-Object { $_ -like 'ok *' }).Count
  $uFail = @($unit | Where-Object { $_ -like 'FAIL *' }).Count
  Check "wheel logic ($uOk checks)" ($uFail -eq 0 -and $uOk -ge 19)
}

Section '2. a stub wheel through irdash, and no focus change'
$fg0 = Fg
$script:wheelLine = Get-WheelLine
$script:hadWheel = ($null -ne $script:wheelLine)
if ((Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15) {
  Check 'the deploy lock is free' $false
  Note ('held by ' + (Get-Content $lock))
} elseif (Test-Path $hook) {
  Check 'the test hook is free' $false
} else {
  Set-Content -LiteralPath $lock -Value ('c07 ' + (Get-Date).ToString('HH:mm:ss'))
  $script:locked = $true
  Set-Content -LiteralPath $hook -Value 'c07 review'
  $script:madeHook = $true
}
$live = $script:madeHook
$off = $null
if ($live) {
  try { $off = J '/vault/review' } catch { Note "review before sandbox: $($_.Exception.Message)" }
  # vault=1 is the normal setting on this PC now (2026-10-10), so "off while vault=0" cannot be looked at: say so instead of failing it
  if ($off -and $off.enabled -eq $true) { Note 'skipped: vault=1 in irdash.ini on this PC, so the "review stays off while vault=0" check does not apply' }
  else { Check 'the review stays off while vault=0' ($off -and $off.enabled -eq $false) }
  try { $sb = J '/vault/test/sandbox?on=1&reset=1'; $script:sand = ($sb.sandbox -eq $true) } catch { Note $_.Exception.Message }
  Check 'the scratch vault is on (the real Vault is untouched)' $script:sand
}
if (-not $script:sand) { $live = $false }
$wheel = $null
if ($live) {
  try { $wheel = J '/vault/test/wheel?op=const' } catch { Note $_.Exception.Message }
  Check 'teach is 10 s and the default is 60 s' ($wheel -and $wheel.teachMs -eq 10000 -and $wheel.defaultMs -eq 60000)
  if (-not $wheel) { $live = $false; Note 'this irdash has no wheel route yet: deploy with dash\build.ps1, then run this test again' }
}
if ($live) {
  $edge = J '/vault/test/wheel?op=edge&prev=0&now=4'
  Check 'a stub rising bit is device 0 button 3' ($edge.edges -eq '0:3')
  $act = J '/vault/test/wheel?op=act&bind=0:3&dev=0&btn=3&driving=1&review=1'
  Check 'while driving the stub button is KEEP, even during a review' ($act.action -eq 'keep')
  $act2 = J '/vault/test/wheel?op=act&bind=0:3&dev=0&btn=3&driving=0&review=1'
  Check 'after the race the same button is KEEP ALL' ($act2.action -eq 'keepall')
  $line = J ('/vault/test/wheel?op=line&laps=' + (Qs '14|79.8|PB;9|80.4|top 6%'))
  $sent = "$($line.line)"
  Check 'the sentence names the PB and the top 6 percent' ($line.n -eq 2 -and $sent.Contains('2 laps saved') -and $sent.Contains('1:19.8') -and $sent.Contains('(PB)') -and $sent.Contains('top 6%') -and $sent.Contains([char]0x2014))
  $null = J '/vault/test/wheel?op=seed&clear=1'
  $pend = J '/vault/review?open=1'
  Check 'the review stays up while the laps are still being found' ($pend.up -eq $true -and $pend.pending -eq $true -and $pend.n -eq 0 -and $pend.defaultMs -eq 60000)
  $null = J ('/vault/test/wheel?op=seed&secs=30&laps=' + (Qs '14|79.8|PB;9|80.4|top 6%;7|81.2|best 3'))
  $filled = J '/vault/review'
  Check 'those laps appear without restarting the 60 s timer' ($filled.up -eq $true -and $filled.n -eq 3 -and $filled.waitMs -eq 60000 -and "$($filled.line)".Contains('lap 14 1:19.8 (PB)'))
  $null = J '/vault/test/wheel?op=seed&clear=1'
  # teach ignores a button that is already down, then takes the next press
  $null = J '/vault/test/events?clear=1'
  $null = J '/vault/test/wheel?op=stub&masks=16'
  $g = Begin-Get '/vault/test/wheel?op=teach&ms=4000'
  Start-Sleep -Milliseconds 500
  $null = J '/vault/test/wheel?op=stub&masks=0'
  Start-Sleep -Milliseconds 200
  $null = J '/vault/test/wheel?op=stub&masks=16'
  $taught = End-Get $g 8
  Check 'teach saved the stub press as wheel button 0:5' ("$taught" -like '*0:5*')
  Check 'teach wrote wheel_keep=0:5 in irdash.ini' ((Get-WheelLine) -eq 'wheel_keep=0:5')
  $null = J '/vault/test/wheel?op=stub&masks=0'
  $g2 = Begin-Get '/api/do?c=wheelteach'
  Start-Sleep -Milliseconds 400
  $null = J '/vault/test/wheel?op=stub&masks=4'
  $real = End-Get $g2 12
  Check 'wheelteach (the 10 s route) saved the next stub press' ($real.Trim() -eq 'ok' -and (Get-WheelLine) -eq 'wheel_keep=0:3')
  $null = J '/vault/test/wheel?op=stub&masks=0'
  Start-Sleep -Milliseconds 800
  $null = J '/vault/test/yaml'
  $fgA = Fg
  Frame 'IsOnTrack=1&OnPitRoad=0&PlayerTrackSurface=1&SessionNum=0&SessionUniqueID=4242&LapCompleted=3&FuelLevel=50&SessionTime=100&LapLastLapTime=80&Speed=30&PlayerCarMyIncidentCount=0&PlayerCarPosition=5&PlayerCarClassPosition=5&Lap=4&LapDistPct=0.3'
  $null = J '/vault/test/events?clear=1'
  $null = J '/vault/test/wheel?op=stub&masks=4'
  Check 'while driving, the stub button marks KEEP' (Wait-Ev 'wheel keep' 3)
  $ev = Events
  Check 'that press did not KEEP ALL' ("$ev" -notlike '*keepall*')
  Check 'KEEP did not move the focus' ((Fg) -eq $fgA)
  $null = J '/vault/test/wheel?op=stub&masks=0'
  $null = Http '/api/test/end' 8
  Start-Sleep -Milliseconds 400
  $seed = '14|79.8|PB;9|80.4|top 6%;7|81.2|best 3'
  $null = J ('/vault/test/wheel?op=seed&secs=30&laps=' + (Qs $seed))
  $open = J '/vault/review?open=1'
  Check 'the review opens off track with the three laps and a 60 s default' ($open.up -eq $true -and $open.driving -eq $false -and $open.n -eq 3 -and $open.defaultMs -eq 60000 -and $open.waitMs -eq 30000 -and "$($open.line)".Contains('lap 14 1:19.8 (PB)'))
  Start-Sleep -Seconds 1
  $again = J '/vault/review?open=1'
  Check 'a second open does not restart the timer' ($again.up -eq $true -and $again.leftMs -lt ($open.leftMs - 400))
  Frame 'IsOnTrack=1&SessionNum=0&Speed=30'
  Start-Sleep -Milliseconds 500
  $back = J '/vault/review'
  $ev2 = Events
  Check 'back in the car closes the review and does not KEEP ALL' ($back.driving -eq $true -and $back.up -eq $false -and "$ev2" -notlike '*keepall*')
  $no = Http '/api/do?c=vkkeepall' 8
  Check 'KEEP ALL is refused while he is driving' ($no.code -eq 400 -and $no.body.Trim() -eq 'no')
  $null = Http '/api/test/end' 8
  Start-Sleep -Milliseconds 300
  $null = J '/vault/test/wheel?op=stub&masks=0'
  $null = J '/vault/test/events?clear=1'
  $null = J ('/vault/test/wheel?op=seed&secs=30&laps=' + (Qs $seed))
  $null = J '/vault/review?open=1'
  Start-Sleep -Milliseconds 800
  $fgB = Fg
  $null = J '/vault/test/wheel?op=stub&masks=4'
  Check 'the stub button during the review is KEEP ALL' (Wait-Ev 'wheel keepall' 3)
  $kept = J '/vault/review'
  Check 'the review is kept, and the focus stayed' ($kept.kept -eq $true -and $kept.up -eq $false -and (Fg) -eq $fgB)
  $null = J '/vault/test/wheel?op=stub&masks=0'
  $null = J '/vault/test/events?clear=1'
  $null = J ('/vault/test/wheel?op=seed&secs=30&laps=' + (Qs $seed))
  $null = J '/vault/review?open=1'
  $ch = Http '/api/do?c=vkchoose' 8
  $nav = J '/vault/nav'
  $after = J '/vault/review'
  $ev3 = Events
  Check 'CHOOSE opens the Vault and cancels the timer' ($ch.body.Trim() -eq 'ok' -and $nav.to -eq 'vault' -and $after.up -eq $false -and $after.kept -eq $false -and "$ev3" -like '*choose*' -and "$ev3" -notlike '*keepall*')
  $null = Http '/api/do?c=vkclose' 8
  $null = J '/vault/test/events?clear=1'
  $null = J ('/vault/test/wheel?op=seed&secs=2&laps=' + (Qs $seed))
  $armed = J '/vault/review?open=1'
  Check 'a test may arm 2 s, and the remembered default is still 60 s' ($armed.up -eq $true -and $armed.waitMs -eq 2000 -and $armed.defaultMs -eq 60000)
  Start-Sleep -Seconds 3
  $done = J '/vault/review'
  Check 'doing nothing keeps all when the timer ends' ($done.kept -eq $true -and $done.up -eq $false -and (Events) -like '*keepall*')
  Check 'the wheel work did not move the focus' ((Fg) -eq $fg0)
}

Section '3. the after-session coach carries the laps-saved strip (KEEP ALL by itself, CHOOSE opens the Vault)'
if (-not $live) { Note 'skipped: the live wheel route is not up' }
else {
  # 2026-10-18: the old debrief carried the strip; when the coach became the after-session screen (D-03, debrief-v4.js) nothing
  # armed the keeper review any more, so the 60 s keep-all never started and CHOOSE never appeared. The coach does it now.
  $fgP = Fg
  $null = Http '/api/test/end' 8
  $null = J ('/vault/test/wheel?op=seed&clear=1')
  $null = J '/vault/test/yaml'
  Cdp-Open "$api/v2/index.html"
  $up = Wait-True "(typeof Debrief4!=='undefined' && typeof L!=='undefined')" 15
  Check 'the top-screen page loaded' $up
  $null = J ('/vault/test/wheel?op=seed&secs=8&laps=' + (Qs '14|79.8|PB;9|80.4|top 6%;7|81.2|best 3'))
  $tel0 = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
  $ibt = (Get-ChildItem $tel0 -Filter '*.ibt' | Sort-Object LastWriteTime | Select-Object -First 1).Name
  $null = Cdp-Eval ("Debrief4.showCoach({ meta: { file: " + (ConvertTo-Json $ibt -Compress) + " } }); 1")
  $panel = Wait-True "(function(){var d=document.getElementById('debrief4'),r=document.getElementById('db4Keep');if(!d||!r||!d.contains(r))return false;var t=(r.querySelector('.line')||{}).textContent||'';return t.indexOf('3 laps saved')>=0&&t.indexOf('lap 14 1:19.8 (PB)')>=0&&t.indexOf('top 6%')>=0;})()" 12
  Check 'the coach shows the saved-laps strip with the three seeded laps' $panel
  $meta = Cdp-Eval "(function(){var r=document.getElementById('db4Keep');if(!r)return '';var k=document.getElementById('db4KeepAll'),c=document.getElementById('db4Choose');return r.getAttribute('data-default')+'|'+r.getAttribute('data-wait')+'|'+(k&&!k.hidden&&k.classList.contains('def')?'K':'')+'|'+(c&&!c.hidden?'C':'')+'|'+((r.querySelector('.sub')||{}).textContent||'');})()"
  Check 'KEEP ALL is the default and the filled button, CHOOSE is beside it, this test armed 8 s' ("$meta" -like '60000|8000|K|C|Keeping all in *')
  $big = Cdp-Eval "(function(){var r=document.getElementById('db4Keep').getBoundingClientRect(),b=document.getElementById('db4KeepAll').getBoundingClientRect(),w=document.getElementById('debrief4').getBoundingClientRect();return r.bottom<=w.bottom&&r.left>=0&&r.right<=w.right&&b.height>=56&&b.width>=156;})()"
  Check 'the strip is on screen and its buttons are big targets' ($big -eq $true)
  Start-Sleep -Milliseconds 600
  Cdp-Shot (Join-Path $shots 'c07-review.png')
  Check 'the picture was saved (tests\shots\c07-review.png: look at it)' (Test-Path (Join-Path $shots 'c07-review.png'))
  $keptP = Wait-True "(function(){var s=document.querySelector('#db4Keep .sub');return !!(s&&s.textContent==='Kept');})()" 15
  Check 'doing nothing on the page keeps all when the timer ends' $keptP
  Check 'the page test did not move the focus' ((Fg) -eq $fgP)
  $errs = Cdp-Eval "(window.__errs||[]).join(' | ')"
  Check 'the page reported no script error' ("$errs" -eq '')
  if ("$errs" -ne '') { Note $errs }
  Cdp-Close
}

Section '5. the session is over but the sim program is still open: the laps still appear (C-27)'
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$fA = 'chevyvettez06rgt3_roadatlanta full 2026-10-09 14-58-37.ibt'
$srcDir = Join-Path $root 'vault-test\src'
if (-not $live) { Note 'skipped: the live wheel route is not up' }
elseif (-not (Test-Path (Join-Path $tel $fA))) { Check 'an older telemetry file is on this PC to copy into the scratch vault' $false }
else {
  Cdp-Close
  $null = Http '/api/test/end' 8
  $null = J '/vault/test/sandbox?on=1&reset=1'
  $null = J '/vault/test/wheel?op=seed&clear=1'
  Get-ChildItem $srcDir -Filter *.ibt -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  $sim = $null
  try { $sim = J '/vault/test/simrunning?on=1' } catch { Note $_.Exception.Message }
  Check 'the sim program is pretended to be still open (the test never starts it; needs the irdash built for C-27: dash\build.ps1)' ($sim -and $sim.simRunning -eq $true)
  if ($sim -and $sim.simRunning -eq $true) {
  $info = J ('/ibt/laps?file=' + (Qs $fA))
  $secs = [int]$info.seconds
  Check "the older telemetry file knows how long it was ($secs s)" ($secs -gt 20)
  $script:c27File = Join-Path $srcDir ('chevyvettez06rgt3_roadatlanta full ' + (Get-Date).ToString('yyyy-MM-dd HH-mm-ss') + '.ibt')
  Copy-Item (Join-Path $tel $fA) $script:c27File -Force
  Patch-Ibt $script:c27File $secs
  Check 'the scratch copy of the finished session is in place' (Test-Path $script:c27File)

  # --- the files of a session that is still running are never read ---
  $null = J '/vault/test/yaml'
  Frame 'IsOnTrack=1&OnPitRoad=0&PlayerTrackSurface=1&SessionNum=2&SessionUniqueID=4243&SessionState=4&Speed=40&SessionTime=500&LapDistPct=0.4'
  $r1 = 0; for ($i = 0; $i -lt 6; $i++) { $r1 += [int](Over-Scan).read; Start-Sleep -Milliseconds 1500 }
  Check 'on track in a running session: the newest file is not read (9 s of tries)' ($r1 -eq 0)
  Frame 'IsOnTrack=0&Speed=0'
  $r2 = 0; for ($i = 0; $i -lt 6; $i++) { $r2 += [int](Over-Scan).read; Start-Sleep -Milliseconds 1500 }
  Check 'out of the car but the session is still running (the garage): not read either' ($r2 -eq 0)

  # A lost SDK link does not prove the session ended while the sim remains open.
  $null = J '/vault/test/disconnected?on=1'
  [IO.File]::SetLastWriteTime($script:c27File, (Get-Date).AddMinutes(-3))
  $lostRead = 0
  for ($i = 0; $i -lt 7; $i++) { $lostRead += [int](Over-Scan).read; Start-Sleep -Milliseconds 1500 }
  Check 'SDK disconnected while the sim is open: even a stale settled file is not read' ($lostRead -eq 0)
  $null = J '/vault/test/disconnected?on=0'

  # --- chequered flag and out of the car = over, but a file that is still growing waits ---
  Frame 'SessionState=5'
  $r3 = 0
  for ($i = 0; $i -lt 8; $i++) {
    $fs = [IO.File]::Open($script:c27File, 'Append', 'Write', 'ReadWrite'); $fs.WriteByte(0); $fs.Close()      # one byte: not a whole record, so the laps are unchanged
    $r3 += [int](Over-Scan).read; Start-Sleep -Milliseconds 1500
  }
  Check 'the session is over but the file is still growing: not read (12 s of tries)' ($r3 -eq 0)
  $t0 = Get-Date; $got = 0
  while (((Get-Date) - $t0).TotalSeconds -lt 30 -and $got -eq 0) { $got += [int](Over-Scan).read; if ($got -eq 0) { Start-Sleep -Milliseconds 1500 } }
  $took = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  Check "the file stopped growing: it is read while the sim is still open ($took s)" ($got -eq 1)
  $lst = J '/vault/list'
  Check 'the laps of that session are in the scratch vault' (@($lst.moments | Where-Object { $_.kind -eq 'lap' }).Count -ge 1)

  # --- the real thing: the session ends, the strip is waiting, and the laps show up by themselves ---
  $null = Http '/api/test/end' 8
  $null = J '/vault/test/sandbox?on=1&reset=1'
  $null = J '/vault/test/wheel?op=seed&clear=1'
  $null = J '/vault/test/simrunning?on=1'
  Cdp-Open "$api/v2/index.html"
  $up = Wait-True "(typeof Debrief!=='undefined' && typeof L!=='undefined')" 15
  Check 'the top-screen page loaded' $up
  Check 'a pretend practice session on track with one lap counted' (Practice-Stint)
  Patch-Ibt $script:c27File $secs
  Frame 'IsOnTrack=0&Speed=0'
  $null = Wait-True "(!!document.getElementById('debrief'))" 8
  $null = J ('/vault/test/wheel?op=seed&secs=45&laps=' + (Qs '14|79.8|PB;9|80.4|top 6%;7|81.2|best 3'))
  $before = J '/vault/list'
  Check 'nothing of that session is in the vault before it ends' (@($before.moments | Where-Object { $_.kind -eq 'lap' }).Count -eq 0)
  $tEnd = Get-Date
  $null = Http '/api/test/end' 8
  $rv = J '/vault/review'
  # (the strip itself is on the after-session coach now: section 3. The server's review below is what it shows.)
  $null = Http '/vault/review?open=1' 8; Start-Sleep -Milliseconds 800
  $rv = J '/vault/review'
  Check 'the review contains exactly the seeded three laps' ($rv.n -eq 3 -and $rv.up -eq $true -and "$($rv.line)".Contains('lap 14 1:19.8 (PB)') -and "$($rv.line)".Contains('lap 9 1:20.4 (top 6%)') -and "$($rv.line)".Contains('lap 7 1:21.2 (best 3)'))
  $errs5 = Cdp-Eval "(window.__errs||[]).join(' | ')"
  Check 'the page reported no script error' ("$errs5" -eq '')
  Cdp-Close
  $null = J '/vault/test/simrunning?on=0'
  }
}

Section '6. an irdash restart is not the end of a session: no debrief and no strip (C-27)'
if (-not $live) { Note 'skipped: the live wheel route is not up' }
else {
  Cdp-Close
  $null = Http '/api/test/end' 8
  $null = J '/vault/test/wheel?op=seed&clear=1'
  Cdp-Open "$api/v2/index.html"
  $up = Wait-True "(typeof Debrief!=='undefined' && typeof L!=='undefined')" 15
  Check 'the top-screen page loaded' $up
  Check 'a pretend practice session on track with one lap counted' (Practice-Stint)
  # the stream drops the way it does while irdash restarts: no more frames, and the connection says "no server" (not "no sim")
  $null = Cdp-Eval "(function(){window.__of=window.onFrame;window.onFrame=function(){};Object.defineProperty(Conn,'status',{get:function(){return 'noserver';},set:function(){},configurable:true});L.connected=false;return 1;})()"
  Start-Sleep -Seconds 6
  $deb6 = Cdp-Eval "(!!document.getElementById('debrief'))"
  $rv6 = J '/vault/review'
  Check 'the stream dropping (an irdash restart) puts up no debrief and no strip' ($deb6 -eq $false -and $rv6.up -eq $false)
  Cdp-Close
}

} catch {
  $script:err = $_.Exception.Message
  Check "the test ran to the end ($script:err)" $false
} finally {
  try { if ($script:sand) { $null = Http '/vault/test/wheel?op=stub&off=1' 8 } } catch { }
  try { if ($script:sand) { $null = Http '/vault/test/wheel?op=bind&val=' 8 } } catch { }
  try { if ($script:sand) { $null = Http '/vault/test/simrunning?on=0' 8 } } catch { }
  try { $null = Http '/api/test/end' 8 } catch { }
  try { Restore-WheelLine } catch { }
  try { if ($script:sand) { $null = Http '/vault/test/sandbox?on=0' 15 } } catch { }
  try { if ($script:c27File -and (Test-Path $script:c27File)) { Remove-Item -LiteralPath $script:c27File -Force -ErrorAction SilentlyContinue } } catch { }
  if ($script:madeHook -and (Test-Path $hook)) { Remove-Item -LiteralPath $hook -Force -ErrorAction SilentlyContinue }
  if ($script:locked -and (Test-Path $lock)) { Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue }
  Exit-TestLock
  try { Cdp-Close } catch { }
}

Write-Host ''
Write-Host "$pass passed, $fail failed"
if ($script:err -or $fail -gt 0) { exit 1 }
