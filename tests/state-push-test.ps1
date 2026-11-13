# state-push-test.ps1 - offline (W0-5): irdash's one state push, from a throw-away exe built from dash\src + tests\state-push-main.cs that runs
# irdash's real Server on port 8296 over a throw-away www folder (never 8199, never the live irdash, no SDK reader, no deck, no iRacing):
#   1. GET /state has every part (kids, tow, keymsg, the four page requests, guest, mydrive, doctor, overlays, recorder, health, showcase,
#      rig, version, session, lists, seq)        2. seq moves only when a part changes (a seconds counter is not a change)
#   3. /stream?state=1 pushes event: state within 300 ms of Changed(); at most 4 pushes a second; an old stream gets none
#   4. ?v=<version> scripts are kept for good, everything else no-store; pages name their scripts with ?v=; /version follows a file change
#   5. keep-alive: two requests on one connection; Connection: close is honoured; 30 at once all answered
#   6. /deck/summary has every opener key's part; the session YAML is parsed into the fields the pages read
#   powershell -ExecutionPolicy Bypass -File tests\state-push-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }
$tmp = Join-Path $env:TEMP ('state-push-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null

'W0-5 state push (irdash Server on port 8296)'
try {
  # the harness: the build.ps1 source list + tests\state-push-main.cs
  $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  $b = Get-Content (Join-Path $root 'dash\build.ps1') -Raw
  $srcs = @([regex]::Matches($b, '"\$d\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('dash\src\' + $_.Groups[1].Value) })
  $srcs += @([regex]::Matches($b, '"\.\.\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('src\' + $_.Groups[1].Value) })
  $srcs += (Join-Path $PSScriptRoot 'state-push-main.cs')
  $exe = Join-Path $tmp 'state-push.exe'
  $cout = & $csc /nologo /target:exe /optimize+ /platform:anycpu /main:IRDash.StatePushMain "/out:$exe" /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll @srcs 2>&1 | Out-String
  ok "the harness (dash\src + tests\state-push-main.cs, $($srcs.Count) files) compiles" (Test-Path $exe) ($cout -split "`n" | Select-String 'error' | Select-Object -First 5 | Out-String)

  # a small www: one page naming a script and a style (and links that must stay as they are)
  $www = Join-Path $tmp 'www'; New-Item -ItemType Directory -Force (Join-Path $www 'v2') | Out-Null
  Set-Content -Encoding utf8 (Join-Path $www 'v2\a.js') '/* a */'
  Set-Content -Encoding utf8 (Join-Path $www 'v2\s.css') 'body{}'
  Set-Content -Encoding utf8 (Join-Path $www 'v2\page.html') '<!doctype html><link rel="stylesheet" href="s.css"><script src="a.js"></script><script src="https://example.invalid/x.js"></script><img src="pic.png"><script src="b.js?x=1"></script>'
  # the session YAML of the 12 Nov race fixture (tests\tools\ibt-cut.ps1), when it is on this PC
  $yaml = ''
  $ibt = Join-Path $root 'tests\fixtures\race-12nov.ibt'
  if (Test-Path $ibt) {
    $fs = [IO.File]::Open($ibt, 'Open', 'Read', 'ReadWrite')
    try { $h = New-Object byte[] 144; [void]$fs.Read($h, 0, 144); $len = [BitConverter]::ToInt32($h, 16); $off = [BitConverter]::ToInt32($h, 20); $buf = New-Object byte[] $len; $fs.Position = $off; [void]$fs.Read($buf, 0, $len) } finally { $fs.Dispose() }
    $z = [Array]::IndexOf($buf, [byte]0); if ($z -lt 0) { $z = $len }
    $yaml = Join-Path $tmp 'session.yaml'; [IO.File]::WriteAllBytes($yaml, $buf[0..($z - 1)])
  } else { '  skip tests\fixtures\race-12nov.ibt is not here (tests\tools-test.ps1 builds it): no session YAML checks' }

  if (Test-Path $exe) {
    Assert-RigFree -Where 'the harness'
    $psi = New-Object Diagnostics.ProcessStartInfo $exe
    $psi.Arguments = "8296 `"$www`"" + $(if ($yaml) { " `"$yaml`"" } else { '' })
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    $pr = [Diagnostics.Process]::Start($psi); try { $pr.PriorityClass = 'BelowNormal' } catch { }
    $out = $pr.StandardOutput.ReadToEnd(); $null = $pr.WaitForExit(120000)
    foreach ($l in ($out -split "`r?`n")) {
      if ($l -match '^\s+ok\s+(.*)$') { $script:pass++; "  ok   $($Matches[1])" }
      elseif ($l -match '^\s+FAIL\s+(.*)$') { $script:fail++; "  FAIL $($Matches[1])" }
      elseif ($l -match '^(Section|\s+info)') { $l }
    }
    ok 'the harness ran to the end' ($out -match 'result: \d+ ok') ($out.Substring([Math]::Max(0, $out.Length - 400)))
  }
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
"state-push-test: $($script:pass) ok, $($script:fail) FAIL"
if ($script:fail -gt 0) { exit 1 }
