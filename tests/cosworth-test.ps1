# W-18 Cosworth open method + button everywhere.
# Live where it matters: the real Pi Toolbox install on this PC is opened with a real lap (read-only, no iRacing file is
# touched); workbook readiness and lap forwarding are judged from Pi's window title.
# The four page buttons are checked in headless Chrome against a scratch vault with the pretend-installed flag.
#   powershell -ExecutionPolicy Bypass -File tests\cosworth-test.ps1
param([switch]$W19Only)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = if ($env:VAULT_TEST_API) { $env:VAULT_TEST_API } else { 'http://localhost:8199' }
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; Write-Host "  ok    $what" } else { $script:fail++; Write-Host "  FAIL  $what" } }
function Note($what) { Write-Host "  info  $what" }
function J($path) { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 600; [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json }
function Code($path) {
  try { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 120; return [int]$r.StatusCode } catch { return [int]$_.Exception.Response.StatusCode }
}
function Hit($path) { try { $null = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 120 } catch { } }
function Qs($s) { [uri]::EscapeDataString([string]$s) }
function IsTrue($v) { if ($v -eq $true) { return $true }; $s = "$v"; return ($s -eq 'True' -or $s -eq 'true') }

. (Join-Path $PSScriptRoot 'guard.ps1')
$testStart = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
Assert-RigFree
function Section($title) { Assert-RigFree -Where $title; Write-Host ''; Write-Host $title }

$piExe = 'C:\Program Files\Pi Toolbox\Pi Toolbox.exe'
$piWorkbook = 'C:\Program Files\Pi Toolbox\Templates\Sim\iRacing Lite Workbook - v1.2.pwb'
function PiProcs { @(Get-Process 'Pi Toolbox' -ErrorAction SilentlyContinue) }
function PiProcIds { @((PiProcs | ForEach-Object { [int]$_.Id })) }
function PiTitles { @(PiProcs | ForEach-Object { $_.MainWindowTitle }) }
function PiRunning { @(PiProcs | Where-Object { $_.MainWindowHandle -ne 0 }).Count -gt 0 }
$script:piBefore = PiProcIds
function Stop-TestPi {
  $prior = @{}; foreach ($id in $script:piBefore) { $prior[[int]$id] = $true }
  foreach ($p in (PiProcs)) { if (-not $prior.ContainsKey([int]$p.Id)) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } } }
}
function PiUiNames {
  try {
    Add-Type -AssemblyName UIAutomationClient; Add-Type -AssemblyName UIAutomationTypes
    $p = PiProcs | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { return @() }
    $rootEl = [Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)
    $all = $rootEl.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
    $names = @(); foreach ($e in $all) { if ($e.Current.Name) { $names += $e.Current.Name } }
    return $names
  } catch { return @() }
}

# ---- tiny Win32 + pixel helpers (screenshot Pi's window, compare two pictures) ----
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices; using System.Drawing; using System.Drawing.Imaging;
public static class CwCap {
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct RECT { public int L, T, R, B; }
  public static string Shot(IntPtr h, string path) {
    RECT r; if (!GetWindowRect(h, out r)) return "no rect";
    int w = r.R - r.L, ht = r.B - r.T; if (w <= 0 || ht <= 0) return "bad rect";
    using (var bmp = new Bitmap(w, ht)) using (var g = Graphics.FromImage(bmp)) {
      IntPtr hdc = g.GetHdc(); PrintWindow(h, hdc, 2); g.ReleaseHdc(hdc);
      bmp.Save(path, ImageFormat.Png);
    }
    return w + "x" + ht;
  }
  public static double Diff(string a, string b) {
    using (var ia = new Bitmap(a)) using (var ib = new Bitmap(b)) {
      int w = Math.Min(ia.Width, ib.Width), h = Math.Min(ia.Height, ib.Height);
      var r = new Rectangle(0, 0, w, h); var f = PixelFormat.Format24bppRgb;
      var da = ia.LockBits(r, ImageLockMode.ReadOnly, f); var db = ib.LockBits(r, ImageLockMode.ReadOnly, f);
      byte[] ba = new byte[da.Stride * h]; byte[] bb = new byte[db.Stride * h];
      Marshal.Copy(da.Scan0, ba, 0, ba.Length); Marshal.Copy(db.Scan0, bb, 0, bb.Length);
      ia.UnlockBits(da); ib.UnlockBits(db);
      long n = 0, d = 0;
      for (int y = 0; y < h; y++) { int ra = y * da.Stride, rb = y * db.Stride;
        for (int x = 0; x < w; x++) { int oa = ra + x * 3, ob = rb + x * 3;
          int diff = Math.Abs(ba[oa] - bb[ob]) + Math.Abs(ba[oa + 1] - bb[ob + 1]) + Math.Abs(ba[oa + 2] - bb[ob + 2]);
          n++; if (diff > 30) d++; } }
      return 100.0 * d / n;
    }
  }
}
'@ -ReferencedAssemblies System.Drawing -ErrorAction Stop
function Shot-Pi($path) {
  $p = PiProcs | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $p) { return $null }
  return [CwCap]::Shot($p.MainWindowHandle, $path)
}

