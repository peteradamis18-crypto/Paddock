# P3 Pro analysis tools (docs\PLAN-v3.md): X/Y scatter with a least-squares fit, histogram, maths channels (the server's small parser, no eval) and the
# CSV / .xlsx export of the analysis workbench. The server side (dash\src\protools.cs) is run on COPIES of two old .ibt files (the vault's own copies,
# never Documents\iRacing, never the newest file) through irdash.exe's one-shot mode; the page (dash\www\v2\workbench-pro.js) runs in headless Chrome at
# 1920x1080 against the running irdash (the live part runs only when the deployed irdash has the pro routes; `dash\build.ps1` puts them there).
# Every number is checked against an independent computation made here from the /analysis/channels reply or the raw .ibt records.
#   powershell -ExecutionPolicy Bypass -File tests\pro-tools-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree

$pass = 0; $fail = 0; $t0 = [Diagnostics.Stopwatch]::StartNew()
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
$pbName = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt'      # lap 7 = 79.549, the lap of every check
$midName = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 13-28-11.ibt'     # its reference: the afternoon lap 7, 79.575
$copies = @(@{ from = '2026-10-10 00-13-18.ibt'; to = $pbName }, @{ from = '2026-10-10 13-28-11.ibt'; to = $midName })
$car = 'Chevrolet Corvette Z06 GT3.R'
$work = Join-Path $env:TEMP ('pro-tools-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$store = Join-Path $work 'store'
$marker = Join-Path $work 'CODE-RAN.txt'
$inv = [Globalization.CultureInfo]::InvariantCulture

# ---- the binary reply of /analysis/channels ("PWB1", int32 header length, JSON header, Float32 arrays in the header's order) ----
function Read-Wb($path) {
  $b = [IO.File]::ReadAllBytes($path)
  if ($b.Length -lt 8 -or [Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'PWB1') { return @{ ok = $false; text = [Text.Encoding]::UTF8.GetString($b) } }
  $hl = [BitConverter]::ToInt32($b, 4); $head = [Text.Encoding]::UTF8.GetString($b, 8, $hl) | ConvertFrom-Json
  $arr = @{}; $pos = 8 + $hl; $n = [int]$head.n
  foreach ($k in $head.arrays) { $a = [Array]::CreateInstance([single], $n); [Buffer]::BlockCopy($b, $pos, $a, 0, $n * 4); $arr[$k] = $a; $pos += $n * 4 }
  return @{ ok = $true; head = $head; arr = $arr; bytes = $b.Length; used = $pos }
}

# Independent helpers written for this test (never Paddock's own code): a raw .ibt reader, a Householder-QR polynomial least squares (the page solves the
# normal equations), and a streaming reader for the cells of an .xlsx sheet.
Add-Type -ReferencedAssemblies 'System.Xml' -TypeDefinition @'
using System; using System.Collections.Generic; using System.IO; using System.Text; using System.Xml;
public static class ProRaw {
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
public static class ProLsq {
  // y = c0 + c1 x + ... + c_order x^order by Householder QR on the Vandermonde matrix of x / max|x|; coefficients are returned for the raw x
  public static double[] Fit(double[] x, double[] y, int order) {
    int n = x.Length, m = order + 1; double s = 0; foreach (double v in x) s = Math.Max(s, Math.Abs(v)); if (s == 0) s = 1;
    double[,] A = new double[n, m]; double[] b = (double[])y.Clone();
    for (int i = 0; i < n; i++) { double u = x[i] / s, p = 1; for (int j = 0; j < m; j++) { A[i, j] = p; p *= u; } }
    for (int j = 0; j < m; j++) {
      double nrm = 0; for (int i = j; i < n; i++) nrm += A[i, j] * A[i, j]; nrm = Math.Sqrt(nrm); if (A[j, j] > 0) nrm = -nrm;
      double[] v = new double[n]; for (int i = j; i < n; i++) v[i] = A[i, j]; v[j] -= nrm;
      double vn = 0; for (int i = j; i < n; i++) vn += v[i] * v[i]; if (vn == 0) continue;
      for (int k = j; k < m; k++) { double d = 0; for (int i = j; i < n; i++) d += v[i] * A[i, k]; d = 2 * d / vn; for (int i = j; i < n; i++) A[i, k] -= d * v[i]; }
      double db = 0; for (int i = j; i < n; i++) db += v[i] * b[i]; db = 2 * db / vn; for (int i = j; i < n; i++) b[i] -= db * v[i];
    }
    double[] c = new double[m];
    for (int j = m - 1; j >= 0; j--) { double t = b[j]; for (int k = j + 1; k < m; k++) t -= A[j, k] * c[k]; c[j] = t / A[j, j]; }
    for (int j = 0; j < m; j++) c[j] /= Math.Pow(s, j);
    return c;
  }
  public static double R2(double[] x, double[] y, double[] c) {
    double ym = 0; foreach (double v in y) ym += v; ym /= y.Length; double ssr = 0, sst = 0;
    for (int i = 0; i < x.Length; i++) { double yh = 0; for (int k = c.Length - 1; k >= 0; k--) yh = yh * x[i] + c[k]; ssr += (y[i] - yh) * (y[i] - yh); sst += (y[i] - ym) * (y[i] - ym); }
    return 1 - ssr / sst;
  }
}
public static class ProXlsx {
  // every cell of a worksheet part: "B7" -> text (shared strings are not used by Paddock's files; inline strings and numbers both come back as text)
  public static Dictionary<string,string> Cells(Stream s) {
    var d = new Dictionary<string,string>();
    using (XmlReader r = XmlReader.Create(s)) {
      string refc = null, type = null; bool inV = false, inT = false; StringBuilder sb = new StringBuilder();
      while (r.Read()) {
        if (r.NodeType == XmlNodeType.Element) {
          if (r.LocalName == "c") { refc = r.GetAttribute("r"); type = r.GetAttribute("t"); sb.Length = 0; }
          else if (r.LocalName == "v") { inV = true; }
          else if (r.LocalName == "t") { inT = true; }
        } else if (r.NodeType == XmlNodeType.Text || r.NodeType == XmlNodeType.SignificantWhitespace || r.NodeType == XmlNodeType.Whitespace) {
          if (inV || inT) sb.Append(r.Value);
        } else if (r.NodeType == XmlNodeType.EndElement) {
          if (r.LocalName == "v") inV = false; else if (r.LocalName == "t") inT = false;
          else if (r.LocalName == "c" && refc != null) { d[refc] = sb.ToString(); refc = null; }
        }
      }
    }
    return d;
  }
  public static string Col(int c) { string s = ""; c++; while (c > 0) { int r = (c - 1) % 26; s = (char)('A' + r) + s; c = (c - 1) / 26; } return s; }
}
'@

# ---- headless Chrome with the DevTools protocol (the same harness as workbench-test; its own port) ----
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('pro-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9395
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
function Cdp-Json($expr) {
  $txt = Cdp-Eval "JSON.stringify($expr)"
  if ($txt -is [string] -and $txt.StartsWith('js error')) { throw $txt }
  $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer; $ser.MaxJsonLength = 100MB
  return $ser.DeserializeObject($txt)
}
function Cdp-Await($expr) { $s = Cdp-Eval ('(' + $expr + ').then(function(r){return JSON.stringify(r)})'); if ($s -is [string] -and $s.StartsWith('js error')) { throw $s }; return $s | ConvertFrom-Json }
function Cdp-Shot($path) { $s = Cdp 'Page.captureScreenshot' @{ format = 'png' }; [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data)) }
function Cdp-Mouse($x, $y) {
  $null = Cdp 'Input.dispatchMouseEvent' @{ type = 'mouseMoved'; x = $x; y = $y }
  $null = Cdp 'Input.dispatchMouseEvent' @{ type = 'mousePressed'; x = $x; y = $y; button = 'left'; clickCount = 1 }
  $null = Cdp 'Input.dispatchMouseEvent' @{ type = 'mouseReleased'; x = $x; y = $y; button = 'left'; clickCount = 1 }
}
function Cdp-Key($key, $mod = 0) {
  $code = switch ($key) { 'Enter' { 13 } 'Escape' { 27 } default { 0 } }
  $null = Cdp 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = $key; code = $key; windowsVirtualKeyCode = $code; modifiers = $mod; text = $(if ($key.Length -eq 1) { $key } else { '' }) }
  $null = Cdp 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = $key; code = $key; windowsVirtualKeyCode = $code; modifiers = $mod }
}
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 300; try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
function Cdp-Goto($url) {
  if (-not $script:cdp) { Cdp-Open $url } else { $null = Cdp-Eval 'window.__old = 1'; $null = Cdp 'Page.navigate' @{ url = $url } }
  for ($i = 0; $i -lt 120; $i++) { Start-Sleep -Milliseconds 250; if ((Cdp-Eval 'window.__old ? 0 : (window.WB && (WB.extras || WB.error) ? 1 : 0)') -eq 1) { break } }
  Start-Sleep -Milliseconds 600
}

Add-Type -AssemblyName System.Web.Extensions
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName WindowsBase

try {
  New-Item -ItemType Directory -Force $work | Out-Null
  Section '1. copies of two old sessions (the vault''s own copies)'
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
  Check 'dash\build.ps1 -NoDeploy compiled (protools.cs is in its list)' ($LASTEXITCODE -eq 0 -and $m.Success -and ((Get-Content (Join-Path $root 'dash\build.ps1') -Raw) -match 'protools\.cs'))
  if (-not $m.Success) { throw $build }
  $exe = Join-Path $m.Groups[1].Value.Trim() 'irdash.exe'

  function Run-Exe($argLine) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe; $psi.Arguments = $argLine; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit(300000)) { try { $proc.Kill() } catch { }; throw "timed out: $argLine" }
    return $proc.ExitCode
  }
  function Invoke-Channels($id, $lap, $ref, $ch, $tag) {
    $out = Join-Path $work "$tag.bin"
    $code = Run-Exe "--analysis --channels --root `"$root`" --dir `"$work`" --id `"$id`" --lap $lap --ref `"$ref`" --ch `"$ch`" --out `"$out`""
    $r = Read-Wb $out; $r.exit = $code; return $r
  }
  # a batch of formulas ("name TAB unit TAB formula" lines) through the pro tools' one-shot mode: one result per line
  function Invoke-Maths($lines, $tag) {
    $ex = Join-Path $work "$tag.txt"; [IO.File]::WriteAllLines($ex, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
    $out = Join-Path $work $tag
    $code = Run-Exe "--analysis --pro --op maths --root `"$root`" --dir `"$work`" --id `"$pbName`" --lap 7 --ref pb --exprs `"$ex`" --out `"$out`""
    $res = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
      $bin = "$out.$i.bin"; $js = "$out.$i.json"
      if (Test-Path -LiteralPath $bin) { $r = Read-Wb $bin; $res += , @{ ok = $true; head = $r.head; arr = $r.arr } }
      elseif (Test-Path -LiteralPath $js) { $e = [IO.File]::ReadAllText($js) | ConvertFrom-Json; $res += , @{ ok = $false; error = [string]$e.error; pos = $e.pos } }
      else { $res += , @{ ok = $false; error = '(no output)' } }
    }
    return @{ exit = $code; res = $res }
  }
  function Invoke-Pro($op, $extra, $tag) {
    $out = Join-Path $work "$tag.out"
    $code = Run-Exe "--analysis --pro --op $op --root `"$root`" --dir `"$work`" --id `"$pbName`" --lap 7 --ref pb --store `"$store`" $extra --out `"$out`""
    return @{ exit = $code; path = $out; bytes = $(if (Test-Path -LiteralPath $out) { [IO.File]::ReadAllBytes($out) } else { $null }) }
  }

  # the page's own channel list (workbench.js CHANS): the lap and its reference, the base of every independent calculation below
  $chp = ([regex]::Match((Get-Content (Join-Path $root 'dash\www\v2\workbench.js') -Raw -Encoding UTF8), 'var CHANS = \[(.*?)\];', 'Singleline').Groups[1].Value -replace "[\s']", '')
  $wf = Invoke-Channels $pbName 7 'pb' $chp 'lap7full'
  if (-not $wf.ok) { throw "channels failed: $($wf.text)" }
  $h = $wf.head; $n = [int]$h.n; $L = [double]$h.lengthM
  $WA = $wf.arr
  Note "lap 7: $n samples every $($h.step) m, $($h.lap.time) s, reference lap $($h.ref.lap) $($h.ref.time) s ($($chp.Split(',').Count) channels)"

  Section '3. the formula parser: precedence, functions, unknown names, division by zero, nothing runs'
  $consts = @(
    @('2 + 3 * 4', 14), @('(2 + 3) * 4', 20), @('2 ^ 3 ^ 2', 512), @('-2 ^ 2', -4), @('10 - 4 - 3', 3), @('100 / 4 / 5', 5), @('8 / 2 * 4', 16), @('7 % 3', 1), @('-7 % 3', 2),
    @('2 * 3 % 4', 2), @('2 * -3', -6), @('1 - -1', 2), @('-(3 + 4) * 2', -14), @('2 ^ -1', 0.5), @('1e3 + .5', 1000.5), @('2 + 3 > 4', 1), @('1 + 2 == 3', 1), @('1 || 0 && 0', 1),
    @('3 > 2 && 2 > 1', 1), @('3 > 2 && 2 < 1', 0), @('!0', 1), @('!5', 0), @('5 == 5', 1), @('5 != 5', 0), @('2 <= 2', 1), @('pi', [math]::PI), @('g', 9.81),
    @('abs(-3)', 3), @('abs ( -3 )', 3), @('sqrt(16)', 4), @('min(3, 1, 2)', 1), @('max(3, 1, 2)', 3), @('MAX(1, 2)', 2), @('round(2.5)', 3), @('round(-2.5)', -3), @('round(3.14159, 2)', 3.14),
    @('floor(-1.5)', -2), @('ceil(1.2)', 2), @('clamp(15, 0, 10)', 10), @('clamp(-5, 0, 10)', 0), @('hypot(3, 4)', 5), @('if(1 > 2, 10, 20)', 20), @('if(2 > 1, 10, 20)', 10),
    @('if(1, if(0, 1, 2), 3)', 2), @('atan2(1, 1)', [math]::Atan2(1, 1)), @('deg(pi)', 180), @('rad(180)', [math]::PI), @('sin(0)', 0), @('cos(0)', 1), @('ln(1)', 0), @('log10(1000)', 3),
    @('pow(2, 10)', 1024), @('sign(-4)', -1), @('exp(0)', 1))
  $chan = @(
    @('Speed * 3.6', 'kmh1', { param($W, $i) [double]$W['Speed'][$i] * 3.6 }),
    @('speed*3.6', 'kmh2', { param($W, $i) [double]$W['Speed'][$i] * 3.6 }),
    @('abs(SteeringWheelAngle)', 'abs', { param($W, $i) [math]::Abs([double]$W['SteeringWheelAngle'][$i]) }),
    @('kmh', 'der-kmh', { param($W, $i) [double]$W['Speed'][$i] * 3.6 }),
    @('[Lateral G]', 'br-latg', { param($W, $i) [double]$W['LatAccel'][$i] / 9.81 }),
    @('[Speed km/h] / 3.6', 'br-kmh', { param($W, $i) [double]$W['Speed'][$i] }),
    @('latG * 2 + 1', 'latg2', { param($W, $i) [double]$W['LatAccel'][$i] / 9.81 * 2 + 1 }),
    @('sqrt(LatAccel^2 + LongAccel^2) / g', 'gtot', { param($W, $i) [math]::Sqrt([double]$W['LatAccel'][$i] * $W['LatAccel'][$i] + [double]$W['LongAccel'][$i] * $W['LongAccel'][$i]) / 9.81 }),
    @('max(Throttle, Brake)', 'maxpedal', { param($W, $i) [math]::Max([double]$W['Throttle'][$i], [double]$W['Brake'][$i]) }),
    @('Speed - Speed', 'zero', { param($W, $i) 0.0 }),
    @('if(Speed > 50, 100 / Speed, 0)', 'lazy', { param($W, $i) if ([double]$W['Speed'][$i] -gt 50) { 100 / [double]$W['Speed'][$i] } else { 0.0 } }),
    @('slipRear', 'der-slip', { param($W, $i) $s = [double]$W['Speed'][$i]; $a = [single]$(if ($s -gt 8) { ([double]$W['LRspeed'][$i] - $s) / $s * 100 } else { 0 }); $b = [single]$(if ($s -gt 8) { ([double]$W['RRspeed'][$i] - $s) / $s * 100 } else { 0 }); ([double]$a + $b) / 2 }),
    @('beta', 'der-beta', { param($W, $i) [math]::Atan2([double]$W['VelocityY'][$i], [math]::Max(1.0, [double]$W['VelocityX'][$i])) * 57.2958 }))
  $errs = @(
    @('Spead * 2', 'Try Speed'), @('Speed *', 'expected a number or a channel name'), @('(Speed + 1', 'never closed'), @('Speed + 1)', 'no "\(" before'), @('abs(1, 2)', 'needs 1 value'),
    @('foo(3)', 'not a function'), @('', 'Type a formula'), @('3Speed', 'Write a \*'), @('Speed ** 2', 'expected a number or a channel name before "\*"'), @('1 = 1', 'Use =='),
    @('NoSuchChannel + 1', 'Unknown name'), @('Speed $ 2', 'did not expect'), @('max(1)', 'needs 2 to 8'), @('sqrt', 'is a function'), @('abs(', 'stops too early|never closed'),
    @('Speed Throttle', 'did not expect'), @('[Nothing here]', 'do not know the channel'), @('1/0', 'divides by zero at every point'), @('5 % 0', 'divides by zero'), @('ln(-1)', 'no value anywhere'),
    @(('(' * 60) + '1' + (')' * 60), 'brackets inside brackets'), @(('1+' * 250) + '1', 'too long'))
  $markerEsc = $marker -replace '\\', '\\'
  $hostile = @('System.Diagnostics.Process.Start("calc")', 'alert(1)', '1; 2', 'Speed; Remove-Item *', '$(whoami)', '`calc`', '__import__("os").system("calc")', 'eval("1")', 'Speed + (new Object)', '"abc"', 'x = 1',
    "System.IO.File.WriteAllText(`"$markerEsc`", `"x`")", 'Process.Start', '..\..\Windows', '{1}', 'Speed.ToString()', 'new', 'a => a')
  $all = @(); $all += $consts | ForEach-Object { 'c' + "`t`t" + $_[0] }; $all += $chan | ForEach-Object { 'n' + "`tu`t" + $_[0] }; $all += $errs | ForEach-Object { 'e' + "`t`t" + $_[0] }; $all += $hostile | ForEach-Object { 'h' + "`t`t" + $_ }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $mb = Invoke-Maths $all 'maths'
  Note "$($all.Count) formulas worked out in one run: $($sw.ElapsedMilliseconds) ms (the file is read for each one)"
  Check 'the one-shot run finished (exit 0) and answered every formula' ($mb.exit -eq 0 -and $mb.res.Count -eq $all.Count)
  $ix = 0
  # constants
  $bad = @(); for ($k = 0; $k -lt $consts.Count; $k++) {
    $r = $mb.res[$ix++]
    if (-not $r.ok) { $bad += "$($consts[$k][0]) -> $($r.error)"; continue }
    $a = $r.arr[('lap.' + $r.head.channels[0].key)]; $want = [double]$consts[$k][1]
    if (-not ((Near $a[0] $want (1e-5 * [math]::Max(1, [math]::Abs($want)))) -and (Near $a[$a.Length - 1] $want (1e-5 * [math]::Max(1, [math]::Abs($want)))))) { $bad += "$($consts[$k][0]) = $($a[0]) (wanted $want)" }
  }
  if ($bad.Count) { Note ('wrong: ' + ($bad -join ' | ')) }
  Check "precedence, brackets, left and right association, comparisons, logic and the functions give the hand-worked answers ($($consts.Count) formulas)" ($bad.Count -eq 0)
  # channels: against the lap's own reply, point by point, lap and reference
  $bad = @(); $worst = 0.0
  foreach ($c in $chan) {
    $r = $mb.res[$ix++]
    if (-not $r.ok) { $bad += "$($c[0]) -> $($r.error)"; continue }
    $key = $r.head.channels[0].key; $la = $r.arr["lap.$key"]; $ra = $r.arr["ref.$key"]
    $Wl = @{}; $Wr = @{}; foreach ($nm in 'Speed', 'SteeringWheelAngle', 'LatAccel', 'LongAccel', 'Throttle', 'Brake', 'LRspeed', 'RRspeed', 'VelocityX', 'VelocityY') { $Wl[$nm] = $WA["lap.$nm"]; $Wr[$nm] = $WA["ref.$nm"] }
    $md = 0.0
    for ($i = 0; $i -lt $n; $i += 1) {
      $e1 = & $c[2] $Wl $i; $e2 = & $c[2] $Wr $i
      $d1 = [math]::Abs([double]$la[$i] - $e1) / [math]::Max(1.0, [math]::Abs($e1)); $d2 = [math]::Abs([double]$ra[$i] - $e2) / [math]::Max(1.0, [math]::Abs($e2))
      if ($d1 -gt $md) { $md = $d1 }; if ($d2 -gt $md) { $md = $d2 }
    }
    if ($md -gt 2e-6) { $bad += "$($c[0]) differs by $md" }
    if ($md -gt $worst) { $worst = $md }
    if ($c[1] -eq 'lazy' -and $r.head.blank -ne 0) { $bad += 'if(Speed > 50, 100 / Speed, 0) must not divide in the branch that is not taken' }
  }
  if ($bad.Count) { Note ('wrong: ' + ($bad -join ' | ')) }
  Note "largest relative difference against an independent calculation of the same formula: $($worst.ToString('0.0e+0'))"
  Check "13 formulas on channels agree point by point with an independent calculation (lap and reference, $n points each): Speed * 3.6, abs(SteeringWheelAngle), [Lateral G], derived kmh / slipRear / beta, if() ..." ($bad.Count -eq 0)
  # a formula that divides by zero in some places: blanks exactly there, said in words
  $r = (Invoke-Maths @("inv`t`t1 / Brake", "rt`t`tsqrt(LatAccel)", "same`tunit x`tSpeed * 3.6") 'blanks').res
  $brake = $WA['lap.Brake']; $lat = $WA['lap.LatAccel']
  $zeros = 0; $neg = 0; for ($i = 0; $i -lt $n; $i++) { if ($brake[$i] -eq 0) { $zeros++ }; if ($lat[$i] -lt 0) { $neg++ } }
  $ia = $r[0].arr['lap.' + $r[0].head.channels[0].key]; $blank = 0; $wrongBlank = 0
  $tooBig = 0   # a Brake of 1e-40 gives 1e40, more than a Float32 can hold: that is blank too
  for ($i = 0; $i -lt $n; $i++) { $b0 = [double]$brake[$i]; $want = ($b0 -eq 0) -or ($b0 -ne 0 -and [math]::Abs(1.0 / $b0) -gt 3.4028234e38); if ($b0 -ne 0 -and $want) { $tooBig++ }; $isn = [single]::IsNaN($ia[$i]); if ($isn) { $blank++ }; if ($isn -ne $want) { $wrongBlank++ } }
  Check "1 / Brake leaves a blank exactly where Brake is 0 ($zeros of $n points; $tooBig more where 1 / Brake is too big for a float), the rest is a number, and the reply says so in words" ($r[0].ok -and $blank -eq ($zeros + $tooBig) -and $wrongBlank -eq 0 -and $r[0].head.blank -eq ($zeros + $tooBig) -and $r[0].head.note -like '*division by zero*')
  for ($i = 0; $i -lt $n; $i++) { if (-not [single]::IsNaN($ia[$i]) -and [single]::IsInfinity($ia[$i])) { $wrongBlank++ } }
  Check 'no infinity is ever sent: a value that overflows is a blank, never +Infinity' ($wrongBlank -eq 0)
  $ra2 = $r[1].arr['lap.' + $r[1].head.channels[0].key]; $blank2 = 0; for ($i = 0; $i -lt $n; $i++) { if ([single]::IsNaN($ra2[$i])) { $blank2++ } }
  Check "sqrt(LatAccel) is blank exactly where LatAccel is negative ($neg points)" ($r[1].ok -and $blank2 -eq $neg -and $r[1].head.note -like '*no value*')
  Check 'the reply names the channel (key m_<name>), keeps the unit and the formula text, and carries the reference lap too' ($r[2].ok -and $r[2].head.channels[0].key -eq 'm_same' -and $r[2].head.channels[0].unit -eq 'unit x' -and $r[2].head.channels[0].desc -eq 'Speed * 3.6' -and $r[2].arr.ContainsKey('ref.m_same') -and $r[2].arr.ContainsKey('lap.t'))
  # errors
  $bad = @(); $words = $true
  foreach ($e in $errs) {
    $r = $mb.res[$ix++]
    if ($r.ok) { $bad += "$($e[0].Substring(0, [math]::Min(30, $e[0].Length))) was accepted"; continue }
    if ($r.error -notmatch $e[1]) { $bad += "'$($e[0].Substring(0, [math]::Min(30, $e[0].Length)))' said: $($r.error)" }
    if ($r.error -match 'Exception|System\.|   at |NullReference|IRDash' -or $r.error.Length -lt 12) { $words = $false; $bad += "not plain words: $($r.error)" }
  }
  if ($bad.Count) { Note ('wrong: ' + ($bad -join ' | ')) }
  Check "every mistake ($($errs.Count) kinds: unknown name with a suggestion, unclosed or extra bracket, wrong argument count, unknown function, empty, 3Speed, **, =, division by zero everywhere, too long, too deep) is refused with its own sentence" ($bad.Count -eq 0)
  Check 'no error message shows a stack trace or a class name (plain words only)' $words
  # nothing runs
  $bad = @(); foreach ($hx in $hostile) { $r = $mb.res[$ix++]; if ($r.ok) { $bad += "ACCEPTED: $hx" } }
  if ($bad.Count) { Note ($bad -join ' | ') }
  Check "$($hostile.Count) hostile formulas (process start, file write, script, eval, shell, lambda, member calls) are all refused" ($bad.Count -eq 0)
  Check 'the formula that would have written a file did not write it (nothing is evaluated by the runtime)' (-not (Test-Path -LiteralPath $marker))
  $src = Get-Content (Join-Path $root 'dash\src\protools.cs') -Raw -Encoding UTF8
  Check 'protools.cs has no eval-like machinery: no Process, Reflection, CodeDom, ScriptEngine, Assembly.Load, Activator or JavaScript eval' ($src -notmatch 'System\.Diagnostics|Reflection|CodeDom|ScriptEngine|Assembly\.Load|Activator|\.Invoke\(|Process\.Start')
  $js = Get-Content (Join-Path $root 'dash\www\v2\workbench-pro.js') -Raw -Encoding UTF8
  Check 'workbench-pro.js has no eval, new Function or setTimeout-with-a-string' ($js -notmatch '\beval\s*\(|new Function|setTimeout\s*\(\s*["'']|setInterval\s*\(\s*["'']')

  Section '4. saved per car: save, list, replace, delete, the limit'
  New-Item -ItemType Directory -Force $store | Out-Null
  $r = Invoke-Pro 'save' "--car `"$car`" --name `"A, B @x`" --unit `"km/h`" --expr `"max(Speed, 20) * 3.6`"" 's1'
  $j = [Text.Encoding]::UTF8.GetString($r.bytes) | ConvertFrom-Json
  Check 'saving keeps the commas inside the formula and cleans the name (no comma, no @)' ($r.exit -eq 0 -and @($j.formulas).Count -eq 1 -and $j.formulas[0].name -eq 'A B x' -and $j.formulas[0].expr -eq 'max(Speed, 20) * 3.6' -and $j.formulas[0].unit -eq 'km/h' -and $j.formulas[0].key -eq 'm_a_b_x')
  $null = Invoke-Pro 'save' "--car `"$car`" --name `"second`" --unit `"`" --expr `"Throttle * 100`"" 's2'
  $r = Invoke-Pro 'save' "--car `"$car`" --name `"a b X`" --unit `"`" --expr `"Brake * 100`"" 's3'
  $j = [Text.Encoding]::UTF8.GetString($r.bytes) | ConvertFrom-Json
  Check 'saving the same name again (any capitals) replaces it and keeps the order' (@($j.formulas).Count -eq 2 -and $j.formulas[0].expr -eq 'Brake * 100' -and $j.formulas[1].name -eq 'second')
  $other = Invoke-Pro 'formulas' "--car `"Ferrari 296 GT3`"" 's4'
  Check 'another car has its own (empty) list' (([Text.Encoding]::UTF8.GetString($other.bytes) | ConvertFrom-Json).formulas.Count -eq 0)
  $f = Get-ChildItem $store -Filter '*.txt' | Select-Object -First 1
  Check 'the list is a small text file per car (data\maths\<car>.txt, one formula a line)' ($f -and $f.Name -eq 'chevrolet-corvette-z06-gt3-r.txt' -and @(Get-Content $f.FullName).Count -eq 2)
  $r = Invoke-Pro 'delete' "--car `"$car`" --name `"SECOND`"" 's5'
  Check 'delete removes one formula (name matched without capitals)' ((([Text.Encoding]::UTF8.GetString($r.bytes)) | ConvertFrom-Json).formulas.Count -eq 1)
  for ($k = 0; $k -lt 11; $k++) { $null = Invoke-Pro 'save' "--car `"$car`" --name `"f$k`" --unit `"`" --expr `"Speed + $k`"" "s6$k" }
  $r = Invoke-Pro 'save' "--car `"$car`" --name `"one too many`" --unit `"`" --expr `"Speed`"" 's7'
  Check '12 formulas is the most for one car; the 13th is refused in words' ($r.exit -eq 1 -and [Text.Encoding]::UTF8.GetString($r.bytes) -like '*12 maths channels*')
  Remove-Item -LiteralPath $store -Recurse -Force; New-Item -ItemType Directory -Force $store | Out-Null

  Section '5. export: CSV equals /analysis/channels, and the .xlsx is a real workbook with the same numbers'
  $null = Invoke-Pro 'save' "--car `"$car`" --name `"Speed km/h`" --unit `"km/h`" --expr `"Speed * 3.6`"" 'e1'
  $null = Invoke-Pro 'save' "--car `"$car`" --name `"Inverse brake`" --unit `"`" --expr `"1 / Brake`"" 'e2'
  $chList = 'Speed,Gear,RPM,kmh,latG,slipRear,@Speed km/h,@Inverse brake,NoSuchChannel'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $rc = Invoke-Pro 'export' "--fmt csv --ch `"$chList`" --which both" 'x-csv'
  Note "CSV export, process start included: $($sw.ElapsedMilliseconds) ms, $([math]::Round($rc.bytes.Length / 1KB)) KB"
  Check 'the CSV export ran (exit 0)' ($rc.exit -eq 0 -and $rc.bytes.Length -gt 100000)
  $csv = [Text.Encoding]::UTF8.GetString($rc.bytes)
  Check 'CSV is plain UTF-8 (no byte-order mark) with CRLF lines' ($rc.bytes[0] -ne 0xEF -and $csv.Contains("`r`n"))
  $lines = $csv.Split("`n") | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -ne '' }
  $hdr = $lines[0].Split(',')
  Note ('header: ' + ($hdr -join ' | '))
  Check 'one header row, then one row per sample (n = 4058)' ($lines.Count -eq $n + 1)
  $want = @('Distance (m)', 'Time (s) lap 7', 'Time (s) ref 7', 'Speed (m/s) lap 7', 'Speed (m/s) ref 7', 'Gear lap 7', 'Gear ref 7', 'RPM (revs/min) lap 7', 'RPM (revs/min) ref 7', 'Speed (km/h) lap 7', 'Speed (km/h) ref 7', 'Lateral G (g) lap 7', 'Lateral G (g) ref 7', 'Rear wheel slip (%) lap 7', 'Rear wheel slip (%) ref 7', 'Speed km/h (km/h) lap 7', 'Speed km/h (km/h) ref 7', 'Inverse brake lap 7', 'Inverse brake ref 7')
  Check 'the header names every column with its unit from the file (Speed (m/s), RPM (revs/min)), derived channels with theirs, maths channels with their own, lap and reference side by side' (($hdr -join '|') -eq ($want -join '|'))
  $rows = New-Object 'string[][]' $n; for ($i = 0; $i -lt $n; $i++) { $rows[$i] = $lines[$i + 1].Split(',') }
  Check 'every row has a value or a blank for every column' (@($rows | Where-Object { $_.Count -ne $hdr.Count }).Count -eq 0)
  function Col-Index($name) { return [array]::IndexOf($hdr, $name) }
  function Sg($s) { return [single]::Parse($s, $inv) }
  # distance
  $dc = Col-Index 'Distance (m)'; $d0 = [double]::Parse($rows[0][$dc], $inv); $dN = [double]::Parse($rows[$n - 1][$dc], $inv); $mono = $true
  for ($i = 1; $i -lt $n; $i++) { if ([double]::Parse($rows[$i][$dc], $inv) -le [double]::Parse($rows[$i - 1][$dc], $inv)) { $mono = $false; break } }
  Check "distance runs from 0 to the track length ($($h.lengthM) m) in steps of about 1 m" ($d0 -eq 0 -and (Near $dN $L 0.06) -and $mono -and (Near ([double]::Parse($rows[1][$dc], $inv)) $h.step 0.001))
  # raw columns = the reply, exactly (a float round-trips through its text)
  $exact = $true; $detail = ''
  foreach ($pair in @(@('Time (s) lap 7', 'lap.t'), @('Time (s) ref 7', 'ref.t'), @('Speed (m/s) lap 7', 'lap.Speed'), @('Speed (m/s) ref 7', 'ref.Speed'), @('Gear lap 7', 'lap.Gear'), @('Gear ref 7', 'ref.Gear'), @('RPM (revs/min) lap 7', 'lap.RPM'), @('RPM (revs/min) ref 7', 'ref.RPM'))) {
    $ci = Col-Index $pair[0]; $arr = $WA[$pair[1]]
    for ($i = 0; $i -lt $n; $i++) { if ((Sg $rows[$i][$ci]) -ne $arr[$i]) { $exact = $false; $detail = "$($pair[0]) row $i : $($rows[$i][$ci]) against $($arr[$i])"; break } }
    if (-not $exact) { break }
  }
  if ($detail) { Note $detail }
  Check "Speed, Gear, RPM and both time axes of the CSV equal the /analysis/channels reply exactly, all $n rows, lap and reference" $exact
  # derived columns: the same formula worked out here
  $bad = 0; $ci1 = Col-Index 'Speed (km/h) lap 7'; $ci2 = Col-Index 'Lateral G (g) ref 7'; $ci3 = Col-Index 'Speed km/h (km/h) lap 7'
  for ($i = 0; $i -lt $n; $i++) {
    if (-not (Near (Sg $rows[$i][$ci1]) ([double]$WA['lap.Speed'][$i] * 3.6) 1e-4)) { $bad++ }
    if (-not (Near (Sg $rows[$i][$ci2]) ([double]$WA['ref.LatAccel'][$i] / 9.81) 1e-5)) { $bad++ }
    if (-not (Near (Sg $rows[$i][$ci3]) ([double]$WA['lap.Speed'][$i] * 3.6) 1e-4)) { $bad++ }
  }
  Check 'the derived Speed (km/h), Lateral G and the maths channel Speed km/h (all from the saved formula) equal the independent calculation in every row' ($bad -eq 0)
  $ci4 = Col-Index 'Inverse brake lap 7'; $blanks = 0; $wrong = 0; $firstBad = ''
  for ($i = 0; $i -lt $n; $i++) {
    $b0 = [double]$WA['lap.Brake'][$i]; $isBlank = $rows[$i][$ci4] -eq ''; if ($isBlank) { $blanks++ }
    $want = ($b0 -eq 0) -or [math]::Abs(1.0 / $b0) -gt 3.4028234e38
    if ($isBlank -ne $want) { $wrong++; if (-not $firstBad) { $firstBad = "row $i brake $b0 cell '$($rows[$i][$ci4])' want blank: $want" } }
    elseif (-not $isBlank -and -not (Near (Sg $rows[$i][$ci4]) (1.0 / $b0) (1e-6 * [math]::Max(1.0, [math]::Abs(1.0 / $b0))))) { $wrong++; if (-not $firstBad) { $firstBad = "row $i brake $b0 cell '$($rows[$i][$ci4])' against $(1.0 / $b0)" } }
  }
  if ($firstBad) { Note $firstBad }
  Check "the maths channel 1 / Brake is blank in the CSV exactly where Brake is 0 or too big ($blanks rows) and 1 / Brake elsewhere" ($wrong -eq 0 -and $blanks -gt 100)
  # hand check against the raw records
  $names = @('SessionTime', 'LapDistPct', 'Speed'); $raw = [ProRaw]::All((Join-Path $work $pbName), $names)
  $ixr = New-Object System.Collections.Generic.List[int]; for ($i = 0; $i -lt $raw['Lap'].Length; $i++) { if ($raw['IsOnTrack'][$i] -ne 0 -and [int]$raw['Lap'][$i] -eq 7) { $ixr.Add($i) } }
  $row = 1500; $target = [double]::Parse($rows[$row][$dc], $inv); $j = -1
  for ($k = 1; $k -lt $ixr.Count; $k++) { if ($raw['LapDistPct'][$ixr[$k]] * $L -ge $target) { $j = $k; break } }
  $r0 = $ixr[$j - 1]; $r1 = $ixr[$j]; $d0r = $raw['LapDistPct'][$r0] * $L; $d1r = $raw['LapDistPct'][$r1] * $L; $fr = ($target - $d0r) / ($d1r - $d0r)
  $hand = $raw['Speed'][$r0] + ($raw['Speed'][$r1] - $raw['Speed'][$r0]) * $fr
  $got = [double](Sg $rows[$row][(Col-Index 'Speed (m/s) lap 7')])
  Note "HAND CHECK row $row ($target m): the raw .ibt records give $([math]::Round($hand, 3)) m/s, the CSV $([math]::Round($got, 3)) m/s ($([math]::Round($got * 3.6, 1)) km/h)"
  Check 'the speed at that metre in the CSV matches the raw 60 Hz records within 0.05 m/s' (Near $got $hand 0.05)
  # which laps
  $rl = Invoke-Pro 'export' "--fmt csv --ch Speed,kmh --which lap" 'x-lap'; $hl = ([Text.Encoding]::UTF8.GetString($rl.bytes).Split("`n")[0]).TrimEnd("`r")
  $rr = Invoke-Pro 'export' "--fmt csv --ch Speed,kmh --which ref" 'x-ref'; $hr = ([Text.Encoding]::UTF8.GetString($rr.bytes).Split("`n")[0]).TrimEnd("`r")
  Check 'which=lap writes only the lap columns, which=ref only the reference columns' ($hl -eq 'Distance (m),Time (s) lap 7,Speed (m/s) lap 7,Speed (km/h) lap 7' -and $hr -eq 'Distance (m),Time (s) ref 7,Speed (m/s) ref 7,Speed (km/h) ref 7')
  $rd = Invoke-Pro 'export' "--fmt csv --which both" 'x-def'; $hd = ([Text.Encoding]::UTF8.GetString($rd.bytes).Split("`n")[0]).TrimEnd("`r").Split(',')
  Check 'with no channel list the export is the standard set: speed, throttle, brake, steering, gear, RPM, lateral and longitudinal g, slip angle, wheel force' ($hd.Count -eq 3 + 2 * 10 -and $hd -contains 'Throttle (%) lap 7' -and $hd -contains 'Steering angle (deg) lap 7' -and $hd -contains 'Wheel force (%) ref 7')

  # ---- the .xlsx ----
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $rx = Invoke-Pro 'export' "--fmt xlsx --ch `"$chList`" --which both" 'x-xlsx'
  Note "xlsx export, process start included: $($sw.ElapsedMilliseconds) ms, $([math]::Round($rx.bytes.Length / 1KB)) KB"
  $xl = Join-Path $work 'lap7.xlsx'; [IO.File]::WriteAllBytes($xl, $rx.bytes)
  Check 'the .xlsx export ran (exit 0) and is a zip (PK header)' ($rx.exit -eq 0 -and $rx.bytes[0] -eq 0x50 -and $rx.bytes[1] -eq 0x4B -and $rx.bytes.Length -gt 50000)
  $zip = [IO.Compression.ZipFile]::OpenRead($xl)
  try {
    $names = @($zip.Entries | ForEach-Object { $_.FullName })
    Note ('parts: ' + ($names -join ', '))
    Check 'the workbook has the parts Excel needs: [Content_Types].xml, _rels/.rels, xl/workbook.xml, its rels, xl/styles.xml, two sheets' ((@('[Content_Types].xml', '_rels/.rels', 'xl/workbook.xml', 'xl/_rels/workbook.xml.rels', 'xl/styles.xml', 'xl/worksheets/sheet1.xml', 'xl/worksheets/sheet2.xml') | Where-Object { $names -notcontains $_ }).Count -eq 0)
    $wellFormed = $true; $why = ''
    foreach ($e in $zip.Entries) { try { $sr = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8); $x = New-Object Xml.XmlDocument; $x.LoadXml($sr.ReadToEnd()); $sr.Dispose() } catch { $wellFormed = $false; $why = "$($e.FullName): $($_.Exception.Message)" } }
    if ($why) { Note $why }
    Check 'every part is well-formed XML' $wellFormed
    $sr = New-Object IO.StreamReader($zip.GetEntry('xl/workbook.xml').Open()); $wb = $sr.ReadToEnd(); $sr.Dispose()
    Check 'sheet 1 is named after the lap ("Lap 7"), sheet 2 is "Info"' ($wb -match 'name="Lap 7"' -and $wb -match 'name="Info"')
    $sr = New-Object IO.StreamReader($zip.GetEntry('xl/worksheets/sheet1.xml').Open()); $s1 = $sr.ReadToEnd(); $sr.Dispose()
    Check 'the header row is frozen and bold, the dimension is A1:S4059 (19 columns, 4058 rows and the header)' ($s1 -match 'state="frozen"' -and $s1 -match 's="1"' -and $s1 -match 'ref="A1:S4059"')
    $cells = [ProXlsx]::Cells($zip.GetEntry('xl/worksheets/sheet1.xml').Open())
    $hdrOk = $true
    for ($c = 0; $c -lt $hdr.Count; $c++) { $hk = [ProXlsx]::Col($c) + '1'; $hv = $cells[$hk]; if ($hv -ne $hdr[$c]) { $hdrOk = $false; Note ('header ' + $c + ' : ' + $hv + ' against ' + $hdr[$c]) } }
    Check 'the header cells are the CSV header, unit by unit' $hdrOk
    $diff = 0; $blankOk = 0; $first = ''
    for ($i = 0; $i -lt $n; $i++) {
      for ($c = 0; $c -lt $hdr.Count; $c++) {
        $ref = [ProXlsx]::Col($c) + ($i + 2); $csvText = $rows[$i][$c]
        if ($csvText -eq '') { if ($cells.ContainsKey($ref)) { $diff++; if (-not $first) { $first = "$ref should be empty" } } else { $blankOk++ } }
        elseif (-not $cells.ContainsKey($ref) -or $cells[$ref] -ne $csvText) { $diff++; if (-not $first) { $first = "$ref : $($cells[$ref]) against $csvText" } }
      }
    }
    if ($first) { Note $first }
    Check "every one of the $($n * $hdr.Count) numbers in the .xlsx is the CSV's number ($blankOk blank cells stay empty cells)" ($diff -eq 0 -and $blankOk -gt 100)
    $info = [ProXlsx]::Cells($zip.GetEntry('xl/worksheets/sheet2.xml').Open()); $infoText = ($info.Values -join ' | ')
    Check 'the Info sheet names the car, the track, the lap, its time, the reference lap and each channel''s unit and formula' ($infoText -like "*$car*" -and $infoText -like '*Road Atlanta*' -and $infoText -like '*79.549*' -and $infoText -like '*79.575*' -and $infoText -like '*Speed * 3.6*' -and $infoText -like '*maths channel*' -and $infoText -like '*km/h*')
    Check 'a channel the car''s file does not have is left out and said so on the Info sheet' ($infoText -like '*Left out NoSuchChannel*')
  } finally { $zip.Dispose() }
  # the package opens with .NET's own OPC reader (content types and relationships resolve)
  $pkgOk = $false; $partCount = 0
  try { $pk = [IO.Packaging.Package]::Open($xl, [IO.FileMode]::Open, [IO.FileAccess]::Read); $partCount = @($pk.GetParts()).Count; $rel = @($pk.GetRelationshipsByType('http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument')); $pkgOk = $rel.Count -eq 1 -and $partCount -ge 5; $pk.Close() } catch { Note $_.Exception.Message }
  Check "System.IO.Packaging opens it as an Office package ($partCount parts, the workbook is the office document)" $pkgOk

  # ------------------------------------------------------------------------------------------------------------------------------
  # the page, live: needs the deployed irdash (dash\build.ps1) - the lead's deploy puts the routes there
  # ------------------------------------------------------------------------------------------------------------------------------
  Section '6. the pro routes on the running irdash'
  # irdash answers 503 while a session is on the track (also a pretend one another test runs through the test hook): wait for it to end, up to 5 minutes
  function Wait-NotDriving {
    for ($w = 0; $w -lt 100; $w++) {
      $code = 0; try { $null = Invoke-WebRequest -UseBasicParsing 'http://localhost:8199/analysis/pro/export?id=x&lap=99' -TimeoutSec 10 } catch { try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 } }
      if ($code -ne 503) { return }
      if ($w -eq 0) { Note 'irdash says a session is on the track (503): waiting for it to end' }
      Assert-RigFree -Where 'waiting for the track to be free'; Start-Sleep -Seconds 3
    }
  }
  Wait-NotDriving
  $srcStamp = (Get-Item -LiteralPath (Join-Path $root 'dash\src\protools.cs')).LastWriteTimeUtc
  $deployed = (Get-Item -LiteralPath $shipped).LastWriteTimeUtc -gt $srcStamp
  $up = $false
  if ($deployed -and (Get-Process irdash -ErrorAction SilentlyContinue)) { try { $r = Invoke-WebRequest -UseBasicParsing ('http://localhost:8199/analysis/pro/formulas?scratch=1&car=' + [uri]::EscapeDataString($car)) -TimeoutSec 5; $up = $r.StatusCode -eq 200 } catch { } }
  if (-not $up) { Note "skipped: irdash.exe $(if ($deployed) { 'is deployed' } else { 'is older than protools.cs' }) but the pro routes do not answer - run dash\build.ps1 (when sim=False) and this test again"; Check 'the live part ran (it needs the deployed irdash)' $false }
  else {
    $docFile = Join-Path $docTel $pbName
    $idq = [uri]::EscapeDataString($pbName)
    $base = 'http://localhost:8199/analysis/pro'
    $rj = Invoke-WebRequest -UseBasicParsing ("$base/formulas?scratch=1&car=" + [uri]::EscapeDataString($car)) -TimeoutSec 10
    $startList = @(($rj.Content | ConvertFrom-Json).formulas)
    Check 'GET /analysis/pro/formulas answers 200 JSON with the (scratch) list for the car' ($rj.StatusCode -eq 200 -and $rj.Content.Contains('"formulas":['))
    $rm = Invoke-WebRequest -UseBasicParsing "$base/maths?id=$idq&lap=7&ref=pb&name=T&expr=$([uri]::EscapeDataString('Speed * 3.6'))&unit=km%2Fh" -TimeoutSec 60
    $mb2 = $rm.RawContentStream.ToArray()
    Check 'GET /analysis/pro/maths answers 200 with the PWB1 binary (the same layout as /analysis/channels)' ($rm.StatusCode -eq 200 -and [Text.Encoding]::ASCII.GetString($mb2, 0, 4) -eq 'PWB1')
    $be = 0; try { $null = Invoke-WebRequest -UseBasicParsing "$base/maths?id=$idq&lap=7&ref=pb&name=T&expr=$([uri]::EscapeDataString('Spead * 2'))" -TimeoutSec 30 } catch { $be = [int]$_.Exception.Response.StatusCode; $body = [string]$_.ErrorDetails.Message }
    Check 'a wrong formula is HTTP 400 with the sentence in JSON' ($be -eq 400 -and $body -like '*Try Speed*')
    $rx2 = Invoke-WebRequest -UseBasicParsing "$base/export?id=$idq&lap=7&ref=pb&fmt=xlsx&scratch=1&ch=Speed,kmh,latG" -TimeoutSec 90
    $cd = [string]$rx2.Headers['Content-Disposition']
    Check 'GET /analysis/pro/export?fmt=xlsx is a file download (xlsx content type, attachment, a sensible name)' ($rx2.StatusCode -eq 200 -and $rx2.Headers['Content-Type'] -like '*spreadsheetml.sheet*' -and $cd -like 'attachment; filename="Paddock-Road-Atlanta-lap7-2026-10-10.xlsx"')
    $rc2 = Invoke-WebRequest -UseBasicParsing "$base/export?id=$idq&lap=7&ref=pb&fmt=csv&ch=Speed,kmh,latG&which=lap" -TimeoutSec 90
    Check 'fmt=csv is text/csv with its own file name; the first line is the header' ($rc2.Headers['Content-Type'] -like 'text/csv*' -and ([string]$rc2.Headers['Content-Disposition']) -like '*Paddock-Road-Atlanta-lap7-2026-10-10.csv*' -and $rc2.Content.StartsWith('Distance (m),Time (s) lap 7,Speed (m/s) lap 7,Speed (km/h) lap 7,Lateral G (g) lap 7'))
    $none = 0; try { $null = Invoke-WebRequest -UseBasicParsing "$base/export?id=$idq&lap=99&ref=pb" -TimeoutSec 30 } catch { $none = [int]$_.Exception.Response.StatusCode }
    Check 'a lap that is not in the file is refused (404), not a half file' ($none -eq 404)

    Section '7. the PRO page in headless Chrome: tab rule, X/Y scatter, histogram, maths channels, export, pictures'
    Wait-NotDriving
    $pageUrl = "http://localhost:8199/v2/workbench.html?id=$idq&lap=7&scratch=1&nodl=1"
    Cdp-Goto ($pageUrl + '&page=pro')
    $pages = @(Cdp-Json 'WB.pages()')
    Check "the PRO tab is there when the server answers, after the others ($($pages -join ' '))" ($pages -contains 'pro' -and $pages[-1] -eq 'pro')
    Check 'the page opened on it (&page=pro), the tab row shows PRO, the deck is told the page list' ((Cdp-Eval 'WB.state.page') -eq 'pro' -and (Cdp-Eval 'document.getElementById("tabs").innerText') -match 'PRO' -and (Cdp-Eval 'WB.deck()') -match 'pgs=[^&]*pro')
    $panels = @(Cdp-Json 'WB.pro.panels()')
    Check "the page has its four displays: X/Y, histogram, maths, export ($($panels -join ' '))" (($panels -contains 'xy') -and ($panels -contains 'hist') -and ($panels -contains 'maths') -and ($panels -contains 'exp'))

    # ---- X/Y: points and fit against an independent computation ----
    $xy = Cdp-Json 'WB.pro.xy()'
    Check 'it opens on LATERAL G v SPEED (the size of lateral g against km/h) with a curve of order 2' ($xy.x -eq 'kmh' -and $xy.y -eq 'latG' -and $xy.ay -eq $true -and $xy.order -eq 2)
    $xs = New-Object 'double[]' $n; $ys = New-Object 'double[]' $n
    for ($i = 0; $i -lt $n; $i++) { $xs[$i] = [double][single]([double]$WA['lap.Speed'][$i] * 3.6); $ys[$i] = [math]::Abs([double][single]([double]$WA['lap.LatAccel'][$i] / 9.81)) }
    $bad = 0; $maxd = 0.0
    for ($k = 0; $k -lt $xy.lap.x.Count; $k++) { $i = $xy.lap.idx[$k]; $d1 = [math]::Abs($xy.lap.x[$k] - $xs[$i]); $d2 = [math]::Abs($xy.lap.y[$k] - $ys[$i]); if ($d1 -gt $maxd) { $maxd = $d1 }; if ($d2 -gt $maxd) { $maxd = $d2 }; if ($d1 -gt 1e-6 -or $d2 -gt 1e-6) { $bad++ } }
    Check "the plotted points are the lap's own: all $($xy.lap.n) (x = Speed x 3.6, y = |LatAccel / 9.81|) equal the values worked out here from the channel reply (largest difference $maxd)" ($bad -eq 0 -and $xy.lap.n -eq $n)
    $fit = [ProLsq]::Fit($xs, $ys, 2); $r2 = [ProLsq]::R2($xs, $ys, $fit)
    $rel = 0.0; for ($k = 0; $k -lt 3; $k++) { $rel = [math]::Max($rel, [math]::Abs($xy.lap.fit.coef[$k] - $fit[$k]) / [math]::Max(1e-9, [math]::Abs($fit[$k]))) }
    Note "fit order 2 (page): $($xy.lap.fit.coef -join ', ') R2 $($xy.lap.fit.r2); independent Householder QR: $($fit -join ', ') R2 $r2"
    Check 'the curve of order 2 (all 3 coefficients) and R2 equal an independent Householder-QR least squares to 1e-6' ($rel -lt 1e-6 -and (Near $xy.lap.fit.r2 $r2 1e-9))
    $xr = New-Object 'double[]' $n; $yr = New-Object 'double[]' $n
    for ($i = 0; $i -lt $n; $i++) { $xr[$i] = [double][single]([double]$WA['ref.Speed'][$i] * 3.6); $yr[$i] = [math]::Abs([double][single]([double]$WA['ref.LatAccel'][$i] / 9.81)) }
    $fr = [ProLsq]::Fit($xr, $yr, 2); $rel = 0.0; for ($k = 0; $k -lt 3; $k++) { $rel = [math]::Max($rel, [math]::Abs($xy.ref.fit.coef[$k] - $fr[$k]) / [math]::Max(1e-9, [math]::Abs($fr[$k]))) }
    Check 'the reference lap has its own curve, equal to the independent fit too' ($rel -lt 1e-6 -and (Near $xy.ref.fit.r2 ([ProLsq]::R2($xr, $yr, $fr)) 1e-9))
    # hand checks: a straight line by the textbook formulas, and a line that must come out exactly
    $null = Cdp-Eval 'WB.pro.setXY({x:"kmh", y:"latG", ay:true, order:1})'; Start-Sleep -Milliseconds 300
    $x1 = Cdp-Json 'WB.pro.xy()'
    $mx = 0.0; $my = 0.0; for ($i = 0; $i -lt $n; $i++) { $mx += $xs[$i]; $my += $ys[$i] }; $mx /= $n; $my /= $n
    $sxy = 0.0; $sxx = 0.0; $syy = 0.0; for ($i = 0; $i -lt $n; $i++) { $sxy += ($xs[$i] - $mx) * ($ys[$i] - $my); $sxx += ($xs[$i] - $mx) * ($xs[$i] - $mx); $syy += ($ys[$i] - $my) * ($ys[$i] - $my) }
    $slope = $sxy / $sxx; $icpt = $my - $slope * $mx; $rr = $sxy * $sxy / ($sxx * $syy)
    Note "HAND CHECK order 1: slope = Sxy / Sxx = $slope, intercept = ymean - slope xmean = $icpt, R2 = Sxy^2 / (Sxx Syy) = $rr  (page: $($x1.lap.fit.coef[1]), $($x1.lap.fit.coef[0]), $($x1.lap.fit.r2))"
    Check 'HAND CHECK: the straight line by the textbook formulas (slope Sxy/Sxx, intercept, R2 = r squared) equals the page''s order-1 curve' ((Near $x1.lap.fit.coef[1] $slope 1e-9) -and (Near $x1.lap.fit.coef[0] $icpt 1e-7) -and (Near $x1.lap.fit.r2 $rr 1e-9))
    $null = Cdp-Eval 'WB.pro.setXY({x:"Speed", y:"kmh", ay:false, ax:false, order:1})'; Start-Sleep -Milliseconds 300
    $x2 = Cdp-Json 'WB.pro.xy()'
    Check 'HAND CHECK: km/h against m/s is the line y = 3.6 x exactly (slope 3.6, intercept 0, R2 = 1)' ((Near $x2.lap.fit.coef[1] 3.6 1e-6) -and (Near $x2.lap.fit.coef[0] 0 1e-4) -and (Near $x2.lap.fit.r2 1 1e-9))
    $null = Cdp-Eval 'WB.pro.setXY({x:"kmh", y:"latG", ay:true, ax:false, order:3})'; Start-Sleep -Milliseconds 300
    $x3 = Cdp-Json 'WB.pro.xy()'; $f3 = [ProLsq]::Fit($xs, $ys, 3)
    $rel = 0.0; for ($k = 0; $k -lt 4; $k++) { $rel = [math]::Max($rel, [math]::Abs($x3.lap.fit.coef[$k] - $f3[$k]) / [math]::Max(1e-12, [math]::Abs($f3[$k]))) }
    Check 'order 3 (4 coefficients) equals the independent fit as well' ($x3.lap.fit.coef.Count -eq 4 -and $rel -lt 1e-5)
    $null = Cdp-Eval 'WB.pro.setXY({order:0})'; Start-Sleep -Milliseconds 300
    Check 'CURVE OFF draws no curve and the lines under the picture give the points only' ((Cdp-Json 'WB.pro.xy()').lap.fit -eq $null -and (Cdp-Eval 'document.querySelector(".pr-eq").innerText') -match '\d+ points' -and (Cdp-Eval 'document.querySelector(".pr-eq").innerText') -notmatch 'R. 0\.')
    $null = Cdp-Eval 'WB.pro.setXY({x:"kmh", y:"latG", ay:true, order:2})'; Start-Sleep -Milliseconds 300
    $eq = Cdp-Eval 'document.querySelector(".pr-eq").innerText'
    Note ('equation lines on screen: ' + ($eq -replace "`n", ' / '))
    Check 'the equation and R2 are on screen for the lap and the reference ("y = ... x(squared) ... R(squared) 0.xxx")' ($eq -match 'LAP 7' -and $eq -match 'REF 7' -and $eq -match 'y = .* x. .*R. 0\.\d+' -and $eq -notmatch 'the curve explains')
    Check 'the three presets are there (lateral g v speed, rear slip v throttle, long g v brake) and each one draws' ((Cdp-Eval 'document.querySelector(".pr-ctl").innerText') -match 'LATERAL G v SPEED' -and (Cdp-Eval 'document.querySelector(".pr-ctl").innerText') -match 'REAR SLIP v THROTTLE' -and (Cdp-Eval 'document.querySelector(".pr-ctl").innerText') -match 'LONG G v BRAKE')
    foreach ($pr in @(@('slip', 'thrPct', 'slipRear'), @('long', 'brkPct', 'longG'))) {
      $null = Cdp-Eval ('(function(){var b=[].filter.call(document.querySelectorAll(".pr-ctl .pr-btn"),function(e){return e.textContent===' + (ConvertTo-Json $(if ($pr[0] -eq 'slip') { 'REAR SLIP v THROTTLE' } else { 'LONG G v BRAKE' }) -Compress) + '})[0]; b.click(); })()'); Start-Sleep -Milliseconds 500
      $xp = Cdp-Json 'WB.pro.xy()'
      Check "preset $($pr[0]): x = $($pr[1]), y = $($pr[2]), $($xp.lap.n) points and a curve with R2 $([math]::Round($xp.lap.fit.r2, 3))" ($xp.x -eq $pr[1] -and $xp.y -eq $pr[2] -and $xp.lap.n -gt 4000 -and $xp.lap.fit -ne $null)
    }
    # independent rear slip: the mean of the two rear wheel slips, worked out here from the wheel speeds
    $null = Cdp-Eval 'WB.pro.setXY({x:"thrPct", y:"slipRear", ay:false, ax:false, order:1})'; Start-Sleep -Milliseconds 300
    $xs2 = Cdp-Json 'WB.pro.xy()'; $badS = 0
    for ($k = 0; $k -lt $xs2.lap.x.Count; $k++) { $i = $xs2.lap.idx[$k]; $s = [double]$WA['lap.Speed'][$i]; $a = [single]$(if ($s -gt 8) { ([double]$WA['lap.LRspeed'][$i] - $s) / $s * 100 } else { 0 }); $b = [single]$(if ($s -gt 8) { ([double]$WA['lap.RRspeed'][$i] - $s) / $s * 100 } else { 0 }); if (-not (Near $xs2.lap.y[$k] (([double]$a + $b) / 2) 1e-3)) { $badS++ }; if (-not (Near $xs2.lap.x[$k] ([double]$WA['lap.Throttle'][$i] * 100) 1e-3)) { $badS++ } }
    Check 'rear wheel slip (left and right rear wheel slip averaged) and throttle % match the values worked out here from the wheel speeds, point by point' ($badS -eq 0)

    # zoom window: the points inside it are the bright ones
    $null = Cdp-Eval 'WB.pro.setXY({x:"kmh", y:"latG", ay:true, ax:false, c:"brkPct", order:2})'; Start-Sleep -Milliseconds 400
    $null = Cdp-Eval 'WB.cmd("zoom-reset")'; Start-Sleep -Milliseconds 200
    $full = Cdp-Json 'WB.pro.xy()'
    Check 'not zoomed: every point is bright' (-not $full.zoomed -and $full.bright -eq $full.lap.n)
    $null = Cdp-Eval 'WB.cmd("cursor", 3500); WB.cmd("zoom-corner")'; Start-Sleep -Milliseconds 500
    $zm = Cdp-Json 'WB.pro.xy()'; $st = Cdp-Json 'WB.state'
    $z0 = [math]::Floor($st.z0); $z1 = [math]::Ceiling($st.z1); $cnt = 0; for ($k = 0; $k -lt $zm.lap.idx.Count; $k++) { if ($zm.lap.idx[$k] -ge $z0 -and $zm.lap.idx[$k] -le $z1) { $cnt++ } }
    Check "zoomed on a corner ($z0 to $z1 m): exactly the $cnt points of those metres are bright, the other $($zm.lap.n - $cnt) are dim" ($zm.zoomed -and $zm.bright -eq $cnt -and $cnt -gt 100 -and $cnt -lt $zm.lap.n / 3)
    # pixels: an isolated in-zoom point against an isolated out-of-zoom point on the static layer (lap only, no curve, no colour: nothing else is drawn near a point)
    $null = Cdp-Eval 'WB.pro.setXY({laps:"lap", order:0, c:""})'; Start-Sleep -Milliseconds 500
    $js ='(function(z0,z1){var d=WB.displays().filter(function(q){return q.kind==="xy"})[0],s=d.d.lap,r=devicePixelRatio||1,pts=[];for(var i=0;i<s.x.length;i++){if(s.x[i]!==s.x[i])continue;pts.push([i,d.px(s.x[i]),d.py(s.y[i])])}' +
      'function lone(i){for(var k=0;k<pts.length;k++){if(k!==i&&Math.abs(pts[k][1]-pts[i][1])<7&&Math.abs(pts[k][2]-pts[i][2])<7)return false}return true}' +
      'function px(k){var p=d.cs.getImageData(Math.round(pts[k][1]*r)-1,Math.round(pts[k][2]*r)-1,3,3).data,m=0;for(var q=0;q<9;q++)m=Math.max(m,(p[q*4]+p[q*4+1]+p[q*4+2])*p[q*4+3]/255);return Math.round(m)}' +
      'var inK=-1,outK=-1;for(var k=0;k<pts.length&&(inK<0||outK<0);k++){var i=pts[k][0];if(i>=z0&&i<=z1){if(inK<0&&lone(k))inK=k}else{if(outK<0&&lone(k))outK=k}}return {inV:inK>=0?px(inK):-1,outV:outK>=0?px(outK):-1}})'
    $pxv = Cdp-Json ($js + "($z0,$z1)")
    Note "brightness (colour x opacity) of an isolated point inside the window: $($pxv.inV); outside: $($pxv.outV)"
    Check 'on the canvas an in-window point is much brighter than an out-of-window point (the window is linked: the others are dimmed to 16 %)' ($pxv.inV -gt 150 -and $pxv.outV -ge 0 -and $pxv.outV -lt $pxv.inV * 0.5)
    $null = Cdp-Eval 'WB.pro.setXY({laps:"both", order:2, c:"brkPct"})'; Start-Sleep -Milliseconds 400
    # the cursor: a ring on the lap's point, linked to the shared cursor
    $null = Cdp-Eval 'WB.cmd("cursor", 3450)'; Start-Sleep -Milliseconds 300
    $ring = Cdp-Json '(function(){var d=WB.displays().filter(function(q){return q.kind==="xy"})[0],s=d.d.lap,i=3450,r=devicePixelRatio||1,x=d.px(s.x[i]),y=d.py(s.y[i]);var p=d.co.getImageData(Math.round((x+8)*r)-2,Math.round(y*r)-2,5,5).data,m=0,g=0;for(var q=0;q<25;q++){if(p[q*4+3]>150&&p[q*4]>200&&p[q*4+1]>150&&p[q*4+2]<110)g++}return {gold:g,cur:WB.state.cur}})()'
    Check 'the cursor ring of the lap''s point at the cursor is on the overlay in gold (the shared cursor moves it)' ($ring.gold -ge 2 -and $ring.cur -eq 3450)
    # hover on the scatter moves the shared cursor
    $pos = Cdp-Json '(function(){var d=WB.displays().filter(function(q){return q.kind==="xy"})[0],s=d.d.lap,i=1200,r=d.stage.getBoundingClientRect();return {x:r.left+d.px(s.x[i]),y:r.top+d.py(s.y[i]),i:i}})()'
    $null = Cdp 'Input.dispatchMouseEvent' @{ type = 'mouseMoved'; x = [int][math]::Round($pos.x); y = [int][math]::Round($pos.y) }; Start-Sleep -Milliseconds 300
    $hov = Cdp-Json ('(function(mx,my){var d=WB.displays().filter(function(q){return q.kind==="xy"})[0],s=d.d.lap,c=Math.round(WB.state.cur),r=d.stage.getBoundingClientRect();return {cur:WB.state.cur,dist:Math.hypot(r.left+d.px(s.x[c])-mx,r.top+d.py(s.y[c])-my)}})(' + [int][math]::Round($pos.x) + ',' + [int][math]::Round($pos.y) + ')')
    Note "hover over the lap's point at 1200 m: the shared cursor is at $($hov.cur) ($([math]::Round($hov.dist, 1)) px from the mouse)"
    Check 'moving the mouse over the scatter puts the shared cursor on the lap point nearest to it (within 22 px of the mouse; it was at 3450 m)' ($hov.cur -ne 3450 -and $hov.dist -lt 23)
    $null = Cdp-Eval 'WB.cmd("zoom-reset")'; Start-Sleep -Milliseconds 300
    Cdp-Shot (Join-Path $shots 'wb-pro-colour.png')

    # ---- histogram: sums to 100, matches an independent count ----
    $null = Cdp-Eval 'WB.pro.setHist("kmh")'; Start-Sleep -Milliseconds 300
    $hi = Cdp-Json 'WB.pro.hist()'
    $okW = ($hi.w -in 1, 2, 5, 10, 20, 25, 50, 0.5, 0.2, 0.1, 100, 250, 500) -and $hi.nb -ge 8 -and $hi.nb -le 36
    Check "the speed histogram has sensible bins: $($hi.nb) bars of $($hi.w) km/h from $($hi.e0) (a 1-2-5 width, 8 to 36 bars, edges on multiples of the width)" ($okW -and ([math]::Abs($hi.e0 / $hi.w - [math]::Round($hi.e0 / $hi.w)) -lt 1e-9))
    Check 'the bars of the lap add up to 100 % of the lap time, and the reference''s too' ((Near $hi.lap.sum 100 1e-9) -and (Near $hi.ref.sum 100 1e-9))
    # independent count: the time each 1 m sample stands for, in the bin of its km/h
    function Hist-Count($vals, $t, $e0, $w, $nb) {
      $cnt = New-Object 'double[]' $nb; $tot = 0.0; $m = $vals.Length
      for ($i = 0; $i -lt $m; $i++) {
        if ($i -eq 0) { $wt = ($t[1] - $t[0]) / 2 } elseif ($i -eq $m - 1) { $wt = ($t[$m - 1] - $t[$m - 2]) / 2 } else { $wt = ($t[$i + 1] - $t[$i - 1]) / 2 }
        $b = [math]::Floor(($vals[$i] - $e0) / $w + 1e-9); if ($b -lt 0) { $b = 0 }; if ($b -ge $nb) { $b = $nb - 1 }
        $cnt[$b] += $wt; $tot += $wt
      }
      return , @($cnt | ForEach-Object { $_ / $tot * 100 })
    }
    $ind = Hist-Count $xs ($WA['lap.t']) $hi.e0 $hi.w $hi.nb
    $dmax = 0.0; for ($k = 0; $k -lt $hi.nb; $k++) { $dmax = [math]::Max($dmax, [math]::Abs($hi.lap.pct[$k] - $ind[$k])) }
    Check "every bar of the lap equals the independent time-weighted count in its band (largest difference $($dmax.ToString('0.0e+0')) percentage points)" ($dmax -lt 1e-7)
    $ind2 = Hist-Count $xr ($WA['ref.t']) $hi.e0 $hi.w $hi.nb
    $dmax2 = 0.0; for ($k = 0; $k -lt $hi.nb; $k++) { $dmax2 = [math]::Max($dmax2, [math]::Abs($hi.ref.pct[$k] - $ind2[$k])) }
    Check 'and every bar of the reference lap' ($dmax2 -lt 1e-7)
    # against the raw 60 Hz records of the lap: the share of records in each band (the 1 m grid is a resampling, so a small tolerance)
    $rawL = New-Object 'double[]' $ixr.Count; for ($k = 0; $k -lt $ixr.Count; $k++) { $rawL[$k] = $raw['Speed'][$ixr[$k]] * 3.6 }
    $cnt = New-Object 'double[]' $hi.nb; foreach ($v in $rawL) { $b = [math]::Floor(($v - $hi.e0) / $hi.w + 1e-9); if ($b -lt 0) { $b = 0 }; if ($b -ge $hi.nb) { $b = $hi.nb - 1 }; $cnt[$b]++ }
    $dr = 0.0; for ($k = 0; $k -lt $hi.nb; $k++) { $dr = [math]::Max($dr, [math]::Abs($hi.lap.pct[$k] - $cnt[$k] / $rawL.Count * 100)) }
    Note "against the raw 60 Hz records of lap 7 ($($rawL.Count) of them): largest difference in any bar $([math]::Round($dr, 3)) percentage points"
    Check 'against the raw 60 Hz records the share of time in each band is within 0.6 percentage points (a 1 m grid resamples the lap)' ($dr -lt 0.6)
    $null = Cdp-Eval 'WB.pro.setHist("Gear")'; Start-Sleep -Milliseconds 300
    $hg = Cdp-Json 'WB.pro.hist()'
    $gear = New-Object 'double[]' $n; for ($i = 0; $i -lt $n; $i++) { $gear[$i] = $WA['lap.Gear'][$i] }
    $indg = Hist-Count $gear ($WA['lap.t']) $hg.e0 $hg.w $hg.nb; $dg = 0.0; for ($k = 0; $k -lt $hg.nb; $k++) { $dg = [math]::Max($dg, [math]::Abs($hg.lap.pct[$k] - $indg[$k])) }
    Check "gears get one bar per gear (width 1, $($hg.nb) bars), add up to 100 % and equal the independent time in each gear" ($hg.integer -and $hg.w -eq 1 -and (Near $hg.lap.sum 100 1e-9) -and $dg -lt 1e-7)
    $null = Cdp-Eval 'WB.pro.setHist("thrPct")'; Start-Sleep -Milliseconds 300
    $ht = Cdp-Json 'WB.pro.hist()'
    Check "a pedal (0 to 100 %) gets whole-number bands ($($ht.nb) bars of $($ht.w)) and still adds up to 100 % in both laps" ((Near $ht.lap.sum 100 1e-9) -and (Near $ht.ref.sum 100 1e-9) -and $ht.nb -ge 8 -and $ht.nb -le 36)
    Check 'the facts under the histogram (lowest, average, highest, where most time is spent) are on screen with the unit' ((Cdp-Eval 'document.querySelectorAll(".pr-eq")[1].innerText') -match 'lowest .* average .* highest .*most time')
    $null = Cdp-Eval 'WB.pro.setHist("kmh")'; Start-Sleep -Milliseconds 300

    # ---- maths channels on the page ----
    Section '7b. maths channels on the page: add, trace row, saved per car, plain-word errors, no hotkeys while typing'
    $r1 = Cdp-Await 'WB.pro.addMaths("Speed km/h", "Speed * 3.6", "km/h")'
    Start-Sleep -Milliseconds 700
    Check 'adding "Speed * 3.6" works out, saves it and rebuilds the page' ($r1.ok -eq $true -and $r1.key -eq 'm_speed_km_h')
    $mm = @(Cdp-Json 'WB.pro.maths()')
    $Wd = Cdp-Json '(function(){var d=WB.data();return {lap:Array.prototype.slice.call(d.A.c.m_speed_km_h),ref:Array.prototype.slice.call(d.R.c.m_speed_km_h)}})()'
    $bad = 0; for ($i = 0; $i -lt $n; $i++) { if (-not (Near $Wd.lap[$i] ([double]$WA['lap.Speed'][$i] * 3.6) 1e-3) -or -not (Near $Wd.ref[$i] ([double]$WA['ref.Speed'][$i] * 3.6) 1e-3)) { $bad++ } }
    Check 'the channel the page now holds is Speed x 3.6 on every sample of the lap and the reference' ($bad -eq 0 -and $mm.Count -ge 1)
    $kinds = @(Cdp-Json 'WB.displays().map(function(d){return d.kind})')
    Check 'it is shown as a trace row (a trace display with the channel''s name), linked to the page''s cursor and zoom' (($kinds -contains 'traces') -and ((Cdp-Eval 'WB.displays().filter(function(d){return d.kind==="traces"})[0].rows.map(function(r){return r.key}).join(",")') -eq 'm_speed_km_h'))
    Check 'the formula is on screen next to its name: "Speed km/h = Speed * 3.6"' ((Cdp-Eval 'document.querySelector(".pr-mlist").innerText') -match 'Speed km/h' -and (Cdp-Eval 'document.querySelector(".pr-mlist").innerText') -match '= Speed \* 3\.6')
    $trT = Cdp-Eval 'WB.displays().filter(function(d){return d.kind==="traces"})[0].ph.innerText'
    Check 'and in the trace display''s title' ($trT -match 'Speed \* 3\.6')
    $null = Cdp-Eval 'WB.cmd("cursor", 2000)'; Start-Sleep -Milliseconds 300
    $valTxt = Cdp-Json 'WB.textBoxes().filter(function(b){return /^[0-9]+$/.test(b.s)}).map(function(b){return b.s})'
    Check 'the trace row prints the value at the shared cursor (the lap''s km/h at 2000 m)' ((@($valTxt) -contains [string][math]::Round([double]$WA['lap.Speed'][2000] * 3.6)) -or (@($valTxt) -contains [string][math]::Round(([double]$WA['lap.Speed'][2000] * 3.6), 0)))
    $r2 = Cdp-Await 'WB.pro.addMaths("Steering size", "abs(SteeringWheelAngle)", "rad")'; Start-Sleep -Milliseconds 500
    $null = Cdp-Eval 'WB.pro.setXY({x:"m_speed_km_h", y:"m_steering_size", ax:false, ay:false, c:"", order:1})'; Start-Sleep -Milliseconds 500
    $xm = Cdp-Json 'WB.pro.xy()'
    Check 'a maths channel can be the X or Y of the scatter and the colour (here: his own Speed km/h against his own Steering size, with a straight line)' ($xm.x -eq 'm_speed_km_h' -and $xm.y -eq 'm_steering_size' -and $xm.lap.n -eq $n -and $xm.lap.fit -ne $null)
    $null = Cdp-Eval 'WB.pro.setXY({x:"kmh", y:"latG", ay:true, order:2})'; Start-Sleep -Milliseconds 300
    # a wrong formula through the real boxes: the words appear, nothing is saved
    $cnt0 = (Invoke-WebRequest -UseBasicParsing ("$base/formulas?scratch=1&car=" + [uri]::EscapeDataString($car))).Content | ConvertFrom-Json
    $pos = Cdp-Json '(function(){var f=function(s){var r=document.querySelector(s).getBoundingClientRect();return [r.left+r.width/2,r.top+r.height/2]};return {nm:f(".pr-form input:nth-child(1)"),ex:f(".pr-form input:nth-child(2)"),add:f(".pr-add")}})()'
    Cdp-Mouse $pos.nm[0] $pos.nm[1]; $null = Cdp 'Input.insertText' @{ text = 'Oops' }
    Cdp-Mouse $pos.ex[0] $pos.ex[1]; $null = Cdp 'Input.insertText' @{ text = 'Spead * 2' }
    Cdp-Mouse $pos.add[0] $pos.add[1]; Start-Sleep -Milliseconds 900
    $msg = Cdp-Eval 'document.querySelector(".pr-note.err") ? document.querySelector(".pr-note.err").innerText : ""'
    Note "message on screen: $msg"
    $cnt1 = (Invoke-WebRequest -UseBasicParsing ("$base/formulas?scratch=1&car=" + [uri]::EscapeDataString($car))).Content | ConvertFrom-Json
    Check 'a wrong formula typed into the boxes and ADDed shows its sentence ("Unknown name ""Spead"" ... Try Speed.") and saves nothing' ($msg -match 'Unknown name "Spead".*Try Speed\.' -and @($cnt1.formulas).Count -eq @($cnt0.formulas).Count)
    # typing never reaches the page's hotkeys
    $axis0 = Cdp-Eval 'WB.state.axis'; $tile0 = Cdp-Eval 'WB.state.tile'
    Cdp-Mouse $pos.ex[0] $pos.ex[1]; foreach ($ch in 'd', 't', 'z', 'p', 'o') { Cdp-Key $ch }
    Check 'typing the letters d t z p o into the formula box does not switch axis, tile, zoom or page (the page''s hotkeys are off while typing)' ((Cdp-Eval 'WB.state.axis') -eq $axis0 -and (Cdp-Eval 'WB.state.tile') -eq $tile0 -and (Cdp-Eval 'WB.state.page') -eq 'pro' -and (Cdp-Eval 'WB.state.z1 - WB.state.z0 > WB.data().n - 3'))
    Cdp-Close
    # saved per car: a fresh page load finds the formulas again (the server's file, not this browser)
    Cdp-Goto ($pageUrl + '&page=pro')
    $mm2 = @(Cdp-Json 'WB.pro.maths()')
    Check "saved per car: a new page load shows both formulas again ($(($mm2 | ForEach-Object { $_.name }) -join ', ')), worked out on this lap" ($mm2.Count -ge 2 -and @($mm2 | Where-Object { $_.name -eq 'Speed km/h' -and $_.expr -eq 'Speed * 3.6' -and -not $_.err }).Count -eq 1)
    Check 'and they are in the channel picker too (search "steering size")' ((Cdp-Eval 'WB.search("steering size").join("|")') -like '*Steering size*')

    # ---- picker options X/Y and HIST ----
    Section '7c. the channel picker''s X/Y and HIST options'
    $null = Cdp-Eval 'WB.cmd("page","driver")'; Start-Sleep -Milliseconds 400
    Cdp-Key '/'; Start-Sleep -Milliseconds 300
    $null = Cdp 'Input.insertText' @{ text = 'LG' }; Start-Sleep -Milliseconds 300
    $pick = Cdp-Json '(function(){var p=document.querySelector(".picker");return {on:p.className.indexOf("on")>=0,first:p.querySelector(".pr .p1").textContent,acts:[].map.call(p.querySelectorAll(".pbtn"),function(b){return b.textContent})}})()'
    Check 'the picker (key /) has X/Y and HIST buttons under the list; "LG" finds Lateral G first' ($pick.on -and $pick.first -eq 'Lateral G' -and (($pick.acts -join ' ') -match 'X/Y' ) -and (($pick.acts -join ' ') -match 'HIST'))
    Cdp-Shot (Join-Path $shots 'wb-pro-picker.png')
    Cdp-Key 'Enter' 8; Start-Sleep -Milliseconds 600
    $s1 = Cdp-Json '({page:WB.state.page,y:WB.pro.xy().y,open:document.querySelector(".picker").className})'
    Check 'Shift+Enter sends it to the X/Y display: the PRO page opens with Lateral G as the Y channel and the picker closes' ($s1.page -eq 'pro' -and $s1.y -eq 'latG' -and $s1.open -notmatch 'on')
    $null = Cdp-Eval 'WB.cmd("page","driver")'; Start-Sleep -Milliseconds 400
    Cdp-Key '/'; Start-Sleep -Milliseconds 300; $null = Cdp 'Input.insertText' @{ text = 'LG' }; Start-Sleep -Milliseconds 300
    Cdp-Key 'Enter' 2; Start-Sleep -Milliseconds 600
    $s2 = Cdp-Json '({page:WB.state.page,h:WB.pro.hist().key})'
    Check 'Ctrl+Enter sends it to the histogram: the PRO page opens with the histogram of Lateral G' ($s2.page -eq 'pro' -and $s2.h -eq 'latG')
    $null = Cdp-Eval 'WB.pro.setHist("kmh")'
    # the plain Enter still adds a trace row on DRIVER (the C-41 behaviour is intact)
    $null = Cdp-Eval 'WB.cmd("page","driver")'; Start-Sleep -Milliseconds 400
    Cdp-Key '/'; Start-Sleep -Milliseconds 300; $null = Cdp 'Input.insertText' @{ text = 'LG' }; Start-Sleep -Milliseconds 300
    Cdp-Key 'Enter'; Start-Sleep -Milliseconds 600
    Check 'plain Enter still adds the channel as a trace row on DRIVER (the existing picker behaviour)' ((Cdp-Json 'WB.state.extra') -contains 'latG')
    $null = Cdp-Eval 'WB.state.extra.length = 0; WB.cmd("page","pro")'; Start-Sleep -Milliseconds 400

    # ---- export from the page ----
    Section '7d. export from the page: one obvious button'
    $exp = Cdp-Json '(function(){var b=document.querySelector(".pr-go"),r=b.getBoundingClientRect();return {t:b.textContent,x:r.left+r.width/2,y:r.top+r.height/2,w:r.width,h:r.height,chips:[].map.call(document.querySelectorAll(".pr-chips .pr-btn"),function(e){return e.textContent}),sel:WB.pro.exportSel()}})()'
    Check "the first and biggest button is EXCEL .xlsx ($([math]::Round($exp.w)) x $([math]::Round($exp.h)) px), CSV beside it; the chosen channels are chips you can click off (default set + his maths channels: $($exp.sel.Count))" ($exp.t -match 'EXCEL' -and $exp.w -gt 150 -and $exp.h -gt 40 -and $exp.sel.Count -ge 12 -and ($exp.sel -contains '@Speed km/h'))
    Cdp-Mouse $exp.x $exp.y
    $last = $null; for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Milliseconds 300; $last = Cdp-Json 'WB.pro.state.exp.last'; if ($last) { break } }
    Note "after the click: $($last | ConvertTo-Json -Compress)"
    Check 'pressing it makes the file (HTTP 200, a name like Paddock-Road-Atlanta-lap7-2026-10-10.xlsx, a real size) and says where it went' ($last -and $last.name -eq 'Paddock-Road-Atlanta-lap7-2026-10-10.xlsx' -and $last.size -gt 50000 -and (Cdp-Eval 'document.querySelector(".pr-note.ok") ? document.querySelector(".pr-note.ok").innerText : ""') -match 'Saved .*xlsx.*Downloads')
    $bytesX = (Invoke-WebRequest -UseBasicParsing ('http://localhost:8199' + $last.url) -TimeoutSec 90).RawContentStream.ToArray()
    $xl2 = Join-Path $work 'page.xlsx'; [IO.File]::WriteAllBytes($xl2, $bytesX); $z2 = [IO.Compression.ZipFile]::OpenRead($xl2)
    $c2 = [ProXlsx]::Cells($z2.GetEntry('xl/worksheets/sheet1.xml').Open()); $z2.Dispose()
    $hdr2 = @(); for ($c = 0; $c -lt 60; $c++) { $k = [ProXlsx]::Col($c) + '1'; if ($c2.ContainsKey($k)) { $hdr2 += $c2[$k] } else { break } }
    Note ('the page''s file has these columns: ' + ($hdr2 -join ' | '))
    Check 'the file the button fetched holds the chosen channels (the standard ten and his two maths channels) for the lap and the reference, units in the header' ($hdr2.Count -eq 3 + 2 * 12 -and ($hdr2 -contains 'Speed km/h (km/h) lap 7') -and ($hdr2 -contains 'Steering size (rad) ref 7') -and ($hdr2 -contains 'Chassis slip angle (deg) lap 7'))
    $null = Cdp-Eval 'window.__fx = 0; var __of = window.fetch; window.fetch = function (u) { if (String(u).indexOf("/export") >= 0) window.__fx++; return __of.apply(this, arguments); }'
    Start-Sleep -Milliseconds 900
    Cdp-Mouse $exp.x $exp.y; Cdp-Mouse $exp.x $exp.y; Cdp-Mouse $exp.x $exp.y; Start-Sleep -Milliseconds 1800
    Check 'a button pressed 3 times in a row (a Stream Deck key can arrive 2-3 times) asks for the file once' ((Cdp-Eval 'window.__fx') -eq 1)
    # chips toggle
    $null = Cdp-Eval '[].filter.call(document.querySelectorAll(".pr-chips .pr-btn"),function(e){return e.textContent==="Gear"})[0].click()'; Start-Sleep -Milliseconds 300
    Check 'clicking a chip leaves that channel out of the export' (-not ((Cdp-Json 'WB.pro.exportSel()') -contains 'Gear') -and ((Cdp-Eval 'WB.pro.exportUrl("csv")') -notmatch 'Gear'))
    $null = Cdp-Eval 'localStorage.removeItem("wbProExp")'

    # ---- layout, pictures, speed ----
    Section '7e. layout, pictures, speed'
    $null = Cdp-Eval 'WB.pro.setXY({x:"kmh", y:"latG", ay:true, ax:false, c:"", order:2}); WB.pro.setHist("kmh"); WB.cmd("zoom-reset"); WB.cmd("cursor", 1500)'; Start-Sleep -Milliseconds 700
    $ov = Cdp-Json 'WB.overlaps()'
    Note "text boxes measured: $($ov.boxes)"; if ($ov.bad.Count) { Note ('overlapping: ' + ($ov.bad -join '; ')) }
    Check 'no text overlaps another on the PRO page (canvas and DOM boxes measured)' ($ov.boxes -gt 120 -and $ov.bad.Count -eq 0)
    $off = Cdp-Json '(function(){var o=[];WB.textBoxes().concat(WB.domBoxes()).forEach(function(q){if(q.x<-0.5||q.x+q.w>1920.5||q.y<-0.5||q.y+q.h>1080.5)o.push(q.s+"@"+Math.round(q.x)+","+Math.round(q.y))});return o})()'
    Check 'nothing sits outside the 1920x1080 screen' (@($off | Where-Object { $_ }).Count -eq 0)
    $pan = Cdp-Json '(function(){var r=[].map.call(document.querySelectorAll(".panel"),function(p){var b=p.getBoundingClientRect();return {x:b.left,y:b.top,r:b.right,b:b.bottom}}),bad=[];for(var i=0;i<r.length;i++){if(r[i].b>1080.5||r[i].r>1920.5)bad.push("off "+i);for(var j=i+1;j<r.length;j++){var p=r[i],q=r[j];if(p.x<q.r-1&&q.x<p.r-1&&p.y<q.b-1&&q.y<p.b-1)bad.push(i+"x"+j)}}return {n:r.length,bad:bad}})()'
    Check "the $($pan.n) panels do not overlap each other and all sit inside the screen" ($pan.n -ge 5 -and @($pan.bad).Count -eq 0)
    $small = Cdp-Json '(function(){var o=[];WB.textBoxes().forEach(function(b){if(b.h<12)o.push(b.s)});return o})()'
    Check 'canvas labels are 14 px or larger' (@($small | Where-Object { $_ -and $_ -notmatch '^[0-9A-Za-z]{1,3}$' }).Count -eq 0)
    $fit = Cdp-Json '(function(){var t=document.getElementById("tabs");t.className="tabs many";t.innerHTML=["DRIVER","GRIP","BRAKING","TYRES","SUSP.","SPLITS","VIDEO","RACE","CAREER","PRO"].map(function(n){return "<span>"+n+"</span>"}).join("");var r=t.getBoundingClientRect(),vs=document.getElementById("vs").getBoundingClientRect();return {right:r.right,vsLeft:vs.left}})()'
    Note "ten tabs (DRIVER ... CAREER, PRO): they end at $([math]::Round($fit.right)) px, the lap times start at $([math]::Round($fit.vsLeft)) px"
    Check 'ten tabs including PRO still fit the header with at least 100 px before the lap times' ($fit.right + 100 -lt $fit.vsLeft)
    $null = Cdp-Eval 'WB.cmd("page","pro")'; Start-Sleep -Milliseconds 500
    $perf = Cdp-Json '({cursor:WB.bench(200,false),full:WB.bench(20,true)})'
    Note "frame time on the PRO page (headless, software rendering): cursor move $([math]::Round($perf.cursor, 2)) ms, full redraw on a zoom change $([math]::Round($perf.full, 2)) ms"
    Check 'the cursor frame is under 4 ms and a full redraw under 25 ms (the budget is 16.7 ms at 60 fps; the top screen has a GPU)' ($perf.cursor -lt 4 -and $perf.full -lt 25)
    $null = Cdp-Eval 'WB.cmd("cursor", 1500)'; Start-Sleep -Milliseconds 400
    Cdp-Shot (Join-Path $shots 'wb-pro.png')
    # clean up what the page saved in the scratch store
    foreach ($nm in 'Speed km/h', 'Steering size') { $null = Cdp-Eval ('WB.pro.removeMaths(' + (ConvertTo-Json $nm -Compress) + ')') }
    Start-Sleep -Milliseconds 500
    Check 'no JavaScript exception during the whole page run' ($script:cdp.errors.Count -eq 0)
    if ($script:cdp.errors.Count) { Note ($script:cdp.errors -join ' / ') }
    Cdp-Close

    Section '7f. the tab rule: only where it works'
    Cdp-Goto ($pageUrl + '&probase=' + [uri]::EscapeDataString('/analysis/nopro/') + '&page=pro')
    $pgNo = @(Cdp-Json 'WB.pages()')
    Check 'a server without the pro routes (answers 404): no PRO tab, no error on screen, and &page=pro opens DRIVER' (($pgNo -notcontains 'pro') -and (Cdp-Eval 'WB.state.page') -eq 'driver' -and (Cdp-Eval 'document.getElementById("tabs").innerText') -notmatch 'PRO' -and -not (Cdp-Eval 'WB.error || ""'))
    Check 'the DRIVER page is untouched (its + CHANNEL still works) and the deck is not told about a page that does not exist' ((Cdp-Eval 'WB.deck()') -notmatch 'pgs=[^&]*pro')
    Cdp-Close
    # a fixture page (no server behind it: the file of one lap) has no PRO tab either: the maths and the export need the server
    $fxUrl = 'file:///' + (Join-Path $work 'lap7full.bin').Replace('\', '/')
    Cdp-Goto ('file:///' + (Join-Path $root 'dash\www\v2\workbench.html').Replace('\', '/') + '?data=' + [uri]::EscapeDataString($fxUrl))
    Check 'a page opened from a fixture file (no server) offers no PRO tab and shows no error' ((@(Cdp-Json 'WB.pages()') -notcontains 'pro') -and -not (Cdp-Eval 'WB.error || ""') -and $script:cdp.errors.Count -eq 0)
    Cdp-Close
  }
}
finally {
  Cdp-Close
  # the scratch store of the test (never his saved formulas)
  foreach ($nm in 'Speed km/h', 'Steering size', 'Oops', 'T') { try { $null = Invoke-WebRequest -UseBasicParsing ("http://localhost:8199/analysis/pro/delete?scratch=1&car=" + [uri]::EscapeDataString($car) + "&name=" + [uri]::EscapeDataString($nm)) -TimeoutSec 5 } catch { } }
  $sd = Join-Path $root 'data\maths-test'; if (Test-Path -LiteralPath $sd) { Get-ChildItem $sd -Filter '*.txt' | Where-Object { $_.Length -eq 0 } | Remove-Item -Force -ErrorAction SilentlyContinue; if (-not (Get-ChildItem $sd)) { Remove-Item $sd -Force -ErrorAction SilentlyContinue } }
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
  Assert-RigFree -Where 'done'
}
Write-Host "`npro-tools-test: $pass passed, $fail failed. Pictures in $shots (wb-pro*.png). $([math]::Round($t0.Elapsed.TotalSeconds)) s"
if ($fail -gt 0) { exit 1 }
