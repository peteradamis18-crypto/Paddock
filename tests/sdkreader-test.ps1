# sdkreader-test.ps1 (W2-1) - the SDK reader on its own (dash\src\sdkreader.cs): the session YAML parsed once per SessionVersion into
# Sdk.Session, the race channel set on /stream?set=race (exactly 24 keys, 15 Hz), ?vars= unchanged, and the race state part
# (statebuilder.cs RacePart: every contract name, null out of a session, at most 4 changes a second at 20x).
# OFFLINE: a throw-away exe built from dash\src (the build.ps1 list) + tests\sdkreader-main.cs runs irdash's real Sdk pretend-session pump,
# IbtReplay and Server on port 8291 (never 8199) and plays tests\fixtures\race-12nov.ibt (cut from the old 12 Nov file when missing).
# No SDK shared memory, no iRacing, no deck, no live irdash.
#   powershell -ExecutionPolicy Bypass -File tests\sdkreader-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }
$tmp = Join-Path $env:TEMP ('sdkreader-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
$fx = Join-Path $root 'tests\fixtures'; $race = Join-Path $fx 'race-12nov.ibt'
$source = 'C:\Users\peter\OneDrive\Documents\iRacing\telemetry\toyotagr86_roadatlanta full 2026-11-12 09-28-07.ibt'
$port = 8291

'W2-1 SDK reader (irdash Server on port 8291)'
try {
  Assert-RigFree -Where '0. compile'
  'Section 0. the harness'
  $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  $b = Get-Content (Join-Path $root 'dash\build.ps1') -Raw
  $srcs = @([regex]::Matches($b, '"\$d\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('dash\src\' + $_.Groups[1].Value) })
  $srcs += @([regex]::Matches($b, '"\.\.\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('src\' + $_.Groups[1].Value) })
  $srcs += (Join-Path $PSScriptRoot 'sdkreader-main.cs')
  $exe = Join-Path $tmp 'sdkreader.exe'
  $cout = & $csc /nologo /target:exe /optimize+ /platform:anycpu /main:IRDash.SdkReaderMain "/out:$exe" /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll @srcs 2>&1 | Out-String
  ok "the harness (dash\src + tests\sdkreader-main.cs, $($srcs.Count) files) compiles" (Test-Path $exe) ($cout -split "`n" | Select-String 'error' | Select-Object -First 5 | Out-String)
  if (-not (Test-Path $race) -and (Test-Path $source)) { & (Join-Path $root 'tests\tools\ibt-cut.ps1') -Source $source -Out $race -From 200 -To 380 | Out-Null }
  ok 'the fixture tests\fixtures\race-12nov.ibt is here' (Test-Path $race)

  Assert-RigFree -Where '0b. source'
  'Section 0b. the move (source)'
  $ird = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs'))
  $sdk = [IO.File]::ReadAllText((Join-Path $root 'dash\src\sdkreader.cs'))
  ok 'the Sdk class left irdash.cs and lives in sdkreader.cs' ($ird -notmatch 'static class Sdk\b' -and $sdk -match 'static class Sdk\b')
  ok 'irdash.cs keeps the "iRacing SDK reader" marker right after IbtReplay (tools-test and blackbox-test cut IbtReplay up to it)' ($ird.IndexOf('    // ---------------- iRacing SDK reader') -gt $ird.IndexOf('    // ---------------- Telemetry replay'))
  ok 'ReadYaml runs only when iRacing''s SessionInfoUpdate moves' ($sdk -match 'if \(upd != lastUpd\) \{ yaml = ReadYaml\(va\); lastUpd = upd; sessVer\+\+; \}')
  ok 'the session is parsed in Publish, before the frame is out' ($sdk -match '(?s)static void Publish\(Frame f\)\s*\{\s*ParseSession\(f\);')
  ok '/stream takes ?set= (Sdk.SetNames) and sends every key of a set' ($ird -match 'Sdk\.SetNames\(setName\)' -and $ird -match 'Sdk\.FrameJson\(f, names, setNames != null\)')
  ok 'the race part is made on the state builder''s tick (StateBuilder.Add("race", 250, 250, ...)); no new poller' ($ird -match 'StateBuilder\.Add\("race", 250, 250, StateBuilder\.RacePart\);')
  ok 'sdkreader.cs stays C# 5 (no $", ?., nameof, out var)' (-not ($sdk -match '(^|[\s(=,+])\$"|\?\.[A-Za-z]|nameof\(|out var '))

  if ((Test-Path $exe) -and (Test-Path $race)) {
    Assert-RigFree -Where '1-4. run'
    $www = Join-Path $tmp 'www'; New-Item -ItemType Directory -Force (Join-Path $www 'v2') | Out-Null
    Set-Content -Encoding utf8 (Join-Path $www 'v2\index.html') '<!doctype html><title>t</title>'
    $p = New-Object Diagnostics.ProcessStartInfo $exe
    $p.Arguments = "$port `"$www`" `"$race`""; $p.UseShellExecute = $false; $p.RedirectStandardOutput = $true; $p.CreateNoWindow = $true
    $pr = [Diagnostics.Process]::Start($p); try { $pr.PriorityClass = 'BelowNormal'; $pr.ProcessorAffinity = [IntPtr]3 } catch { }
    $lines = $pr.StandardOutput.ReadToEnd() -split "`r?`n"; $pr.WaitForExit()
    foreach ($l in $lines) {
      if ($l -match '^\s+ok\s+(.*)') { ok $Matches[1] $true } elseif ($l -match '^\s+FAIL\s+(.*)') { ok $Matches[1] $false } elseif ($l -match '^(Section|\s+info)') { $l }
    }
    ok 'the harness ran to the end' ($lines -contains 'DONE')
  }
} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
"`n$($script:pass) ok, $($script:fail) FAIL"
if ($script:fail -gt 0) { exit 1 }