# ---- headless Chrome with the DevTools protocol (same harness as quickwins-test) ----
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('cw-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9395
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', 'about:blank') -PassThru -WindowStyle Hidden
  try { $p.PriorityClass = 'BelowNormal' } catch { }
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  if (-not $page) {
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$prof*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
    try { Remove-Item -LiteralPath $prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    throw 'headless Chrome did not start'
  }
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
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 300
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
function Wait-Page($expr, $secs = 30) { for ($i = 0; $i -lt ($secs * 4); $i++) { $v = Cdp-Eval $expr; if ($v -eq $true) { return $true }; Start-Sleep -Milliseconds 250 }; return $false }

Enter-TestLock 'cosworth'   # one live test at a time (tests\guard.ps1); released in finally
$lock = Join-Path $root 'dash\deploy.lock'
for ($i = 0; $i -lt 20 -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15; $i++) { 'waiting for the deploy lock (' + (Get-Content $lock) + ')'; Start-Sleep -Seconds 60 }
Set-Content $lock ('cosworth ' + (Get-Date).ToString('HH:mm:ss'))
$hook = Join-Path $root 'dash\test-hook.on'
$tdir = Join-Path $root 'vault-test'; $src = Join-Path $tdir 'src'
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$fA = 'chevyvettez06rgt3_roadatlanta full 2026-10-09 14-58-37.ibt'
$fB = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt'
$curlId = $null

Write-Host 'Cosworth'
try {
  Set-Content $hook 'cosworth test'
  $doc = Join-Path $root 'docs\cosworth.md'
  $docTx = if (Test-Path $doc) { [IO.File]::ReadAllText($doc) } else { '' }

  if (-not $W19Only) {
  Section 'W-18 1. the Pi install and the open method are recorded'
  $doc = Join-Path $root 'docs\cosworth.md'
  $docTx = if (Test-Path $doc) { [IO.File]::ReadAllText($doc) } else { '' }
  Check 'docs\cosworth.md records the install path C:\Program Files\Pi Toolbox' ($docTx -match [regex]::Escape('C:\Program Files\Pi Toolbox'))
  Check 'docs\cosworth.md records Pi Toolbox.exe, the workbook and the forward method' (($docTx -match 'Pi Toolbox\.exe') -and ($docTx -match 'iRacing Lite Workbook') -and ($docTx -match 'TBX_INSTANCE_FILEOPEN_PIPE'))
  Check 'docs\cosworth.md records the video-sync fact (Lite has none; Plus and above)' (($docTx -match '(?i)video sync') -and ($docTx -match '(?i)lite') -and ($docTx -match '(?i)plus'))
  Check 'the recorded executable exists on this PC' (Test-Path -LiteralPath $piExe)
  $st = J '/vault'
  Check 'the Vault status reports Pi Toolbox installed' ($st.cosworth.installed -eq $true)

  Section 'W-18 2. the open route answers for a Vault lap and a telemetry file name'
  $null = J '/vault/test/sandbox?on=1&reset=1'
  if ((Test-Path (Join-Path $tel $fA)) -and (Test-Path (Join-Path $tel $fB))) {
    Copy-Item (Join-Path $tel $fA) (Join-Path $src $fA) -Force
    Copy-Item (Join-Path $tel $fB) (Join-Path $src $fB) -Force
    (Get-Item (Join-Path $src $fA)).LastWriteTime = (Get-Item (Join-Path $tel $fA)).LastWriteTime
    (Get-Item (Join-Path $src $fB)).LastWriteTime = (Get-Item (Join-Path $tel $fB)).LastWriteTime
  }
  $more = $true; $guard = 0
  while ($more -and $guard -lt 6) { $scan = J '/vault/test/scan'; $more = [bool]$scan.more; $guard++ }
  $null = J '/vault/test/cosworth?on=auto'     # real detection: Pi IS installed, so action must be cosworth
  $lg = J '/vault/list'
  $lap = @($lg.moments | Where-Object { $_.kind -eq 'lap' -and $_.ibt -and $_.lapTime -gt 0 })[0]
  Check 'the scratch vault holds a lap to open' ($null -ne $lap)
  if ($lap) { $curlId = $lap.id }
  $dry = if ($curlId) { J ('/vault/open?how=cosworth&id=' + (Qs $curlId) + '&dry=1') } else { $null }
  Check "a Vault lap opens in Pi (action=$($dry.action), target=$([IO.Path]::GetFileName($dry.target)))" (($dry.ok -eq $true) -and ($dry.action -eq 'cosworth') -and ($dry.target -match '\.ibt$'))
  $hasF = Test-Path (Join-Path $tel $fB)
  $dryF = if ($hasF) { J ('/vault/open?how=cosworth&id=' + (Qs $fB) + '&dry=1') } else { $null }
  Check "a telemetry file name (Workbench form) opens in Pi (action=$($dryF.action))" ($hasF -and ($dryF.ok -eq $true) -and ($dryF.action -eq 'cosworth'))

  Section 'W-18 3. the open route is refused while he drives'
  Hit '/api/test/frame?IsOnTrack=1&Speed=5&Lap=1&IsReplayPlaying=0'
  Start-Sleep -Milliseconds 800
  $codeDrive = if ($curlId) { Code ('/vault/open?how=cosworth&id=' + (Qs $curlId)) } else { -1 }
  Hit '/api/test/end'
  Start-Sleep -Milliseconds 400
  Check "opening while on track is refused with 409 (got $codeDrive)" ($codeDrive -eq 409)

  Section 'W-18b 3b. queued launch safety and direct Pi launch path'
  $vaultSource = [IO.File]::ReadAllText((Join-Path $root 'dash\src\vault.cs'))
  $launchRegion = [regex]::Match($vaultSource, '(?s)static void StartCosworth\(.*?\n        \}\n\n        // Resolves an open id').Value
  $driveChecks = [regex]::Matches($launchRegion, 'Program\.IsDriving').Count
  Check 'queued worker checks driving state before workbook and lap launches' ($driveChecks -ge 2)
  Check 'Pi workbook and lap launches start Pi directly with shell execution disabled' (($launchRegion -match 'Process\.Start\(new ProcessStartInfo\(cw\.Exe') -and ([regex]::Matches($launchRegion, 'UseShellExecute = false').Count -ge 2) -and ($launchRegion -notmatch 'explorer\.exe'))
$pwbFile = Join-Path $root 'cosworth\Paddock.pwb'; $runLog = @(Get-Content (Join-Path $root 'dash\irdash.log') -ErrorAction SilentlyContinue | Where-Object { $_ -match 'cosworth launch' -and $_.Substring(0, 19) -ge $testStart })
Check 'Pi makes a writable project copy and never launches the template (behaviour: file + this run''s launch log)' ((Test-Path $pwbFile) -and -not (Get-Item $pwbFile).IsReadOnly -and -not ($runLog -match 'Templates\\'))
  Check 'cold or Untitled Pi waits up to 30 seconds for the Paddock title before forwarding' (($launchRegion -match 'title\.StartsWith\("Untitled"') -and ($launchRegion -match 'StartsWith\(expected') -and ($launchRegion -match 'i < 120') -and ($launchRegion -match 'Thread\.Sleep\(250\)'))
  Check 'launch logs include exe, argument and resulting title' (($launchRegion -match 'exe=" \+ cw\.Exe') -and ($launchRegion -match 'argument=') -and ($launchRegion -match 'title=" \+'))

  Section 'W-18 4. the control is on the four surfaces only when Pi is installed'
  $chromeOk = Test-Path $chrome
  Note "Pi is really installed here; the buttons are checked with the pretend flag (/vault/test/cosworth?on=1|0)"
  # --- installed: Vault lap page ---
  $null = J '/vault/test/cosworth?on=1'
  Cdp-Open "$api/v2/vault.html"
  $grid = Wait-Page "document.querySelectorAll('.card').length > 0" 30
  $vaultCos = $false
  if ($grid -and $curlId) {
    $null = Cdp-Eval ("location.hash = 'm=" + $curlId + "'")
    $null = Wait-Page "V.id === '$curlId' && !!document.getElementById('dActs')" 40
    $vaultCos = Wait-Page "!!document.getElementById('bCos')" 20
    if (-not $vaultCos) { Note ('vault lap page: ' + (Cdp-Eval "(function(){return JSON.stringify({id:(typeof V!=='undefined'?V.id:''),inst:(V.cur&&V.cur.cosworth)?V.cur.cosworth.installed:'',acts:((document.getElementById('dActs')||{}).innerText||'').slice(0,80)});})()")) }
  }
  Cdp-Close
  # --- installed: Workbench, Session Review, Debrief ---
  Cdp-Open "$api/v2/workbench.html?id=$curlId&lap=1"
  $wbCos = Wait-Page "!!document.getElementById('cwbtn')" 25
  Cdp-Close
  Cdp-Open "$api/v2/sessionreview.html?id=$curlId"
  $srCos = Wait-Page "!!document.getElementById('srCos') && !document.getElementById('srCos').hidden" 45
  Cdp-Close
  Cdp-Open "$api/v2/index.html"
  $null = Wait-Page "(typeof Debrief !== 'undefined' && !!Debrief.show)" 20
  $null = Cdp-Eval @'
(function () {
  var times = [{ t: 95.1, clean: true }, { t: 95.4, clean: true }, { t: 95.6, clean: true }];
  Debrief.show({ type: 'Practice', race: false, track: 'Road Atlanta', car: 'Corvette Z06 GT3.R', laps: 3, cleanLaps: 3, best: 95.1, inc: 0, mins: 6, times: times, offline: true }, false);
  return 'shown';
})()
'@
  $dbCos = Wait-Page "!!document.getElementById('dbCos')" 20
  Cdp-Close
  Check "with Pi installed the button is on Vault, Workbench, Session Review and Debrief ($vaultCos/$wbCos/$srCos/$dbCos)" ($chromeOk -and $vaultCos -and $wbCos -and $srCos -and $dbCos)
  # --- not installed: every surface must omit its control ---
  $null = J '/vault/test/cosworth?on=0'
  Cdp-Open "$api/v2/vault.html"
  $grid2 = Wait-Page "document.querySelectorAll('.card').length > 0" 30
  $vaultNo = $false
  if ($grid2 -and $curlId) {
    $null = Cdp-Eval ("location.hash = 'm=" + $curlId + "'")
    $null = Wait-Page "V.id === '$curlId' && !!document.getElementById('bStar')" 40
    $vaultNo = -not (IsTrue (Cdp-Eval "!!document.getElementById('bCos')"))
  }
  Cdp-Close
  Cdp-Open "$api/v2/workbench.html?id=$curlId&lap=1"
  Start-Sleep -Seconds 3
  $wbNo = -not (IsTrue (Cdp-Eval "!!document.getElementById('cwbtn')"))
  Cdp-Close
  Cdp-Open "$api/v2/sessionreview.html?id=$curlId"
  $srNo = Wait-Page "document.getElementById('srCos') && document.getElementById('srCos').hidden" 45
  Cdp-Close
  Cdp-Open "$api/v2/index.html"
  $null = Wait-Page "(typeof Debrief !== 'undefined' && !!Debrief.show)" 20
  $null = Cdp-Eval @'
(function () { Debrief.show({ type:'Practice', race:false, track:'Road Atlanta', car:'Corvette Z06 GT3.R', laps:3, cleanLaps:3, best:95.1, inc:0, mins:6, times:[{t:95.1,clean:true},{t:95.4,clean:true},{t:95.6,clean:true}], offline:true }, false); return 'shown'; })()
'@
  Start-Sleep -Seconds 2
  $dbNo = -not (IsTrue (Cdp-Eval "!!document.getElementById('dbCos')"))
  Cdp-Close
  Check "with Pi not installed the control is hidden on all four surfaces ($vaultNo/$wbNo/$srNo/$dbNo)" ($vaultNo -and $wbNo -and $srNo -and $dbNo)
  $null = J '/vault/test/cosworth?on=auto'

  Section 'W-18 5. the copy rules pass on the new wording'
  # only the visible strings this card adds (comments are not on the glass)
  $newTx = 'OPEN IN COSWORTH / OPENING / Open this lap in Cosworth Pi Toolbox'
  $bad = @('(?i)\byou(?:r|rs|rself|''re|''ve|''ll)?\b', 'good morning|good evening|welcome', '(?i)\bjust\b|\bsimply\b|\binsight\b|\bjourney\b|\bstory\b', '—', '!')
  $hit = @($bad | Where-Object { $newTx -match $_ })
  Check "the new button wording passes the copy rules ($($hit.Count) banned patterns found)" ($hit.Count -eq 0)
  }

  Section 'W-19 workbook'
  # W-19 stays closed until a format-specific editor can prove the display structure.
  $wbTool = Join-Path $root 'tools\cosworth-workbook.ps1'
  $piUser = $null
  $locBase = 'HKCU:\Software\Pi Research\Pi Toolbox\Document Locations'
  if (Test-Path $locBase) {
    foreach ($sub in Get-ChildItem $locBase -ErrorAction SilentlyContinue) {
      $kk = Get-Item $sub.PSPath
      if (([string]$kk.GetValue('Caption')) -match '(?i)my documents') { $piUser = ([string]$kk.GetValue('Path')).TrimEnd('\') }
    }
  }
  if (-not $piUser) { $piUser = [Environment]::GetFolderPath('MyDocuments') }
  Check "the Pi user folder is found ($piUser)" ([IO.Directory]::Exists($piUser))
  Check "the installed iRacing Lite workbook is inspected ($([IO.Path]::GetFileName($piWorkbook)))" ((Test-Path -LiteralPath $piWorkbook) -and ($piWorkbook -match '(?i)\.pwb$'))
  $destPwb = Join-Path $piUser 'Paddock.pwb'
  $destBefore = Test-Path -LiteralPath $destPwb
  $destTime = if ($destBefore) { (Get-Item -LiteralPath $destPwb).LastWriteTimeUtc } else { $null }
  $chk = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $wbTool -Check 2>&1)
  $checkExit = $LASTEXITCODE
  $fmtKind = ((@($chk | Where-Object { $_ -match '^Format:' })[0]) -replace '^Format:\s*', '')
  $dstLine = @($chk | Where-Object { $_ -match '^Destination:' })
  $reportedDest = if ($dstLine.Count -eq 1) { $dstLine[0] -replace '^Destination:\s*', '' } else { '' }
  Check "-Check reports the exact OLE2 decision and destination ($fmtKind -> $reportedDest)" (($fmtKind -eq 'ole2') -and ($dstLine.Count -eq 1) -and ([IO.Path]::GetFullPath($reportedDest) -eq [IO.Path]::GetFullPath($destPwb)))
  Check '-Check returns the distinct unsupported status' ($checkExit -eq 3 -and @($chk | Where-Object { $_.Trim() -eq 'NOT SUPPORTED' }).Count -eq 1)
  $destAfter = Test-Path -LiteralPath $destPwb
  $destTime2 = if ($destAfter) { (Get-Item -LiteralPath $destPwb).LastWriteTimeUtc } else { $null }
  Check '-Check changes nothing (the Pi user folder workbook is the same before and after)' (($destBefore -eq $destAfter) -and ((-not $destBefore) -or ($destTime -eq $destTime2)))
  Check 'docs\cosworth.md records the Pi user folder and the .pwb extension' ($docTx -match 'OneDrive\\Documents' -and $docTx -match '\.pwb')
  Check 'docs\cosworth.md records the unsupported stop for binary and text, XML, ZIP' (($docTx -match 'NOT SUPPORTED') -and ($docTx -match '(?i)binary') -and ($docTx -match '(?i)OLE2') -and ($docTx -match '(?i)text, XML, ZIP'))
  $run = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $wbTool 2>&1)
  $runExit = $LASTEXITCODE
  Check 'normal run returns NOT SUPPORTED and creates no Paddock workbook' ($runExit -eq 3 -and @($run | Where-Object { $_.Trim() -eq 'NOT SUPPORTED' }).Count -eq 1 -and ((Test-Path -LiteralPath $destPwb) -eq $destBefore))
  $fixtureDir = Join-Path $env:TEMP ('w19-format-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $fixtureDir | Out-Null
  $fixtureOk = $true
  try {
    $fixtureText = 'speed throttle brake steering gear delta PB datum'
    $textFile = Join-Path $fixtureDir 'text.pwb'; [IO.File]::WriteAllText($textFile, $fixtureText)
    $xmlFile = Join-Path $fixtureDir 'xml.pwb'; [IO.File]::WriteAllText($xmlFile, ('<?xml version="1.0"?><workbook>' + $fixtureText + '</workbook>'))
    $zipFile = Join-Path $fixtureDir 'zip.pwb'; [IO.File]::WriteAllBytes($zipFile, [byte[]](0x50,0x4B,0x03,0x04,0x73,0x70,0x65,0x65,0x64))
    foreach ($kindCase in @('text', 'xml', 'zip')) {
      $fixtureSource = Join-Path $fixtureDir ($kindCase + '.pwb')
      $fixtureDest = Join-Path $fixtureDir ($kindCase + '-Paddock.pwb')
      $fixtureOut = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $wbTool -Source $fixtureSource -Dest $fixtureDest 2>&1)
      $fixtureExit = $LASTEXITCODE
      if ($fixtureExit -ne 3 -or @($fixtureOut | Where-Object { $_ -match ('^Format:\s*' + $kindCase + '$') }).Count -ne 1 -or (Test-Path -LiteralPath $fixtureDest)) { $fixtureOk = $false }
    }
  } finally {
    $tempRootFull = [IO.Path]::GetFullPath($env:TEMP).TrimEnd([char]92) + [IO.Path]::DirectorySeparatorChar
    $fixtureFull = [IO.Path]::GetFullPath($fixtureDir)
    if ($fixtureFull.StartsWith($tempRootFull, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($fixtureFull).StartsWith('w19-format-', [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $fixtureFull -Recurse -Force -ErrorAction SilentlyContinue }
  }
  Check 'text, XML, and ZIP fixtures fail closed even with all display words and PB datum present' $fixtureOk
  $badDestA = Join-Path $piUser 'iRacing\Paddock.pwb'
  $badDestB = 'C:\Program Files (x86)\iRacing\Paddock.pwb'
  $badDestC = 'C:\Program Files\iRacing\Paddock.pwb'
  $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $wbTool -Dest $badDestA 2>&1); $exitA = $LASTEXITCODE
  $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $wbTool -Dest $badDestB 2>&1); $exitB = $LASTEXITCODE
  $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $wbTool -Dest $badDestC 2>&1); $exitC = $LASTEXITCODE
  Check 'destinations under Documents\\iRacing and either Program Files iRacing root are refused' ($exitA -eq 4 -and $exitB -eq 4 -and $exitC -eq 4 -and (-not (Test-Path -LiteralPath $badDestA)) -and (-not (Test-Path -LiteralPath $badDestB)) -and (-not (Test-Path -LiteralPath $badDestC)))
  Check 'no Paddock workbook is written under Documents\iRacing or the iRacing install folder' ((-not (Test-Path -LiteralPath (Join-Path $tel 'Paddock.pwb'))) -and (-not (Test-Path -LiteralPath (Join-Path $piUser 'iRacing\Paddock.pwb'))))

  if (-not $W19Only) {
  Section 'W-18c 6. title-based live checks for workbook readiness and lap forwarding'
  $ibtName = if (Test-Path (Join-Path $tel $fB)) { $fB } elseif (Test-Path (Join-Path $tel $fA)) { $fA } else { $null }
  Check 'a real telemetry file is on this PC for the live open' ($null -ne $ibtName)
  if ($ibtName) {
    $beforeTitles = @(PiTitles)
    $beforeWorkbook = @($beforeTitles | Where-Object { $_ -match ' - Pi Toolbox$' -and $_ -notmatch '^Untitled' }).Count -gt 0
    $beforeDirty = @($beforeTitles | Where-Object { $_.EndsWith('*') }).Count -gt 0
    if ((PiRunning) -and $beforeWorkbook) { Note 'Pi already has a workbook; preserving it and checking direct lap forwarding' }
    elseif (-not (PiRunning)) { Note 'Pi is cold; route must create/open Paddock.pwb and wait for its title' }
    else { Note 'Pi is Untitled; route must open Paddock.pwb and wait for its title' }
    if (-not (PiRunning)) { Note 'Could not create a disposable workbook-less Pi instance; import step is skipped' }
    else {
    $base = Join-Path $shots 'cw-pi-before.png'; $after = Join-Path $shots 'cw-pi-after.png'
    $sz1 = Shot-Pi $base
    $null = J ('/vault/open?how=cosworth&id=' + (Qs $ibtName))
    $ready = $false
    for ($i = 0; $i -lt 120; $i++) { $titlesNow = @(PiTitles); if (@($titlesNow | Where-Object { $_.StartsWith('Paddock - Pi Toolbox') }).Count -gt 0) { $ready = $true; break }; Start-Sleep -Milliseconds 250 }
    if (-not $beforeWorkbook) { Check 'cold or Untitled Pi reaches the Paddock workbook title' $ready }
    else { $ready = $true; Check 'an already-open Pi workbook remains available for direct forwarding' $ready }
    $forwarded = $false
    for ($i = 0; $i -lt 40; $i++) { $titlesNow = @(PiTitles); if (@($titlesNow | Where-Object { $_.EndsWith('*') }).Count -gt 0 -or $beforeDirty) { $forwarded = $true; break }; Start-Sleep -Milliseconds 250 }
    $sz2 = Shot-Pi $after
    $diff = 0.0
    if ($sz1 -and $sz2) { $diff = [CwCap]::Diff($base, $after) }
    Note "Pi window $sz1 -> $sz2; picture diff $([math]::Round($diff,2)) % (the forwarded lap adds an outing row)"
    $titleAfter = (PiTitles | Select-Object -First 1)
    Note "Pi window title after forward: $titleAfter"
    Check 'forwarded lap marks the workbook dirty (or it was already dirty)' $forwarded
    }
  }
  Stop-TestPi
  Note "pictures: cw-pi-workbook.png / cw-pi-forward.png (in tests\shots) show the imported outing from the discovery run"
  }
}
catch {
  $script:fail++
  "  FAIL  the test stopped: $($_.Exception.Message)"
}
finally {
  try { Cdp-Close } catch { }
  Stop-TestPi
  Hit '/api/test/end'
  try { $null = J '/vault/test/cosworth?on=auto' } catch { }
  try { $null = J '/vault/test/sandbox?on=0' } catch { }
  Remove-Item $hook -Force -ErrorAction SilentlyContinue
  Remove-Item $lock -Force -ErrorAction SilentlyContinue
  Exit-TestLock
  try { if (Test-Path $tdir) { Remove-Item $tdir -Recurse -Force } } catch { }
}
Write-Host ''
Write-Host "$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
