# rigpage-test.ps1 - offline (W5-1): RIG's two switches (dash\src\rigpage.cs) on a pretend irdash. A throw-away exe built from dash\src
# + tests\rigpage-main.cs runs irdash's real Server on port 8371 (never 8199, never the live irdash, clear of the 8297-8312 and 8341 other tests use) with a throw-away ini and a copied
# registry tree under HKCU\Software\PaddockTest (HKLM is only read; the test key is deleted at the end):
#   1. the mic names ("Headset (Arctis 7P+)"), the reader on a made-up tree (active only, sorted, the default), the copy of this PC's devices
#   2. GET /api/settings, startupsound on/off (read back, the ini), a bad argument 400, mic next x4 wraps round, a mic by name,
#      an unknown name refused (400), mic default, the repeat guard, the "settings" and "ac" parts in /state
#   3. source: startup.js asks /api/settings (300 ms) and stays silent when it says false; player.js opens the chosen mic by its label
#   powershell -ExecutionPolicy Bypass -File tests\rigpage-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }
$tmp = Join-Path $env:TEMP ('rigpage-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null

'W5-1 RIG settings (irdash Server on port 8371)'
try {
  $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  $b = Get-Content (Join-Path $root 'dash\build.ps1') -Raw
  $srcs = @([regex]::Matches($b, '"\$d\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('dash\src\' + $_.Groups[1].Value) })
  $srcs += @([regex]::Matches($b, '"\.\.\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('src\' + $_.Groups[1].Value) })
  ok 'dash\build.ps1 names rigpage.cs' (($srcs -match 'rigpage\.cs').Count -eq 1)
  $srcs += (Join-Path $PSScriptRoot 'rigpage-main.cs')
  $exe = Join-Path $tmp 'rigpage.exe'
  $cout = & $csc /nologo /target:exe /optimize+ /platform:anycpu /main:IRDash.RigPageMain "/out:$exe" /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll @srcs 2>&1 | Out-String
  ok "the harness (dash\src + tests\rigpage-main.cs, $($srcs.Count) files) compiles (C# 5)" (Test-Path $exe) ($cout -split "`n" | Select-String 'error' | Select-Object -First 5 | Out-String)

  $www = Join-Path $tmp 'www'; New-Item -ItemType Directory -Force (Join-Path $www 'app') | Out-Null
  Set-Content -Encoding utf8 (Join-Path $www 'app\index.html') '<!doctype html><title>t</title>'
  $ini = Join-Path $tmp 'irdash.ini'; Set-Content -Encoding ascii $ini "; throw-away`r`nport=8371"
  if (Test-Path $exe) {
    Assert-RigFree -Where 'the harness'
    $psi = New-Object Diagnostics.ProcessStartInfo $exe
    $psi.Arguments = "8371 `"$www`" `"$ini`""
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    $pr = [Diagnostics.Process]::Start($psi); try { $pr.PriorityClass = 'BelowNormal' } catch { }
    $out = $pr.StandardOutput.ReadToEnd(); $null = $pr.WaitForExit(120000)
    foreach ($l in ($out -split "`r?`n")) {
      if ($l -match '^\s+ok\s+(.*)$') { $script:pass++; "  ok   $($Matches[1])" }
      elseif ($l -match '^\s+FAIL\s+(.*)$') { $script:fail++; "  FAIL $($Matches[1])" }
      elseif ($l -match '^(Section|\s+info)') { $l }
    }
    ok 'the harness ran to the end' ($out -match 'result: \d+ ok') ($out.Substring([Math]::Max(0, $out.Length - 400)))
    ok 'nothing was left under HKCU\Software\PaddockTest by this run' (-not (Test-Path "HKCU:\Software\PaddockTest\rigpage-$($pr.Id)"))
  }

  'Section 3. who reads the switches (source)'
  $st = [IO.File]::ReadAllText((Join-Path $root 'dash\www\app\pages\startup.js'))
  ok 'startup.js asks /api/settings once per play with a 300 ms limit and keeps the tones when there is no answer' ($st -match "fetch\('/api/settings'" -and $st -match '300' -and $st -match 'catch \(e\) \{ return true; \}')
  ok 'startup.js plays silent when startupSound is false (quiet hours still apply)' ($st -match 'j\.startupSound === false' -and $st -match 'play\(el, \{ sound: sound, quiet: isQuietHours\(\)')
  $pl = [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\player.js'))
  ok 'player.js: after getUserMedia, enumerateDevices and the deviceId whose label contains the chosen name (else Windows'' default)' ($pl -match 'enumerateDevices\(\)' -and $pl -match "deviceId: \{ exact: dev\.deviceId \}" -and $pl -match "send\('/api/settings'\)" -and $pl -match 'label\)\.toLowerCase\(\)\.indexOf\(want\)')
  ok 'player.js still records which mic was used (the track label)' ($pl.Contains('this.mic = track.label'))
  $dc = [IO.File]::ReadAllText((Join-Path $root 'dash\src\doctor.cs'))
  ok 'Doctor''s graphics check takes the frame limit from SimSettings.FpsCap, no literal 160' ($dc -match 'SimSettings\.FpsCap\(v\)' -and $dc -notmatch 'DesiredFPSLimit"\) == "160"')
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
"rigpage-test: $($script:pass) ok, $($script:fail) FAIL"
if ($script:fail -gt 0) { exit 1 }
